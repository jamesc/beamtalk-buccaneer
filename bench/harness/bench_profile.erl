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

-export([main/0, profile/3, split/1, class_stats_on/0, class_stats/0]).

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
