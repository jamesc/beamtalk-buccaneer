%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Tests for the report side of environment errors (BT-4856): the
%% gate verdict's precedence and the environment-error tables. bench_main
%% is compiled with -DTEST for these (bench/tests/run.sh).
-module(bench_main_tests).
-include_lib("eunit/include/eunit.hrl").

flat(IoData) -> binary_to_list(iolist_to_binary(IoData)).

-define(LIMIT, <<"emfile: open file descriptors: raise ulimit -n to at least 20000">>).

%% A server error is a MISS, whatever else happened.
verdict_server_error_is_a_miss_test() ->
    ?assertEqual("MISS (errors)", bench_main:verdict(higher, 100.0, [90.0], "2", [])),
    %% Real server errors win over environment errors on the same row.
    ?assertEqual("MISS (errors)", bench_main:verdict(higher, 100.0, [90.0], "2", [?LIMIT])).

%% An environment error makes the row invalid: not a pass, not a MISS,
%% even when the numbers would pass or miss.
verdict_environment_error_is_invalid_test() ->
    V = flat(bench_main:verdict(higher, 100.0, [90.0], "0", [?LIMIT])),
    ?assertMatch("INVALID (environment: emfile" ++ _, V),
    ?assertMatch("INVALID" ++ _,
                 flat(bench_main:verdict(higher, 10.0, [90.0], "0", [?LIMIT]))),
    ?assertMatch("INVALID" ++ _,
                 flat(bench_main:verdict(higher, undefined, [], "0", [?LIMIT]))).

verdict_without_errors_compares_test() ->
    ?assertEqual("pass", bench_main:verdict(higher, 100.0, [90.0, 95.0], "0", [])),
    ?assertEqual("MISS", bench_main:verdict(higher, 80.0, [90.0, 95.0], "0", [])),
    ?assertEqual("pass", bench_main:verdict(lower, 5.0, [6.0, 7.0], "0", [])),
    ?assertEqual("MISS", bench_main:verdict(lower, 9.0, [6.0, 7.0], "0", [])),
    ?assertEqual("no data", bench_main:verdict(higher, undefined, [90.0], "0", [])),
    ?assertEqual("no data", bench_main:verdict(higher, 100.0, [], "0", [])).

results() ->
    [{"idle_10k", cowboy, #{errors => 0, env_errors => 8996, env_limits => [?LIMIT]}},
     {"idle_10k", bandit, #{errors => 0, bytes_per_conn => 5000.0}},
     {"churn", cowboy, #{errors => 3, rps => 10.0}}].

env_helpers_test() ->
    R = results(),
    ?assertEqual([?LIMIT], bench_main:env_limits("idle_10k", [cowboy, bandit], R)),
    ?assertEqual([], bench_main:env_limits("idle_10k", [bandit], R)),
    ?assertEqual("0", bench_main:env_errors("idle_10k", bandit, R)),
    ?assertMatch("8996 (emfile" ++ _, bench_main:env_errors("idle_10k", cowboy, R)),
    %% Server errors are not environment errors.
    ?assertEqual("0", bench_main:env_errors("churn", cowboy, R)).

env_section_lists_only_environment_errors_test() ->
    Rows = [{"idle_10k", idle, #{}, memory}, {"churn", churn, #{}, gate}],
    Out = flat(bench_main:env_section(Rows, [cowboy, bandit], results())),
    ?assertNotEqual(nomatch, string:find(Out, "## Environment errors")),
    ?assertNotEqual(nomatch, string:find(Out, "- idle_10k, bare cowboy: 8996")),
    ?assertEqual(nomatch, string:find(Out, "Bandit")),
    ?assertEqual(nomatch, string:find(Out, "churn,")),
    %% None: no section at all.
    ?assertEqual("", bench_main:env_section(Rows, [bandit], results())).

%% BT-4976: the line says which happened, with the target and free ports.
settle_line_drained_test() ->
    L = flat(bench_main:settle_line(#{outcome => drained, waited_ms => 2300, start => 32840,
                                      remaining => 0, target => 3276, range => 32768})),
    ?assertEqual("settled in 2.3 s: TIME_WAIT 32840 -> 0 (target <= 3276); "
                 "free client ports 0 -> 32768 of 32768", L).

settle_line_timeout_says_gave_up_test() ->
    L = flat(bench_main:settle_line(#{outcome => timeout, waited_ms => 1900, start => 20576,
                                      remaining => 2613, target => 1000, range => 32768})),
    ?assertMatch("WARNING gave up after 1.9 s: TIME_WAIT 20576 -> 2613 (target <= 1000)" ++ _, L),
    ?assertEqual(nomatch, string:find(L, "settled")).

settle_line_without_a_known_range_omits_free_ports_test() ->
    L = flat(bench_main:settle_line(#{outcome => drained, waited_ms => 0, start => 0,
                                      remaining => 0, target => 0, range => undefined})),
    ?assertEqual("settled in 0.0 s: TIME_WAIT 0 -> 0 (target <= 0)", L).

%% BENCH_SKIP_BANDIT (bench/ab.sh, bench/rows_ab.sh) leaves bandit out of the
%% default servers; unset or empty keeps it (BT-5001).
resolve_impls_default_test() ->
    All = bench_peer:bench_impls(),
    ?assert(lists:member(bandit, All)),
    ?assertEqual({ok, All}, bench_main:resolve_impls(default, false)),
    ?assertEqual({ok, All}, bench_main:resolve_impls(default, "")),
    {ok, Skipped} = bench_main:resolve_impls(default, "1"),
    ?assertEqual(All -- [bandit], Skipped).

%% An explicit list is kept as given, unless it names bandit under the skip.
resolve_impls_explicit_test() ->
    ?assertEqual({ok, [cowboy, bandit]}, bench_main:resolve_impls([cowboy, bandit], false)),
    ?assertEqual({ok, [cowboy]}, bench_main:resolve_impls([cowboy], "1")),
    {error, Msg} = bench_main:resolve_impls([cowboy, bandit], "1"),
    ?assertNotEqual(nomatch, string:find(Msg, "BENCH_SKIP_BANDIT")).
