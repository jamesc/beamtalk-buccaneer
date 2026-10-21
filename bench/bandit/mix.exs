# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0

# Spike 1's context baseline: Bandit 1.12.5 with a bare Plug equivalent to
# the spike's and beamtalk-http's handlers. The harness loads its compiled
# beams into a peer node.
defmodule BanditNode.MixProject do
  use Mix.Project

  def project do
    [
      app: :bandit_node,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:bandit, "== 1.12.5"}]
    ]
  end

  def application, do: [extra_applications: [:logger, :ssl]]
end
