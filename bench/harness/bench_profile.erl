%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Profile one bench row on one server: the load runs from this VM
%% while every process in the server peer is traced with call-time (or
%% call-count, or call-memory) breakpoints for a window in the middle of
%% the run. Prints the top functions by own time and the same grouped by
%% module, so a cost can be placed in Buccaneer, beamtalk-http, the
%% Beamtalk runtime or OTP. Then counts the calls a request makes into
%% Beamtalk class processes (`sys:statistics`, BT-4065). Adapted from
%% Catalina's `bench_profile`.
%%
%%   bench/run.sh bench_profile [--impl http_buccaneer|buccaneer|http_cowboy|bandit]
%%       [--row ROW] [--seconds N] [--top N] [--type call_time|call_count|call_memory]
-module(bench_profile).

-export([main/0, profile/3, class_stats_on/0, class_stats/0]).

main() ->
    Opts = parse(init:get_plain_arguments(), #{impl => buccaneer, row => "get_c10",
                                               seconds => 3, top => 40, type => call_time}),
    {ok, _} = application:ensure_all_started(ssl),
    #{impl := Impl, row := RowId} = Opts,
    [{_, Kind, Params, _}] = [R || R = {Id, _, _, _} <- bench_main:rows(full), Id =:= RowId],
    Peer = bench_peer:start(Impl),
    Tls = maps:get(tls, Params, false),
    {ok, Port} = bench_peer:call(Peer, bench_node, start_server, [#{tls => Tls}]),
    bench_load:wait_ready(Port, Tls, 120000),
    Secs = maps:get(seconds, Opts),
    Self = self(),
    Run = Params#{warmup_ms => 1000, duration_ms => Secs * 1000 + 2000},
    Load = spawn_link(fun() -> Self ! {load, bench_load:Kind(Port, Run)} end),
    timer:sleep(1500),
    Out = bench_peer:call(Peer, ?MODULE, profile,
                          [maps:get(type, Opts), Secs * 1000, maps:get(top, Opts)], 600000),
    Metrics = receive {load, M} -> M end,
    unlink(Load),
    io:format("~s ~s: ~.1f req/s while profiling (profiler overhead included)~n~n~s",
              [Impl, RowId, float(maps:get(rps, Metrics, 0)), Out]),
    %% Class-process calls per request, over 2,000 sequential GETs.
    bench_peer:call(Peer, ?MODULE, class_stats_on, []),
    {ok, C} = bench_conn:connect(Port, Tls),
    lists:foldl(fun(_, Buf) ->
        ok = bench_conn:send(C, bench_http:get(<<"/">>)),
        {ok, {200, _, _}, Rest} = bench_http:read_response(C, Buf),
        Rest
    end, <<>>, lists:seq(1, 2000)),
    bench_conn:close(C),
    Calls = bench_peer:call(Peer, ?MODULE, class_stats, []),
    io:format("~nCalls into class processes per GET (2,000 sequential):~n~s",
              [[io_lib:format("~8.2f  ~p~n", [In / 2000, N]) || {In, N} <- Calls]]),
    bench_peer:call(Peer, bench_node, stop_server, [5000]),
    bench_peer:stop(Peer),
    halt(0).

parse(["--impl", I | T], O) -> parse(T, O#{impl => list_to_atom(I)});
parse(["--row", R | T], O) -> parse(T, O#{row => R});
parse(["--seconds", N | T], O) -> parse(T, O#{seconds => list_to_integer(N)});
parse(["--top", N | T], O) -> parse(T, O#{top => list_to_integer(N)});
parse(["--type", Ty | T], O) -> parse(T, O#{type => list_to_atom(Ty)});
parse([], O) -> O;
parse([X | _], _) -> error({unknown_argument, X}).

%% Runs in the server peer. Traces every process for `Ms` and answers the
%% report as an iolist. Reads the counters with `erlang:trace_info/2`
%% rather than `tprof`/`eprof`, which call `M:module_info(functions)`
%% (Beamtalk-compiled modules do not export it) and crash.
profile(Type, Ms, Top) ->
    erlang:trace_pattern({'_', '_', '_'}, true, [local, Type]),
    erlang:trace(all, true, [call]),
    timer:sleep(Ms),
    erlang:trace(all, false, [call]),
    erlang:trace_pattern({'_', '_', '_'}, pause, [local, Type]),
    Rows = lists:append([module_rows(M, Type) || {M, _} <- code:all_loaded()]),
    erlang:trace_pattern({'_', '_', '_'}, false, [local, Type]),
    Total = lists:sum([V || {V, _, _} <- Rows]),
    ByFun = lists:reverse(lists:keysort(1, Rows)),
    ByMod = lists:reverse(lists:keysort(2, maps:to_list(lists:foldl(fun({V, {M, _, _}, _}, Acc) ->
        maps:update_with(M, fun(X) -> X + V end, V, Acc)
    end, #{}, Rows)))),
    Unit = case Type of call_time -> "us"; call_count -> "calls"; call_memory -> "words" end,
    [io_lib:format("total ~p ~s over ~p ms~n~nTop functions (own):~n", [Total, Unit, Ms]),
     [io_lib:format("~6.2f%  ~12w ~s ~10w calls  ~p~n", [pct(V, Total), V, Unit, C, MFA])
      || {V, MFA, C} <- lists:sublist(ByFun, Top)],
     io_lib:format("~nBy module:~n", []),
     [io_lib:format("~6.2f%  ~12w ~s  ~p~n", [pct(V, Total), V, Unit, M])
      || {M, V} <- lists:sublist(ByMod, Top)]].

module_rows(M, Flag) ->
    Funs = try erlang:get_module_info(M, functions) catch _:_ -> [] end,
    [{V, {M, F, A}, C} || {F, A} <- Funs, {V, C} <- [read(M, F, A, Flag)], C > 0].

read(M, F, A, call_time) ->
    case erlang:trace_info({M, F, A}, call_time) of
        {call_time, L} when is_list(L) ->
            lists:foldl(fun({_Pid, C, S, Us}, {V, N}) -> {V + S * 1000000 + Us, N + C} end, {0, 0}, L);
        _ -> {0, 0}
    end;
read(M, F, A, call_memory) ->
    case erlang:trace_info({M, F, A}, call_memory) of
        {call_memory, L} when is_list(L) ->
            lists:foldl(fun({_Pid, C, W}, {V, N}) -> {V + W, N + C} end, {0, 0}, L);
        _ -> {0, 0}
    end;
read(M, F, A, call_count) ->
    case erlang:trace_info({M, F, A}, call_count) of
        {call_count, C} when is_integer(C) -> {C, C};
        _ -> {0, 0}
    end.

pct(_, 0) -> 0.0;
pct(V, T) -> 100 * V / T.

%% Messages into each Beamtalk class process (`sys:statistics`).
class_stats_on() ->
    [catch sys:statistics(N, true) || N <- class_processes()],
    ok.

class_stats() ->
    R = [{In, N} || N <- class_processes(), {ok, St} <- [catch sys:statistics(N, get)],
                    In <- [proplists:get_value(messages_in, St, 0)], In > 0],
    [catch sys:statistics(N, false) || N <- class_processes()],
    lists:reverse(lists:sort(R)).

class_processes() ->
    [N || N <- registered(), lists:prefix("beamtalk_class_", atom_to_list(N))].
