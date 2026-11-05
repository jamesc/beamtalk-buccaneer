%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc A minimal HTTP/2 client (prior knowledge, `h2c`) for the bench's
%% context row: GETs with a static HPACK header block, any number of
%% streams in flight per connection. It answers SETTINGS and PING, opens
%% the connection and stream windows wide at the start, and replenishes
%% the connection window as DATA arrives. It decodes nothing it does not
%% need: a response is done when its stream sees END_STREAM, and its
%% status is read from the header block's first field after any table
%% size update (`:status 200` is static-table entry 8, sent as 0x88).
-module(bench_h2).

-export([connect/1, request/2, next_event/1, close/1]).

-define(PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(WINDOW, 1073741823).
-define(RECV_TIMEOUT, 60000).

-define(DATA, 0).
-define(HEADERS, 1).
-define(RST_STREAM, 3).
-define(SETTINGS, 4).
-define(PING, 6).
-define(GOAWAY, 7).
-define(CONTINUATION, 9).

%% Answers `{ok, H2}`: #{conn, buf, next (stream id), consumed}.
connect(Port) ->
    case bench_conn:connect(Port, false) of
        {ok, C} ->
            %% SETTINGS_INITIAL_WINDOW_SIZE (4) wide open, then the
            %% connection window to match.
            Settings = frame(?SETTINGS, 0, 0, <<4:16, ?WINDOW:32>>),
            Update = frame(8, 0, 0, <<0:1, (?WINDOW - 65535):31>>),
            ok = bench_conn:send(C, [?PREFACE, Settings, Update]),
            {ok, #{conn => C, buf => <<>>, next => 1, consumed => 0}};
        E -> E
    end.

%% Send `GET Path` on a new stream. Answers `{StreamId, H2}`.
request(H2 = #{conn := C, next := Id}, Path) ->
    Block = [16#82, 16#86, path_field(Path), 16#01, 9, <<"localhost">>],
    ok = bench_conn:send(C, frame(?HEADERS, 16#5, Id, Block)),
    {Id, H2#{next => Id + 2}}.

path_field(<<"/">>) -> 16#84;
path_field(Path) -> [16#04, byte_size(Path), Path].

%% The next stream event: `{done, StreamId, Status, H2}` when a stream
%% ends, `{reset, StreamId, H2}`, or `{error, Reason}`. Connection-level
%% frames are handled on the way.
next_event(H2 = #{buf := Buf}) ->
    case Buf of
        <<Len:24, Type:8, Flags:8, _:1, Id:31, Payload:Len/binary, Rest/binary>> ->
            handle(Type, Flags, Id, Payload, H2#{buf => Rest});
        _ ->
            case bench_conn:recv(maps:get(conn, H2), 0, ?RECV_TIMEOUT) of
                {ok, D} -> next_event(H2#{buf => <<Buf/binary, D/binary>>});
                {error, R} -> {error, R}
            end
    end.

handle(?SETTINGS, Flags, 0, _P, H2 = #{conn := C}) ->
    case Flags band 1 of
        1 -> ok;
        0 -> ok = bench_conn:send(C, frame(?SETTINGS, 1, 0, <<>>))
    end,
    next_event(H2);
handle(?PING, 0, 0, P, H2 = #{conn := C}) ->
    ok = bench_conn:send(C, frame(?PING, 1, 0, P)),
    next_event(H2);
handle(?GOAWAY, _, 0, <<_:32, Code:32, _/binary>>, _H2) ->
    {error, {goaway, Code}};
handle(?HEADERS, Flags, Id, P, H2) ->
    Status = status(strip(Flags, P)),
    case Flags band 1 of
        1 -> {done, Id, Status, H2};
        0 -> next_event(H2#{{status, Id} => Status})
    end;
handle(?DATA, Flags, Id, P, H2 = #{conn := C, consumed := Used0}) ->
    Used = Used0 + byte_size(P),
    H2b = case Used > ?WINDOW div 2 of
        true ->
            ok = bench_conn:send(C, frame(8, 0, 0, <<0:1, Used:31>>)),
            H2#{consumed => 0};
        false ->
            H2#{consumed => Used}
    end,
    case Flags band 1 of
        1 -> {done, Id, maps:get({status, Id}, H2b, undefined), maps:remove({status, Id}, H2b)};
        0 -> next_event(H2b)
    end;
handle(?RST_STREAM, _, Id, _, H2) ->
    {reset, Id, H2};
handle(_Other, _Flags, _Id, _P, H2) ->
    %% WINDOW_UPDATE, CONTINUATION (the status is in the first block),
    %% PRIORITY: nothing to do.
    next_event(H2).

%% The header block without padding and priority fields.
strip(Flags, P0) ->
    {Pad, P1} = case Flags band 16#8 of
        0 -> {0, P0};
        _ -> <<N:8, R/binary>> = P0, {N, R}
    end,
    P2 = case Flags band 16#20 of
        0 -> P1;
        _ -> <<_:40, R2/binary>> = P1, R2
    end,
    binary:part(P2, 0, byte_size(P2) - Pad).

%% Dynamic table size updates (001xxxxx) may come first.
status(<<2#001:3, 31:5, Rest/binary>>) -> status(skip_varint(Rest));
status(<<2#001:3, _:5, Rest/binary>>) -> status(Rest);
status(<<16#88, _/binary>>) -> 200;
status(<<B, _/binary>>) -> {first_byte, B};
status(<<>>) -> empty.

skip_varint(<<1:1, _:7, Rest/binary>>) -> skip_varint(Rest);
skip_varint(<<0:1, _:7, Rest/binary>>) -> Rest.

frame(Type, Flags, Id, Payload) ->
    Len = iolist_size(Payload),
    [<<Len:24, Type:8, Flags:8, 0:1, Id:31>>, Payload].

close(#{conn := C}) -> bench_conn:close(C).
