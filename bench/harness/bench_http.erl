%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc A minimal HTTP/1.1 client over `bench_conn`: build requests and
%% read responses (content-length or chunked bodies) with
%% `erlang:decode_packet`. Keeps a read buffer, so pipelined responses
%% read back one at a time.
-module(bench_http).

-export([request/3, request/4, get/1, get/2, read_response/2, read_response/3,
         status/1, body/1, body_size/1, closes/1]).

-define(RECV_TIMEOUT, 60000).

get(Path) -> request(<<"GET">>, Path, [], <<>>).

get(Path, Headers) -> request(<<"GET">>, Path, Headers, <<>>).

request(Method, Path, Headers) -> request(Method, Path, Headers, <<>>).

%% A request with a content-length body (when the body is not empty).
request(Method, Path, Headers, Body) ->
    Len = case iolist_size(Body) of
        0 when Method =:= <<"GET">>; Method =:= <<"HEAD">> -> [];
        N -> [{<<"content-length">>, integer_to_binary(N)}]
    end,
    [Method, " ", Path, " HTTP/1.1\r\nhost: localhost\r\n",
     [[K, ": ", V, "\r\n"] || {K, V} <- Headers ++ Len], "\r\n", Body].

%% Read one response from C, starting with the leftover Buf. Answers
%% `{ok, Response, Rest}` or `{error, Reason}`. A Response is
%% `{Status, Close, Body}`; with `discard` (the bench default) Body is the
%% body's size, with `keep` its bytes.
read_response(C, Buf) -> read_response(C, Buf, discard).

read_response(C, Buf, Mode) ->
    case erlang:decode_packet(http_bin, Buf, []) of
        {ok, {http_response, _V, Status, _R}, Rest} ->
            read_headers(C, Rest, #{status => Status, len => undefined, chunked => false,
                                    close => false, mode => Mode});
        {more, _} -> more(C, Buf, fun(B) -> read_response(C, B, Mode) end);
        Other -> {error, {bad_status_line, Other}}
    end.

read_headers(C, Buf, St) ->
    case erlang:decode_packet(httph_bin, Buf, []) of
        {ok, {http_header, _, 'Content-Length', _, V}, Rest} ->
            read_headers(C, Rest, St#{len => binary_to_integer(V)});
        {ok, {http_header, _, 'Transfer-Encoding', _, V}, Rest} ->
            read_headers(C, Rest, St#{chunked => string:lowercase(V) =:= <<"chunked">>});
        {ok, {http_header, _, 'Connection', _, V}, Rest} ->
            read_headers(C, Rest, St#{close => string:lowercase(V) =:= <<"close">>});
        {ok, {http_header, _, _, _, _}, Rest} ->
            read_headers(C, Rest, St);
        {ok, http_eoh, Rest} ->
            body_start(C, Rest, St);
        {more, _} ->
            more(C, Buf, fun(B) -> read_headers(C, B, St) end);
        Other ->
            {error, {bad_header, Other}}
    end.

%% 1xx responses (100 Continue) are skipped: the final one follows.
body_start(C, Rest, #{status := S, mode := Mode}) when S >= 100, S < 200, S =/= 101 ->
    read_response(C, Rest, Mode);
body_start(_C, Rest, #{status := 101} = St) ->
    {ok, done(St, <<>>), Rest};
body_start(C, Rest, #{chunked := true} = St) ->
    read_chunks(C, Rest, St, []);
body_start(C, Rest, #{len := undefined} = St) when map_get(close, St) ->
    read_to_close(C, Rest, St);
body_start(C, Rest, #{len := undefined} = St) ->
    read_fixed(C, Rest, St#{len => 0});
body_start(C, Rest, St) ->
    read_fixed(C, Rest, St).

read_fixed(_C, Buf, #{len := Len} = St) when byte_size(Buf) >= Len ->
    <<Body:Len/binary, Rest/binary>> = Buf,
    {ok, done(St, Body), Rest};
read_fixed(C, Buf, St) ->
    more(C, Buf, fun(B) -> read_fixed(C, B, St) end).

read_to_close(C, Buf, St) ->
    case bench_conn:recv(C, 0, ?RECV_TIMEOUT) of
        {ok, D} -> read_to_close(C, <<Buf/binary, D/binary>>, St);
        {error, closed} -> {ok, done(St, Buf), <<>>};
        {error, R} -> {error, R}
    end.

read_chunks(C, Buf, St, Acc) ->
    case binary:split(Buf, <<"\r\n">>) of
        [SizeLine, Rest] ->
            [Hex | _] = binary:split(SizeLine, <<";">>),
            case binary_to_integer(string:trim(Hex), 16) of
                0 -> read_trailers(C, Rest, St, Acc);
                N -> read_chunk(C, Rest, N, St, Acc)
            end;
        [_] ->
            more(C, Buf, fun(B) -> read_chunks(C, B, St, Acc) end)
    end.

read_chunk(C, Buf, N, St, Acc) when byte_size(Buf) >= N + 2 ->
    <<Data:N/binary, "\r\n", Rest/binary>> = Buf,
    Acc1 = case St of
        #{mode := keep} -> [Data | Acc];
        _ -> [N | Acc]
    end,
    read_chunks(C, Rest, St, Acc1);
read_chunk(C, Buf, N, St, Acc) ->
    more(C, Buf, fun(B) -> read_chunk(C, B, N, St, Acc) end).

read_trailers(C, Buf, St, Acc) ->
    case binary:split(Buf, <<"\r\n">>) of
        [<<>>, Rest] ->
            Body = case St of
                #{mode := keep} -> iolist_to_binary(lists:reverse(Acc));
                _ -> lists:sum(Acc)
            end,
            {ok, {maps:get(status, St), maps:get(close, St), Body}, Rest};
        [_Trailer, Rest] -> read_trailers(C, Rest, St, Acc);
        [_] -> more(C, Buf, fun(B) -> read_trailers(C, B, St, Acc) end)
    end.

done(#{status := S, close := Close, mode := keep}, Body) -> {S, Close, Body};
done(#{status := S, close := Close}, Body) -> {S, Close, byte_size(Body)}.

more(C, Buf, K) ->
    case bench_conn:recv(C, 0, ?RECV_TIMEOUT) of
        {ok, Data} -> K(<<Buf/binary, Data/binary>>);
        {error, R} -> {error, R}
    end.

status({S, _, _}) -> S.
closes({_, Close, _}) -> Close.
body({_, _, B}) -> B.
body_size({_, _, B}) when is_binary(B) -> byte_size(B);
body_size({_, _, N}) -> N.
