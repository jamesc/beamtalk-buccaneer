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
%%       [--row ROW] [--seconds N] [--top N] [--workers N]
%%       [--type call_time|call_count|call_memory|split]
%%
%% `--type split` (Buccaneer impls; meant for the churn rows) times each
%% connection's phases from call/return trace timestamps instead: the
%% acceptor's `Connection start:` (Catalina), the handler's wait for its
%% ready message and Catalina's `onReady:` (Catalina), the sniff and the
%% HTTP/1 handler setup (Buccaneer), the first request's
%% `Pipeline runRequest:` (per request), and the close from the
%% pipeline's return to the process exit (shutdown). `--workers` overrides
%% the row's concurrency; 1 gives uncontended wall times.
-module(bench_profile).

-export([main/0, profile/3, split/1, class_stats_on/0, class_stats/0, h2_per_stream/2]).

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
    Run0 = Params#{warmup_ms => 1000, duration_ms => Secs * 1000 + 2000},
    Run = case maps:find(workers, Opts) of
        {ok, W} -> Run0#{workers => W, conns => W};
        error -> Run0
    end,
    Load = spawn_link(fun() -> Self ! {load, bench_load:Kind(Port, Run)} end),
    timer:sleep(1500),
    Out = case maps:get(type, Opts) of
        split -> bench_peer:call(Peer, ?MODULE, split, [Secs * 1000], 600000);
        Type -> bench_peer:call(Peer, ?MODULE, profile, [Type, Secs * 1000, maps:get(top, Opts)], 600000)
    end,
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
parse(["--workers", N | T], O) -> parse(T, O#{workers => list_to_integer(N)});
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

%% === Per-connection phases (--type split) ===

-define(CONN_START, {'bt@catalina@connection', 'class_start:connections:config:handlerConfig:span:acceptor:', 7}).
-define(SNIFF, {'bt@buccaneer@initial_handler', 'class_run:options:', 3}).
-define(REQUEST, {'bt@buccaneer@pipeline', 'class_runRequest:handler:connectionSpan:connData:options:', 6}).

%% Runs in the server peer. Traces the acceptors and every new process
%% (spawn, exit, the connection handler's handle_info/terminate and the
%% three phase functions, with monotonic timestamps) for `Ms`, then
%% answers the mean wall time of each phase per connection.
split(Ms) ->
    Self = self(),
    Tracer = spawn(fun() -> split_collect(Self, []) end),
    Local = [local],
    Return = [{'_', [], [{return_trace}]}],
    [erlang:trace_pattern(MFA, Return, Local) || MFA <- [?CONN_START, ?SNIFF, ?REQUEST]],
    [erlang:trace_pattern({'bt@buccaneer@connection_handler', F, 2}, true, Local)
     || F <- [handle_info, terminate]],
    Acceptors = [P || P <- processes(), is_acceptor(P)],
    Flags = [call, procs, monotonic_timestamp, {tracer, Tracer}],
    [catch erlang:trace(P, true, Flags) || P <- Acceptors],
    erlang:trace(new_processes, true, Flags),
    timer:sleep(Ms),
    erlang:trace(new_processes, false, [call, procs]),
    [catch erlang:trace(P, false, [call, procs]) || P <- Acceptors],
    erlang:trace_pattern({'_', '_', '_'}, false, Local),
    Tracer ! {done, Self},
    Events = receive {split_events, E} -> E after 60000 -> [] end,
    split_report(lists:reverse(Events), Ms).

is_acceptor(P) ->
    case erlang:process_info(P, dictionary) of
        {dictionary, D} ->
            case proplists:get_value('$initial_call', D) of
                {'bt@catalina@acceptor', _, _} -> true;
                _ -> false
            end;
        _ -> false
    end.

split_collect(Owner, Acc) ->
    receive
        {done, Owner} -> Owner ! {split_events, Acc};
        Msg when element(1, Msg) =:= trace_ts -> split_collect(Owner, [Msg | Acc]);
        _ -> split_collect(Owner, Acc)
    end.

%% Per handler pid: spawned, the first handle_info (the ready message),
%% the sniff's call and return, the first runRequest's call and return,
%% terminate, exit. The acceptor's `Connection start:` is timed call to
%% return.
split_report(Events, Ms) ->
    {Conns, _Open, Starts} = lists:foldl(fun split_event/2, {#{}, #{}, []}, Events),
    Done = [C || C = #{spawned := _, ready := _, sniff_call := _, sniff_ret := _,
                       req_call := _, req_ret := _, exit := _} <- maps:values(Conns)],
    Phases = [
        {"(a) Catalina: Connection start: in the acceptor", Starts},
        {"(a) Catalina: handler spawn to its ready message", [R - S || #{spawned := S, ready := R} <- Done]},
        {"(a) Catalina: onReady: (peername, span, wrap, handshake)", [C - R || #{ready := R, sniff_call := C} <- Done]},
        {"(b) Buccaneer: InitialHandler sniff", [Rt - C || #{sniff_call := C, sniff_ret := Rt} <- Done]},
        {"(b) Buccaneer: sniff to first request (HTTP1Handler setup, re-arm, wait)", [Q - Rt || #{sniff_ret := Rt, req_call := Q} <- Done]},
        {"(c) first request: Pipeline runRequest:", [Rr - Q || #{req_call := Q, req_ret := Rr} <- Done]},
        {"(d) shutdown: runRequest return to process exit", [X - Rr || #{req_ret := Rr, exit := X} <- Done]}
    ],
    Sub = [{"    of which terminate: to exit", [X - T || #{terminate := T, exit := X} <- Done]}],
    Total = lists:sum([mean(L) || {_, L} <- Phases]),
    [io_lib:format("~p connections fully traced over ~p ms (~p Connection start: calls)~n~n",
                   [length(Done), Ms, length(Starts)]),
     io_lib:format("~-76s ~9s ~7s~n", ["Phase (mean wall time per connection)", "us", "share"]),
     [io_lib:format("~-76s ~9.1f ~6.1f%~n", [Name, mean(L), pct(mean(L), Total)]) || {Name, L} <- Phases ++ Sub],
     io_lib:format("~-76s ~9.1f~n", ["Total", Total])].

split_event({trace_ts, Pid, call, {M, F, Args}, T}, {Conns, Open, Starts}) ->
    case {M, F, length(Args)} of
        ?CONN_START -> {Conns, Open#{Pid => T}, Starts};
        ?SNIFF -> {first(Pid, sniff_call, T, Conns), Open, Starts};
        ?REQUEST -> {first(Pid, req_call, T, Conns), Open, Starts};
        {_, handle_info, 2} -> {first(Pid, ready, T, Conns), Open, Starts};
        {_, terminate, 2} -> {first(Pid, terminate, T, Conns), Open, Starts};
        _ -> {Conns, Open, Starts}
    end;
split_event({trace_ts, Pid, return_from, MFA, _, T}, {Conns, Open, Starts}) ->
    case MFA of
        ?CONN_START ->
            case maps:take(Pid, Open) of
                {T0, Open2} -> {Conns, Open2, [to_us(T - T0) | Starts]};
                error -> {Conns, Open, Starts}
            end;
        ?SNIFF -> {first(Pid, sniff_ret, T, Conns), Open, Starts};
        ?REQUEST -> {first(Pid, req_ret, T, Conns), Open, Starts};
        _ -> {Conns, Open, Starts}
    end;
split_event({trace_ts, Pid, spawned, _, _, T}, {Conns, Open, Starts}) ->
    {first(Pid, spawned, T, Conns), Open, Starts};
split_event({trace_ts, Pid, exit, _, T}, {Conns, Open, Starts}) ->
    {first(Pid, exit, T, Conns), Open, Starts};
split_event(_, Acc) -> Acc.

%% Keep the first time of each key: a keep-alive connection's later
%% requests do not move it.
first(Pid, Key, T, Conns) ->
    Us = to_us(T),
    maps:update_with(Pid, fun(M) -> maps:merge(#{Key => Us}, M) end, #{Key => Us}, Conns).

to_us(T) -> erlang:convert_time_unit(T, native, microsecond) * 1.0.

mean([]) -> 0.0;
mean(L) -> lists:sum(L) / length(L).

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

pct(_, T) when T == 0 -> 0.0;
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
