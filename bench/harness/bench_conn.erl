%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc One client connection, TCP or TLS, behind one interface (passive
%% mode, binaries, `nodelay`). As Catalina's `bench_conn`.
-module(bench_conn).

-export([connect/2, connect/3, send/2, recv/3, close/1, abort/1, setopts/2]).

-define(CONNECT_TIMEOUT, 60000).

%% Retries a refused or failed connect (a busy listener's backlog) a few
%% times before giving up.
connect(Port, Tls) -> connect(Port, Tls, 20).

connect(Port, Tls, Attempts) ->
    case raw_connect(Port, Tls) of
        {ok, C} -> {ok, C};
        {error, _} when Attempts > 1 ->
            timer:sleep(20 + rand:uniform(50)),
            connect(Port, Tls, Attempts - 1);
        E -> E
    end.

raw_connect(Port, false) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, opts(), ?CONNECT_TIMEOUT) of
        {ok, S} -> {ok, {tcp, S}};
        E -> E
    end;
raw_connect(Port, true) ->
    case ssl:connect({127, 0, 0, 1}, Port,
                     opts() ++ [{verify, verify_none}, {versions, ['tlsv1.3', 'tlsv1.2']}],
                     ?CONNECT_TIMEOUT) of
        {ok, S} -> {ok, {ssl, S}};
        E -> E
    end.

opts() -> [binary, {active, false}, {nodelay, true}].

send({tcp, S}, D) -> gen_tcp:send(S, D);
send({ssl, S}, D) -> ssl:send(S, D).

recv({tcp, S}, N, T) -> gen_tcp:recv(S, N, T);
recv({ssl, S}, N, T) -> ssl:recv(S, N, T).

close({tcp, S}) -> gen_tcp:close(S);
close({ssl, S}) -> ssl:close(S).

%% Close with a reset (linger 0) rather than a FIN, as a client dropping a
%% connection mid-request does.
abort({tcp, S}) ->
    _ = inet:setopts(S, [{linger, {true, 0}}]),
    gen_tcp:close(S);
abort({ssl, S}) ->
    ssl:close(S).

setopts({tcp, S}, O) -> inet:setopts(S, O);
setopts({ssl, S}, O) -> ssl:setopts(S, O).
