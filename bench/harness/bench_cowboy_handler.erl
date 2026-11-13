%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc The bench routes as a plain Erlang cowboy handler: the bare-cowboy
%% row (`cowboy` in `bench_peer`), the counterpart of the Buccaneer
%% standalone `Exchange` handler (`HttpNode startStandalone:`) and the
%% Bandit Plug (`bench/bandit`). No beamtalk-http and no Beamtalk runtime:
%% cowboy 2.20 and ranch, as beamtalk-http's cowboy backend runs them.
%%
%% `/` answers `hello world` (`text/plain`); `POST /echo` the request
%% body; `/chunked` 1 MiB as 16 chunks of 64 KiB; `/file` a 1 MiB file
%% (sendfile); `/slow` `hello world` after a second; `/ws` a WebSocket
%% echo. (No `-behaviour(cowboy_handler)`: cowboy is not on the path when
%% `bench/run.sh` compiles the harness.)
-module(bench_cowboy_handler).

-export([init/2, websocket_handle/2, websocket_info/2]).

%% The file bench_node writes at boot (HttpNode filePath, the Bandit
%% plug's file_path), relative to the repository root, the peers' working
%% directory.
-define(BODY_FILE, "_build/bench/buccaneer_bench_1mib").
-define(BODY_SIZE, 1048576).
-define(CHUNK_SIZE, 65536).

init(Req, State) ->
    route(cowboy_req:path(Req), Req, State).

route(P, Req0, State) when P =:= <<"/echo">>; P =:= <<"/echo_raw">> ->
    {Body, Req1} = read_body(Req0, []),
    {ok, octets(Body, Req1), State};
route(<<"/chunked">>, Req0, State) ->
    Req = cowboy_req:stream_reply(200, #{<<"content-type">> => <<"application/octet-stream">>}, Req0),
    Chunk = binary:copy(<<"x">>, ?CHUNK_SIZE),
    [ok = cowboy_req:stream_body(Chunk, nofin, Req) || _ <- lists:seq(1, 15)],
    ok = cowboy_req:stream_body(Chunk, fin, Req),
    {ok, Req, State};
route(<<"/file">>, Req, State) ->
    {ok, octets({sendfile, 0, ?BODY_SIZE, ?BODY_FILE}, Req), State};
route(<<"/slow">>, Req, State) ->
    timer:sleep(1000),
    {ok, hello(Req), State};
route(<<"/ws">>, Req, State) ->
    {cowboy_websocket, Req, State};
route(_, Req, State) ->
    {ok, hello(Req), State}.

read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req} -> {iolist_to_binary(lists:reverse(Acc, [Data])), Req};
        {more, Data, Req} -> read_body(Req, [Data | Acc])
    end.

octets(Body, Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => <<"application/octet-stream">>}, Body, Req).

hello(Req) ->
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, <<"hello world">>, Req).

%% === /ws: echo every data frame ===

websocket_handle({text, _} = Frame, State) -> {[Frame], State};
websocket_handle({binary, _} = Frame, State) -> {[Frame], State};
websocket_handle(_, State) -> {[], State}.

websocket_info(_, State) -> {[], State}.
