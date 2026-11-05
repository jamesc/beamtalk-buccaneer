%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Slow-loris against Buccaneer standalone with a 3 s read timeout
%% (`#catalina => #{#readTimeout => 3000}`), in three places: the request
%% line, the headers and the body.
%%
%% - drip: clients sending one byte every 200 ms (well inside the read
%%   timeout, as Bandit allows: it has no whole-request deadline) are
%%   served correctly in the end, while ordinary clients keep being
%%   served promptly alongside them;
%% - stall: clients that stop part-way are closed once the read timeout
%%   (request line, headers) or the body read timeout (`readAll:`'s 15 s
%%   default; the standalone handler then answers 500 or closes) passes,
%%   and the node returns to its baseline.
-module(stress_slowloris).

-export([tests/0]).

-define(KEYS, [processes, ports, ets]).
-define(OPTS, #{buccaneer => #{catalina => #{readTimeout => 3000}}}).

tests() ->
    [{"slowloris_drip", [buccaneer], fun drip/1},
     {"slowloris_stall", [buccaneer], fun stall/1}].

request() -> <<"POST /echo HTTP/1.1\r\nhost: localhost\r\ncontent-length: 20\r\n\r\n01234567890123456789">>.

drip(Ctx) ->
    N = stress_lib:pick(Ctx, {30, 200}),
    stress_lib:with_server(Ctx, ?OPTS, fun(Port) ->
        Base = stress_lib:baseline(Ctx, ?KEYS),
        Self = self(),
        Drips = [spawn_link(fun() -> Self ! {drip, self(), drip_one(Port)} end) || _ <- lists:seq(1, N)],
        %% Ordinary clients while the drips are under way.
        Stop = atomics:new(1, []),
        Normal = [spawn_link(fun() -> Self ! {normal, self(), normal(Port, Stop, [])} end) || _ <- lists:seq(1, 4)],
        DripResults = [receive {drip, P, R} -> R after 120000 -> timeout end || P <- Drips],
        atomics:put(Stop, 1, 1),
        Lat = lists:append([receive {normal, P, R} -> R after 60000 -> [timeout] end || P <- Normal]),
        BadDrips = [R || R <- DripResults, R =/= ok],
        BadNormal = [L || L <- Lat, not is_integer(L)],
        stress_lib:check(BadDrips =:= [], "every dripping client is served", lists:sublist(BadDrips, 5)),
        stress_lib:check(BadNormal =:= [], "ordinary clients are served", lists:sublist(BadNormal, 5)),
        Sorted = lists:sort(Lat),
        P99 = lists:nth(max(1, length(Sorted) * 99 div 100), Sorted),
        stress_lib:check(P99 < 1000000, "ordinary clients stay prompt (p99 under 1 s)", P99),
        stress_lib:back_to(Ctx, Base, ?KEYS),
        #{drips => N, normal_requests => length(Lat), normal_p99_us => P99}
    end).

drip_one(Port) ->
    {ok, C} = bench_conn:connect(Port, false),
    Body = <<"01234567890123456789">>,
    R = case lists:all(fun(B) -> timer:sleep(200), bench_conn:send(C, <<B>>) =:= ok end,
                       binary_to_list(request())) of
        true ->
            case bench_http:read_response(C, <<>>, keep) of
                {ok, {200, _, Body}, _} -> ok;
                Other -> Other
            end;
        false -> send_failed
    end,
    bench_conn:close(C),
    R.

normal(Port, Stop, Acc) ->
    case atomics:get(Stop, 1) of
        1 -> Acc;
        0 ->
            T0 = erlang:monotonic_time(microsecond),
            R = case bench_conn:connect(Port, false) of
                {ok, C} ->
                    X = stress_lib:get_once(C, <<>>),
                    bench_conn:close(C),
                    X;
                E -> E
            end,
            L = case R of
                {ok, _} -> erlang:monotonic_time(microsecond) - T0;
                Other -> Other
            end,
            timer:sleep(20),
            normal(Port, Stop, [L | Acc])
    end.

%% Clients stop part-way; each must be closed (or answered) in time.
stall(Ctx) ->
    N = stress_lib:pick(Ctx, {10, 60}),
    stress_lib:with_server(Ctx, ?OPTS, fun(Port) ->
        Base = stress_lib:baseline(Ctx, ?KEYS),
        Places = [{request_line, <<"GET /sl">>, 3000},
                  {headers, <<"GET / HTTP/1.1\r\nhost: localhost\r\nx-slow: ab">>, 3000},
                  {body, <<"POST /echo HTTP/1.1\r\nhost: localhost\r\ncontent-length: 100\r\n\r\nabc">>, 15000}],
        Self = self(),
        Pids = [{Place, spawn_link(fun() -> Self ! {stall, self(), stall_one(Port, Bytes, Timeout)} end)}
                || {Place, Bytes, Timeout} <- Places, _ <- lists:seq(1, N div 3)],
        Results = [{Place, receive {stall, P, R} -> R after 120000 -> timeout end} || {Place, P} <- Pids],
        Bad = [X || X = {_, R} <- Results, element(1, R) =/= closed],
        stress_lib:check(Bad =:= [], "stalled clients are closed after the read timeout", lists:sublist(Bad, 5)),
        stress_lib:back_to(Ctx, Base, ?KEYS),
        Ms = [M || {_, {closed, _, M}} <- Results],
        #{stalled => length(Results), slowest_close_ms => lists:max(Ms)}
    end).

%% Answers {closed, How, Ms}: the server closed (or answered and closed)
%% within the timeout plus 10 s, and not long before it.
stall_one(Port, Bytes, Timeout) ->
    {ok, C} = bench_conn:connect(Port, false),
    ok = bench_conn:send(C, Bytes),
    T0 = erlang:monotonic_time(millisecond),
    R = bench_http:read_response(C, <<>>),
    Ms = erlang:monotonic_time(millisecond) - T0,
    bench_conn:close(C),
    How = case R of
        {error, closed} -> eof;
        {ok, {S, _, _}, _} -> {status, S};
        Other -> Other
    end,
    case Ms >= Timeout - 500 andalso Ms =< Timeout + 10000 andalso (How =:= eof orelse is_tuple(How)) of
        true -> {closed, How, Ms};
        false -> {not_closed_in_time, How, Ms}
    end.
