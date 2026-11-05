%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Leaks. Churn: thousands of connections ending every way a client
%% can end one (a full request with `connection: close`, a reset after a
%% response, connect-and-close without data, a reset halfway through the
%% request head or the body); the node's processes, ports and ETS return
%% to the baseline. Keep-alive: one connection serving thousands of
%% requests keeps its process dictionary and its memory flat (Bandit
%% clears the dictionary between requests, and so must Buccaneer).
-module(stress_leak).

-export([tests/0, churn/4]).

-define(KEYS, [processes, ports, ets]).

tests() ->
    [{"leak_churn", [http_buccaneer, buccaneer, http_cowboy, bandit], fun churn_leak/1},
     {"leak_keepalive", [http_buccaneer, buccaneer, bandit], fun keepalive_leak/1}].

churn_leak(Ctx) ->
    Cycles = stress_lib:pick(Ctx, {1000, 10000}),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        {ok, _} = churn(Port, 200, 16, false),
        Base = stress_lib:baseline(Ctx, ?KEYS),
        T0 = erlang:monotonic_time(millisecond),
        {ok, Kinds} = churn(Port, Cycles, 32, false),
        Ms = stress_lib:elapsed_ms(T0),
        After = stress_lib:back_to(Ctx, Base, ?KEYS),
        stress_lib:check_ets_rows(Base, After, Cycles),
        #{cycles => Cycles, seconds => Ms / 1000, kinds => Kinds,
          processes => maps:get(processes, After)}
    end).

%% `Cycles` connection cycles over `Workers` processes. Answers
%% {ok, CountsByKind} or fails with the errors.
churn(Port, Cycles, Workers, Tls) ->
    Counter = atomics:new(1, []),
    Self = self(),
    Pids = [spawn_link(fun() -> Self ! {churned, self(), churn_loop(Port, Tls, Counter, Cycles, #{})} end)
            || _ <- lists:seq(1, Workers)],
    Merged = stress_lib:merge_counts([receive {churned, P, R} -> R after 600000 -> #{timeout => 1} end
                                      || P <- Pids]),
    case maps:filter(fun(K, _) -> is_tuple(K) orelse K =:= timeout end, Merged) of
        Errors when map_size(Errors) =:= 0 -> {ok, Merged};
        Errors -> error({churn_errors, Errors})
    end.

churn_loop(Port, Tls, Counter, Cycles, Acc) ->
    case atomics:add_get(Counter, 1, 1) > Cycles of
        true -> Acc;
        false ->
            Kind = case rand:uniform(10) of
                1 -> no_data;
                2 -> half_head;
                3 -> half_body;
                4 -> reset_after_response;
                _ -> close_request
            end,
            Key = case cycle(Port, Tls, Kind) of ok -> Kind; Error -> {Kind, Error} end,
            churn_loop(Port, Tls, Counter, Cycles, stress_lib:bump(Key, Acc))
    end.

cycle(Port, Tls, Kind) ->
    case bench_conn:connect(Port, Tls) of
        {ok, C} ->
            R = case Kind of
                no_data -> ok;
                half_head -> bench_conn:send(C, <<"GET / HTTP/1.1\r\nhost: loc">>);
                half_body -> bench_conn:send(C, <<"POST /echo HTTP/1.1\r\nhost: localhost\r\n"
                                                  "content-length: 10000\r\n\r\npartial">>);
                reset_after_response ->
                    case stress_lib:get_once(C, <<>>) of {ok, _} -> ok; E -> E end;
                close_request ->
                    ok = bench_conn:send(C, bench_http:get(<<"/">>, [{<<"connection">>, <<"close">>}])),
                    case bench_http:read_response(C, <<>>, keep) of
                        {ok, {200, _, <<"hello world">>}, _} -> ok;
                        E -> E
                    end
            end,
            case Kind of
                close_request -> bench_conn:close(C);
                _ -> bench_conn:abort(C)
            end,
            R;
        {error, R} -> {connect, R}
    end.

%% One connection, `N` requests (GETs and 1 KiB echoes): the connection
%% process's dictionary does not grow, and its memory after the last
%% request is within 256 KiB of where it was after the first tenth.
keepalive_leak(Ctx) ->
    N = stress_lib:pick(Ctx, {500, 5000}),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        _ = stress_lib:baseline(Ctx, ?KEYS),
        {ok, C} = bench_conn:connect(Port, false),
        Body = rand:bytes(1024),
        Run = fun(K, Buf0) ->
            lists:foldl(fun(I, Buf) ->
                R = case I rem 2 of
                    0 -> stress_lib:get_once(C, Buf);
                    1 -> stress_lib:post_once(C, Buf, Body)
                end,
                case R of {ok, Rest} -> Rest; E -> error({request_failed, I, E}) end
            end, Buf0, lists:seq(1, K))
        end,
        Buf1 = Run(N div 10, <<>>),
        stress_lib:node_call(Ctx, gc_all, []),
        [{Dict0, Mem0}] = stress_lib:node_call(Ctx, connection_info, []),
        _ = Run(N - N div 10, Buf1),
        stress_lib:node_call(Ctx, gc_all, []),
        [{Dict1, Mem1}] = stress_lib:node_call(Ctx, connection_info, []),
        bench_conn:close(C),
        stress_lib:check(Dict1 =< Dict0, "the process dictionary does not grow", {Dict0, Dict1}),
        stress_lib:check(Mem1 =< Mem0 + 262144, "connection memory stays flat", {Mem0, Mem1}),
        #{requests => N, dictionary => {Dict0, Dict1}, memory => {Mem0, Mem1}}
    end).
