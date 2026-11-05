%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Chaos: kill processes under load.
%%
%% - connections: keep-alive clients doing GETs and echoes while a killer
%%   kills a random connection process every 50 ms. A killed connection's
%%   client sees a closed socket and reconnects; no client ever gets a
%%   wrong or corrupted answer; the server keeps serving; and once the load
%%   stops the node is back to its baseline.
%% - streams: HTTP/2 connections with 10 streams in flight while a killer
%%   kills a random stream process every 20 ms (a quarter of the
%%   streams are `/slow`, so there are always some alive). The killed
%%   stream is reset (or answered 500), or its connection goes away and
%%   the client reconnects; no stream ever gets a wrong answer; back to
%%   baseline after (this caught the TimeoutProxy leak, BT-4086).
-module(stress_chaos).

-export([tests/0]).

-define(KEYS, [processes, ports, ets]).

tests() ->
    [{"chaos_kill_connections", [http_buccaneer, buccaneer, http_cowboy, bandit], fun connections/1},
     %% Not Bandit: there a killed stream process leaves its stream
     %% unanswered (no RST_STREAM), and the client waits until it times out
     %% (Bandit 1.12.5, measured in BT-4086). Buccaneer resets the stream.
     {"chaos_kill_streams", [http_buccaneer, buccaneer], fun streams/1}].

connections(Ctx) ->
    Secs = stress_lib:pick(Ctx, {5, 30}),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        Base = stress_lib:baseline(Ctx, ?KEYS),
        Stop = atomics:new(1, []),
        Self = self(),
        Clients = [spawn_link(fun() -> Self ! {client, self(), client(Port, Stop, #{})} end)
                   || _ <- lists:seq(1, 32)],
        Kills = killer(Ctx, kill_random_connection, 50, Secs * 1000),
        atomics:put(Stop, 1, 1),
        Counts = stress_lib:merge_counts([receive {client, P, R} -> R after 120000 -> #{stuck => 1} end
                                          || P <- Clients]),
        Bad = maps:without([ok, killed], Counts),
        stress_lib:check(Bad =:= #{}, "no wrong answers; killed connections just close", Bad),
        stress_lib:check(maps:get(ok, Counts, 0) > 0, "the load ran", Counts),
        stress_lib:back_to(Ctx, Base, ?KEYS),
        Counts#{kills => Kills}
    end).

client(Port, Stop, Acc) ->
    case atomics:get(Stop, 1) of
        1 -> Acc;
        0 ->
            case bench_conn:connect(Port, false) of
                {ok, C} -> client_loop(Port, C, <<>>, Stop, Acc);
                E -> client(Port, Stop, stress_lib:bump({connect, E}, Acc))
            end
    end.

client_loop(Port, C, Buf, Stop, Acc) ->
    case atomics:get(Stop, 1) of
        1 -> bench_conn:close(C), Acc;
        0 ->
            Body = rand:bytes(rand:uniform(4096)),
            R = case rand:uniform(2) of
                1 -> stress_lib:get_once(C, Buf);
                2 -> stress_lib:post_once(C, Buf, Body)
            end,
            case R of
                {ok, Rest} -> client_loop(Port, C, Rest, Stop, stress_lib:bump(ok, Acc));
                {error, E} when E =:= closed; E =:= econnreset; E =:= enotconn ->
                    bench_conn:close(C),
                    client(Port, Stop, stress_lib:bump(killed, Acc));
                Other ->
                    bench_conn:close(C),
                    client(Port, Stop, stress_lib:bump(Other, Acc))
            end
    end.

%% Kill with `Fun` every `Every` ms for `Ms`; answers how many it killed.
killer(Ctx, Fun, Every, Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    killer_loop(Ctx, Fun, Every, Deadline, 0).

killer_loop(Ctx, Fun, Every, Deadline, N) ->
    case erlang:monotonic_time(millisecond) > Deadline of
        true -> N;
        false ->
            timer:sleep(Every),
            K = case stress_lib:node_call(Ctx, Fun, []) of none -> 0; _ -> 1 end,
            killer_loop(Ctx, Fun, Every, Deadline, N + K)
    end.

streams(Ctx) ->
    Secs = stress_lib:pick(Ctx, {5, 30}),
    stress_lib:with_server(Ctx, #{}, fun(Port) ->
        Base = stress_lib:baseline(Ctx, ?KEYS),
        Stop = atomics:new(1, []),
        Self = self(),
        Clients = [spawn_link(fun() -> Self ! {client, self(), h2_clients(Port, Stop, #{})} end)
                   || _ <- lists:seq(1, 8)],
        Kills = killer(Ctx, kill_random_stream, 20, Secs * 1000),
        atomics:put(Stop, 1, 1),
        Counts = stress_lib:merge_counts([receive {client, P, R} -> R after 120000 -> #{stuck => 1} end
                                          || P <- Clients]),
        Bad = maps:filter(fun(K, _) -> not lists:member(K, [ok, reset, status_500, goaway, closed]) end, Counts),
        stress_lib:check(Bad =:= #{}, "killed streams are reset, answered 500 or their connection closed", Bad),
        stress_lib:check(maps:get(ok, Counts, 0) > 0, "the load ran", Counts),
        stress_lib:back_to(Ctx, Base, ?KEYS),
        Counts#{kills => Kills}
    end).

%% Reconnect after a connection-level close until Stop.
h2_clients(Port, Stop, Acc) ->
    case atomics:get(Stop, 1) of
        1 -> Acc;
        0 ->
            Acc1 = h2_client(Port, Stop, Acc),
            case atomics:get(Stop, 1) of
                1 -> Acc1;
                0 -> h2_clients(Port, Stop, Acc1)
            end
    end.

h2_client(Port, Stop, Acc) ->
    case bench_h2:connect(Port) of
        {ok, H0} ->
            H = lists:foldl(fun(_, H1) -> element(2, bench_h2:request(H1, path())) end,
                            H0, lists:seq(1, 10)),
            h2_loop(H, 10, Stop, Acc);
        E -> stress_lib:bump({connect, E}, Acc)
    end.

%% `Open` streams in flight; each finished one is replaced until Stop.
h2_loop(H, 0, _Stop, Acc) -> bench_h2:close(H), Acc;
h2_loop(H, Open, Stop, Acc) ->
    case bench_h2:next_event(H) of
        {done, _, 200, H1} -> next(H1, Open, Stop, stress_lib:bump(ok, Acc));
        {done, _, {first_byte, 16#8e}, H1} -> next(H1, Open, Stop, stress_lib:bump(status_500, Acc));
        {done, _, S, H1} -> next(H1, Open, Stop, stress_lib:bump({status, S}, Acc));
        {reset, _, H1} -> next(H1, Open, Stop, stress_lib:bump(reset, Acc));
        {error, {goaway, _}} -> stress_lib:bump(goaway, Acc);
        {error, closed} -> stress_lib:bump(closed, Acc);
        {error, R} -> stress_lib:bump({connection_error, R}, Acc)
    end.

next(H, Open, Stop, Acc) ->
    case atomics:get(Stop, 1) of
        1 -> h2_loop(H, Open - 1, Stop, Acc);
        0 ->
            {_, H1} = bench_h2:request(H, path()),
            h2_loop(H1, Open, Stop, Acc)
    end.

%% One stream in four is `/slow` (a second in the handler), so there are
%% always stream processes alive for the killer to find.
path() ->
    case rand:uniform(4) of
        1 -> <<"/slow">>;
        _ -> <<"/">>
    end.
