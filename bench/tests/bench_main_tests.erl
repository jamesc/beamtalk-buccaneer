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
