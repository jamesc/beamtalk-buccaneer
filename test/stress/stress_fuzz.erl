%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Request fuzz: pipelined batches of random requests (GET, POST with
%% a content-length body, POST with a chunked body in random chunk sizes
%% and extensions, random header-name case), the batch's bytes sent in
%% random splits with random pauses. Every response is read back in order
%% and checked byte for byte. Then malformed requests: the server rejects
%% them (4xx, or 505 for an unknown version) or closes, keeps serving, and leaks nothing.
-module(stress_fuzz).

-export([tests/0]).

-define(KEYS, [processes, ports, ets]).
-define(ALL, [http_buccaneer, buccaneer, http_cowboy, bandit]).

tests() ->
    [{"fuzz_pipelined_requests", ?ALL, fun fuzz/1},
     {"fuzz_malformed_requests", ?ALL, fun malformed/1}].

fuzz(Ctx) ->
    Workers = stress_lib:pick(Ctx, {8, 32}),
    Batches = stress_lib:pick(Ctx, {20, 150}),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        Base = stress_lib:baseline(Ctx, ?KEYS),
        Self = self(),
        Pids = [spawn_link(fun() -> Self ! {fuzzed, self(), worker(Port, Batches, #{})} end)
                || _ <- lists:seq(1, Workers)],
        Counts = stress_lib:merge_counts([receive {fuzzed, P, R} -> R after 600000 -> #{stuck => 1} end
                                          || P <- Pids]),
        Bad = maps:without([get, post, chunked, closed_by_server], Counts),
        stress_lib:check(Bad =:= #{}, "every response arrives intact and in order", Bad),
        After = stress_lib:back_to(Ctx, Base, ?KEYS),
        stress_lib:check_ets_rows(Base, After, Workers * Batches),
        Counts
    end).

worker(_Port, 0, Acc) -> Acc;
worker(Port, N, Acc) ->
    {ok, C} = bench_conn:connect(Port, false),
    Reqs = [request(rand:uniform(3)) || _ <- lists:seq(1, rand:uniform(8))],
    Bytes = iolist_to_binary([B || {_, B, _} <- Reqs]),
    Sender = spawn_link(fun() -> send_split(C, Bytes) end),
    Acc1 = read_all(C, Reqs, <<>>, Acc),
    unlink(Sender),
    exit(Sender, kill),
    bench_conn:close(C),
    worker(Port, N - 1, Acc1).

read_all(_C, [], _Buf, Acc) -> Acc;
read_all(C, [{Kind, _, Expect} | Rest], Buf, Acc) ->
    case bench_http:read_response(C, Buf, keep) of
        {ok, {200, Close, Expect}, Buf1} ->
            Acc1 = stress_lib:bump(Kind, Acc),
            case Close of
                %% cowboy closes after max_keepalive; the rest are unsent.
                true -> stress_lib:bump(closed_by_server, Acc1);
                false -> read_all(C, Rest, Buf1, Acc1)
            end;
        {ok, {S, _, B}, _} -> stress_lib:bump({Kind, bad_response, S, byte_size(B), byte_size(Expect)}, Acc);
        {error, R} -> stress_lib:bump({Kind, R}, Acc)
    end.

%% {Kind, Bytes, ExpectedBody}
request(1) ->
    {get, bench_http:request(<<"GET">>, <<"/">>, [{case_of(<<"x-fuzz">>), <<"1">>}]), <<"hello world">>};
request(2) ->
    Body = rand:bytes(size()),
    {post, iolist_to_binary(bench_http:request(<<"POST">>, <<"/echo">>, [], Body)), Body};
request(3) ->
    Body = rand:bytes(size()),
    {chunked, iolist_to_binary([<<"POST /echo HTTP/1.1\r\nhost: localhost\r\n">>,
                                case_of(<<"transfer-encoding">>), <<": chunked\r\n\r\n">>,
                                chunks(Body), <<"0\r\n\r\n">>]), Body}.

size() ->
    case rand:uniform(4) of
        1 -> 0;
        2 -> rand:uniform(100);
        3 -> rand:uniform(8000);
        4 -> rand:uniform(70000)
    end.

chunks(<<>>) -> [];
chunks(B) ->
    N = min(byte_size(B), rand:uniform(9000)),
    <<C:N/binary, Rest/binary>> = B,
    Ext = case rand:uniform(5) of 1 -> <<";ext=1">>; _ -> <<>> end,
    [integer_to_binary(N, 16), Ext, <<"\r\n">>, C, <<"\r\n">> | chunks(Rest)].

case_of(Name) ->
    << <<(case rand:uniform(2) of 1 -> string:to_upper(Ch); 2 -> Ch end)>> || <<Ch>> <= Name >>.

%% Send in random pieces (1 byte to 16 KiB), sometimes pausing.
send_split(_C, <<>>) -> ok;
send_split(C, B) ->
    N = min(byte_size(B), case rand:uniform(3) of 1 -> rand:uniform(16); _ -> rand:uniform(16384) end),
    <<P:N/binary, Rest/binary>> = B,
    case bench_conn:send(C, P) of
        ok ->
            case rand:uniform(20) of 1 -> timer:sleep(rand:uniform(3)); _ -> ok end,
            send_split(C, Rest);
        _ -> ok
    end.

%% === Malformed ===

malformed(Ctx) ->
    Rounds = stress_lib:pick(Ctx, {3, 20}),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        Base = stress_lib:baseline(Ctx, ?KEYS),
        Outcomes = lists:append([[malformed_one(Port, Bad) || Bad <- cases()] || _ <- lists:seq(1, Rounds)]),
        Counts = lists:foldl(fun stress_lib:bump/2, #{}, Outcomes),
        Bad = maps:filter(fun(K, _) -> not lists:member(K, [rejected, closed]) end, Counts),
        stress_lib:check(Bad =:= #{}, "every malformed request is rejected (4xx, 505) or closed", Bad),
        {ok, C} = bench_conn:connect(Port, false),
        stress_lib:check(element(1, stress_lib:get_once(C, <<>>)) =:= ok, "still serving"),
        bench_conn:close(C),
        stress_lib:back_to(Ctx, Base, ?KEYS),
        Counts
    end).

cases() ->
    [<<"GET\r\n\r\n">>,
     <<"GET / HTTP/1.1\r\nhost localhost\r\n\r\n">>,
     <<"GET / HTTP/9.9\r\nhost: localhost\r\n\r\n">>,
     <<"POST /echo HTTP/1.1\r\nhost: localhost\r\ncontent-length: -5\r\n\r\n">>,
     <<"POST /echo HTTP/1.1\r\nhost: localhost\r\ncontent-length: abc\r\n\r\n">>,
     <<"POST /echo HTTP/1.1\r\nhost: localhost\r\ncontent-length: 3\r\ncontent-length: 4\r\n\r\nabcd">>,
     <<"POST /echo HTTP/1.1\r\nhost: localhost\r\ntransfer-encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n">>,
     <<"GET / HTTP/1.1\r\nhost: localhost\r\nbad header\r\n\r\n">>,
     <<(rand:bytes(64))/binary, "\r\n\r\n">>,
     <<"\r\n\r\n\r\n\r\n">>].

malformed_one(Port, Bytes) ->
    {ok, C} = bench_conn:connect(Port, false),
    ok = bench_conn:send(C, Bytes),
    R = case bench_http:read_response(C, <<>>) of
        {ok, {S, _, _}, _} when S >= 400, S < 500; S =:= 505 -> rejected;
        {ok, {S, _, _}, _} -> {status, S};
        {error, closed} -> closed;
        {error, {bad_status_line, {more, _}}} -> closed;
        {error, R0} -> {error, R0}
    end,
    bench_conn:close(C),
    R.
