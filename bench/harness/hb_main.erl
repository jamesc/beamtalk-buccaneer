%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc `just spike-bench` (Phase 0 spike 1): keep-alive `GET /` against the
%% Buccaneer spike (Catalina + `SpikeHandler`), beamtalk-http 0.1.10 on
%% cowboy (the release gate's baseline) and Bandit 1.12.5 (context).
%%
%% Each server runs in its own peer VM for the whole run, the load
%% generator in this one. Every round measures every row once per server,
%% back to back, rotating which goes first, so the load of the shared
%% machine hits all three alike; the load average is recorded with every
%% measurement. The report gives medians over the rounds and the Buccaneer
%% ratios. A parse microbenchmark runs in the Buccaneer node once per round.
%%
%%   bench/run.sh [--rounds 5] [--duration 5000] [--warmup 1000]
%%                [--conns 1,10,100] [--rows smoke] [--out DIR] [--profile]
%%
%% `--profile` adds, after the rounds, a sampling profile of the Buccaneer
%% node under a 10-connection load and of the parse, plus the processes
%% with the longest message queues (the serialisation points).
-module(hb_main).

-export([main/0]).

main() ->
    Opts = parse(init:get_plain_arguments(), #{
        rounds => 5, duration => 5000, warmup => 1000, conns => [1, 10, 100],
        out => filename:join([os:getenv("BENCH_ROOT"), "_build", "bench"])
    }),
    try run(Opts) of
        ok -> halt(0)
    catch
        C:R:St ->
            io:format(standard_error, "bench failed: ~p:~p~n~p~n", [C, R, St]),
            halt(1)
    end.

parse(["--rounds", N | T], O) -> parse(T, O#{rounds => list_to_integer(N)});
parse(["--duration", N | T], O) -> parse(T, O#{duration => list_to_integer(N)});
parse(["--warmup", N | T], O) -> parse(T, O#{warmup => list_to_integer(N)});
parse(["--conns", L | T], O) ->
    parse(T, O#{conns => [list_to_integer(C) || C <- string:split(L, ",", all)]});
parse(["--rows", "smoke" | T], O) ->
    parse(T, O#{rounds => 1, duration => 1000, warmup => 300, conns => [1, 10]});
parse(["--out", D | T], O) -> parse(T, O#{out => D});
parse(["--profile" | T], O) -> parse(T, O#{profile => true});
parse([], O) -> O;
parse([X | _], _) -> error({unknown_argument, X}).

rows(#{conns := Conns}) ->
    [{"get_c" ++ integer_to_list(C), #{conns => C}} || C <- Conns].

%% === The run ===

run(Opts = #{rounds := Rounds, out := Out}) ->
    ok = filelib:ensure_path(Out),
    Rows = rows(Opts),
    Stamp = calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}]),
    Tag = [C || C <- Stamp, C =/= $:],
    RawFile = filename:join(Out, "raw-" ++ Tag ++ ".jsonl"),
    {ok, Raw} = file:open(RawFile, [write]),
    Env = environment(),
    log("spike-bench: ~p rounds, ~p rows, ~p ms per measurement; load ~s~n",
        [Rounds, length(Rows), maps:get(duration, Opts), load()]),
    Impls = hb_peer:impls(),
    Peers = maps:from_list([{I, hb_peer:start(I)} || I <- Impls]),
    {Results, Parses} = lists:unzip(
        [round(R, Rows, Impls, Peers, Opts, Raw) || R <- lists:seq(1, Rounds)]),
    Profile = case maps:get(profile, Opts, false) of
        true -> profile(maps:get(buccaneer, Peers), Opts);
        false -> []
    end,
    [hb_peer:stop(P) || P <- maps:values(Peers)],
    file:close(Raw),
    Report = [report(Rows, lists:append(Results), Parses,
                     Env#{started => Stamp, finished_load => load(), opts => Opts}),
              Profile],
    ReportFile = filename:join(Out, "report-" ++ Tag ++ ".md"),
    ok = file:write_file(ReportFile, Report),
    io:put_chars(Report),
    log("~nraw: ~s~nreport: ~s~n", [RawFile, ReportFile]),
    ok.

round(R, Rows, Impls, Peers, Opts, Raw) ->
    Order = rotate(Impls, R - 1),
    log("round ~p (load ~s)~n", [R, load()]),
    Parse = hb_peer:call(maps:get(buccaneer, Peers), hb_node, parse_bench, [20000]),
    log("  parse  ~p~n", [Parse]),
    Ms = lists:append([[measure(R, Row, I, maps:get(I, Peers), Opts, Raw) || I <- Order]
                       || Row <- Rows]),
    {Ms, Parse}.

rotate(L, 0) -> L;
rotate([H | T], N) -> rotate(T ++ [H], N - 1).

measure(Round, {Id, Params}, Impl, Peer, Opts, Raw) ->
    Load = load(),
    {ok, Port} = hb_peer:call(Peer, hb_node, start_server, [#{port => 0}]),
    Metrics = try
        hb_load:wait_ready(Port, 120000),
        hb_load:get(Port, Params#{
            warmup_ms => maps:get(warmup, Opts), duration_ms => maps:get(duration, Opts)})
    after
        hb_peer:call(Peer, hb_node, stop_server, [5000])
    end,
    Rec = #{round => Round, row => list_to_binary(Id), impl => Impl,
            load => list_to_binary(Load), metrics => Metrics},
    io:format(Raw, "~s~n", [json:encode(jsonable(Rec))]),
    log("  ~-10s ~-10s ~s  (load ~s)~n", [Id, Impl, brief(Metrics), Load]),
    {Id, Impl, Metrics#{load => Load}}.

brief(#{rps := R, p50 := P50, p99 := P99, errors := E, server_closes := C}) ->
    io_lib:format("~10.1f req/s  p50 ~s  p99 ~s  errors ~p  server closes ~p",
                  [R, us(P50), us(P99), E, C]);
brief(M) ->
    io_lib:format("~p", [M]).

us(undefined) -> "-";
us(V) when V >= 1000 -> io_lib:format("~.2fms", [V / 1000]);
us(V) -> io_lib:format("~wus", [round(V)]).

%% === Profile ===

profile(Peer, _Opts) ->
    log("profile (load ~s)~n", [load()]),
    Parse = hb_peer:call(Peer, hb_node, profile_parse, [20000]),
    {ok, Port} = hb_peer:call(Peer, hb_node, start_server, [#{port => 0}]),
    hb_load:wait_ready(Port, 120000),
    Calls = class_calls(Peer, Port, 10000),
    Self = self(),
    Load = spawn(fun() ->
        Self ! {load, hb_load:get(Port, #{conns => 10, warmup_ms => 500, duration_ms => 8000})}
    end),
    timer:sleep(700),
    Requests = hb_peer:call(Peer, hb_node, profile_requests, [1000]),
    Queues = hb_peer:call(Peer, hb_node, queue_samples, [20, 5]),
    M = receive {load, R} -> R after 120000 -> exit(Load, kill), #{} end,
    hb_peer:call(Peer, hb_node, stop_server, [5000]),
    [io_lib:format("~n## Profile (Buccaneer node, `--profile`)~n~n"
                   "Under a 10-connection load (~s, while sampled):~n~n", [brief(M)]),
     "Longest message queues, sampled every 100 ms (queue length, process):\n\n```\n",
     [io_lib:format("~0p~n", [Q]) || Q <- Queues],
     "```\n",
     "\n### Calls into class processes per request (10,000 sequential requests, one connection)\n\n"
     "| per request | class process |\n|---:|---|\n",
     [io_lib:format("| ~.2f | `~s` |~n", [In / 10000, Nm]) || {In, Nm} <- Calls],
     profile_table("Handlers in a request and running processes, sampled", Requests),
     profile_table("The parse alone (`SpikeParser readHead:socket:` in a loop), sampled", Parse)].

class_calls(Peer, Port, N) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}, {nodelay, true}]),
    ok = hb_peer:call(Peer, hb_node, class_stats_on, []),
    lists:foldl(fun(_, B) ->
        ok = gen_tcp:send(S, <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
        {ok, 200, R} = hb_load:read_response(S, B),
        R
    end, <<>>, lists:seq(1, N)),
    gen_tcp:close(S),
    hb_peer:call(Peer, hb_node, class_stats, []).

profile_table(Title, #{samples := N, inclusive := I, self := S}) ->
    [io_lib:format("~n### ~s (~p stacks)~n~n| % on stack | function |~n|---:|---|~n", [Title, N]),
     [io_lib:format("| ~p | `~s` |~n", [P, F]) || {P, F} <- lists:sublist(I, 20)],
     "\n| % at top | function |\n|---:|---|\n",
     [io_lib:format("| ~p | `~s` |~n", [P, F]) || {P, F} <- lists:sublist(S, 15)]].

%% === Report ===

metrics() -> [{rps, "req/s"}, {p50, "p50 us"}, {p99, "p99 us"}, {p999, "p99.9 us"}].

report(Rows, Results, Parses, Env) ->
    O = maps:get(opts, Env),
    Header = io_lib:format(
        "# Spike 1: HTTP/1 keep-alive GET~n~n"
        "- Started: ~s~n- Machine: ~s~n- OS: ~s~n- OTP: ~s (ERTS ~s), ~p schedulers~n"
        "- Elixir: ~s~n- Beamtalk: ~s~n- Buccaneer worktree: ~s~n"
        "- Servers: Buccaneer spike (Catalina + SpikeHandler), beamtalk-http 0.1.10 on cowboy, Bandit 1.12.5~n"
        "- Rounds: ~p, ~p ms measured after ~p ms warm-up per measurement~n"
        "- Load at start: ~s~n- Load at end: ~s~n- Load per measurement: ~s~n~n"
        "Medians over the rounds. `B/cowboy` and `B/Bandit` are Buccaneer / the other: "
        "above 1 is better for Buccaneer on req/s, worse on latency.~n~n"
        "| Row | Metric | Buccaneer spike | cowboy | Bandit | B/cowboy | B/Bandit | Buccaneer rounds | cowboy rounds | Bandit rounds |~n"
        "|---|---|---:|---:|---:|---:|---:|---|---|---|~n",
        [maps:get(started, Env), maps:get(machine, Env), maps:get(os, Env),
         maps:get(otp, Env), maps:get(erts, Env), maps:get(schedulers, Env),
         maps:get(elixir, Env), maps:get(beamtalk, Env), maps:get(buccaneer, Env),
         maps:get(rounds, O), maps:get(duration, O), maps:get(warmup, O),
         maps:get(load, Env), maps:get(finished_load, Env), load_range(Results)]),
    Lines = [row_lines(Id, Results) || {Id, _} <- Rows],
    ParseLines = parse_lines(Parses),
    [Header, Lines, ParseLines].

row_lines(Id, Results) ->
    [begin
        [B, C, D] = [values(Id, I, Key, Results) || I <- [buccaneer, cowboy, bandit]],
        [Mb, Mc, Md] = [median(V) || V <- [B, C, D]],
        io_lib:format("| ~s | ~s | ~s | ~s | ~s | ~s | ~s | ~s | ~s | ~s |~n",
                      [Id, Label, fmt(Mb), fmt(Mc), fmt(Md), ratio(Mb, Mc), ratio(Mb, Md),
                       all(B), all(C), all(D)])
     end || {Key, Label} <- metrics()].

parse_lines(Parses) ->
    E = median([maps:get(erlang_ns, P) || P <- Parses]),
    B = median([maps:get(beamtalk_ns, P) || P <- Parses]),
    D = median([maps:get(bare_decode_packet_ns, P) || P <- Parses]),
    R = median([maps:get(result_ok_ns, P) || P <- Parses]),
    io_lib:format(
        "~n## Parse microbenchmark (Buccaneer node, 20,000 parses per round)~n~n"
        "The spike's 7-header GET head, request line to `http_eoh`.~n~n"
        "| Parser | ns per request head | rounds |~n|---|---:|---|~n"
        "| Erlang, `decode_packet` + lowercase names (Bandit's path) | ~s | ~s |~n"
        "| Beamtalk `SpikeParser readHead:socket:` | ~s | ~s |~n"
        "| One bare `decode_packet(http_bin, ...)` call (request line only) | ~s | ~s |~n"
        "| One `Result ok:` via class_send (the pre-BT-4065 path, for reference) | ~s | ~s |~n"
        "| Ratio Beamtalk / Erlang | ~s | |~n",
        [fmt(E), all([maps:get(erlang_ns, P) || P <- Parses]),
         fmt(B), all([maps:get(beamtalk_ns, P) || P <- Parses]),
         fmt(D), all([maps:get(bare_decode_packet_ns, P) || P <- Parses]),
         fmt(R), all([maps:get(result_ok_ns, P) || P <- Parses]),
         ratio(B, E)]).

values(Id, Impl, Key, Results) ->
    [V || {I, Im, M} <- Results, I =:= Id, Im =:= Impl,
          V <- [maps:get(Key, M, undefined)], is_number(V)].

load_range(Results) ->
    Ones = [list_to_float(hd(string:lexemes(maps:get(load, M), " ")))
            || {_, _, M} <- Results, is_list(maps:get(load, M, undefined))],
    case Ones of
        [] -> "-";
        _ -> io_lib:format("1-min ~.2f to ~.2f", [lists:min(Ones), lists:max(Ones)])
    end.

median([]) -> undefined;
median(Vs) ->
    S = lists:sort(Vs),
    N = length(S),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

ratio(undefined, _) -> "-";
ratio(_, undefined) -> "-";
ratio(_, T) when T == 0 -> "-";
ratio(C, T) -> io_lib:format("~.3f", [C / T]).

fmt(undefined) -> "-";
fmt(V) when V >= 100 -> integer_to_list(round(V));
fmt(V) -> io_lib:format("~.1f", [float(V)]).

all(Vs) -> lists:join(", ", [fmt(V) || V <- Vs]).

%% === Environment ===

environment() ->
    #{
        machine => machine(),
        os => trim(os:cmd("uname -sr")),
        otp => erlang:system_info(otp_release),
        erts => erlang:system_info(version),
        schedulers => erlang:system_info(schedulers_online),
        elixir => env_or("BENCH_ELIXIR_VERSION", "?"),
        beamtalk => env_or("BENCH_BEAMTALK_VERSION", "?"),
        buccaneer => env_or("BENCH_BUCCANEER_REV", "?"),
        load => load()
    }.

machine() ->
    case os:type() of
        {unix, darwin} ->
            trim(os:cmd("sysctl -n machdep.cpu.brand_string")) ++ ", "
                ++ trim(os:cmd("sysctl -n hw.ncpu")) ++ " cores, "
                ++ integer_to_list(list_to_integer(trim(os:cmd("sysctl -n hw.memsize"))) div (1 bsl 30))
                ++ " GiB";
        _ ->
            trim(os:cmd("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2")) ++ ", "
                ++ trim(os:cmd("nproc")) ++ " cores"
    end.

%% The 1/5/15-minute load averages.
load() ->
    case file:read_file("/proc/loadavg") of
        {ok, B} ->
            string:join(lists:sublist(string:lexemes(binary_to_list(B), " "), 3), " ");
        _ ->
            trim(string:replace(string:replace(os:cmd("sysctl -n vm.loadavg"), "{", ""), "}", ""))
    end.

env_or(K, D) -> case os:getenv(K) of false -> D; "" -> D; V -> V end.

trim(S) -> string:trim(lists:flatten(S)).

jsonable(M) when is_map(M) -> maps:map(fun(_, V) -> jsonable(V) end, M);
jsonable(L) when is_list(L) -> [jsonable(X) || X <- L];
jsonable(undefined) -> null;
jsonable(A) when is_atom(A) -> A;
jsonable(N) when is_number(N) -> N;
jsonable(B) when is_binary(B) -> B;
jsonable(T) -> iolist_to_binary(io_lib:format("~0p", [T])).

log(F, A) -> io:format(standard_error, F, A).
