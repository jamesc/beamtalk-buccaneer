%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc A minimal WebSocket client: the upgrade on `GET /ws`, masked text
%% frames out, server frames in (any length encoding; no fragmentation,
%% which none of the echo servers sends for these sizes).
-module(bench_ws).

-export([connect/1, echo/2, close/1]).

-define(RECV_TIMEOUT, 60000).

%% Answers `{ok, Ws}` once the server answered 101.
connect(Port) ->
    case bench_conn:connect(Port, false) of
        {ok, C} ->
            Key = base64:encode(rand:bytes(16)),
            Req = bench_http:get(<<"/ws">>, [
                {<<"upgrade">>, <<"websocket">>}, {<<"connection">>, <<"Upgrade">>},
                {<<"sec-websocket-key">>, Key}, {<<"sec-websocket-version">>, <<"13">>}]),
            ok = bench_conn:send(C, Req),
            case bench_http:read_response(C, <<>>) of
                {ok, {101, _, _}, Rest} -> {ok, #{conn => C, buf => Rest}};
                {ok, Other, _} -> bench_conn:close(C), {error, {not_upgraded, Other}};
                E -> bench_conn:close(C), E
            end;
        E -> E
    end.

%% Send `Data` as a text frame and read the echo. Answers `{ok, Ws}`, or
%% `{error, Reason}` (`{mismatch, ...}` when the bytes differ).
echo(Ws = #{conn := C}, Data) ->
    Mask = rand:bytes(4),
    ok = bench_conn:send(C, [16#81, len(byte_size(Data)), Mask, crypto:exor(Data, mask(Mask, byte_size(Data)))]),
    case read_frame(Ws) of
        {ok, 1, Data, Ws1} -> {ok, Ws1};
        {ok, Op, Other, _} -> {error, {mismatch, Op, byte_size(Other)}};
        E -> E
    end.

len(N) when N < 126 -> 16#80 bor N;
len(N) when N < 65536 -> <<(16#80 bor 126), N:16>>;
len(N) -> <<(16#80 bor 127), N:64>>.

mask(M, N) ->
    Whole = binary:copy(M, N div 4 + 1),
    binary:part(Whole, 0, N).

read_frame(Ws = #{buf := Buf}) ->
    case parse(Buf) of
        {ok, Op, Payload, Rest} -> {ok, Op, Payload, Ws#{buf => Rest}};
        more ->
            case bench_conn:recv(maps:get(conn, Ws), 0, ?RECV_TIMEOUT) of
                {ok, D} -> read_frame(Ws#{buf => <<Buf/binary, D/binary>>});
                E -> E
            end
    end.

parse(<<_Fin:1, _:3, Op:4, 0:1, 126:7, N:16, P:N/binary, Rest/binary>>) -> {ok, Op, P, Rest};
parse(<<_Fin:1, _:3, Op:4, 0:1, 127:7, N:64, P:N/binary, Rest/binary>>) -> {ok, Op, P, Rest};
parse(<<_Fin:1, _:3, Op:4, 0:1, N:7, P:N/binary, Rest/binary>>) when N < 126 -> {ok, Op, P, Rest};
parse(_) -> more.

close(#{conn := C}) ->
    Mask = rand:bytes(4),
    _ = bench_conn:send(C, [16#88, 16#82, Mask, crypto:exor(<<1000:16>>, binary:part(Mask, 0, 2))]),
    bench_conn:close(C).
