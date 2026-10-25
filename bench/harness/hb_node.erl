%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc The harness's side of a server peer node (see `hb_peer`): boots
%% one implementation, starts and stops one server at a time, and runs the
%% parse microbenchmark. Adapted from Catalina's `bench_node`.
-module(hb_node).

-export([boot/1, impl/0, start_server/1, stop_server/1, parse_bench/1, profile_parse/1,
         queue_samples/2, profile_requests/1, class_stats_on/0, class_stats/0]).

boot(Impl) ->
    persistent_term:put({?MODULE, impl}, Impl),
    logger:set_primary_config(level, critical),
    boot_impl(Impl).

boot_impl(bandit) ->
    {ok, _} = application:ensure_all_started(bandit),
    {module, _} = code:ensure_loaded('Elixir.BanditNode.HelloPlug'),
    ok;
boot_impl(Impl) ->
    {ok, _} = application:ensure_all_started(beamtalk_stdlib),
    App = list_to_atom(atom_to_list(Impl) ++ "_node"),
    {ok, _} = application:ensure_all_started(App),
    %% Load every package module so its class registers (on_load).
    Dirs = [D || D <- code:get_path(), is_package_ebin(D)],
    [code:ensure_loaded(list_to_atom(filename:basename(F, ".beam")))
        || D <- Dirs, F <- filelib:wildcard(filename:join(D, "bt@*.beam"))],
    ok.

is_package_ebin(Dir) ->
    lists:any(fun(Part) -> lists:suffix("_node", Part) end, filename:split(Dir)).

impl() -> persistent_term:get({?MODULE, impl}).

%% Start a server owned by a long-lived process (the caller is a transient
%% peer-call process, and the servers link to their starter). Answers
%% `{ok, Port}`.
start_server(Opts) ->
    Caller = self(),
    Ref = make_ref(),
    Owner = spawn(fun() -> owner(Caller, Ref, Opts) end),
    receive
        {Ref, Reply} -> Reply
    after 60000 ->
        exit(Owner, kill),
        {error, start_timeout}
    end.

owner(Caller, Ref, Opts) ->
    process_flag(trap_exit, true),
    case catch start(impl(), Opts) of
        {ok, Server, Port} ->
            register(hb_node_owner, self()),
            Caller ! {Ref, {ok, Port}},
            owner_loop(Server);
        Other ->
            Caller ! {Ref, {error, Other}}
    end.

owner_loop(Server) ->
    receive
        {stop, From, Ref} ->
            Result = (catch stop(impl(), Server)),
            unregister(hb_node_owner),
            From ! {Ref, Result};
        {'EXIT', _, _} ->
            owner_loop(Server)
    end.

stop_server(_Timeout) ->
    case whereis(hb_node_owner) of
        undefined -> ok;
        Owner ->
            Ref = make_ref(),
            Owner ! {stop, self(), Ref},
            receive {Ref, Reply} -> Reply after 60000 -> timeout end
    end.

start(buccaneer, Opts) ->
    M = 'bt@buccaneer_node@buccaneer_node',
    Srv = M:'class_start:'(nil, #{port => maps:get(port, Opts, 0), numAcceptors => 100}),
    {ok, Srv, M:'class_port:'(nil, Srv)};
start(cowboy, Opts) ->
    M = 'bt@cowboy_node@cowboy_node',
    Srv = M:'class_start:'(nil, maps:get(port, Opts, 0)),
    {ok, Srv, M:'class_port:'(nil, Srv)};
start(bandit, Opts) ->
    {ok, Pid} = 'Elixir.Bandit':start_link([
        {plug, 'Elixir.BanditNode.HelloPlug'},
        {port, maps:get(port, Opts, 0)},
        {ip, loopback},
        {thousand_island_options, [{num_acceptors, 100}]}
    ]),
    {ok, {_, Port}} = 'Elixir.ThousandIsland':listener_info(Pid),
    {ok, Pid, Port}.

stop(buccaneer, Srv) -> 'bt@buccaneer_node@buccaneer_node':'class_stop:'(nil, Srv);
stop(cowboy, Srv) -> 'bt@cowboy_node@cowboy_node':'class_stop:'(nil, Srv);
stop(bandit, Pid) -> 'Elixir.ThousandIsland':stop(Pid, 5000).

%% === Parse microbenchmark (Buccaneer node only) ===

%% ns per request-head parse of the spike's 7-header GET: pure Erlang
%% `decode_packet` to `http_eoh`, and the Beamtalk `SpikeParser`.
parse_bench(N) ->
    Req = request(),
    Bt = fun() -> 'bt@buccaneer_node@spike_parser':'class_readHead:socket:'(nil, Req, nil) end,
    Erl = fun() -> erl_parse(Req) end,
    %% Same answer shape check: both see 7 headers and an empty rest.
    {7, <<>>} = Erl(),
    _ = Bt(),
    %% One `Result ok:` via class_send: the pre-BT-4065 path generated code
    %% no longer takes (reference only, not on the parse path anymore).
    ResultOk = fun() ->
        beamtalk_object_class:class_send(beamtalk_class_registry:whereis_class('Result'), 'ok:', [1])
    end,
    #{erlang_ns => time_ns(Erl, N), beamtalk_ns => time_ns(Bt, N),
      bare_decode_packet_ns => time_ns(fun() -> erlang:decode_packet(http_bin, Req, []) end, N),
      result_ok_ns => time_ns(ResultOk, N)}.

time_ns(F, N) ->
    loop(F, 1000),
    T0 = erlang:monotonic_time(),
    loop(F, N),
    erlang:convert_time_unit(erlang:monotonic_time() - T0, native, nanosecond) div N.

loop(_, 0) -> ok;
loop(F, N) -> F(), loop(F, N - 1).

request() ->
    <<"GET /hello/world?x=1 HTTP/1.1\r\nhost: localhost:4000\r\nuser-agent: spike/1.0\r\n"
      "accept: text/html,application/xhtml+xml\r\naccept-encoding: gzip, deflate\r\n"
      "accept-language: en-GB,en;q=0.9\r\nconnection: keep-alive\r\n"
      "x-request-id: 6f1e1f5c-2a8b-4f0e-9d7e-1c2b3a4d5e6f\r\n\r\n">>.

%% Bandit's read path in plain Erlang: request line, then headers with the
%% names lowercased, to `http_eoh`.
erl_parse(Bin) ->
    {ok, {http_request, _M, {abs_path, _P}, _V}, Rest} = erlang:decode_packet(http_bin, Bin, []),
    erl_headers(Rest, []).

erl_headers(Bin, Acc) ->
    case erlang:decode_packet(httph_bin, Bin, []) of
        {ok, {http_header, _, F, _, V}, Rest} ->
            erl_headers(Rest, [{ascii_lower(name(F)), V} | Acc]);
        {ok, http_eoh, Rest} ->
            {length(Acc), Rest}
    end.

name(A) when is_atom(A) -> atom_to_binary(A);
name(B) -> B.

%% Bandit's `String.downcase(name, :ascii)`.
ascii_lower(B) -> << <<(if C >= $A, C =< $Z -> C + 32; true -> C end)>> || <<C>> <= B >>.

%% === Profiles (`hb_main --profile`) ===

%% A sampling profile of the Beamtalk parse (tprof and eprof cannot trace
%% in a Beamtalk node: tprof answers `badarg`, eprof crashes on a module it
%% lists but cannot load). A process parses in a loop while this one reads
%% the stacks of every running process Samples times (the class processes
%% the parse calls included); answers the share of stacks per function
%% found anywhere on the stack ("inclusive") and at the top ("self"), as
%% {percent, "M:F/A"}, heaviest first.
profile_parse(Samples) ->
    Req = request(),
    Worker = spawn(fun Loop() ->
        'bt@buccaneer_node@spike_parser':'class_readHead:socket:'(nil, Req, nil),
        Loop()
    end),
    timer:sleep(200),
    Stacks = sample_all(Samples, []),
    exit(Worker, kill),
    summarise(Stacks).

%% The same over the node while the load generator drives the server:
%% each round samples every process that is running or is inside a
%% request (a `bt@buccaneer_node` frame on its stack; a handler blocked in
%% a call to a class process counts there).
profile_requests(Samples) ->
    Stacks = sample_all(Samples, []),
    summarise(Stacks).

sample_all(0, Acc) -> Acc;
sample_all(N, Acc) ->
    Busy = [St || P <- processes(), P =/= self(),
                  {status, Status} <- [erlang:process_info(P, status)],
                  {current_stacktrace, St} <- [erlang:process_info(P, current_stacktrace)],
                  Status =:= running orelse in_request(St)],
    timer:sleep(1),
    sample_all(N - 1, [[mfa(F) || F <- St] || St <- Busy] ++ Acc).

in_request(St) ->
    lists:any(fun({M, _, _, _}) ->
        lists:prefix("bt@buccaneer_node", atom_to_list(M))
    end, St).

mfa({M, F, A, _}) when is_integer(A) -> lists:flatten(io_lib:format("~p:~p/~p", [M, F, A]));
mfa({M, F, Args, _}) -> lists:flatten(io_lib:format("~p:~p/~p", [M, F, length(Args)])).

summarise(Stacks) ->
    Total = max(1, length(Stacks)),
    Incl = count([lists:usort(S) || S <- Stacks]),
    Self = count([[hd(S)] || S <- Stacks, S =/= []]),
    Pct = fun(Counts) ->
        lists:sublist(lists:reverse(lists:sort(
            [{round(C * 1000 / Total) / 10, F} || {F, C} <- maps:to_list(Counts)])), 30)
    end,
    #{samples => Total, inclusive => Pct(Incl), self => Pct(Self)}.

count(Lists) ->
    lists:foldl(fun(L, Acc) ->
        lists:foldl(fun(F, A) -> maps:update_with(F, fun(C) -> C + 1 end, 1, A) end, Acc, L)
    end, #{}, Lists).

%% Sample, Count times every 100 ms, the processes with the longest message
%% queues: {queue length, registered name or initial call}.
queue_samples(Count, Top) ->
    [begin
         timer:sleep(100),
         Qs = [{L, who(P)} || P <- processes(),
                              {message_queue_len, L} <- [erlang:process_info(P, message_queue_len)],
                              L > 0],
         lists:sublist(lists:reverse(lists:sort(Qs)), Top)
     end || _ <- lists:seq(1, Count)].

who(P) ->
    case erlang:process_info(P, [registered_name, dictionary]) of
        [{registered_name, N}, _] when is_atom(N), N =/= [] -> N;
        [_, {dictionary, D}] ->
            case proplists:get_value('$initial_call', D) of
                undefined -> proplists:get_value('$beamtalk_class', D, P);
                IC -> IC
            end;
        _ -> P
    end.


%% Messages into each Beamtalk class process (`sys:statistics`), to count
%% the synchronous class-process calls a request makes (BT-4065): switch
%% on, drive N requests, then read `{messages_in, class process}`.
class_stats_on() ->
    [catch sys:statistics(N, true) || N <- class_processes()],
    ok.

class_stats() ->
    R = [{In, N} || N <- class_processes(), {ok, St} <- [catch sys:statistics(N, get)],
                    In <- [proplists:get_value(messages_in, St, 0)], In > 0],
    [catch sys:statistics(N, false) || N <- class_processes()],
    lists:reverse(lists:sort(R)).

class_processes() ->
    [N || N <- registered(), lists:prefix("beamtalk_class_", atom_to_list(N))].
