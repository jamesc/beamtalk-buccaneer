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

-export([main/0, profile/3, class_stats_on/0, class_stats/0, h2_per_stream/2]).

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
    case Kind of
        h2 ->
            %% One stream at a time on one h2c connection, from inside the
            %% peer so the connection process can be traced (BT-4469).
            io:format("~n~s", [bench_peer:call(Peer, ?MODULE, h2_per_stream, [Port, 2000], 600000)]);
        _ ->
            {ok, C} = bench_conn:connect(Port, Tls),
            lists:foldl(fun(_, Buf) ->
                ok = bench_conn:send(C, bench_http:get(<<"/">>)),
                {ok, {200, _, _}, Rest} = bench_http:read_response(C, Buf),
                Rest
            end, <<>>, lists:seq(1, 2000)),
            bench_conn:close(C)
    end,
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
    Live = maps:from_keys(processes(), true),
    erlang:trace_pattern({'_', '_', '_'}, pause, [local, Type]),
    Rows = lists:append([module_rows(M, Type) || {M, _} <- code:all_loaded()]),
    Split = case Type of call_time -> split_by_liveness(Live); _ -> [] end,
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
     Split,
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

%% Call time in processes still alive at the end of the window
%% (connections, acceptors, servers) against processes that ended in it
%% (per-request ones: HTTP/2 stream processes), with each group's top
%% functions.
split_by_liveness(Live) ->
    Per = lists:append([[{maps:is_key(P, Live), S * 1000000 + Us, {M, F, A}}
                         || {P, _C, S, Us} <- L]
                        || {M, _} <- code:all_loaded(),
                           {F, A} <- (try erlang:get_module_info(M, functions) catch _:_ -> [] end),
                           {call_time, L} <- [erlang:trace_info({M, F, A}, call_time)], is_list(L)]),
    Sum = fun(Alive) -> lists:sum([V || {A, V, _} <- Per, A =:= Alive]) end,
    Top = fun(Alive) ->
        ByFun = maps:to_list(lists:foldl(fun({A, V, MFA}, Acc) when A =:= Alive ->
                                                 maps:update_with(MFA, fun(X) -> X + V end, V, Acc);
                                            (_, Acc) -> Acc end, #{}, Per)),
        [io_lib:format("    ~12w us  ~p~n", [V, MFA])
         || {MFA, V} <- lists:sublist(lists:reverse(lists:keysort(2, ByFun)), 12)]
    end,
    [io_lib:format("~nBy process: ~p us in live processes (connections), ~p us in ended ones (streams)~n",
                   [Sum(true), Sum(false)]),
     io_lib:format("  Live processes, top functions (own):~n", []), Top(true),
     io_lib:format("  Ended processes, top functions (own):~n", []), Top(false)].

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

%% Runs in the server peer (BT-4469): N sequential GETs, one stream at a
%% time, on one h2c connection. Traces the server's connection process:
%% the messages it receives per stream by kind (gen_server calls by
%% selector, socket data, DOWNs, other), its reductions per stream, the
%% processes spawned per stream, and the HPACK time spent in it.
h2_per_stream(Port, N) ->
    Before = processes(),
    {ok, H0} = bench_h2:connect(Port),
    H1 = h2_get(H0),
    timer:sleep(100),
    Conn = h2_conn_process(processes() -- [self() | Before]),
    Self = self(),
    Tracer = spawn(fun() -> h2_tally(Self, #{}) end),
    %% Only the HPACK entry points are traced, so each one's call time
    %% includes everything it calls.
    Hpack = [{'bt@hpack@hpack', 'class_encode:headers:table:', '_'},
             {'bt@hpack@hpack', 'class_decode:table:', '_'}],
    [erlang:trace_pattern(MFA, true, [local, call_time]) || MFA <- Hpack],
    erlang:trace(Conn, true, ['receive', call, procs, {tracer, Tracer}]),
    {reductions, R0} = process_info(Conn, reductions),
    T0 = erlang:monotonic_time(microsecond),
    H2 = lists:foldl(fun(_, H) -> h2_get(H) end, H1, lists:seq(1, N)),
    T1 = erlang:monotonic_time(microsecond),
    {reductions, R1} = process_info(Conn, reductions),
    erlang:trace(Conn, false, ['receive', call, procs]),
    [erlang:trace_pattern(MFA, pause, [local, call_time]) || MFA <- Hpack],
    HpackRows = [{V, {M, F, A}, C} || {M, F, A0} <- Hpack, {F1, A} <- erlang:get_module_info(M, functions),
                                     F1 =:= F, A0 =:= '_', {V, C} <- [read(M, F, A, call_time)]],
    [erlang:trace_pattern(MFA, false, [local, call_time]) || MFA <- Hpack],
    %% A second pass with every function traced, in the connection only:
    %% where its time per stream goes.
    %% call_time breakpoints only (no `local` call-trace messages).
    erlang:trace_pattern({'_', '_', '_'}, true, [call_time]),
    erlang:trace(Conn, true, [call, {tracer, Tracer}]),
    H3 = lists:foldl(fun(_, H) -> h2_get(H) end, H2, lists:seq(1, N)),
    erlang:trace(Conn, false, [call]),
    erlang:trace_pattern({'_', '_', '_'}, pause, [call_time]),
    ConnRows = lists:reverse(lists:keysort(1, lists:append(
                 [module_rows(M, call_time) || {M, _} <- code:all_loaded()]))),
    erlang:trace_pattern({'_', '_', '_'}, false, [call_time]),
    ConnTotal = lists:sum([V || {V, _, _} <- ConnRows]),
    bench_h2:close(H3),
    Tracer ! {done, Self},
    Tally = receive {tally, T} -> T after 5000 -> #{} end,
    Top = fun(F) -> lists:sum([Us || {Us, {_, Fn, _}, _} <- HpackRows,
                                     lists:prefix(F, atom_to_list(Fn))]) end,
    HpackCalls = lists:sum([C || {_, _, C} <- HpackRows]),
    HpackUs = lists:sum([Us || {Us, _, _} <- HpackRows]),
    [io_lib:format("HTTP/2 per stream (~p sequential GETs, one stream at a time, ~.1f us/stream):~n",
                   [N, (T1 - T0) / N]),
     io_lib:format("~8.2f  connection reductions~n", [(R1 - R0) / N]),
     io_lib:format("~8.2f  HPACK us per stream, ~.2f calls (encode ~.2f us, decode ~.2f us)~n",
                   [HpackUs / N, HpackCalls / N, Top("class_encode") / N, Top("class_decode") / N]),
     io_lib:format("Messages into the connection process per stream:~n", []),
     [io_lib:format("~8.2f  ~p~n", [V / N, K])
      || {K, V} <- lists:reverse(lists:keysort(2, maps:to_list(Tally)))],
     io_lib:format("Connection process, own time per stream (~.1f us traced, all functions):~n",
                   [ConnTotal / N]),
     [io_lib:format("~8.2f us ~8.2f calls  ~p~n", [V / N, C / N, MFA])
      || {V, MFA, C} <- lists:sublist(ConnRows, 30)]].

h2_get(H) ->
    {Id, H1} = bench_h2:request(H, <<"/">>),
    h2_wait(Id, H1).

h2_wait(Id, H) ->
    case bench_h2:next_event(H) of
        {done, Id, 200, H1} -> H1;
        {done, _, _, H1} -> h2_wait(Id, H1);
        Other -> error({h2_get, Other})
    end.

%% The new process with the most reductions: the connection (stream
%% processes of the warm-up GET have ended by now).
h2_conn_process(New) ->
    Live = [{R, P} || P <- New, {reductions, R} <- [process_info(P, reductions)]],
    {_, Conn} = lists:max(Live),
    Conn.

h2_tally(Owner, Acc) ->
    receive
        {done, Owner} -> Owner ! {tally, Acc};
        {trace, _, 'receive', Msg} -> h2_tally(Owner, h2_bump(h2_kind(Msg), Acc));
        {trace, _, spawn, _, _} -> h2_tally(Owner, h2_bump(spawned_processes, Acc));
        _ -> h2_tally(Owner, Acc)
    end.

h2_bump(K, Acc) -> maps:update_with(K, fun(V) -> V + 1 end, 1, Acc).

h2_kind({'$gen_call', _, Req}) -> {call, h2_selector(Req)};
h2_kind({'$gen_cast', Req}) -> {cast, h2_selector(Req)};
h2_kind({tcp, _, _}) -> socket_data;
h2_kind({ssl, _, _}) -> socket_data;
h2_kind({'DOWN', _, _, _, _}) -> 'DOWN';
h2_kind(T) when is_tuple(T), tuple_size(T) > 0, is_atom(element(1, T)) -> {other, element(1, T)};
h2_kind(A) when is_atom(A) -> {other, A};
h2_kind(_) -> other.

h2_selector(T) when is_tuple(T), tuple_size(T) > 0 -> element(1, T);
h2_selector(A) -> A.
