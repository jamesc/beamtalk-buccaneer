# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# The spike classes bench/buccaneer_node needs, sourced by bench/spike.sh
# and bench/run.sh (one list, so the two cannot drift). They are tracked in
# spikes/engine_spikes/src and copied into bench/buccaneer_node/src, where
# bench/buccaneer_node/.gitignore ignores them: `beamtalk build` skips
# symlinked sources, so they are copied rather than linked.
#
# Usage: . bench/spike_files.sh; stage_spike_sources "$root"

stage_spike_sources() { # root
  local f
  for f in spike_parser spike_request spike_exchange spike_exchange_state spike_not_owner spike_probe spike_handler; do
    cp "$1/spikes/engine_spikes/src/$f.bt" "$1/bench/buccaneer_node/src/$f.bt"
  done
}
