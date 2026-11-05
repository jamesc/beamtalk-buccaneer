%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Helpers shared by the stress tests (`just stress`, see
%% `stress_main`). Adapted from Catalina's. A test gets a context map:
%%
%%   impl   http_buccaneer | buccaneer | http_cowboy | bandit
%%   peer   the server peer node (`bench_peer`)
%%   size   smoke | full
%%   soak_minutes
-module(stress_lib).

-export([
    with_server/3,
    ready/2,
    node_call/3,
    stats/1,
    settle/2,
    baseline/2,
    back_to/3,
    wait_until/3,
    check/2,
    check/3,
    pick/2,
    get_once/2,
    post_once/3,
    elapsed_ms/1,
    check_ets_rows/3,
    bump/2,
    merge_counts/1,
    log/2
]).

%% Start a server with `Opts`, run `Fun(Port)`, and stop it whatever happens.
with_server(Ctx, Opts, Fun) ->
    {ok, Port} = node_call(Ctx, start_server, [Opts]),
    try
        ready(Port, Opts),
        Fun(Port)
    after
        node_call(Ctx, stop_server, [10000])
    end.

%% Wait until a server just started is serving.
ready(Port, Opts) ->
    bench_load:wait_ready(Port, maps:get(tls, Opts, false), 120000).

node_call(#{peer := Peer}, F, A) -> bench_peer:call(Peer, bench_node, F, A).

stats(Ctx) -> node_call(Ctx, stats, []).

%% Node stats once the server is quiet: after garbage collection, and once
%% the counts in `Keys` have stopped changing.
settle(Ctx, Keys) -> settle(Ctx, Keys, undefined, 20).

settle(Ctx, Keys, Prev, Tries) ->
    node_call(Ctx, gc_all, []),
    timer:sleep(250),
    S = stats(Ctx),
    Now = maps:with(Keys, S),
    case Now =:= Prev orelse Tries =:= 0 of
        true -> S;
        false -> settle(Ctx, Keys, Now, Tries - 1)
    end.

%% The baseline once no connection is open.
baseline(Ctx, Keys) ->
    wait_until(fun() -> node_call(Ctx, connection_count, []) =:= 0 end, 30000, no_connections),
    settle(Ctx, Keys).

%% Wait for every connection to close, then compare with the baseline.
back_to(Ctx, Base, Keys) ->
    wait_until(fun() -> node_call(Ctx, connection_count, []) =:= 0 end, 90000, connections_closed),
    After = settle(Ctx, Keys),
    Diff = maps:from_list([{K, {maps:get(K, Base), maps:get(K, After)}}
                           || K <- Keys, maps:get(K, Base) =/= maps:get(K, After)]),
    check(Diff =:= #{}, "processes, ports and ETS tables back to baseline", Diff),
    After.

%% Poll `Fun` until it answers true, or fail with `What` after `Ms`.
wait_until(Fun, Ms, What) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    wait_loop(Fun, Deadline, What).

wait_loop(Fun, Deadline, What) ->
    case Fun() of
        true -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> error({timed_out_waiting_for, What});
                false ->
                    timer:sleep(50),
                    wait_loop(Fun, Deadline, What)
            end
    end.

check(Cond, What) -> check(Cond, What, []).

check(true, _What, _Detail) -> ok;
check(_, What, Detail) -> error({check_failed, What, Detail}).

pick(#{size := smoke}, {Smoke, _Full}) -> Smoke;
pick(#{size := full}, {_Smoke, Full}) -> Full.

%% One `GET /` on C with leftover Buf: answers `{ok, Rest}` on a 200
%% `hello world` or the reason.
get_once(C, Buf) ->
    case bench_conn:send(C, bench_http:get(<<"/">>)) of
        ok ->
            case bench_http:read_response(C, Buf, keep) of
                {ok, {200, _, <<"hello world">>}, Rest} -> {ok, Rest};
                {ok, Other, _} -> {bad_response, Other};
                E -> E
            end;
        E -> E
    end.

%% One `POST /echo` with Body: `{ok, Rest}` when the echo matches.
post_once(C, Buf, Body) ->
    case bench_conn:send(C, bench_http:request(<<"POST">>, <<"/echo">>, [], Body)) of
        ok ->
            case bench_http:read_response(C, Buf, keep) of
                {ok, {200, _, Body}, Rest} -> {ok, Rest};
                {ok, {S, _, B}, _} -> {mismatch, S, byte_size(B), byte_size(Body)};
                E -> E
            end;
        E -> E
    end.

%% ETS rows may move a little (timers, caches) but must not grow with the
%% work done: one row per 100 units of `Work` at most.
check_ets_rows(Base, After, Work) ->
    Grown = maps:get(ets_rows, After) - maps:get(ets_rows, Base),
    check(Grown =< max(20, Work div 100), "ETS rows do not grow with the load",
          #{base => maps:get(ets_rows, Base), now => maps:get(ets_rows, After), work => Work}).

elapsed_ms(T0) -> erlang:monotonic_time(millisecond) - T0.

bump(K, M) -> maps:update_with(K, fun(X) -> X + 1 end, 1, M).

merge_counts(Ms) ->
    lists:foldl(fun(M, Acc) ->
        maps:fold(fun(K, V, A) -> maps:update_with(K, fun(X) -> X + V end, V, A) end, Acc, M)
    end, #{}, Ms).

log(F, A) -> io:format(standard_error, "    " ++ F ++ "~n", A).
