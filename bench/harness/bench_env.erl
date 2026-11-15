%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc The machine's limits, as the harness sees them (BT-4856).
%%
%% Two jobs:
%%
%% 1. Tell an environment error from a server error. `eaddrnotavail` (the
%%    client has run out of ports, because the previous measurement's closed
%%    connections still hold them) and `emfile` (the client has run out of
%%    file descriptors) say nothing about the server under test, so they are
%%    counted apart (`env_errors`, naming the limit) and never as `errors`.
%%    Anything else is a server error, as before.
%%
%% 2. Settle between measurements. After a churn or idle row the client's
%%    sockets sit in TIME_WAIT; the next server would start with fewer ports
%%    than the last one had. `settle/2` waits, up to a bound, until the
%%    TIME_WAIT sockets of the server's port have drained.
%%
%% The pure parts take their input as arguments so they are tested without
%% a loaded machine (bench/tests/bench_env_tests.erl).
-module(bench_env).

-export([classify/1, split/1, failure/1, limit/2,
         parse_proc_net_tcp/2, parse_netstat/2, time_wait/1,
         ephemeral_range/0, tw_reuse/0, settle/2, settle/3, settle_opts/0]).

-define(DEFAULT_SETTLE_MS, 60000).

%% === Environment errors ===

%% The environment error a reason is, `{Atom, LimitText}`, or `server`.
%% Looks inside tuples and lists, so `{error, eaddrnotavail}` from a connect,
%% `{tls_alert, ...}` wrappers and a crash's `{C, R, Frame}` all classify.
classify(Reason) ->
    case find_env(Reason) of
        undefined -> server;
        Atom -> {Atom, limit(Atom, os:type())}
    end.

find_env(eaddrnotavail) -> eaddrnotavail;
find_env(emfile) -> emfile;
find_env(T) when is_tuple(T) -> find_env(tuple_to_list(T));
find_env([H | T]) ->
    case find_env(H) of
        undefined -> find_env(T);
        A -> A
    end;
find_env(_) -> undefined.

%% The limit an environment error names, for the OS.
limit(emfile, _) ->
    <<"open file descriptors: raise ulimit -n to at least 20000">>;
limit(eaddrnotavail, {unix, darwin}) ->
    <<"client ports: set net.inet.ip.portrange.first=32768 and net.inet.tcp.msl=1000 (sysctl -w)">>;
limit(eaddrnotavail, _) ->
    <<"client ports: widen net.ipv4.ip_local_port_range (sysctl -w)">>.

%% Reasons -> {ServerErrors, EnvErrors}, each a list of reasons; EnvErrors
%% as `{Atom, LimitText, Reason}`.
split(Reasons) ->
    lists:foldr(fun(R, {S, E}) ->
        case classify(R) of
            server -> {[R | S], E};
            {A, L} -> {S, [{A, L, R} | E]}
        end
    end, {[], []}, Reasons).

%% The metrics fields for a measurement that failed outright (the server
%% did not start, a crash): one error, an environment one if the reason is.
failure(Reason) ->
    case classify(Reason) of
        server ->
            #{errors => 1, error_reasons => [Reason]};
        {A, L} ->
            #{errors => 0, error_reasons => [Reason],
              env_errors => 1, env_limits => [limit_text(A, L)]}
    end.

limit_text(A, L) -> iolist_to_binary([atom_to_list(A), ": ", L]).

%% === TIME_WAIT ===

%% Sockets in TIME_WAIT with `Port` at either end, from the text of
%% /proc/net/tcp (or tcp6): `sl local_address rem_address st ...`, addresses
%% as HEXIP:HEXPORT, state 06.
parse_proc_net_tcp(Text, Port) ->
    length([L || L <- string:split(Text, "\n", all),
                 case string:lexemes(L, " ") of
                     [_, Local, Rem, "06" | _] ->
                         hex_port(Local) =:= Port orelse hex_port(Rem) =:= Port;
                     _ -> false
                 end]).

hex_port(Addr) ->
    case string:split(Addr, ":", trailing) of
        [_, P] ->
            try list_to_integer(P, 16) catch error:badarg -> -1 end;
        _ -> -1
    end.

%% The same from `netstat -an -p tcp` (macOS, BSD): addresses as
%% `127.0.0.1.54321` (port after the last dot), state last.
parse_netstat(Text, Port) ->
    length([L || L <- string:split(Text, "\n", all),
                 case string:lexemes(L, " ") of
                     [_, _, _, Local, Rem, "TIME_WAIT" | _] ->
                         dot_port(Local) =:= Port orelse dot_port(Rem) =:= Port;
                     _ -> false
                 end]).

dot_port(Addr) ->
    case string:split(Addr, ".", trailing) of
        [_, P] ->
            try list_to_integer(P) catch error:badarg -> -1 end;
        _ -> -1
    end.

%% {ok, N} for the platform, or unavailable (no /proc/net/tcp and no
%% netstat on the PATH).
time_wait(Port) ->
    case os:type() of
        {unix, darwin} -> netstat_count(Port);
        _ ->
            case file:read_file("/proc/net/tcp") of
                {ok, V4} ->
                    V6 = case file:read_file("/proc/net/tcp6") of {ok, B} -> B; _ -> <<>> end,
                    {ok, parse_proc_net_tcp(binary_to_list(V4), Port)
                         + parse_proc_net_tcp(binary_to_list(V6), Port)};
                _ -> netstat_count(Port)
            end
    end.

netstat_count(Port) ->
    case os:find_executable("netstat") of
        false -> unavailable;
        _ -> {ok, parse_netstat(os:cmd("netstat -an -p tcp 2>/dev/null"), Port)}
    end.

%% The client's ephemeral port range, {ok, Low, High} or unavailable.
ephemeral_range() ->
    case os:type() of
        {unix, darwin} ->
            case {sysctl("net.inet.ip.portrange.first"), sysctl("net.inet.ip.portrange.last")} of
                {{ok, F}, {ok, L}} -> {ok, F, L};
                _ -> unavailable
            end;
        _ ->
            case file:read_file("/proc/sys/net/ipv4/ip_local_port_range") of
                {ok, B} ->
                    case string:lexemes(binary_to_list(B), " \t\n") of
                        [F, L] -> {ok, list_to_integer(F), list_to_integer(L)};
                        _ -> unavailable
                    end;
                _ -> unavailable
            end
    end.

sysctl(Name) ->
    try {ok, list_to_integer(string:trim(os:cmd("sysctl -n " ++ Name ++ " 2>/dev/null")))}
    catch error:badarg -> unavailable end.

%% === Settle ===

%% Settle options from the machine: wait up to BENCH_SETTLE_MS (default
%% 60 s; 0 turns the wait off), until the TIME_WAIT sockets are down to a
%% tenth of the ephemeral range, which leaves the next server nine tenths
%% of it. With the range unknown the target is zero.
settle_opts() ->
    Timeout = case os:getenv("BENCH_SETTLE_MS") of
        false -> ?DEFAULT_SETTLE_MS;
        "" -> ?DEFAULT_SETTLE_MS;
        S -> try list_to_integer(S) catch error:badarg -> ?DEFAULT_SETTLE_MS end
    end,
    Target = case ephemeral_range() of
        {ok, Lo, Hi} -> (Hi - Lo + 1) div 10;
        unavailable -> 0
    end,
    #{timeout_ms => Timeout, poll_ms => 500, target => Target}.

%% Wait for the server's TIME_WAIT sockets to drain, for the row's port.
%% Answers `#{waited_ms, start, remaining, outcome}` where outcome is
%% `drained`, `timeout`, `unavailable` (no way to count here: no wait at
%% all), `reuse` (the OS reuses the ports: no wait) or `off`.
settle(Port, Opts) ->
    case tw_reuse() of
        true ->
            #{waited_ms => 0, start => undefined, remaining => undefined, outcome => reuse};
        false ->
            settle(Port, Opts, #{count => fun time_wait/1,
                         sleep => fun timer:sleep/1,
                         now => fun() -> erlang:monotonic_time(millisecond) end})
    end.

%% Linux with net.ipv4.tcp_tw_reuse 1 or 2 (2 is the default since 4.19)
%% reuses loopback TIME_WAIT ports for new connections, so the held ports
%% do not starve the next server and waiting out Linux's fixed 60 s buys
%% nothing.
tw_reuse() ->
    case file:read_file("/proc/sys/net/ipv4/tcp_tw_reuse") of
        {ok, B} -> lists:member(string:trim(binary_to_list(B)), ["1", "2"]);
        _ -> false
    end.

%% As settle/2 with the count, sleep and clock injected (for tests).
settle(Port, #{timeout_ms := Timeout, poll_ms := Poll, target := Target},
       #{count := Count, sleep := Sleep, now := Now}) ->
    T0 = Now(),
    case Timeout =< 0 of
        true -> #{waited_ms => 0, start => undefined, remaining => undefined, outcome => off};
        false ->
            case Count(Port) of
                unavailable ->
                    #{waited_ms => 0, start => undefined, remaining => undefined,
                      outcome => unavailable};
                {ok, N0} ->
                    {N, Outcome} = wait(Port, N0, Target, T0 + Timeout, Poll, Count, Sleep, Now),
                    #{waited_ms => Now() - T0, start => N0, remaining => N, outcome => Outcome}
            end
    end.

wait(_, N, Target, _, _, _, _, _) when N =< Target -> {N, drained};
wait(Port, N, Target, Deadline, Poll, Count, Sleep, Now) ->
    case Now() >= Deadline of
        true -> {N, timeout};
        false ->
            Sleep(Poll),
            case Count(Port) of
                {ok, N1} -> wait(Port, N1, Target, Deadline, Poll, Count, Sleep, Now);
                unavailable -> {N, timeout}
            end
    end.
