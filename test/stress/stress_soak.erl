%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Soak: mixed load on beamtalk-http on Buccaneer for
%% `--soak-minutes` (30 by default, 1 with `--smoke`): HTTP/1.1 keep-alive
%% clients (GETs and echoes up to 64 KiB, bytes checked), churning
%% clients, TLS keep-alive clients and a TLS churner on a second (TLS)
%% server in the same node, HTTP/2 connections with 10 streams each,
%% WebSocket echo clients, and a pool of idle connections. The node is
%% sampled throughout.
%%
%% Passes when there are no client errors or corrupted bytes, the process
%% count and the memory floor do not grow (the last third of the samples
%% against the first third, after a warm-up sample), and once the load
%% stops the process, port and ETS counts return to the baseline and
%% memory settles back near it. As Catalina's soak, the trend check
%% compares the floor (lowest sample) of each third: retained memory
%% raises the floor, in-flight memory does not.
-module(stress_soak).

-export([tests/0]).

-define(KEYS, [processes, ports, ets]).

tests() ->
    [{"soak_mixed_load", [http_buccaneer], fun soak/1}].

soak(Ctx = #{soak_minutes := Minutes}) ->
    Ms = round(Minutes * 60000),
    Interval = max(1000, min(10000, Ms div 30)),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        {ok, _} = stress_leak:churn(Port, 200, 16, false),
        Base = stress_lib:baseline(Ctx, ?KEYS),
        {ok, TlsPort} = stress_lib:node_call(Ctx, start_server, [#{name => tls, tls => true}]),
        try
            stress_lib:ready(TlsPort, #{tls => true}),
            Idle = bench_load:open_idle(Port, stress_lib:pick(Ctx, {100, 500}), false),
            Load = start(Port, TlsPort),
            Samples = sample(Ctx, erlang:monotonic_time(millisecond) + Ms, Interval, []),
            Errors = stop(Load),
            bench_load:close_idle(Idle),
            stress_lib:node_call(Ctx, stop_server, [tls, 10000]),
            After = stress_lib:back_to(Ctx, Base, ?KEYS),
            judge(Base, After, Samples, Errors, Minutes)
        after
            stress_lib:node_call(Ctx, stop_server, [tls, 10000])
        end
    end).

judge(Base, After, Samples, Counts, Minutes) ->
    Bad = maps:filter(fun(K, _) -> is_tuple(K) end, Counts),
    stress_lib:check(maps:size(Counts) > 0 andalso lists:sum(maps:values(Counts)) > 0, "the load ran", Counts),
    stress_lib:check(Bad =:= #{}, "no client errors or corrupted bytes", Bad),
    Steady = tl(lists:reverse(Samples)),
    Third = max(1, length(Steady) div 3),
    First = lists:sublist(Steady, Third),
    Last = lists:nthtail(length(Steady) - Third, Steady),
    Max = fun(K, L) -> lists:max([maps:get(K, S) || S <- L]) end,
    Min = fun(K, L) -> lists:min([maps:get(K, S) || S <- L]) end,
    ProcGrowth = Max(processes, Last) - Max(processes, First),
    MemFirst = Min(memory, First),
    MemLast = Min(memory, Last),
    stress_lib:check(ProcGrowth =< 50, "process count does not grow", {Max(processes, First), Max(processes, Last)}),
    stress_lib:check(MemLast =< MemFirst * 1.10 + 16 * 1048576, "the memory floor does not grow",
                     {round(MemFirst), round(MemLast)}),
    Settled = maps:get(memory, After),
    stress_lib:check(Settled =< maps:get(memory, Base) * 1.10 + 16 * 1048576,
                     "memory settles back to the baseline after the load", {maps:get(memory, Base), Settled}),
    stress_lib:check_ets_rows(Base, After, lists:sum(maps:values(Counts))),
    Counts#{minutes => Minutes, samples => length(Samples),
            processes_first_last => {Max(processes, First), Max(processes, Last)},
            memory_floor_mib_first_last => {round(MemFirst / 1048576), round(MemLast / 1048576)},
            memory_mib_base_settled => {round(maps:get(memory, Base) / 1048576), round(Settled / 1048576)}}.

sample(Ctx, Deadline, Interval, Acc) ->
    Acc1 = [stress_lib:stats(Ctx) | Acc],
    case erlang:monotonic_time(millisecond) + Interval > Deadline of
        true -> Acc1;
        false ->
            timer:sleep(Interval),
            sample(Ctx, Deadline, Interval, Acc1)
    end.

%% === Load ===

start(Port, TlsPort) ->
    Stop = atomics:new(1, []),
    Self = self(),
    Spawn = fun(F) -> spawn_link(fun() -> Self ! {soak, self(), F()} end) end,
    Pids = [Spawn(fun() -> keepalive(Port, false, Stop, 65536) end) || _ <- lists:seq(1, 8)]
        ++ [Spawn(fun() -> keepalive(Port, false, Stop, 512) end) || _ <- lists:seq(1, 8)]
        ++ [Spawn(fun() -> churn(Port, false, Stop, #{}) end) || _ <- lists:seq(1, 4)]
        ++ [Spawn(fun() -> keepalive(TlsPort, true, Stop, 16384) end) || _ <- lists:seq(1, 4)]
        ++ [Spawn(fun() -> churn(TlsPort, true, Stop, #{}) end)]
        ++ [Spawn(fun() -> h2(Port, Stop) end) || _ <- lists:seq(1, 4)]
        ++ [Spawn(fun() -> ws(Port, Stop) end) || _ <- lists:seq(1, 8)],
    {Stop, Pids}.

stop({Stop, Pids}) ->
    atomics:put(Stop, 1, 1),
    stress_lib:merge_counts([receive {soak, P, R} -> R after 120000 -> #{{stuck, P} => 1} end || P <- Pids]).

%% A keep-alive connection: GETs and echoes of up to MaxSize bytes.
keepalive(Port, Tls, Stop, MaxSize) ->
    {ok, C} = bench_conn:connect(Port, Tls),
    keepalive_loop(C, <<>>, Stop, MaxSize, #{}).

keepalive_loop(C, Buf, Stop, MaxSize, Acc) ->
    case atomics:get(Stop, 1) of
        1 -> bench_conn:close(C), Acc;
        0 ->
            R = case rand:uniform(3) of
                1 -> stress_lib:get_once(C, Buf);
                _ -> stress_lib:post_once(C, Buf, rand:bytes(rand:uniform(MaxSize)))
            end,
            case R of
                {ok, Rest} -> keepalive_loop(C, Rest, Stop, MaxSize, stress_lib:bump(http1, Acc));
                Other -> bench_conn:close(C), stress_lib:bump({http1, Other}, Acc)
            end
    end.

churn(Port, Tls, Stop, Acc) ->
    case atomics:get(Stop, 1) of
        1 -> Acc;
        0 ->
            R = case bench_conn:connect(Port, Tls) of
                {ok, C} ->
                    ok = bench_conn:send(C, bench_http:get(<<"/">>, [{<<"connection">>, <<"close">>}])),
                    X = case bench_http:read_response(C, <<>>, keep) of
                        {ok, {200, true, <<"hello world">>}, _} -> churn;
                        Other -> {churn, Other}
                    end,
                    bench_conn:close(C),
                    X;
                E -> {churn_connect, E}
            end,
            churn(Port, Tls, Stop, stress_lib:bump(R, Acc))
    end.

h2(Port, Stop) ->
    {ok, H0} = bench_h2:connect(Port),
    H = lists:foldl(fun(_, H1) -> element(2, bench_h2:request(H1, <<"/">>)) end, H0, lists:seq(1, 10)),
    h2_loop(H, 10, Stop, #{}).

h2_loop(H, 0, _Stop, Acc) -> bench_h2:close(H), Acc;
h2_loop(H, Open, Stop, Acc) ->
    case bench_h2:next_event(H) of
        {done, _, 200, H1} ->
            case atomics:get(Stop, 1) of
                1 -> h2_loop(H1, Open - 1, Stop, stress_lib:bump(h2, Acc));
                0 ->
                    {_, H2} = bench_h2:request(H1, <<"/">>),
                    h2_loop(H2, Open, Stop, stress_lib:bump(h2, Acc))
            end;
        Other -> stress_lib:bump({h2, element(1, Other)}, Acc)
    end.

ws(Port, Stop) ->
    {ok, W} = bench_ws:connect(Port),
    ws_loop(W, Stop, #{}).

ws_loop(W, Stop, Acc) ->
    case atomics:get(Stop, 1) of
        1 -> bench_ws:close(W), Acc;
        0 ->
            Msg = binary:copy(<<"w">>, rand:uniform(8192)),
            case bench_ws:echo(W, Msg) of
                {ok, W1} -> ws_loop(W1, Stop, stress_lib:bump(ws, Acc));
                Other -> bench_ws:close(W), stress_lib:bump({ws, Other}, Acc)
            end
    end.
