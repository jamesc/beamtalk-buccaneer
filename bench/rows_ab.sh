#!/usr/bin/env bash
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# Rows A/B (BT-4979): the same bench rows on a base ref and on this
# checkout, alternating which goes first, in one run on one machine, so a
# change shows against run-to-run noise rather than against an old number.
# Unlike bench/ab.sh (the h2c PR gate) it runs `bench_main` rows as they
# are, so it covers memory (`idle_*`) and the HTTP/1 and TLS rows.
#
#   bench/rows_ab.sh BASE_REF [--rounds N] [--duration MS] [--only ROWS] [--impls LIST]
#
# It needs no Elixir: it sets BENCH_SKIP_BANDIT, so the default servers are
# http_buccaneer, buccaneer and cowboy, and `--impls` naming bandit is refused.
#
# Raw JSON lines of each side go to _build/rows_ab/{base,pr}.jsonl. Both
# sides are measured by this checkout's harness (bench/ and test/stress/
# are copied over the base checkout), so only src/ differs.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
base_ref="$1"
shift
rounds=3
rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) rounds="$2"; shift 2 ;;
    *) rest+=("$1"); shift ;;
  esac
done

work="$root/_build/rows_ab"
base="$work/base"
rm -rf "$work"
mkdir -p "$work"
git -C "$root" worktree prune
git -C "$root" worktree add -f --detach "$base" "$base_ref" >/dev/null
rm -rf "$base/bench" "$base/test/stress"
cp -r "$root/bench" "$base/bench"
cp -r "$root/test/stress" "$base/test/stress"
rm -rf "$base/bench/http_node/_build"
export BENCH_SKIP_BANDIT=1

echo "== base $(git -C "$base" rev-parse --short HEAD), PR $(git -C "$root" rev-parse --short HEAD)"
measure() { # side dir
  local out="$work/out-$1"
  mkdir -p "$out"
  "$2/bench/run.sh" bench_main --rounds 1 --out "$out" ${rest[@]+"${rest[@]}"} >"$work/$1.log" 2>&1 \
    || { echo "$1 failed, see $work/$1.log" >&2; tail -20 "$work/$1.log" >&2; return 1; }
  cat "$out"/raw-*.jsonl >>"$work/$1.jsonl"
  rm -f "$out"/raw-*.jsonl
}
for i in $(seq 1 "$rounds"); do
  if [ $((i % 2)) -eq 1 ]; then order="base pr"; else order="pr base"; fi
  for side in $order; do
    d="$base"; [ "$side" = pr ] && d="$root"
    echo "round $i: $side"
    measure "$side" "$d"
  done
done
echo "raw: $work/base.jsonl $work/pr.jsonl"
