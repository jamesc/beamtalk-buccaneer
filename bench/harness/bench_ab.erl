%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc The PR speed gate (BT-4843, `just bench-ab`): measures one
%% checkout's HTTP/2 speed, and compares two measurements. Not the release
%% gate (`bench_main`): short, and it compares a PR with `main` on the
%% same machine rather than with a baseline.
%%
%%   bench/run.sh bench_ab measure [--rounds N] [--duration MS] [--warmup MS]
%%       [--streams N] --out FILE
%%   bench/run.sh bench_ab compare [--threshold PCT] [--summary FILE]
%%       --base FILE... --pr FILE...
%%
%% `measure` appends one JSON line to FILE per call. Each round measures,
%% in this order and on a fresh server each:
%%
%%   latency  Buccaneer standalone: microseconds per stream over N
%%            sequential GETs on one h2c connection (one stream at a time,
%%            no tracing). The metric that went 86 to 432 us in BT-4842.
%%   rps      `h2_get_10x10` (10 connections, 10 streams in flight each),
%%            on Buccaneer standalone and on bare cowboy.
%%
%% Bare cowboy is the control. It contains no Buccaneer code, so its
%% numbers move only with the machine. `compare` shows how far the two
%% sides' controls differ, so a result can be read against runner noise.
%%
%% `compare` takes the medians over every sample of each side (the
%% caller interleaves base and PR runs) and exits 1 when the PR is more
%% than THRESHOLD percent worse than the base on a gated metric. Gated:
%% Buccaneer's us per stream and its h2_get_10x10 req/s. Reduction counts
%% are not gated: BT-4842 left them unchanged (the cost was waiting).
-module(bench_ab).

-export([main/0]).

-define(DEFAULT_THRESHOLD, 25).

main() ->
    case init:get_plain_arguments() of
        ["measure" | Args] -> measure(parse_measure(Args, #{rounds => 2, duration => 2000, warmup => 500,
                                                           streams => 2000}));
        ["compare" | Args] -> compare(parse_compare(Args, #{threshold => ?DEFAULT_THRESHOLD, base => [], pr => []}));
        Other -> error({usage, Other})
    end.

%% === measure ===

parse_measure(["--rounds", N | T], O) -> parse_measure(T, O#{rounds => list_to_integer(N)});
parse_measure(["--duration", N | T], O) -> parse_measure(T, O#{duration => list_to_integer(N)});
parse_measure(["--warmup", N | T], O) -> parse_measure(T, O#{warmup => list_to_integer(N)});
parse_measure(["--streams", N | T], O) -> parse_measure(T, O#{streams => list_to_integer(N)});
parse_measure(["--out", F | T], O) -> parse_measure(T, O#{out => F});
parse_measure([], O = #{out := _}) -> O;
parse_measure(Args, _) -> error({bad_arguments, Args}).

measure(#{rounds := Rounds, duration := Dur, warmup := Warm, streams := N, out := Out}) ->
    {ok, _} = application:ensure_all_started(ssl),
    Peers = #{I => bench_peer:start(I) || I <- [buccaneer, cowboy]},
    Rs = [begin
              Lat = with_server(maps:get(buccaneer, Peers), fun(Port) -> latency(Port, N) end),
              Cb = with_server(maps:get(cowboy, Peers), fun(Port) -> latency(Port, N) end),
              B = with_server(maps:get(buccaneer, Peers), fun(Port) -> rps(Port, Warm, Dur) end),
              C = with_server(maps:get(cowboy, Peers), fun(Port) -> rps(Port, Warm, Dur) end),
              io:format(standard_error, "  round ~p: ~.1f us/stream (cowboy ~.1f), ~.1f req/s (cowboy ~.1f)~n",
                        [R, Lat, Cb, B, C]),
              #{us_per_stream => Lat, cowboy_us_per_stream => Cb, rps => B, cowboy_rps => C}
          end || R <- lists:seq(1, Rounds)],
    [bench_peer:stop(P) || P <- maps:values(Peers)],
    Rec = #{rev => list_to_binary(os:getenv("BENCH_BUCCANEER_REV", "unknown")), rounds => Rs},
    ok = file:write_file(Out, [json:encode(Rec), "\n"], [append]),
    halt(0).

with_server(Peer, Fun) ->
    {ok, Port} = bench_peer:call(Peer, bench_node, start_server, [#{tls => false}]),
    try
        bench_load:wait_ready(Port, false, 120000),
        Fun(Port)
    after
        bench_peer:call(Peer, bench_node, stop_server, [5000])
    end.

%% Microseconds per stream over N sequential GETs on one connection,
%% after a warm-up of N div 10.
latency(Port, N) ->
    {ok, H0} = bench_h2:connect(Port),
    H1 = lists:foldl(fun(_, H) -> h2_get(H) end, H0, lists:seq(1, max(50, N div 10))),
    T0 = erlang:monotonic_time(microsecond),
    H2 = lists:foldl(fun(_, H) -> h2_get(H) end, H1, lists:seq(1, N)),
    T1 = erlang:monotonic_time(microsecond),
    bench_h2:close(H2),
    (T1 - T0) / N.

h2_get(H) ->
    {Id, H1} = bench_h2:request(H, <<"/">>),
    wait(Id, H1).

wait(Id, H) ->
    case bench_h2:next_event(H) of
        {done, Id, 200, H1} -> H1;
        {done, _, _, H1} -> wait(Id, H1);
        Other -> error({h2_get, Other})
    end.

rps(Port, Warm, Dur) ->
    M = bench_load:h2(Port, #{conns => 10, streams => 10, warmup_ms => Warm, duration_ms => Dur}),
    case maps:get(errors, M, 0) of
        0 -> maps:get(rps, M);
        E -> error({load_errors, E, maps:get(error_reasons, M, [])})
    end.

%% === compare ===

parse_compare(["--threshold", P | T], O) -> parse_compare(T, O#{threshold => list_to_number(P)});
parse_compare(["--summary", F | T], O) -> parse_compare(T, O#{summary => F});
parse_compare(["--base" | T], O) -> files(T, base, O);
parse_compare(["--pr" | T], O) -> files(T, pr, O);
parse_compare([], O) -> O;
parse_compare(Args, _) -> error({bad_arguments, Args}).

files(["--" ++ _ | _] = T, _, O) -> parse_compare(T, O);
files([F | T], Key, O) -> files(T, Key, O#{Key := maps:get(Key, O) ++ [F]});
files([], _, O) -> O.

list_to_number(S) ->
    try list_to_integer(S) catch error:badarg -> list_to_float(S) end.

%% {key, label, lower is better, gated}
-define(METRICS, [
    {us_per_stream, "Buccaneer, sequential us/stream (2,000 GETs)", true, true},
    {rps, "Buccaneer, h2_get_10x10 req/s", false, true},
    {cowboy_us_per_stream, "control: bare cowboy us/stream", true, false},
    {cowboy_rps, "control: bare cowboy h2_get_10x10 req/s", false, false}]).

compare(#{threshold := Pct, base := BaseFiles, pr := PrFiles} = Opts) ->
    {BaseRev, Base} = load(BaseFiles),
    {PrRev, Pr} = load(PrFiles),
    Rows = [row(M, Base, Pr, Pct) || M <- ?METRICS],
    Failed = [L || {L, _, _, _, _, true, true} <- Rows],
    Md = report(BaseRev, PrRev, length(Base), length(Pr), Rows, Pct, Failed),
    io:put_chars(Md),
    case maps:find(summary, Opts) of
        {ok, F} -> ok = file:write_file(F, Md, [append]);
        error -> ok
    end,
    halt(case Failed of [] -> 0; _ -> 1 end).

load(Files) ->
    Recs = lists:append([decode_lines(F) || F <- Files]),
    Rev = case Recs of [#{<<"rev">> := R} | _] -> R; _ -> <<"?">> end,
    {Rev, lists:append([Rs || #{<<"rounds">> := Rs} <- Recs])}.

decode_lines(F) ->
    {ok, Bin} = file:read_file(F),
    [json:decode(L) || L <- binary:split(Bin, <<"\n">>, [global, trim_all])].

median(L) ->
    S = lists:sort(L),
    N = length(S),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, S);
        0 -> (lists:nth(N div 2, S) + lists:nth(N div 2 + 1, S)) / 2
    end.

%% How much worse the PR is, in percent: positive is slower.
row({Key, Label, LowerBetter, Gated}, Base, Pr, Pct) ->
    K = atom_to_binary(Key),
    B = median([maps:get(K, R) || R <- Base]),
    P = median([maps:get(K, R) || R <- Pr]),
    Worse = case LowerBetter of
        true -> (P / B - 1) * 100;
        false -> (B / P - 1) * 100
    end,
    {Label, B, P, Worse, LowerBetter, Gated, Worse > Pct}.

report(BaseRev, PrRev, NB, NP, Rows, Pct, Failed) ->
    Verdict = case Failed of
        [] -> io_lib:format("**Pass**: the PR is within ~s% of main on both gated metrics.", [num(Pct)]);
        _ -> io_lib:format("**Fail**: the PR is more than ~s% slower than main on: ~s.",
                           [num(Pct), lists:join("; ", Failed)])
    end,
    Ctl = [W || {_, _, _, W, _, false, _} <- Rows],
    Note = case [W || W <- Ctl, abs(W) > Pct / 2] of
        [] -> "";
        _ -> "\n\nThe control moved by more than half the threshold between the two sides, "
             "so this runner was noisy; read the gated rows with care and re-run.\n"
    end,
    iolist_to_binary([
        "## Buccaneer speed: PR vs main on the same runner\n\n",
        Verdict, "\n\n",
        io_lib:format("main `~s` (~p samples) against PR `~s` (~p samples), medians; "
                      "\"worse\" is positive when the PR is slower. Gate: ~s%.\n\n",
                      [BaseRev, NB, PrRev, NP, num(Pct)]),
        "| Metric | main | PR | PR worse by | Gated |\n|---|---:|---:|---:|---|\n",
        [io_lib:format("| ~s | ~s | ~s | ~s% | ~s |~n",
                       [L, num1(B), num1(P), sign(W), case {G, X} of {false, _} -> "control"; {_, true} -> "**FAIL**"; _ -> "ok" end])
         || {L, B, P, W, _, G, X} <- Rows],
        Note]).

num(N) when is_integer(N) -> integer_to_list(N);
num(N) -> float_to_list(N, [{decimals, 1}]).

num1(V) -> float_to_list(V * 1.0, [{decimals, 1}]).

sign(W) when W >= 0 -> io_lib:format("+~.1f", [W]);
sign(W) -> io_lib:format("~.1f", [W]).
