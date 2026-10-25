#!/usr/bin/env bash
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# Phase 0 spike 1 (`just spike-bench [ARGS...]`): build the three server
# nodes and the Erlang harness, then run hb_main (bench/harness/hb_main.erl
# lists the arguments).
#
#   bench/buccaneer_node  the spike's handler on Catalina (sources copied
#                         from spikes/engine_spikes/src: `beamtalk build` skips
#                         symlinked sources)
#   bench/cowboy_node     beamtalk-http 0.1.10 on cowboy (the gate baseline)
#   bench/bandit          Bandit 1.12.5 (a mix project; context)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

for f in spike_parser spike_request spike_exchange exchange_state not_owner spike_probe spike_handler; do
  cp "$root/spikes/engine_spikes/src/$f.bt" "$root/bench/buccaneer_node/src/$f.bt"
done
(cd "$root/bench/buccaneer_node" && beamtalk build >/dev/null)
(cd "$root/bench/cowboy_node" && beamtalk build >/dev/null)
(cd "$root/bench/bandit" \
  && MIX_ENV=prod mix local.hex --force --if-missing >/dev/null \
  && MIX_ENV=prod mix deps.get >/dev/null \
  && MIX_ENV=prod mix compile >/dev/null)
mkdir -p "$root/_build/bench/ebin"
erlc -o "$root/_build/bench/ebin" "$root"/bench/harness/*.erl

export BENCH_ROOT="$root"
export BENCH_BEAMTALK_LIB="$(beamtalk --print-sysroot)/lib/beamtalk/lib"
export BENCH_ELIXIR_LIB="$(cd "$root/bench/bandit" && elixir -e 'IO.write(Path.dirname(:code.lib_dir(:elixir)))')"
export BENCH_ELIXIR_VERSION="$(cd "$root/bench/bandit" && elixir -e 'IO.write(System.version())')"
export BENCH_BEAMTALK_VERSION="$(beamtalk --version | awk '{print $2}') ($(git -C "$(beamtalk --print-sysroot)/.." rev-parse --short HEAD 2>/dev/null || echo unknown))"
export BENCH_BUCCANEER_REV="$(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet HEAD -- spikes || echo '+dirty')"

exec erl -noshell +P 2000000 +Q 1000000 -pa "$root/_build/bench/ebin" -s hb_main main -extra "$@"
