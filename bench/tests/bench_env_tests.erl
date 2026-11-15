%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Tests for bench_env (BT-4856): environment errors against server
%% errors, TIME_WAIT counting and the settle wait. `just bench-test`.
%%
%% The parsers and the settle loop run on injected text and clocks, so they
%% pass on any OS. The `real_*` tests use the machine they run on (a
%% loopback socket really in TIME_WAIT, a connect that really answers
%% eaddrnotavail) and are skipped where this OS does not behave so.
-module(bench_env_tests).
-include_lib("eunit/include/eunit.hrl").

%% === Classification ===

env_errors_named_test() ->
    ?assertMatch({eaddrnotavail, _}, bench_env:classify(eaddrnotavail)),
    ?assertMatch({eaddrnotavail, _}, bench_env:classify({error, eaddrnotavail})),
    ?assertMatch({emfile, _}, bench_env:classify({error, emfile})),
    %% Nested, as a crash or a failed idle open reports it.
    ?assertMatch({emfile, _}, bench_env:classify({error, {error, emfile}})),
    ?assertMatch({eaddrnotavail, _},
                 bench_env:classify({error, {badmatch, {error, eaddrnotavail}}, [frame]})).

unknown_platform_gets_no_linux_advice_test() ->
    T = bench_env:limit(eaddrnotavail, {unix, freebsd}),
    ?assertEqual(nomatch, binary:match(T, <<"ip_local_port_range">>)),
    ?assertNotEqual(nomatch, binary:match(T, <<"not recognized">>)).

limit_text_names_the_limit_test() ->
    {emfile, Fd} = bench_env:classify(emfile),
    ?assertNotEqual(nomatch, binary:match(Fd, <<"ulimit -n">>)),
    ?assertNotEqual(nomatch, binary:match(bench_env:limit(eaddrnotavail, {unix, darwin}),
                                          <<"net.inet.tcp.msl">>)),
    ?assertNotEqual(nomatch, binary:match(bench_env:limit(eaddrnotavail, {unix, linux}),
                                          <<"ip_local_port_range">>)).

server_errors_stay_server_errors_test() ->
    [?assertEqual(server, bench_env:classify(R)) ||
        R <- [{status, 500}, econnrefused, closed, timeout, incomplete, no_connections,
              {error, econnreset}, {bad_status_line, <<"HTTP/1.1 500">>},
              {h2_reset, 3}, {error, {tls_alert, {handshake_failure, "x"}}}, ready_timeout]].

split_separates_test() ->
    {Server, Env} = bench_env:split([{status, 500}, {error, emfile}, closed, eaddrnotavail]),
    ?assertEqual([{status, 500}, closed], Server),
    ?assertMatch([{emfile, _, {error, emfile}}, {eaddrnotavail, _, eaddrnotavail}], Env).

failure_test() ->
    ?assertEqual(#{errors => 1, error_reasons => [{error, econnrefused}]},
                 bench_env:failure({error, econnrefused})),
    #{errors := 0, env_errors := 1, env_limits := [Limit]} =
        bench_env:failure({error, eaddrnotavail}),
    ?assertNotEqual(nomatch, binary:match(Limit, <<"eaddrnotavail: client ports">>)).

%% A harness run against a port nothing listens on is a server error
%% (connection refused), every worker counted, not an environment error.
load_against_a_dead_port_is_a_server_error_test() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(L),
    gen_tcp:close(L),
    M = bench_load:http(Port, #{conns => 3, warmup_ms => 0, duration_ms => 10}),
    ?assertMatch(#{errors := 3}, M),
    ?assertNot(maps:is_key(env_errors, M)).

%% The OS answers eaddrnotavail for a source address it does not own.
real_eaddrnotavail_test() ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    R = gen_tcp:connect({127, 0, 0, 1}, Port, [{ip, {192, 0, 2, 77}}], 1000),
    gen_tcp:close(L),
    case R of
        {error, eaddrnotavail} ->
            ?assertMatch({eaddrnotavail, _}, bench_env:classify(R));
        _ ->
            ok
    end.

%% === TIME_WAIT parsing ===

proc_net_tcp() ->
    "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
    "   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0\n"
    "   1: 0100007F:C350 0100007F:1F90 06 00000000:00000000 03:000012D0 00000000     0        0 0 3 0\n"
    "   2: 0100007F:1F90 0100007F:C351 06 00000000:00000000 03:000012D0 00000000     0        0 0 3 0\n"
    "   3: 0100007F:C352 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 5 1 0\n"
    "   4: 0100007F:C353 0100007F:2328 06 00000000:00000000 03:000012D0 00000000     0        0 0 3 0\n".

parse_proc_net_tcp_test() ->
    %% 0x1F90 = 8080: lines 1 (client side) and 2 (server side) are
    %% TIME_WAIT on it; 3 is established; 4 is another port's.
    ?assertEqual(2, bench_env:parse_proc_net_tcp(proc_net_tcp(), 8080)),
    ?assertEqual(1, bench_env:parse_proc_net_tcp(proc_net_tcp(), 9000)),
    ?assertEqual(0, bench_env:parse_proc_net_tcp(proc_net_tcp(), 1234)),
    ?assertEqual(0, bench_env:parse_proc_net_tcp("", 8080)).

netstat_text() ->
    "Active Internet connections (including servers)\n"
    "Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)\n"
    "tcp4       0      0  127.0.0.1.8080         *.*                    LISTEN\n"
    "tcp4       0      0  127.0.0.1.50001        127.0.0.1.8080         TIME_WAIT\n"
    "tcp4       0      0  127.0.0.1.8080         127.0.0.1.50002        TIME_WAIT\n"
    "tcp4       0      0  127.0.0.1.50003        127.0.0.1.8080         ESTABLISHED\n"
    "tcp4       0      0  127.0.0.1.50004        127.0.0.1.9090         TIME_WAIT\n"
    "tcp6       0      0  ::1.50005              ::1.8080               TIME_WAIT\n".

parse_netstat_test() ->
    ?assertEqual(3, bench_env:parse_netstat(netstat_text(), 8080)),
    ?assertEqual(1, bench_env:parse_netstat(netstat_text(), 9090)),
    ?assertEqual(0, bench_env:parse_netstat(netstat_text(), 7777)).

%% A client that closes first holds the TIME_WAIT socket, here really.
real_time_wait_test() ->
    case file:read_file("/proc/net/tcp") of
        {ok, _} ->
            {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {active, false}]),
            {ok, Port} = inet:port(L),
            {ok, C} = gen_tcp:connect({127, 0, 0, 1}, Port, [{active, false}]),
            {ok, S} = gen_tcp:accept(L, 1000),
            ok = gen_tcp:close(C),
            ?assertEqual({error, closed}, gen_tcp:recv(S, 0, 1000)),
            ok = gen_tcp:close(S),
            %% The client closed first, so its end is in TIME_WAIT.
            ?assertMatch({ok, N} when N >= 1, bench_env:time_wait(Port)),
            gen_tcp:close(L);
        _ ->
            ok
    end.

%% === Settle ===

%% A scripted machine: successive counts, a clock that advances by the
%% sleeps, nothing real.
scripted(Counts) ->
    Agent = spawn_link(fun() -> agent(Counts, 0) end),
    #{count => fun(_) -> call(Agent, count) end,
      sleep => fun(Ms) -> call(Agent, {sleep, Ms}) end,
      now => fun() -> call(Agent, now) end}.

agent(Counts, Clock) ->
    receive
        {From, count} ->
            {N, Rest} = case Counts of
                [X] -> {X, [X]};
                [X | T] -> {X, T}
            end,
            From ! {self(), N}, agent(Rest, Clock);
        {From, {sleep, Ms}} -> From ! {self(), ok}, agent(Counts, Clock + Ms);
        {From, now} -> From ! {self(), Clock}, agent(Counts, Clock)
    end.

call(Agent, Msg) ->
    Agent ! {self(), Msg},
    receive {Agent, R} -> R end.

opts() -> #{timeout_ms => 10000, poll_ms => 500, target => 100}.

settle_waits_until_drained_test() ->
    Env = scripted([{ok, 9000}, {ok, 5000}, {ok, 1000}, {ok, 90}]),
    ?assertEqual(#{waited_ms => 1500, start => 9000, remaining => 90, outcome => drained},
                 bench_env:settle(8080, opts(), Env)).

settle_does_not_wait_when_already_drained_test() ->
    Env = scripted([{ok, 40}]),
    ?assertEqual(#{waited_ms => 0, start => 40, remaining => 40, outcome => drained},
                 bench_env:settle(8080, opts(), Env)).

settle_is_bounded_test() ->
    Env = scripted([{ok, 9000}]),
    #{outcome := timeout, waited_ms := W, start := 9000, remaining := 9000} =
        bench_env:settle(8080, opts(), Env),
    ?assert(W >= 10000),
    ?assert(W =< 10500).

settle_without_a_way_to_count_does_not_wait_test() ->
    Env = scripted([unavailable]),
    ?assertEqual(#{waited_ms => 0, start => undefined, remaining => undefined,
                   outcome => unavailable},
                 bench_env:settle(8080, opts(), Env)).

settle_off_test() ->
    Env = scripted([{ok, 9000}]),
    ?assertMatch(#{outcome := off, waited_ms := 0},
                 bench_env:settle(8080, (opts())#{timeout_ms := 0}, Env)).
