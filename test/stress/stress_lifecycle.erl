%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Lifecycle under load.
%%
%% - suspend/resume (Buccaneer standalone: Catalina's `suspend`,
%%   `resume`): while suspended, open keep-alive connections keep being
%%   served and new connections are not; after resume, new connections are
%%   served on the same port.
%% - stop drains: requests in flight when the server stops (`/slow`, one
%%   second each) all get their 200 before their connections close, and
%%   the stop returns once they are done. On beamtalk-http, `srv stop`
%%   (its 5 s drain); standalone, `stop: 10000`.
%% - stop past the deadline (standalone, `#catalina #shutdownTimeout`
%%   300 ms, as Bandit's Thousand Island `shutdown_timeout`): the stop
%%   returns at about the deadline, and the in-flight requests are cut off.
-module(stress_lifecycle).

-export([tests/0]).

-define(KEYS, [processes, ports, ets]).

tests() ->
    [{"lifecycle_suspend_resume", [buccaneer], fun suspend_resume/1},
     {"lifecycle_stop_drains", [http_buccaneer, buccaneer, bandit], fun stop_drains/1},
     {"lifecycle_stop_deadline", [buccaneer], fun stop_deadline/1}].

%% A fixed port: resume listens again, and with port 0 it would pick a new one.
suspend_resume(Ctx) ->
    {ok, L} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Free} = inet:port(L),
    gen_tcp:close(L),
    {ok, Port} = stress_lib:node_call(Ctx, start_server, [#{buccaneer => #{port => Free}}]),
    stress_lib:ready(Port, #{}),
    Open = [begin {ok, C} = bench_conn:connect(Port, false), C end || _ <- lists:seq(1, 10)],
    [{ok, <<>>} = stress_lib:get_once(C, <<>>) || C <- Open],
    ok = stress_lib:node_call(Ctx, suspend, []),
    Served = [element(1, stress_lib:get_once(C, <<>>)) || C <- Open],
    stress_lib:check(lists:all(fun(R) -> R =:= ok end, Served), "open connections still served", Served),
    New = case bench_conn:connect(Port, false, 1) of
        {ok, C1} ->
            bench_conn:send(C1, bench_http:get(<<"/">>)),
            R1 = bench_http:read_response(C1, <<>>),
            bench_conn:close(C1),
            R1;
        E -> E
    end,
    stress_lib:check(element(1, New) =:= error, "new connections are not served while suspended", New),
    ok = stress_lib:node_call(Ctx, resume, []),
    {ok, C2} = bench_conn:connect(Port, false),
    After = stress_lib:get_once(C2, <<>>),
    bench_conn:close(C2),
    [bench_conn:close(C) || C <- Open],
    stress_lib:check(element(1, After) =:= ok, "new connections served after resume", After),
    stress_lib:node_call(Ctx, stop_server, [10000]),
    #{while_suspended => New}.

stop_drains(Ctx) ->
    N = 10,
    {ok, Port} = stress_lib:node_call(Ctx, start_server, [#{buccaneer => #{catalina => #{numAcceptors => 1}}}]),
    stress_lib:ready(Port, #{}),
    Self = self(),
    Pids = [spawn_link(fun() -> Self ! {slow, self(), slow_get(Port)} end) || _ <- lists:seq(1, N)],
    timer:sleep(300),
    {Stopped, Ms} = stress_lib:node_call(Ctx, stop_server, [10000]),
    Results = [receive {slow, P, R} -> R after 30000 -> timeout end || P <- Pids],
    Bad = [R || R <- Results, R =/= ok],
    stress_lib:check(Bad =:= [], "every in-flight request completes", Bad),
    stress_lib:check(Ms >= 400 andalso Ms < 9000, "stop waits for them, and no longer", Ms),
    #{stop => Stopped, stop_ms => Ms}.

slow_get(Port) ->
    {ok, C} = bench_conn:connect(Port, false),
    ok = bench_conn:send(C, bench_http:get(<<"/slow">>)),
    R = case bench_http:read_response(C, <<>>, keep) of
        {ok, {200, _, <<"hello world">>}, _} -> ok;
        Other -> Other
    end,
    bench_conn:close(C),
    R.

stop_deadline(Ctx) ->
    {ok, Port} = stress_lib:node_call(Ctx, start_server,
                                      [#{buccaneer => #{catalina => #{numAcceptors => 1, shutdownTimeout => 300}}}]),
    stress_lib:ready(Port, #{}),
    Base = stress_lib:stats(Ctx),
    Self = self(),
    Pids = [spawn_link(fun() -> Self ! {slow, self(), slow_get(Port)} end) || _ <- lists:seq(1, 5)],
    timer:sleep(200),
    {_, Ms} = stress_lib:node_call(Ctx, stop_server, [10000]),
    Results = [receive {slow, P, R} -> R after 30000 -> timeout end || P <- Pids],
    stress_lib:check(Ms < 2000, "stop returns at about the deadline", Ms),
    stress_lib:check(lists:all(fun(R) -> R =/= ok andalso R =/= timeout end, Results),
                     "in-flight requests are cut off", Results),
    After = stress_lib:settle(Ctx, ?KEYS),
    stress_lib:check(maps:get(processes, After) =< maps:get(processes, Base),
                     "no processes left behind", {maps:get(processes, Base), maps:get(processes, After)}),
    #{stop_ms => Ms}.
