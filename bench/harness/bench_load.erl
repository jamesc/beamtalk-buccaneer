%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc The HTTP load generator. Closed loop: each worker sends one
%% request (or WebSocket message, or HTTP/2 stream) and waits for the
%% whole answer before the next. Workers read the phase from a shared
%% `atomics` cell and record into shared `counters` and an `hb_hist`, as
%% Catalina's `bench_load`; only the measured phase counts.
%%
%% Every response is checked: status 200 and, where the row says, the body
%% size. A bad answer is an error, and the worker stops.
-module(bench_load).

-export([http/2, churn/2, h2/2, ws/2, open_idle/3, close_idle/1, wait_ready/3]).

-define(WARMUP, 0).
-define(MEASURE, 1).
-define(STOP, 2).

%% === Rows ===

%% Keep-alive HTTP/1.1. Params: conns, tls, method, path, body, expect
%% (body size, or `any`). A response with `connection: close` (cowboy
%% closes after `max_keepalive`, 1,000 requests) is counted as a server
%% close and the worker reconnects; the reconnect lands in the next
%% request's latency, as a real client sees it.
http(Port, P) ->
    Tls = maps:get(tls, P, false),
    Req = iolist_to_binary(bench_http:request(maps:get(method, P, <<"GET">>), maps:get(path, P, <<"/">>),
                                              maps:get(headers, P, []), maps:get(body, P, <<>>))),
    Expect = maps:get(expect, P, any),
    run(maps:get(conns, P), P, fun(Ctx) ->
        case bench_conn:connect(Port, Tls) of
            {ok, C} ->
                ready(Ctx),
                http_loop(Port, Tls, C, <<>>, Req, Expect, Ctx);
            {error, R} -> failed(Ctx, R)
        end
    end).

http_loop(Port, Tls, C, Buf, Req, Expect, Ctx) ->
    case phase(Ctx) of
        ?STOP -> bench_conn:close(C);
        Phase ->
            T0 = erlang:monotonic_time(),
            R = case bench_conn:send(C, Req) of
                ok -> bench_http:read_response(C, Buf);
                E -> E
            end,
            case R of
                {ok, Resp = {200, Close, _}, Rest} ->
                    case expect(Expect, Resp) of
                        ok ->
                            done(Ctx, Phase, T0, bench_http:body_size(Resp)),
                            case Close of
                                false -> http_loop(Port, Tls, C, Rest, Req, Expect, Ctx);
                                true ->
                                    counters:add(maps:get(ops, Ctx), 2, 1),
                                    bench_conn:close(C),
                                    case bench_conn:connect(Port, Tls) of
                                        {ok, C2} -> http_loop(Port, Tls, C2, <<>>, Req, Expect, Ctx);
                                        Other -> error_in(Ctx, Other)
                                    end
                            end;
                        Bad ->
                            bench_conn:close(C),
                            error_in(Ctx, Bad)
                    end;
                {ok, Resp, _} ->
                    bench_conn:close(C),
                    error_in(Ctx, {status, bench_http:status(Resp)});
                Other ->
                    bench_conn:close(C),
                    error_in(Ctx, Other)
            end
    end.

expect(any, _) -> ok;
expect(N, Resp) ->
    case bench_http:body_size(Resp) of
        N -> ok;
        M -> {body_size, M, expected, N}
    end.

%% A new connection per request, `connection: close` (TLS: a full
%% handshake each time). Params: workers, tls. The latency covers connect,
%% handshake, request and response.
churn(Port, P) ->
    Tls = maps:get(tls, P, false),
    Req = iolist_to_binary(bench_http:get(<<"/">>, [{<<"connection">>, <<"close">>}])),
    run(maps:get(workers, P), P, fun(Ctx) ->
        ready(Ctx),
        churn_loop(Port, Tls, Req, Ctx)
    end).

churn_loop(Port, Tls, Req, Ctx) ->
    case phase(Ctx) of
        ?STOP -> ok;
        Phase ->
            T0 = erlang:monotonic_time(),
            R = case bench_conn:connect(Port, Tls, 1) of
                {ok, C} ->
                    Res = case bench_conn:send(C, Req) of
                        ok -> bench_http:read_response(C, <<>>);
                        E -> E
                    end,
                    bench_conn:close(C),
                    Res;
                E -> {connect, E}
            end,
            case R of
                {ok, {200, _, _}, _} ->
                    done(Ctx, Phase, T0, 0),
                    churn_loop(Port, Tls, Req, Ctx);
                Other ->
                    error_in(Ctx, Other)
            end
    end.

%% HTTP/2 GET over prior-knowledge h2c. Params: conns, streams (in
%% flight per connection).
h2(Port, P) ->
    K = maps:get(streams, P),
    run(maps:get(conns, P), P, fun(Ctx) ->
        case bench_h2:connect(Port) of
            {ok, H0} ->
                ready(Ctx),
                {Inflight, H1} = lists:foldl(fun(_, {M, H}) ->
                    {Id, H2} = bench_h2:request(H, <<"/">>),
                    {M#{Id => erlang:monotonic_time()}, H2}
                end, {#{}, H0}, lists:seq(1, K)),
                h2_loop(H1, Inflight, Ctx);
            {error, R} -> failed(Ctx, R)
        end
    end).

h2_loop(H, Inflight, Ctx) ->
    case bench_h2:next_event(H) of
        {done, Id, 200, H1} ->
            {T0, In1} = maps:take(Id, Inflight),
            case phase(Ctx) of
                ?STOP when map_size(In1) =:= 0 -> bench_h2:close(H1);
                ?STOP -> h2_loop(H1, In1, Ctx);
                Phase ->
                    done(Ctx, Phase, T0, 0),
                    {Id2, H2} = bench_h2:request(H1, <<"/">>),
                    h2_loop(H2, In1#{Id2 => erlang:monotonic_time()}, Ctx)
            end;
        {done, Id, Status, _} -> error_in(Ctx, {h2_status, Id, Status});
        {reset, Id, _} -> error_in(Ctx, {h2_reset, Id});
        {error, R} -> error_in(Ctx, R)
    end.

%% WebSocket echo. Params: conns, size (bytes per text message).
ws(Port, P) ->
    Msg = binary:copy(<<"a">>, maps:get(size, P, 64)),
    run(maps:get(conns, P), P, fun(Ctx) ->
        case bench_ws:connect(Port) of
            {ok, W} ->
                ready(Ctx),
                ws_loop(W, Msg, Ctx);
            {error, R} -> failed(Ctx, R)
        end
    end).

ws_loop(W, Msg, Ctx) ->
    case phase(Ctx) of
        ?STOP -> bench_ws:close(W);
        Phase ->
            T0 = erlang:monotonic_time(),
            case bench_ws:echo(W, Msg) of
                {ok, W1} ->
                    done(Ctx, Phase, T0, byte_size(Msg)),
                    ws_loop(W1, Msg, Ctx);
                Other -> error_in(Ctx, Other)
            end
    end.

%% === Idle connections ===

%% Open N keep-alive connections, 200 at a time, and send each one GET so
%% the server has a request behind it (a connection that never sent one
%% is not yet an HTTP connection on every server). Answers
%% `{Owner, Opened, Failures}`; the sockets stay open until `close_idle/1`.
open_idle(Port, N, Tls) ->
    Self = self(),
    Owner = spawn(fun() -> idle_owner(Self, Port, N, Tls) end),
    receive {Owner, Opened, Failures} -> {Owner, Opened, Failures} end.

idle_owner(Parent, Port, N, Tls) ->
    Req = iolist_to_binary(bench_http:get(<<"/">>)),
    Batches = chunks(lists:seq(1, N), 200),
    Results = lists:append([pmap(fun(_) -> open_one(Port, Tls, Req) end, B) || B <- Batches]),
    Conns = [C || {ok, C} <- Results],
    Parent ! {self(), length(Conns), [E || E = {error, _} <- Results]},
    receive close -> [bench_conn:close(C) || C <- Conns] end,
    Parent ! {self(), closed}.

open_one(Port, Tls, Req) ->
    case bench_conn:connect(Port, Tls) of
        {ok, C} ->
            case bench_conn:send(C, Req) =:= ok andalso bench_http:read_response(C, <<>>) of
                {ok, {200, false, _}, <<>>} -> {ok, C};
                Other -> bench_conn:close(C), {error, Other}
            end;
        E -> E
    end.

%% Sockets belong to the process that opened them; hand them to the owner.
pmap(F, L) ->
    Self = self(),
    Pids = [spawn(fun() ->
        R = F(X),
        case R of
            {ok, {tcp, S}} -> gen_tcp:controlling_process(S, Self);
            {ok, {ssl, S}} -> ssl:controlling_process(S, Self);
            _ -> ok
        end,
        Self ! {self(), R}
    end) || X <- L],
    [receive {P, R} -> R end || P <- Pids].

chunks([], _) -> [];
chunks(L, N) when length(L) =< N -> [L];
chunks(L, N) -> {A, B} = lists:split(N, L), [A | chunks(B, N)].

close_idle({Owner, _, _}) ->
    Owner ! close,
    receive {Owner, closed} -> ok after 120000 -> ok end.

%% === Readiness ===

%% Wait until the server answers a GET, for up to `Ms`.
wait_ready(Port, Tls, Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    wait_ready_loop(Port, Tls, Deadline).

wait_ready_loop(Port, Tls, Deadline) ->
    Ok = case bench_conn:connect(Port, Tls, 1) of
        {ok, C} ->
            R = bench_conn:send(C, bench_http:get(<<"/">>)) =:= ok
                andalso bench_http:read_response(C, <<>>),
            bench_conn:close(C),
            case R of {ok, {200, _, _}, _} -> true; _ -> false end;
        _ -> false
    end,
    case Ok of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> error({server_not_ready, Port});
                false ->
                    timer:sleep(100),
                    wait_ready_loop(Port, Tls, Deadline)
            end
    end.

%% === The worker pool ===

run(N, Opts, Body) ->
    Ctx = #{
        phase => atomics:new(1, []),
        %% 1: operations, 2: server closes, 3: body bytes
        ops => counters:new(3, [write_concurrency]),
        hist => hb_hist:new(),
        coordinator => self()
    },
    Pids = [spawn(fun() -> Body(Ctx) end) || _ <- lists:seq(1, N)],
    {Ready, Failed} = await_ready(length(Pids), 0, 0),
    case Ready of
        0 ->
            atomics:put(maps:get(phase, Ctx), 1, ?STOP),
            [exit(P, kill) || P <- Pids],
            #{errors => N, error_reasons => [no_connections | collect_errors([])]};
        _ ->
            timer:sleep(maps:get(warmup_ms, Opts, 1000)),
            T0 = erlang:monotonic_time(),
            atomics:put(maps:get(phase, Ctx), 1, ?MEASURE),
            timer:sleep(maps:get(duration_ms, Opts, 5000)),
            atomics:put(maps:get(phase, Ctx), 1, ?STOP),
            T1 = erlang:monotonic_time(),
            Secs = erlang:convert_time_unit(T1 - T0, native, microsecond) / 1.0e6,
            Errors = drain_errors(Pids),
            Ops = counters:get(maps:get(ops, Ctx), 1),
            Bytes = counters:get(maps:get(ops, Ctx), 3),
            maps:merge(hb_hist:summary(maps:get(hist, Ctx)), #{
                ops => Ops,
                seconds => Secs,
                rps => Ops / Secs,
                bytes_per_s => Bytes / Secs,
                server_closes => counters:get(maps:get(ops, Ctx), 2),
                connected => Ready,
                connect_failures => Failed,
                errors => length(Errors) + Failed,
                error_reasons => lists:sublist(lists:usort(Errors), 5)
            })
    end.

await_ready(0, R, F) -> {R, F};
await_ready(Left, R, F) ->
    receive
        {ready, _} -> await_ready(Left - 1, R + 1, F);
        {failed, _, _} -> await_ready(Left - 1, R, F + 1)
    after 120000 ->
        {R, F + Left}
    end.

drain_errors(Pids) ->
    Refs = [{P, monitor(process, P)} || P <- Pids],
    [receive {'DOWN', Ref, process, P, _} -> ok after 60000 -> exit(P, kill) end
        || {P, Ref} <- Refs],
    collect_errors([]).

collect_errors(Acc) ->
    receive
        {error_in, _, Why} -> collect_errors([Why | Acc]);
        {ready, _} -> collect_errors(Acc);
        {failed, _, Why} -> collect_errors([Why | Acc])
    after 0 -> Acc
    end.

ready(#{coordinator := C}) -> C ! {ready, self()}.

failed(#{coordinator := C}, Why) -> C ! {failed, self(), Why}.

error_in(#{coordinator := C}, Why) ->
    C ! {error_in, self(), case Why of {error, R} -> R; O -> O end}.

phase(#{phase := A}) -> atomics:get(A, 1).

done(_Ctx, ?WARMUP, _T0, _Bytes) -> ok;
done(_Ctx, ?STOP, _T0, _Bytes) -> ok;
done(#{ops := Ops, hist := H}, ?MEASURE, T0, Bytes) ->
    Us = erlang:convert_time_unit(erlang:monotonic_time() - T0, native, nanosecond) / 1000,
    counters:add(Ops, 1, 1),
    counters:add(Ops, 3, Bytes),
    hb_hist:record(H, Us).
