# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0

defmodule BanditNode.HelloPlug do
  @moduledoc "Answer every request with a fixed `hello world`, as the other servers."
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain", nil)
    |> Plug.Conn.send_resp(200, "hello world")
  end
end
