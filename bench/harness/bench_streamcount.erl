%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Exact work per HTTP/2 stream (BT-4954): N sequential GETs, one
%% stream at a time, on one h2c connection to the standalone Buccaneer
%% server in a peer node. The client runs in this VM, so the peer's counts
%% hold only the server (connection, stream processes, runtime).
%%
%%   bench/run.sh bench_streamcount [--n 2000] [--out FILE]
%%
%% Prints, per stream: wall microseconds (untraced, sequential),
%% reductions of the whole server node (an idle window of the same length
%% is subtracted), and function calls (`call_count` on every loaded
%% function, again minus an idle window), by module and by function.
%% Counts do not move between runs; the timing does, so compare counts
%% and treat the microseconds as indicative. `--out FILE` writes the
%% per-function counts as one Erlang term, for diffing two builds
%% (`bench_streamcount:diff/2`).
-module(bench_streamcount).

-export([main/0, diff/2, reset_counts/0, read_counts/0]).

main() ->
    Opts = parse(init:get_plain_arguments(), #{n => 2000, out => none}),
    N = maps:get(n, Opts),
    Peer = bench_peer:start(buccaneer),
    {ok, Port} = bench_peer:call(Peer, bench_node, start_server, [#{tls => false}]),
    bench_load:wait_ready(Port, false, 120000),
    {ok, H0} = bench_h2:connect(Port),
    H1 = gets(H0, 1000),
    timer:sleep(500),
    %% Idle window: what the server does with no load, for the same time.
    %% Reductions and calls measured over the load window, minus this.
    {R0, _} = bench_peer:call(Peer, erlang, statistics, [reductions]),
    {Wall, H2} = timed(fun() -> gets(H1, N) end),
    {R1, _} = bench_peer:call(Peer, erlang, statistics, [reductions]),
    timer:sleep(Wall div 1000),
    {R2, _} = bench_peer:call(Peer, erlang, statistics, [reductions]),
    Red = R1 - R0,
    Idle = R2 - R1,
    bench_peer:call(Peer, ?MODULE, reset_counts, []),
    H3 = gets(H2, N),
    LoadCounts = bench_peer:call(Peer, ?MODULE, read_counts, []),
    bench_peer:call(Peer, ?MODULE, reset_counts, []),
    timer:sleep(Wall div 1000),
    IdleCounts = bench_peer:call(Peer, ?MODULE, read_counts, []),
    bench_h2:close(H3),
    Net = maps:fold(fun(K, V, Acc) ->
                        C = V - maps:get(K, IdleCounts, 0),
                        case C > 0 of true -> Acc#{K => C}; false -> Acc end
                    end, #{}, LoadCounts),
    report(N, Wall, Red - Idle, Net),
    case maps:get(out, Opts) of
        none -> ok;
        File -> ok = file:write_file(File, io_lib:format("~p.~n", [Net]))
    end,
    bench_peer:stop(Peer),
    halt(0).

report(N, Wall, Reductions, Net) ->
    Total = lists:sum(maps:values(Net)),
    ByMod = maps:to_list(maps:fold(fun({M, _, _}, V, A) ->
                                       maps:update_with(M, fun(X) -> X + V end, V, A)
                                   end, #{}, Net)),
    io:format("HTTP/2 per stream, ~p sequential GETs (untraced wall ~.1f us/stream):~n", [N, Wall / N]),
    io:format("~10.2f  server-node reductions per stream (idle subtracted)~n", [Reductions / N]),
    io:format("~10.2f  function calls per stream (all processes, idle subtracted)~n", [Total / N]),
    io:format("Calls per stream by module:~n"),
    [io:format("~10.2f  ~p~n", [V / N, M])
     || {M, V} <- lists:sublist(lists:reverse(lists:keysort(2, ByMod)), 25)],
    io:format("Calls per stream by function:~n"),
    [io:format("~10.2f  ~p~n", [V / N, MFA])
     || {MFA, V} <- lists:sublist(lists:reverse(lists:keysort(2, maps:to_list(Net))), 40)].

%% Diff two --out files: per-stream calls that differ, largest first, and
%% per-module totals. Counts were taken over the same N.
diff(FileA, FileB) ->
    {ok, [A]} = file:consult(FileA),
    {ok, [B]} = file:consult(FileB),
    Keys = lists:usort(maps:keys(A) ++ maps:keys(B)),
    Rows = [{maps:get(K, B, 0) - maps:get(K, A, 0), K} || K <- Keys],
    Mod = maps:to_list(lists:foldl(fun({D, {M, _, _}}, Acc) ->
                                       maps:update_with(M, fun(X) -> X + D end, D, Acc)
                                   end, #{}, Rows)),
    {lists:sublist(lists:reverse(lists:sort(Rows)), 40),
     lists:sublist(lists:reverse(lists:keysort(2, Mod)), 25),
     lists:sum([D || {D, _} <- Rows])}.

%% Runs in the peer.
reset_counts() ->
    [begin
         erlang:trace_pattern({M, '_', '_'}, true, [local, call_count]),
         erlang:trace_pattern({M, '_', '_'}, restart, [local, call_count])
     end || M <- traced_modules()],
    ok.

%% Everything loaded except the VM's own modules and this one: tracing
%% `erlang`, `erts_*`, `prim_*` and friends changes how the server behaves.
traced_modules() ->
    Skip = [erlang, ets, atomics, counters, persistent_term, init, code, code_server,
            os, file, prim_file, prim_inet, prim_net, prim_socket, prim_buffer, prim_zip,
            peer, erl_prim_loader, error_handler, application_master, ?MODULE],
    [M || {M, _} <- code:all_loaded(), not lists:member(M, Skip),
          not lists:prefix("erts_", atom_to_list(M)), not lists:prefix("prim_", atom_to_list(M))].

read_counts() ->
    [erlang:trace_pattern({M, '_', '_'}, pause, [local, call_count]) || M <- traced_modules()],
    Counts = maps:from_list(lists:append(
        [[{{M, F, A}, C}
          || {F, A} <- M:module_info(functions),
             M =/= ?MODULE,
             {call_count, C} <- [erlang:trace_info({M, F, A}, call_count)],
             is_integer(C), C > 0]
         || M <- traced_modules()])),
    [erlang:trace_pattern({M, '_', '_'}, false, [local, call_count]) || M <- traced_modules()],
    Counts.

timed(Fun) ->
    T0 = erlang:monotonic_time(microsecond),
    R = Fun(),
    {erlang:monotonic_time(microsecond) - T0, R}.

gets(H, 0) -> H;
gets(H, N) ->
    {Id, H1} = bench_h2:request(H, <<"/">>),
    gets(wait(Id, H1), N - 1).

wait(Id, H) ->
    case bench_h2:next_event(H) of
        {done, Id, 200, H1} -> H1;
        {done, _, _, H1} -> wait(Id, H1);
        Other -> error({h2_get, Other})
    end.

parse([], O) -> O;
parse(["--n", N | T], O) -> parse(T, O#{n => list_to_integer(N)});
parse(["--out", F | T], O) -> parse(T, O#{out => F});
parse([Other | _], _) -> error({bad_argument, Other}).
