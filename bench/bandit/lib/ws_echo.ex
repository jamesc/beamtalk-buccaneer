# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0

defmodule BanditNode.WsEcho do
  @moduledoc "A WebSock echoing every data frame, as the Beamtalk nodes' `/ws`."
  @behaviour WebSock

  @impl WebSock
  def init(state), do: {:ok, state}

  @impl WebSock
  def handle_in({data, [opcode: opcode]}, state), do: {:push, {opcode, data}, state}

  @impl WebSock
  def handle_info(_msg, state), do: {:ok, state}
end
