%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

%% @doc Start a server peer node for the release gate (`just bench`,
%% `just stress`): a separate BEAM VM running one implementation, driven
%% over the peer control channel (standard_io, so no epmd or
%% distribution). The load generator runs in the calling VM, so client
%% and server never share schedulers. Adapted from Catalina's
%% `bench_peer`.
%%
%%   http_buccaneer  beamtalk-http's HTTPServer on Buccaneer (the gate)
%%   buccaneer       Buccaneer standalone (an Exchange handler)
%%   bandit          Bandit 1.12.5 with a bare Plug (context)
%%   cowboy          bare cowboy: a plain Erlang handler (`bench_cowboy_handler`),
%%                   no Beamtalk runtime (the gate's baseline; `just bench` only)
%%
%% The two Beamtalk implementations load the same package
%% (`bench/http_node`); each gets its own VM. Bare cowboy loads cowboy and
%% ranch from that package's native dependencies (pinned for the baseline).
%%
%% Paths come from the environment, set by `bench/run.sh`:
%%   BENCH_ROOT            the repository root
%%   BENCH_BEAMTALK_EBINS  the Beamtalk runtime and stdlib ebin directories, ':'-separated
%%   BENCH_ELIXIR_LIB      the directory holding Elixir's `elixir/` and `logger/`
-module(bench_peer).

-export([start/1, start/2, stop/1, call/4, call/5, impls/0, bench_impls/0, gate_impls/0]).

-define(CALL_TIMEOUT, 120000).

impls() -> [http_buccaneer, buccaneer, bandit].

%% `just bench`'s servers: the above plus bare cowboy (BT-4498), the
%% gate's baseline.
bench_impls() -> [http_buccaneer, buccaneer, cowboy, bandit].

%% The pair the gate compares.
gate_impls() -> [http_buccaneer, cowboy].

start(Impl) -> start(Impl, #{}).

%% Opts: `log` (a file for the peer's logger; default `none`, which keeps
%% only critical reports).
start(Impl, Opts) ->
    Args = ["-noinput", "+P", "2000000", "+Q", "1000000"]
        ++ lists:append([["-pa", D] || D <- code_paths(Impl)]),
    {ok, Peer, _Node} = peer:start_link(#{
        connection => standard_io,
        args => Args,
        wait_boot => 60000
    }),
    ok = peer:call(Peer, bench_node, boot, [Impl, maps:get(log, Opts, none)], ?CALL_TIMEOUT),
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
impl_paths(_BeamtalkImpl, Root) ->
    Node = filename:join([Root, "bench", "http_node", "_build"]),
    string:split(env("BENCH_BEAMTALK_EBINS"), ":", all)
        ++ [filename:join([Node, "dev", "ebin"]), filename:join([Node, "dev", "native", "ebin"])]
        ++ filelib:wildcard(filename:join([Node, "deps", "*", "ebin"]))
        ++ filelib:wildcard(filename:join([Node, "dev", "native", "default", "lib", "*", "ebin"])).

env(Name) ->
    case os:getenv(Name) of
        false -> error({missing_environment_variable, Name});
        "" -> error({missing_environment_variable, Name});
        V -> V
    end.
