# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0

defmodule BanditNode.HelloPlug do
  @moduledoc """
  The bench routes as a bare Plug, as the Beamtalk servers serve them
  (`bench/http_node/src/http_node.bt`): `/` answers `hello world`;
  `POST /echo` the request body; `/chunked` 1 MiB as 16 chunks of 64 KiB;
  `/file` a 1 MiB file; `/slow` `hello world` after a second; `/ws` a
  WebSocket echo.
  """
  @behaviour Plug

  @chunk :binary.copy("x", 65536)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/echo"} = conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)

    conn
    |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
    |> Plug.Conn.send_resp(200, body)
  end

  def call(%Plug.Conn{request_path: "/chunked"} = conn, _opts) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(1..16, conn, fn _, c ->
      {:ok, c} = Plug.Conn.chunk(c, @chunk)
      c
    end)
  end

  def call(%Plug.Conn{request_path: "/file"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
    |> Plug.Conn.send_file(200, file_path())
  end

  def call(%Plug.Conn{request_path: "/slow"} = conn, _opts) do
    Process.sleep(1000)
    hello(conn)
  end

  def call(%Plug.Conn{request_path: "/ws"} = conn, _opts) do
    Plug.Conn.upgrade_adapter(conn, :websocket, {BanditNode.WsEcho, [], []})
  end

  def call(conn, _opts), do: hello(conn)

  defp hello(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain", nil)
    |> Plug.Conn.send_resp(200, "hello world")
  end

  # The file bench_node writes at boot (as HttpNode filePath), relative
  # to the repository root, the peers' working directory.
  defp file_path, do: "_build/bench/buccaneer_bench_1mib"
end
