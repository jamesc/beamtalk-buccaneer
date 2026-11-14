#!/usr/bin/env bash
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# The release gate's harness (bench/README.md): build the servers and the
# Erlang harness, then run one entry module:
#   bench/run.sh bench_main [ARGS...]    (just bench)
#   bench/run.sh stress_main [ARGS...]   (just stress)
#
#   bench/http_node   beamtalk-http (tracking origin/main below) on this
#                     checkout's Buccaneer, plus Buccaneer standalone
#   bench/bandit      Bandit 1.12.5 (a mix project; context)
#
# The gate baseline is bare cowboy (a plain Erlang handler, no
# beamtalk-http): cowboy and ranch come from http_node's pinned native
# dependencies (BT-4509).
#
# beamtalk-http pins Buccaneer by git rev, and a path dependency does not
# override a transitive one, so the harness clones beamtalk-http into
# _build/bench/beamtalk-http and points its buccaneer dependency at this
# checkout.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
main="$1"
shift

# beamtalk-http tracks origin/main so the gate always measures current
# beamtalk-http (override with BENCH_HTTP_REV_PIN to pin a revision).
HTTP_REV="${BENCH_HTTP_REV_PIN:-origin/main}"
http="$root/_build/bench/beamtalk-http"
if [ ! -d "$http/.git" ]; then
  mkdir -p "$root/_build/bench"
  git clone -q https://github.com/jamesc/beamtalk-http "$http"
fi
git -C "$http" fetch -q origin
want="$(git -C "$http" rev-parse "$HTTP_REV^{commit}")"
if [ "$(git -C "$http" rev-parse HEAD)" != "$want" ]; then
  git -C "$http" checkout -q -- beamtalk.toml beamtalk.lock 2>/dev/null || true
  git -C "$http" checkout -q "$want"
fi
sed -i.orig "s|^buccaneer = .*|buccaneer = { path = \"$root\" }|" "$http/beamtalk.toml"

(cd "$root/bench/http_node" && beamtalk build >/dev/null)

# `just lint-bench`: lint the staged bench apps (their path deps exist only
# now); fail on a lint failure or a discarded update.
if [ "$main" = lint_bench ]; then
  status=0
  for app in "$root"/bench/*_node; do
    rc=0
    out="$(cd "$app" && beamtalk lint 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "$out"; echo "beamtalk lint failed (exit $rc) in $app" >&2; status=1
    fi
    if grep -qiE 'discarded_?update' <<<"$out"; then
      echo "$out"; echo "discarded update in $app" >&2; status=1
    fi
  done
  exit $status
fi
# BENCH_SKIP_BANDIT=1 (the PR speed gate, bench/ab.sh) needs no Elixir.
if [ -z "${BENCH_SKIP_BANDIT:-}" ]; then
  (cd "$root/bench/bandit" \
    && MIX_ENV=prod mix local.hex --force --if-missing >/dev/null \
    && MIX_ENV=prod mix deps.get >/dev/null \
    && MIX_ENV=prod mix compile >/dev/null)
fi
mkdir -p "$root/_build/bench/ebin"
erlc -o "$root/_build/bench/ebin" "$root"/bench/harness/*.erl "$root"/test/stress/*.erl

export BENCH_ROOT="$root"
# The Beamtalk runtime and stdlib ebin directories, ':'-separated: an
# installed SDK (lib/beamtalk/lib/*/ebin), or a source build's runtime
# (BEAMTALK_RUNTIME_DIR, else <sysroot>/../runtime): rebar3's output plus
# the stdlib class beams under apps/.
sysroot="$(beamtalk --print-sysroot)"
if [ -d "$sysroot/lib/beamtalk/lib" ]; then
  ebins=("$sysroot"/lib/beamtalk/lib/*/ebin)
else
  rt="${BEAMTALK_RUNTIME_DIR:-$sysroot/../runtime}"
  ebins=("$rt"/_build/default/lib/*/ebin "$rt/apps/beamtalk_stdlib/ebin")
fi
export BENCH_BEAMTALK_EBINS="$(IFS=:; echo "${ebins[*]}")"
if [ -z "${BENCH_SKIP_BANDIT:-}" ]; then
  export BENCH_ELIXIR_LIB="$(cd "$root/bench/bandit" && elixir -e 'IO.write(Path.dirname(:code.lib_dir(:elixir)))')"
  export BENCH_ELIXIR_VERSION="$(cd "$root/bench/bandit" && elixir -e 'IO.write(System.version())')"
fi
export BENCH_BANDIT_VERSION="$(sed -n 's/.*"bandit": {:hex, :bandit, "\([^"]*\)".*/\1/p' "$root/bench/bandit/mix.lock")"
export BENCH_COWBOY_VERSION="$(grep -A1 '^name = "cowboy"$' "$root/bench/http_node/beamtalk.lock" | sed -n 's/^version = "\(.*\)"/\1/p')"
export BENCH_BEAMTALK_VERSION="$(beamtalk --version | awk '{print $2}') ($(git -C "$sysroot/.." rev-parse --short HEAD 2>/dev/null || echo installed))"
export BENCH_BUCCANEER_REV="$(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet HEAD -- src || echo '+dirty')"
export BENCH_HTTP_REV="$(git -C "$http" rev-parse --short HEAD)"

# The peers inherit the working directory; the TLS servers read
# test/fixtures/{cert,key}.pem relative to it.
cd "$root"
exec erl -noshell +P 2000000 +Q 1000000 -pa "$root/_build/bench/ebin" -s "$main" main -extra "$@"
