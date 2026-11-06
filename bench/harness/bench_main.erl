%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc `just bench`: the release gate. beamtalk-http on Buccaneer against
%% beamtalk-http on cowboy (the gate), with Buccaneer standalone, bare
%% cowboy (a plain Erlang handler) and Bandit 1.12.5 for context.
%%
%% Every implementation runs in its own peer VM for the whole run, the load
%% generator in this one. Every round measures every row once per
%% implementation, back to back, rotating which goes first, so machine
%% load (the box is shared) hits all alike. Each measurement starts a
%% fresh server. The report gives every round, the medians, the spread
%% (min-max over rounds) and the ratios against cowboy and Bandit.
%%
%%   erl -noshell -pa _build/bench/ebin -s bench_main main -extra \
%%       [--rounds 5] [--duration 5000] [--warmup 1000] [--rows full|smoke]
%%       [--only ROWID,...] [--impls a,b,...] [--out DIR] [--max-load L]
%%
%% The gate rule, per gate row and metric (requests/s and p99): Buccaneer
%% misses when its median is worse than the baseline's worst round (below
%% its lowest requests/s, above its highest p99), that is, worse beyond
%% the rounds' spread. The baseline is cowboy, except on `file_1MiB_c10`,
%% which is gated against Bandit's sendfile: beamtalk-http's cowboy
%% backend cannot send files, so cowboy answers that row from memory.
%%
%% Bare cowboy is reporting only: it splits the gap between the gate pair
%% into engine (Buccaneer standalone ÷ bare cowboy) and adapter
%% ((B ÷ standalone) ÷ (beamtalk-http on cowboy ÷ bare cowboy)).
-module(bench_main).

-export([main/0, rows/1]).

main() ->
    Opts = parse(init:get_plain_arguments(), #{
        rounds => 5, duration => 5000, warmup => 1000, rows => full,
        only => [], impls => bench_peer:bench_impls(), max_load => undefined,
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
parse(["--rows", R | T], O) -> parse(T, O#{rows => list_to_atom(R)});
parse(["--only", R | T], O) -> parse(T, O#{only => string:split(R, ",", all)});
parse(["--impls", R | T], O) -> parse(T, O#{impls => [list_to_atom(I) || I <- string:split(R, ",", all)]});
parse(["--out", D | T], O) -> parse(T, O#{out => D});
parse(["--max-load", L | T], O) -> parse(T, O#{max_load => list_to_number(L)});
parse([], O) -> O;
parse([X | _], _) -> error({unknown_argument, X}).

list_to_number(S) ->
    try list_to_integer(S) catch error:badarg -> list_to_float(S) end.

%% === Rows ===

%% {Id, Kind, Params, Class}. Class `gate` rows decide the gate against
%% cowboy, `{gate, bandit}` rows against Bandit (cowboy still runs, for
%% reference); `context` rows (HTTP/2, WebSocket: beamtalk-http does not
%% serve them on cowboy) skip cowboy; `memory` rows are reported, not
%% gated (no throughput).
rows(full) ->
    [{"get_c" ++ integer_to_list(C), http, #{conns => C}, gate} || C <- [1, 10, 100, 1000]]
    ++ [{"post_echo_64KiB_c10", http, #{conns => 10, method => <<"POST">>, path => <<"/echo">>,
                                        body => binary:copy(<<"p">>, 65536), expect => 65536}, gate},
        {"chunked_1MiB_c10", http, #{conns => 10, path => <<"/chunked">>, expect => 1048576}, gate},
        %% Like for like: sendfile against Bandit's sendfile (BT-4468).
        {"file_1MiB_c10", http, #{conns => 10, path => <<"/file">>, expect => 1048576}, {gate, bandit}},
        {"churn_close_w32", churn, #{workers => 32}, gate},
        {"tls_handshake_w32", churn, #{workers => 32, tls => true}, gate},
        {"tls_get_c100", http, #{conns => 100, tls => true}, gate},
        {"idle_10k", idle, #{conns => 10000}, memory},
        {"h2_get_10x10", h2, #{conns => 10, streams => 10}, context},
        {"ws_echo_c100", ws, #{conns => 100, size => 64}, context}];
rows(smoke) ->
    [{"get_c10", http, #{conns => 10}, gate},
     {"post_echo_64KiB_c10", http, #{conns => 10, method => <<"POST">>, path => <<"/echo">>,
                                     body => binary:copy(<<"p">>, 65536), expect => 65536}, gate},
     {"chunked_1MiB_c10", http, #{conns => 10, path => <<"/chunked">>, expect => 1048576}, gate},
     {"churn_close_w8", churn, #{workers => 8}, gate},
     {"tls_get_c10", http, #{conns => 10, tls => true}, gate},
     {"idle_1k", idle, #{conns => 1000}, memory},
     {"h2_get_2x10", h2, #{conns => 2, streams => 10}, context},
     {"ws_echo_c10", ws, #{conns => 10, size => 64}, context}].

impls_for(context, Impls) -> Impls -- [http_cowboy];
impls_for(_, Impls) -> Impls.

%% === The run ===

run(Opts = #{rounds := Rounds, out := Out}) ->
    ok = filelib:ensure_path(Out),
    {ok, _} = application:ensure_all_started(ssl),
    Rows = select(rows(maps:get(rows, Opts)), maps:get(only, Opts)),
    Stamp = calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}]),
    Tag = [C || C <- Stamp, C =/= $:],
    RawFile = filename:join(Out, "raw-" ++ Tag ++ ".jsonl"),
    {ok, Raw} = file:open(RawFile, [write]),
    Env = environment(),
    Impls = maps:get(impls, Opts),
    log("bench: ~p rounds, ~p rows, ~p ms per measurement, ~p; ~s~n",
        [Rounds, length(Rows), maps:get(duration, Opts), Impls, load()]),
    Peers = maps:from_list([{I, bench_peer:start(I)} || I <- Impls]),
    PerRound = [round(R, Rows, Peers, Opts, Raw) || R <- lists:seq(1, Rounds)],
    Results = lists:append([Rs || {_, _, Rs} <- PerRound]),
    [bench_peer:stop(P) || P <- maps:values(Peers)],
    file:close(Raw),
    Report = [report(Rows, Results, Impls, Env#{started => Stamp, finished_load => load(), opts => Opts}),
              "\nLoad average (1, 5, 15 min) at the start of each round:\n\n",
              [io_lib:format("- round ~p: ~s~n", [R, L]) || {R, L, _} <- PerRound]],
    ReportFile = filename:join(Out, "report-" ++ Tag ++ ".md"),
    ok = file:write_file(ReportFile, unicode:characters_to_binary(Report)),
    io:put_chars(unicode:characters_to_binary(Report)),
    log("~nraw: ~s~nreport: ~s~n", [RawFile, ReportFile]),
    ok.

select(Rows, []) -> Rows;
select(Rows, Only) -> [R || R = {Id, _, _, _} <- Rows, lists:member(Id, Only)].

round(R, Rows, Peers, Opts, Raw) ->
    Base = maps:get(impls, Opts),
    %% Rotate the order each round so no implementation always goes first.
    Shift = (R - 1) rem length(Base),
    Order = lists:nthtail(Shift, Base) ++ lists:sublist(Base, Shift),
    wait_for_quiet(maps:get(max_load, Opts), erlang:monotonic_time(second) + 1800),
    Load = load(),
    log("round ~p (~s)~n", [R, Load]),
    {R, Load, lists:append([[measure(R, Row, I, maps:get(I, Peers), Opts, Raw)
                             || I <- impls_for(Class, Order)]
                            || Row = {_, _, _, Class} <- Rows])}.

measure(Round, {Id, Kind, Params, _Class}, Impl, Peer, Opts, Raw) ->
    Load = load(),
    Tls = maps:get(tls, Params, false),
    Metrics = case bench_peer:call(Peer, bench_node, start_server, [#{tls => Tls}]) of
        {ok, Port} ->
            try
                bench_load:wait_ready(Port, Tls, 120000),
                run_row(Kind, Port, Peer, Params#{
                    warmup_ms => maps:get(warmup, Opts), duration_ms => maps:get(duration, Opts)})
            catch
                C:R:St -> #{errors => 1, error_reasons => [{C, R, hd(St)}]}
            after
                bench_peer:call(Peer, bench_node, stop_server, [5000])
            end;
        Error ->
            #{errors => 1, error_reasons => [Error]}
    end,
    Rec = #{round => Round, row => list_to_binary(Id), impl => Impl,
            load => list_to_binary(Load), metrics => Metrics},
    io:format(Raw, "~s~n", [json:encode(jsonable(Rec))]),
    log("  ~-22s ~-15s ~s~n", [Id, Impl, brief(Kind, Metrics)]),
    {Id, Impl, Metrics}.

run_row(http, Port, _Peer, P) -> bench_load:http(Port, P);
run_row(churn, Port, _Peer, P) -> bench_load:churn(Port, P);
run_row(h2, Port, _Peer, P) -> bench_load:h2(Port, P);
run_row(ws, Port, _Peer, P) -> bench_load:ws(Port, P);
run_row(idle, Port, Peer, #{conns := N}) ->
    Before = settled_stats(Peer),
    Idle = bench_load:open_idle(Port, N, false),
    {_, Opened, Failures} = Idle,
    After = settled_stats(Peer),
    bench_load:close_idle(Idle),
    Held = maps:get(connections, After),
    Base = #{opened => Opened, server_connections => Held,
             open_failures => lists:sublist(lists:usort(Failures), 3)},
    case Opened =:= N andalso Held >= N of
        true ->
            D = fun(K) -> (maps:get(K, After) - maps:get(K, Before)) / N end,
            Base#{bytes_per_conn => D(memory),
                  process_bytes_per_conn => D(process_memory),
                  processes_per_conn => D(processes),
                  errors => 0};
        false ->
            Base#{errors => 1, error_reasons => [incomplete]}
    end.

%% Node stats once the process count has stopped changing, after GC.
settled_stats(Peer) -> settled_stats(Peer, undefined, 40).

settled_stats(Peer, Prev, Tries) ->
    bench_peer:call(Peer, bench_node, gc_all, []),
    timer:sleep(500),
    S = bench_peer:call(Peer, bench_node, stats, []),
    Now = maps:get(processes, S),
    case Now =:= Prev orelse Tries =:= 0 of
        true -> S;
        false -> settled_stats(Peer, Now, Tries - 1)
    end.

brief(idle, #{bytes_per_conn := B, processes_per_conn := P, opened := O}) ->
    io_lib:format("~p conns  ~w B/conn  ~.2f procs/conn", [O, round(B), P]);
brief(_, #{rps := R, p50 := P50, p99 := P99, errors := E}) ->
    io_lib:format("~10.1f /s  p50 ~s  p99 ~s  errors ~p", [R, us(P50), us(P99), E]);
brief(_, M) ->
    io_lib:format("~0P", [M, 20]).

us(undefined) -> "-";
us(V) when V >= 1000 -> io_lib:format("~.2fms", [V / 1000]);
us(V) -> io_lib:format("~wus", [round(V)]).

wait_for_quiet(undefined, _) -> ok;
wait_for_quiet(Max, Deadline) ->
    [L | _] = string:lexemes(load(), " "),
    case list_to_number(string:trim(L)) < Max orelse erlang:monotonic_time(second) > Deadline of
        true -> ok;
        false ->
            log("  load ~s >= ~p, waiting~n", [L, Max]),
            timer:sleep(30000),
            wait_for_quiet(Max, Deadline)
    end.

%% === Report ===

%% {key, label, better}
metrics(idle) ->
    [{bytes_per_conn, "node bytes/conn", lower},
     {process_bytes_per_conn, "process bytes/conn", lower},
     {processes_per_conn, "processes/conn", lower}];
metrics(Kind) when Kind =:= http; Kind =:= churn ->
    [{rps, "req/s", higher}, {bytes_per_s, "MB/s", higher},
     {p50, "p50 µs", lower}, {p99, "p99 µs", lower}, {p999, "p99.9 µs", lower}];
metrics(_) ->
    [{rps, "req/s", higher}, {p50, "p50 µs", lower}, {p99, "p99 µs", lower}, {p999, "p99.9 µs", lower}].

gated(rps) -> true;
gated(p99) -> true;
gated(_) -> false.

report(Rows, Results, Impls, Env) ->
    Opts = maps:get(opts, Env),
    Header = io_lib:format(
        "# Buccaneer release gate~n~n"
        "- Started: ~s~n- Machine: ~s~n- OS: ~s~n- OTP: ~s (ERTS ~s), ~p schedulers~n"
        "- Beamtalk: ~s~n- Buccaneer: ~s~n- beamtalk-http: ~s~n- cowboy: ~s~n"
        "- Elixir: ~s~n- Bandit: ~s~n"
        "- Rounds: ~p, ~p ms measured after ~p ms warm-up per measurement~n"
        "- Load at start: ~s~n- Load at end: ~s~n~n",
        [maps:get(started, Env), maps:get(machine, Env), maps:get(os, Env),
         maps:get(otp, Env), maps:get(erts, Env), maps:get(schedulers, Env),
         maps:get(beamtalk, Env), maps:get(buccaneer, Env), maps:get(http, Env),
         maps:get(cowboy, Env), maps:get(elixir, Env), maps:get(bandit, Env),
         maps:get(rounds, Opts), maps:get(duration, Opts), maps:get(warmup, Opts),
         maps:get(load, Env), maps:get(finished_load, Env)]),
    Gate = ["## The gate\n\n"
            "beamtalk-http on Buccaneer (B) against the row's baseline, medians "
            "over the rounds; `spread` is each side's min-max over the rounds. A metric "
            "misses when B's median is worse than the baseline's worst round. The "
            "baseline is beamtalk-http on cowboy, except where the Baseline column "
            "says Bandit (`file_1MiB_c10`: cowboy cannot send files and answers it "
            "from memory).\n\n"
            "| Row | Metric | Baseline | B median | B spread | Base median | Base spread | B/base | Gate |\n"
            "|---|---|---|---:|---|---:|---|---:|---|\n",
            [gate_lines(Id, Kind, Base, Results) || {Id, Kind, _, Class} <- Rows,
                                                    Base <- gate_baseline(Class)],
            "\n"],
    Ctx = ["## All servers\n\n"
           "Medians. B/x ratios are beamtalk-http on Buccaneer ÷ the other: above 1 is "
           "better on req/s and MB/s, worse on latency and memory. `engine` is "
           "Buccaneer standalone ÷ bare cowboy, the two engines with no beamtalk-http "
           "in front. `adapter` is (B ÷ standalone) ÷ (beamtalk-http on cowboy ÷ bare "
           "cowboy): what beamtalk-http's Buccaneer adapter keeps of its engine's "
           "figure, relative to what its cowboy adapter keeps; below 1 on req/s, the "
           "Buccaneer adapter costs more. B/cowboy is about engine × adapter.\n\n"
           "| Row | Metric | ", lists:join(" | ", [name(I) || I <- Impls]),
           " | B/cowboy | B/Bandit | B/standalone | engine | adapter |\n|---|---|",
           lists:duplicate(length(Impls) + 5, "---:|"), "\n",
           [ctx_lines(Id, Kind, Impls, Results) || {Id, Kind, _, _} <- Rows], "\n"],
    Every = ["## Every round\n\n| Row | Metric | Server | Rounds | Errors |\n|---|---|---|---|---|\n",
             [[[io_lib:format("| ~s | ~s | ~s | ~s | ~s |~n",
                              [Id, Label, name(I), all(Key, values(Id, I, Key, Results)),
                               errors(Id, I, Results)])
                || I <- Impls, values(Id, I, Key, Results) =/= []]
               || {Key, Label, _} <- metrics(Kind)]
              || {Id, Kind, _, _} <- Rows]],
    [Header, Gate, Ctx, Every].

%% The implementation a row is gated against, if any.
gate_baseline(gate) -> [http_cowboy];
gate_baseline({gate, Base}) -> [Base];
gate_baseline(_) -> [].

gate_lines(Id, Kind, Base, Results) ->
    [begin
        B = values(Id, http_buccaneer, Key, Results),
        C = values(Id, Base, Key, Results),
        Mb = median(B),
        Mc = median(C),
        io_lib:format("| ~s | ~s | ~s | ~s | ~s | ~s | ~s | ~s | ~s |~n",
                      [Id, Label, name(Base), fmt(Key, Mb), spread(Key, B), fmt(Key, Mc), spread(Key, C),
                       ratio(Mb, Mc), verdict(Better, Mb, C, errors(Id, http_buccaneer, Results))])
     end || {Key, Label, Better} <- metrics(Kind), gated(Key)].

verdict(_, undefined, _, _) -> "no data";
verdict(_, _, [], _) -> "no data";
verdict(_, _, _, Errors) when Errors =/= "0" -> "MISS (errors)";
verdict(higher, Mb, C, _) -> case Mb < lists:min(C) of true -> "MISS"; false -> "pass" end;
verdict(lower, Mb, C, _) -> case Mb > lists:max(C) of true -> "MISS"; false -> "pass" end.

ctx_lines(Id, Kind, Impls, Results) ->
    [begin
        M = fun(I) -> median(values(Id, I, Key, Results)) end,
        io_lib:format("| ~s | ~s | ~s | ~s | ~s | ~s | ~s | ~s |~n",
                      [Id, Label, lists:join(" | ", [fmt(Key, M(I)) || I <- Impls]),
                       ratio(M(http_buccaneer), M(http_cowboy)), ratio(M(http_buccaneer), M(bandit)),
                       ratio(M(http_buccaneer), M(buccaneer)), ratio(M(buccaneer), M(cowboy)),
                       ratio(quotient(M(http_buccaneer), M(buccaneer)),
                             quotient(M(http_cowboy), M(cowboy)))])
     end || {Key, Label, _} <- metrics(Kind)].

name(http_buccaneer) -> "http on Buccaneer";
name(http_cowboy) -> "http on cowboy";
name(buccaneer) -> "Buccaneer standalone";
name(cowboy) -> "bare cowboy";
name(bandit) -> "Bandit";
name(I) -> atom_to_list(I).

errors(Id, Impl, Results) ->
    Es = [maps:get(errors, M, 0) || {I, Im, M} <- Results, I =:= Id, Im =:= Impl],
    integer_to_list(lists:sum(Es)).

values(Id, Impl, Key, Results) ->
    [V || {I, Im, M} <- Results, I =:= Id, Im =:= Impl,
          V <- [maps:get(Key, M, undefined)], is_number(V)].

median([]) -> undefined;
median(Vs) ->
    S = lists:sort(Vs),
    N = length(S),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

spread(_, []) -> "-";
spread(Key, Vs) -> [fmt(Key, lists:min(Vs)), "-", fmt(Key, lists:max(Vs))].

ratio(undefined, _) -> "-";
ratio(_, undefined) -> "-";
ratio(_, T) when T == 0 -> "-";
ratio(C, T) -> io_lib:format("~.2f", [C / T]).

%% C ÷ T as a number, for a ratio of ratios.
quotient(undefined, _) -> undefined;
quotient(_, undefined) -> undefined;
quotient(_, T) when T == 0 -> undefined;
quotient(C, T) -> C / T.

fmt(_, undefined) -> "-";
fmt(bytes_per_s, V) -> io_lib:format("~.1f", [V / 1.0e6]);
fmt(processes_per_conn, V) -> io_lib:format("~.2f", [V]);
fmt(_, V) when V >= 100 -> integer_to_list(round(V));
fmt(_, V) -> io_lib:format("~.1f", [float(V)]).

all(Key, Vs) -> lists:join(", ", [fmt(Key, V) || V <- Vs]).

%% === Environment ===

environment() ->
    #{
        machine => machine(),
        os => trim(os:cmd("uname -sr")),
        otp => erlang:system_info(otp_release),
        erts => erlang:system_info(version),
        schedulers => erlang:system_info(schedulers_online),
        elixir => env_or("BENCH_ELIXIR_VERSION", "?"),
        bandit => env_or("BENCH_BANDIT_VERSION", "?"),
        beamtalk => env_or("BENCH_BEAMTALK_VERSION", "?"),
        buccaneer => env_or("BENCH_BUCCANEER_REV", "?"),
        http => env_or("BENCH_HTTP_REV", "?"),
        cowboy => env_or("BENCH_COWBOY_VERSION", "?"),
        load => load()
    }.

machine() ->
    case os:type() of
        {unix, darwin} ->
            trim(os:cmd("sysctl -n machdep.cpu.brand_string")) ++ ", "
                ++ trim(os:cmd("sysctl -n hw.ncpu")) ++ " cores";
        _ ->
            trim(os:cmd("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2")) ++ ", "
                ++ trim(os:cmd("nproc")) ++ " cores, "
                ++ trim(os:cmd("free -g | awk '/Mem:/ {print $2}'")) ++ " GiB"
    end.

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
