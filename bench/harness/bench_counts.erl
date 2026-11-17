%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Deterministic per-request counts (BT-4982): reductions, function
%% calls, the FFI proxy and the BIFs behind it, throws, and who calls
%% them, for one request on one keep-alive connection. Counts, unlike
%% timings, do not move with machine noise, so a change that removes work
%% shows as a smaller number (the method of BT-4974: call tracing plus the
%% reductions of the connection process).
%%
%%   bench/run.sh bench_counts [--impl buccaneer|http_buccaneer]
%%       [--request get|post] [--requests N] [--top N] [--show MODULE_PREFIX]
%%       [--callers]
%%
%% Two windows on the same connection, both sequential requests after a
%% warm-up:
%%
%%   1. untraced, `--requests` requests (default 200): reductions of the
%%      process that served them, per request. Tracing adds reductions of
%%      its own, so this window is never traced.
%%   2. traced, 50 requests: every call the connection process makes is
%%      counted per request (the other processes of the peer are not
%%      traced, so the count does not move with them).
%%
%% `--show` lists the functions of modules whose name starts with the
%% prefix (default `bt@buccaneer`; empty for all), most called first.
%% `--callers` also lists who calls each watched function.
-module(bench_counts).

-export([main/0, begin_reductions/0, end_reductions/2, begin_trace/1, end_trace/1]).

-define(TRACED_REQUESTS, 50).

%% Functions whose per-request count the BT-4982 list names.
-define(WATCH, [
    {erlang, throw, 1}, {erlang, erase, 1}, {erlang, erase, 0}, {erlang, put, 2},
    {erlang, get, 0}, {erlang, get, 1}, {erlang, get_keys, 0}, {erlang, get_keys, 1},
    {erlang, iolist_size, 1}, {erlang, byte_size, 1}, {erlang, make_ref, 0},
    {erlang, function_exported, 3}, {erlang, monotonic_time, 1},
    {ets, lookup, 2}, {ets, whereis, 1},
    {persistent_term, get, 1}, {persistent_term, get, 2}, {lists, subtract, 2}, {erlang, decode_packet, 3},
    {beamtalk_erlang_proxy, apply_with_coercion, 6}, {beamtalk_erlang_proxy, direct_call, 4},
    {beamtalk_result, ok, 1},
    {'bt@buccaneer@exchange', load, 1}, {'bt@buccaneer@exchange', 'store:', 2},
    {'bt@buccaneer@exchange', key, 1}, {'bt@buccaneer@exchange', commit, 1}
]).

main() ->
    Opts = parse(init:get_plain_arguments(),
                 #{impl => buccaneer, request => get, requests => 200, top => 40,
                   show => "bt@buccaneer", callers => false}),
    #{impl := Impl, request := Kind, requests := N} = Opts,
    Peer = bench_peer:start(Impl),
    {ok, Port} = bench_peer:call(Peer, bench_node, start_server, [#{tls => false}]),
    bench_load:wait_ready(Port, false, 120000),
    Req = case Kind of
        get -> bench_http:get(<<"/">>);
        post -> bench_http:request(<<"POST">>, <<"/echo">>, [], binary:copy(<<"p">>, 64))
    end,
    {ok, C} = bench_conn:connect(Port, false),
    Round = fun(Buf) ->
        ok = bench_conn:send(C, Req),
        {ok, {200, _, _}, Rest} = bench_http:read_response(C, Buf),
        Rest
    end,
    Run = fun(Count) -> lists:foldl(fun(_, B) -> Round(B) end, <<>>, lists:seq(1, Count)) end,
    Run(300),
    Snap = bench_peer:call(Peer, ?MODULE, begin_reductions, []),
    Run(N),
    {Red, Pid} = bench_peer:call(Peer, ?MODULE, end_reductions, [Snap, N]),
    ok = bench_peer:call(Peer, ?MODULE, begin_trace, [Pid]),
    Run(?TRACED_REQUESTS),
    Traced = bench_peer:call(Peer, ?MODULE, end_trace, [?TRACED_REQUESTS], 600000),
    bench_conn:close(C),
    print(Impl, Kind, N, Red, Traced, Opts),
    bench_peer:call(Peer, bench_node, stop_server, [5000]),
    bench_peer:stop(Peer),
    halt(0).

parse(["--impl", I | T], O) -> parse(T, O#{impl => list_to_atom(I)});
parse(["--request", R | T], O) -> parse(T, O#{request => list_to_atom(R)});
parse(["--requests", N | T], O) -> parse(T, O#{requests => list_to_integer(N)});
parse(["--top", N | T], O) -> parse(T, O#{top => list_to_integer(N)});
parse(["--show", P | T], O) -> parse(T, O#{show => P});
parse(["--callers" | T], O) -> parse(T, O#{callers => true});
parse([], O) -> O;
parse([X | _], _) -> error({unknown_argument, X}).

%% Runs in the server peer.
begin_reductions() ->
    erlang:garbage_collect(),
    timer:sleep(200),
    maps:from_list([{P, R} || P <- processes(), {reductions, R} <- [erlang:process_info(P, reductions)]]).

%% The reductions per request of the process that served them (the one
%% whose count grew most), and that process.
end_reductions(Before, N) ->
    Deltas = [{R - maps:get(P, Before, 0), P}
              || P <- processes(), {reductions, R} <- [erlang:process_info(P, reductions)]],
    {Red, Pid} = lists:max(Deltas),
    {Red / N, Pid}.

%% Trace every call Pid makes; the sink counts them by function and, for
%% the watched ones, by caller.
begin_trace(Pid) ->
    Sink = spawn(fun() -> sink(#{}, #{}) end),
    persistent_term:put({?MODULE, sink}, Sink),
    MS = [{'_', [], [{message, {caller}}]}],
    %% Local patterns see calls inside a module too; a global pattern on the
    %% same function would replace them, so BIFs (global only) go last and
    %% only those on the watch list.
    erlang:trace_pattern({'_', '_', '_'}, MS, [local]),
    [erlang:trace_pattern(MFA, MS, []) || {M, F, A} = MFA <- ?WATCH, erlang:is_builtin(M, F, A)],
    1 = erlang:trace(Pid, true, [call, {tracer, Sink}]),
    ok.

sink(Counts, Callers) ->
    receive
        {trace, _Pid, call, {M, F, Args}, Msg} ->
            MFA = {M, F, length(Args)},
            Caller = case Msg of {caller, C} -> C; C -> C end,
            Callers1 = case lists:member(MFA, ?WATCH) of
                true -> maps:update_with({MFA, Caller}, fun(X) -> X + 1 end, 1, Callers);
                false -> Callers
            end,
            sink(maps:update_with(MFA, fun(X) -> X + 1 end, 1, Counts), Callers1);
        {done, From} ->
            From ! {counts, Counts, Callers}
    end.

end_trace(N) ->
    erlang:trace(all, false, [call]),
    erlang:trace_pattern({'_', '_', '_'}, false, [local]),
    [erlang:trace_pattern(MFA, false, []) || {M, F, A} = MFA <- ?WATCH, erlang:is_builtin(M, F, A)],
    Sink = persistent_term:get({?MODULE, sink}),
    persistent_term:erase({?MODULE, sink}),
    Sink ! {done, self()},
    {Counts, Callers} = receive {counts, Cs, Cl} -> {Cs, Cl} after 60000 -> {#{}, #{}} end,
    #{calls => lists:sum(maps:values(Counts)) / N,
      watch => [{MFA, maps:get(MFA, Counts, 0) / N} || MFA <- ?WATCH],
      functions => lists:reverse(lists:sort([{C / N, MFA} || {MFA, C} <- maps:to_list(Counts)])),
      callers => lists:reverse(lists:sort([{C / N, MFA, Caller} || {{MFA, Caller}, C} <- maps:to_list(Callers)]))}.

print(Impl, Kind, N, Red, #{calls := Calls, watch := Watch, functions := Fs, callers := Callers}, Opts) ->
    io:format("== ~p ~p, per request on one keep-alive connection~n", [Impl, Kind]),
    io:format("reductions (connection process, ~p untraced requests)  ~10.1f~n", [N, Red]),
    io:format("function calls (connection process, ~p traced requests) ~9.1f~n~n", [?TRACED_REQUESTS, Calls]),
    io:format("watched, calls per request~n"),
    [io:format("  ~10.2f  ~p:~p/~p~n", [C, M, F, A]) || {{M, F, A}, C} <- Watch],
    Prefix = maps:get(show, Opts),
    Shown = [{C, MFA} || {C, {M, _, _} = MFA} <- Fs, lists:prefix(Prefix, atom_to_list(M))],
    io:format("~nfunctions in modules ~s*, top ~p by calls per request~n", [Prefix, maps:get(top, Opts)]),
    [io:format("  ~10.2f  ~p:~p/~p~n", [C, M, F, A]) || {C, {M, F, A}} <- lists:sublist(Shown, maps:get(top, Opts))],
    case maps:get(callers, Opts) of
        true ->
            io:format("~nwho calls the watched functions (calls per request)~n"),
            [io:format("  ~7.2f  ~p:~p/~p  <-  ~w~n", [C, M, F, A, Caller]) || {C, {M, F, A}, Caller} <- Callers];
        false -> ok
    end.
