%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc The HTTP load generator: `conns` keep-alive connections in this VM,
%% each sending `GET /` and reading the whole response before the next
%% (closed loop). Workers read the phase from a shared `atomics` cell and
%% record into shared `counters` and an `hb_hist`, as Catalina's
%% `bench_load`.
-module(hb_load).

-export([get/2, wait_ready/2, read_response/2]).

-define(WARMUP, 0).
-define(MEASURE, 1).
-define(STOP, 2).
-define(RECV_TIMEOUT, 30000).

request() -> <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n">>.

%% Options: conns, warmup_ms, duration_ms. Answers #{rps, p50, p99, p999
%% (µs), errors, ...}.
get(Port, Opts) ->
    N = maps:get(conns, Opts),
    run(N, Opts, fun(Ctx) ->
        case connect(Port) of
            {ok, S} ->
                ready(Ctx),
                get_loop(Port, S, <<>>, Ctx);
            {error, R} ->
                failed(Ctx, R)
        end
    end).

%% A response with `connection: close` (cowboy closes a keep-alive
%% connection after `max_keepalive`, 1000 requests by default) is counted,
%% and the worker reconnects; the reconnect is part of the next request's
%% latency.
get_loop(Port, S, Buf, Ctx) ->
    case phase(Ctx) of
        ?STOP ->
            gen_tcp:close(S);
        Phase ->
            T0 = erlang:monotonic_time(),
            case gen_tcp:send(S, request()) of
                ok ->
                    case read_response(S, Buf) of
                        {ok, 200, Rest} ->
                            done(Ctx, Phase, T0),
                            get_loop(Port, S, Rest, Ctx);
                        {close, 200} ->
                            done(Ctx, Phase, T0),
                            counters:add(maps:get(ops, Ctx), 2, 1),
                            gen_tcp:close(S),
                            case connect(Port) of
                                {ok, S2} -> get_loop(Port, S2, <<>>, Ctx);
                                Other -> error_in(Ctx, Other)
                            end;
                        Other ->
                            gen_tcp:close(S),
                            error_in(Ctx, Other)
                    end;
                Other ->
                    gen_tcp:close(S),
                    error_in(Ctx, Other)
            end
    end.

connect(Port) -> connect(Port, 20).

connect(Port, Attempts) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port,
                         [binary, {active, false}, {nodelay, true}], 60000) of
        {ok, S} -> {ok, S};
        {error, _} when Attempts > 1 ->
            timer:sleep(20 + rand:uniform(50)),
            connect(Port, Attempts - 1);
        E -> E
    end.

%% Read one response from S, starting with the leftover Buf. Answers
%% `{ok, Status, Rest}`, `{close, Status}` when the response says
%% `connection: close`, or `{error, Reason}`.
read_response(S, Buf) ->
    case erlang:decode_packet(http_bin, Buf, []) of
        {ok, {http_response, _V, Status, _R}, Rest} -> read_headers(S, Rest, Status, 0, false);
        {more, _} -> more(S, Buf, fun(B) -> read_response(S, B) end);
        Other -> {error, {bad_status_line, Other}}
    end.

read_headers(S, Buf, Status, Len, Close) ->
    case erlang:decode_packet(httph_bin, Buf, []) of
        {ok, {http_header, _, 'Content-Length', _, V}, Rest} ->
            read_headers(S, Rest, Status, binary_to_integer(V), Close);
        {ok, {http_header, _, 'Connection', _, V}, Rest} ->
            read_headers(S, Rest, Status, Len, string:lowercase(V) =:= <<"close">>);
        {ok, {http_header, _, _, _, _}, Rest} ->
            read_headers(S, Rest, Status, Len, Close);
        {ok, http_eoh, Rest} ->
            read_body(S, Rest, Status, Len, Close);
        {more, _} ->
            more(S, Buf, fun(B) -> read_headers(S, B, Status, Len, Close) end);
        Other ->
            {error, {bad_header, Other}}
    end.

read_body(_S, Buf, Status, Len, Close) when byte_size(Buf) >= Len ->
    <<_:Len/binary, Rest/binary>> = Buf,
    case Close of
        true -> {close, Status};
        false -> {ok, Status, Rest}
    end;
read_body(S, Buf, Status, Len, Close) ->
    more(S, Buf, fun(B) -> read_body(S, B, Status, Len, Close) end).

more(S, Buf, K) ->
    case gen_tcp:recv(S, 0, ?RECV_TIMEOUT) of
        {ok, Data} -> K(<<Buf/binary, Data/binary>>);
        {error, R} -> {error, R}
    end.

%% Wait until the server answers a GET, for up to `Ms`.
wait_ready(Port, Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    wait_ready_loop(Port, Deadline).

wait_ready_loop(Port, Deadline) ->
    Ok = case connect(Port, 1) of
        {ok, S} ->
            R = gen_tcp:send(S, request()) =:= ok andalso read_response(S, <<>>),
            gen_tcp:close(S),
            is_tuple(R) andalso element(2, R) =:= 200;
        _ ->
            false
    end,
    case Ok of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> error({server_not_ready, Port});
                false ->
                    timer:sleep(100),
                    wait_ready_loop(Port, Deadline)
            end
    end.

%% === The worker pool ===

run(N, Opts, Body) ->
    Ctx = #{
        phase => atomics:new(1, []),
        ops => counters:new(2, [write_concurrency]),
        hist => hb_hist:new(),
        coordinator => self()
    },
    Pids = [spawn(fun() -> Body(Ctx) end) || _ <- lists:seq(1, N)],
    {Ready, Failed} = await_ready(length(Pids), 0, 0),
    case Ready of
        0 ->
            atomics:put(maps:get(phase, Ctx), 1, ?STOP),
            [exit(P, kill) || P <- Pids],
            #{error => {no_connections, Failed}};
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
            maps:merge(hb_hist:summary(maps:get(hist, Ctx)), #{
                ops => Ops,
                seconds => Secs,
                rps => Ops / Secs,
                server_closes => counters:get(maps:get(ops, Ctx), 2),
                connected => Ready,
                connect_failures => Failed,
                errors => length(Errors),
                error_reasons => lists:usort(Errors)
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

done(_Ctx, ?WARMUP, _T0) -> ok;
done(#{ops := Ops, hist := H}, ?MEASURE, T0) ->
    Us = erlang:convert_time_unit(erlang:monotonic_time() - T0, native, nanosecond) / 1000,
    counters:add(Ops, 1, 1),
    hb_hist:record(H, Us).
