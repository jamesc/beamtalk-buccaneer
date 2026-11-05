%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Limits, with Bandit's answers: `#http1 #maxRequests` closes a
%% keep-alive connection after that many requests (the last response says
%% `connection: close`); more headers than `maxHeaderCount` or a header
%% line longer than `maxHeaderLength` is a 431, a request line longer than
%% `maxRequestLineLength` a 414; `#catalina #numConnections` holds a new
%% connection unserved until one closes. The header limits run with the
%% defaults on beamtalk-http too, and on Bandit (cowboy's limits differ).
-module(stress_limits).

-export([tests/0]).

tests() ->
    [{"limits_max_requests", [buccaneer], fun max_requests/1},
     {"limits_headers", [buccaneer, http_buccaneer, bandit], fun headers/1},
     {"limits_num_connections", [buccaneer], fun num_connections/1}].

max_requests(Ctx) ->
    stress_lib:with_server(Ctx, #{buccaneer => #{http1 => #{maxRequests => 5}}}, fun(Port) ->
        {ok, C} = bench_conn:connect(Port, false),
        Closes = [begin
            ok = bench_conn:send(C, bench_http:get(<<"/">>)),
            {ok, {200, Close, _}, <<>>} = bench_http:read_response(C, <<>>),
            Close
        end || _ <- lists:seq(1, 5)],
        stress_lib:check(Closes =:= [false, false, false, false, true],
                         "only the 5th response says connection: close", Closes),
        Next = bench_conn:recv(C, 0, 5000),
        bench_conn:close(C),
        stress_lib:check(Next =:= {error, closed}, "the connection closes after the 5th", Next),
        #{closes => Closes}
    end).

headers(Ctx) ->
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        Many = [{<<"x-h", (integer_to_binary(I))/binary>>, <<"v">>} || I <- lists:seq(1, 60)],
        Long = [{<<"x-long">>, binary:copy(<<"a">>, 11000)}],
        LongLine = <<"/", (binary:copy(<<"p">>, 11000))/binary>>,
        Got = #{too_many_headers => status(Port, bench_http:get(<<"/">>, Many)),
                header_too_long => status(Port, bench_http:get(<<"/">>, Long)),
                request_line_too_long => status(Port, bench_http:get(LongLine))},
        Want = #{too_many_headers => 431, header_too_long => 431, request_line_too_long => 414},
        stress_lib:check(Got =:= Want, "limits answer 431 / 414", Got),
        {ok, C} = bench_conn:connect(Port, false),
        stress_lib:check(element(1, stress_lib:get_once(C, <<>>)) =:= ok, "still serving"),
        bench_conn:close(C),
        Got
    end).

status(Port, Req) ->
    {ok, C} = bench_conn:connect(Port, false),
    ok = bench_conn:send(C, Req),
    R = case bench_http:read_response(C, <<>>) of
        {ok, {S, _, _}, _} -> S;
        E -> E
    end,
    bench_conn:close(C),
    R.

%% One acceptor allowed 5 connections: a 6th is not served while the 5
%% are open, and is served once one closes.
num_connections(Ctx) ->
    Opts = #{buccaneer => #{catalina => #{numAcceptors => 1, numConnections => 5,
                                          maxConnectionsRetryCount => 1000,
                                          maxConnectionsRetryWait => 50}}},
    stress_lib:with_server(Ctx, Opts, fun(Port) ->
        Held = [begin {ok, C} = bench_conn:connect(Port, false), {ok, <<>>} = stress_lib:get_once(C, <<>>), C end
                || _ <- lists:seq(1, 5)],
        {ok, Sixth} = bench_conn:connect(Port, false),
        ok = bench_conn:send(Sixth, bench_http:get(<<"/">>)),
        Early = bench_conn:recv(Sixth, 0, 1500),
        stress_lib:check(Early =:= {error, timeout}, "the 6th connection waits while 5 are open", Early),
        bench_conn:close(hd(Held)),
        Late = bench_http:read_response(Sixth, <<>>),
        [bench_conn:close(C) || C <- [Sixth | tl(Held)]],
        stress_lib:check(element(1, Late) =:= ok andalso element(1, element(2, Late)) =:= 200,
                         "the 6th is served once one closes", Late),
        #{sixth_waited_ms => 1500}
    end).
