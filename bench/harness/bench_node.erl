%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc The harness's side of a server peer node (see `bench_peer`): boots
%% one implementation, starts and stops its servers, and answers questions
%% about the node for the leak, memory and chaos checks. Adapted from
%% Catalina's `bench_node`.
%%
%% Server options (a map, all optional):
%%   name       which server (default `main`; a node can run several)
%%   tls        serve https with `test/fixtures/{cert,key}.pem`
%%   buccaneer  extra `Buccaneer start:` options (`buccaneer` only), e.g.
%%              #{http1 => #{maxRequests => 5}, catalina => #{numConnections => 10}}
%%
%% Connections are found the same way on every implementation: a
%% connection is a TCP port with a peer, and its process is the port's
%% owner (for TLS, the `ssl` connection process).
-module(bench_node).

-export([
    boot/2,
    impl/0,
    start_server/1,
    stop_server/1,
    stop_server/2,
    suspend/0,
    resume/0,
    stats/0,
    connection_count/0,
    connection_pids/0,
    stream_pids/0,
    dictionary_sizes/0,
    connection_info/0,
    kill_random_connection/0,
    kill_random_stream/0,
    gc_all/0,
    cert_dir/0
]).

-define(NODE, 'bt@http_node@http_node').

%% === Boot ===

boot(Impl, Log) ->
    persistent_term:put({?MODULE, impl}, Impl),
    configure_logger(Log),
    {ok, _} = application:ensure_all_started(ssl),
    %% `/file`'s body (HttpNode filePath, the Bandit plug's file_path).
    ok = file:write_file(filename:join([os:getenv("BENCH_ROOT"), "_build", "bench", "buccaneer_bench_1mib"]),
                         binary:copy(<<"x">>, 1048576)),
    boot_impl(Impl).

boot_impl(bandit) ->
    {ok, _} = application:ensure_all_started(bandit),
    {module, _} = code:ensure_loaded('Elixir.BanditNode.HelloPlug'),
    {module, _} = code:ensure_loaded('Elixir.BanditNode.WsEcho'),
    ok;
boot_impl(_Beamtalk) ->
    {ok, _} = application:ensure_all_started(beamtalk_stdlib),
    {ok, _} = application:ensure_all_started(http_node),
    %% cowboy and ranch for the cowboy backend's own listeners.
    {ok, _} = application:ensure_all_started(cowboy),
    %% Load every package module so its class registers (on_load).
    Dirs = [D || D <- code:get_path(), is_package_ebin(D)],
    [code:ensure_loaded(list_to_atom(filename:basename(F, ".beam")))
        || D <- Dirs, F <- filelib:wildcard(filename:join(D, "bt@*.beam"))],
    ok.

is_package_ebin(Dir) ->
    lists:member("http_node", filename:split(Dir)).

configure_logger(none) ->
    logger:set_primary_config(level, critical);
configure_logger(File) ->
    _ = logger:remove_handler(default),
    ok = logger:add_handler(file, logger_std_h, #{config => #{file => File}, level => all}),
    logger:set_primary_config(level, notice).

impl() -> persistent_term:get({?MODULE, impl}).

cert_dir() -> filename:join([os:getenv("BENCH_ROOT"), "test", "fixtures"]).

%% === Servers ===

%% Start a server owned by a long-lived process (the caller is a transient
%% peer-call process, and servers link to their starter). Answers
%% `{ok, Port}`.
start_server(Opts) ->
    Name = maps:get(name, Opts, main),
    case whereis(owner_name(Name)) of
        undefined -> ok;
        _ -> error({server_already_running, Name})
    end,
    Caller = self(),
    Ref = make_ref(),
    Owner = spawn(fun() -> owner(Caller, Ref, Name, Opts) end),
    receive
        {Ref, Reply} -> Reply
    after 60000 ->
        exit(Owner, kill),
        {error, start_timeout}
    end.

owner_name(Name) -> list_to_atom("bench_node_owner_" ++ atom_to_list(Name)).

owner(Caller, Ref, Name, Opts) ->
    process_flag(trap_exit, true),
    case catch start(impl(), maps:get(tls, Opts, false), Opts) of
        {ok, Server, Port} ->
            register(owner_name(Name), self()),
            persistent_term:put({?MODULE, server, Name}, Server),
            Caller ! {Ref, {ok, Port}},
            owner_loop(Name, Server);
        Other ->
            Caller ! {Ref, {error, Other}}
    end.

owner_loop(Name, Server) ->
    receive
        {stop, Timeout, From, Ref} ->
            T0 = erlang:monotonic_time(millisecond),
            Result = (catch stop(Server, Timeout)),
            Elapsed = erlang:monotonic_time(millisecond) - T0,
            persistent_term:erase({?MODULE, server, Name}),
            unregister(owner_name(Name)),
            From ! {Ref, {Result, Elapsed}};
        {'EXIT', _, _} ->
            owner_loop(Name, Server)
    end.

stop_server(Timeout) -> stop_server(main, Timeout).

%% Stop a server, waiting up to `Timeout` ms where the implementation
%% takes one. Answers `{Result, ElapsedMs}`.
stop_server(Name, Timeout) ->
    case whereis(owner_name(Name)) of
        undefined -> {ok, 0};
        Owner ->
            Ref = make_ref(),
            Owner ! {stop, Timeout, self(), Ref},
            receive {Ref, Reply} -> Reply after Timeout + 60000 -> timeout end
    end.

server() -> persistent_term:get({?MODULE, server, main}).

start(http_buccaneer, false, _Opts) ->
    Srv = ?NODE:'class_startHttp:'(node_class(), buccaneer),
    {ok, {http, Srv}, ?NODE:'class_httpPort:'(node_class(), Srv)};
start(http_cowboy, false, _Opts) ->
    Srv = ?NODE:'class_startHttp:'(node_class(), cowboy),
    {ok, {http, Srv}, ?NODE:'class_httpPort:'(node_class(), Srv)};
start(http_buccaneer, true, _Opts) ->
    Srv = ?NODE:'class_startTls:'(node_class(), #{}),
    {ok, {buccaneer, Srv}, ?NODE:'class_port:'(node_class(), Srv)};
start(http_cowboy, true, _Opts) ->
    %% HTTPServer has no TLS option: beamtalk-http's cowboy handler module
    %% behind a cowboy TLS listener, as `beamtalk_http_server` starts its
    %% clear one.
    Handler = ?NODE:'class_handler:'(node_class(), false),
    Dispatch = cowboy_router:compile([
        {'_', [{'_', beamtalk_http_server_handler, #{handler => Handler}}]}
    ]),
    Ref = make_ref(),
    Dir = cert_dir(),
    {ok, _} = cowboy:start_tls(Ref,
        [{port, 0}, {ip, {127, 0, 0, 1}},
         {certfile, filename:join(Dir, "cert.pem")}, {keyfile, filename:join(Dir, "key.pem")}],
        #{env => #{dispatch => Dispatch}}),
    {ok, {cowboy_tls, Ref}, ranch:get_port(Ref)};
start(buccaneer, Tls, Opts) ->
    Extra = maps:get(buccaneer, Opts, #{}),
    Srv = ?NODE:'class_startStandalone:'(node_class(),
        maps:merge(#{port => 0, ip => {127, 0, 0, 1}, tls => Tls}, Extra)),
    {ok, {buccaneer, Srv}, ?NODE:'class_port:'(node_class(), Srv)};
start(bandit, Tls, _Opts) ->
    Dir = cert_dir(),
    Scheme = case Tls of
        true -> [{scheme, https}, {certfile, filename:join(Dir, "cert.pem")},
                 {keyfile, filename:join(Dir, "key.pem")}];
        false -> []
    end,
    {ok, Pid} = 'Elixir.Bandit':start_link([
        {plug, 'Elixir.BanditNode.HelloPlug'},
        {port, 0},
        {ip, loopback},
        {startup_log, false}
    ] ++ Scheme),
    {ok, {_, Port}} = 'Elixir.ThousandIsland':listener_info(Pid),
    {ok, {bandit, Pid}, Port}.

stop({http, Srv}, _Timeout) -> ?NODE:'class_stopHttp:'(node_class(), Srv);
stop({buccaneer, Srv}, Timeout) -> ?NODE:'class_stop:timeout:'(node_class(), Srv, Timeout);
stop({cowboy_tls, Ref}, _Timeout) -> cowboy:stop_listener(Ref);
stop({bandit, Pid}, Timeout) -> 'Elixir.ThousandIsland':stop(Pid, Timeout).

%% The receiver for a direct class-method call: the class object tuple
%% (codegen reads element 2 of `self` on every self-send).
node_class() ->
    {beamtalk_object, 'HttpNode class', ?NODE, beamtalk_class_registry:whereis_class('HttpNode')}.

%% === Lifecycle (Buccaneer standalone: Catalina's ServerSupervisor) ===

suspend() -> op(suspend).

resume() -> op(resume).

op(Op) ->
    {buccaneer, Srv} = server(),
    case beamtalk_message_dispatch:send(Srv, Op, []) of
        #{isOk := true} -> ok;
        #{errReason := R} -> {error, R};
        Other -> Other
    end.

%% === Inspection ===

%% Connected TCP sockets (ports with a peer). The harness's own peer
%% channel is standard_io, not TCP, so every one is a server connection.
connection_ports() ->
    [P || P <- erlang:ports(),
          erlang:port_info(P, name) =:= {name, "tcp_inet"},
          case inet:peername(P) of {ok, _} -> true; _ -> false end].

connection_count() -> length(connection_ports()).

connection_pids() ->
    lists:usort([Pid || P <- connection_ports(),
                        {connected, Pid} <- [erlang:port_info(P, connected)], is_pid(Pid)]).

%% HTTP/2 stream processes: Buccaneer's `StreamProcess` processes (marked
%% `buccaneer_h2_stream`; actors in builds before BT-4469) and
%% Bandit's `Bandit.HTTP2.StreamProcess` processes, found by their process
%% dictionary. (Not "what a connection monitors": a connection in a
%% `gen_server:call` monitors the callee, a class process or the server
%% actor, and killing those breaks the node.)
stream_pids() ->
    [P || P <- erlang:processes(), P =/= self(), is_stream(P)].

is_stream(P) ->
    case erlang:process_info(P, dictionary) of
        {dictionary, D} ->
            proplists:get_value(buccaneer_h2_stream, D) =:= true
                orelse proplists:get_value('$beamtalk_actor', D) =:= 'StreamProcess'
                orelse element(1, proplists:get_value('$initial_call', D, {x, x, 0}))
                       =:= 'Elixir.Bandit.HTTP2.StreamProcess';
        _ -> false
    end.

%% The process-dictionary size of each connection process.
dictionary_sizes() ->
    [length(D) || C <- connection_pids(), {dictionary, D} <- [erlang:process_info(C, dictionary)]].

%% `{DictionarySize, MemoryBytes}` for each connection process.
connection_info() ->
    [{length(D), M} || C <- connection_pids(),
                       [{dictionary, D}, {memory, M}] <- [erlang:process_info(C, [dictionary, memory])]].

kill_random_connection() -> kill_random(connection_pids()).

kill_random_stream() -> kill_random(stream_pids()).

kill_random([]) -> none;
kill_random(Pids) ->
    P = lists:nth(rand:uniform(length(Pids)), Pids),
    exit(P, kill),
    P.

gc_all() ->
    [erlang:garbage_collect(P) || P <- erlang:processes()],
    ok.

%% Node-wide counters for the leak checks and the memory rows.
stats() ->
    #{
        processes => erlang:system_info(process_count),
        ports => erlang:system_info(port_count),
        ets => length(ets:all()),
        ets_rows => lists:sum([N || T <- ets:all(), N <- [ets:info(T, size)], is_integer(N)]),
        memory => erlang:memory(total),
        process_memory => erlang:memory(processes),
        binary_memory => erlang:memory(binary),
        connections => connection_count()
    }.
