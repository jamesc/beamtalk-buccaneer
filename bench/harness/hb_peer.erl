%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Start a server peer node: a separate BEAM VM running the Buccaneer
%% spike (`buccaneer`), beamtalk-http 0.2.0 on cowboy (`cowboy`) or Bandit
%% 1.12.5 (`bandit`), driven over the peer control channel (standard_io,
%% so no epmd or distribution). Adapted from Catalina's `bench_peer`.
%%
%% Paths come from the environment, set by `bench/run.sh`:
%%   BENCH_ROOT          the repository root
%%   BENCH_BEAMTALK_LIB  `$(beamtalk --print-sysroot)/lib/beamtalk/lib`
%%   BENCH_ELIXIR_LIB    the directory holding Elixir's `elixir/` and `logger/`
-module(hb_peer).

-export([start/1, stop/1, call/4, call/5, impls/0]).

-define(CALL_TIMEOUT, 120000).

impls() -> [buccaneer, cowboy, bandit].

start(Impl) ->
    Args = ["-noinput", "+P", "2000000", "+Q", "1000000"]
        ++ lists:append([["-pa", D] || D <- code_paths(Impl)]),
    {ok, Peer, _Node} = peer:start_link(#{
        connection => standard_io,
        args => Args,
        wait_boot => 60000
    }),
    ok = peer:call(Peer, hb_node, boot, [Impl], ?CALL_TIMEOUT),
    Peer.

stop(Peer) ->
    catch peer:stop(Peer),
    ok.

call(Peer, M, F, A) -> call(Peer, M, F, A, ?CALL_TIMEOUT).

call(Peer, M, F, A, Timeout) -> peer:call(Peer, M, F, A, Timeout).

code_paths(Impl) ->
    Root = env("BENCH_ROOT"),
    Harness = filename:join([Root, "_build", "bench", "ebin"]),
    [Harness | impl_paths(Impl, Root)].

impl_paths(bandit, Root) ->
    Lib = env("BENCH_ELIXIR_LIB"),
    B = filename:join([Root, "bench", "bandit", "_build", "prod", "lib"]),
    [filename:join([Lib, A, "ebin"]) || A <- ["elixir", "logger", "eex"]]
        ++ filelib:wildcard(filename:join([B, "*", "ebin"]));
impl_paths(Impl, Root) ->
    Lib = env("BENCH_BEAMTALK_LIB"),
    Node = filename:join([Root, "bench", atom_to_list(Impl) ++ "_node", "_build"]),
    filelib:wildcard(filename:join([Lib, "*", "ebin"]))
        ++ [filename:join([Node, "dev", "ebin"]), filename:join([Node, "dev", "native", "ebin"])]
        ++ filelib:wildcard(filename:join([Node, "deps", "*", "ebin"]))
        ++ filelib:wildcard(filename:join([Node, "dev", "native", "default", "lib", "*", "ebin"])).

env(Name) ->
    case os:getenv(Name) of
        false -> error({missing_environment_variable, Name});
        "" -> error({missing_environment_variable, Name});
        V -> V
    end.
