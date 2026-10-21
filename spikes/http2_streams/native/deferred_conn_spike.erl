%% Copyright 2026 James Casey
%% SPDX-License-Identifier: Apache-2.0

-module(deferred_conn_spike).
-moduledoc """
Spike 5 only, never shipped: the backing gen_server of `DeferredConn`.
It holds a Beamtalk `ConnLogic` value (`#logic` in the spawn arguments)
and defers every decision to it. Each call is parked (`noreply`) and its
`From` handed to the logic, which replies through `gen_server:reply/2` at
once or from a later message. This models BT-4090's deferred reply on a
pure-Beamtalk `Server`.
""".
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-doc "Start the connection; `Config` holds `#logic`, a `ConnLogic`.".
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

init(#{logic := Logic}) ->
    {ok, #{logic => Logic}}.

%% Strip the propagated context (ADR 0069), as every native actor does.
handle_call({Selector, Args, Ctx}, From, State) when is_map(Ctx) ->
    beamtalk_actor:restore_propagated_ctx(Ctx),
    handle_call({Selector, Args}, From, State);
handle_call({directPing, []}, _From, State) ->
    {reply, {ok, pong}, State};
handle_call({Selector, Args}, From, #{logic := Logic} = State) ->
    Next = beamtalk_message_dispatch:send(Logic, 'call:args:from:', [Selector, Args, From]),
    {noreply, State#{logic := Next}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(Msg, #{logic := Logic} = State) ->
    {noreply, State#{logic := beamtalk_message_dispatch:send(Logic, 'handleInfo:', [Msg])}}.
