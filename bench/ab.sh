#!/usr/bin/env bash
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# The PR speed gate (BT-4843; bench/README.md): build this checkout and a
# base ref (default origin/main) side by side, measure both on this
# machine, interleaved, and fail when this checkout is more than
# BENCH_AB_THRESHOLD percent (default 25) slower. Writes a table to
# $GITHUB_STEP_SUMMARY when set.
#
#   bench/ab.sh [BASE_REF [HEAD_REF]]       (just bench-ab)
#
# HEAD_REF defaults to this checkout. Give one to compare two commits
# (the validation run of BT-4843: base da40286, head 657a4b8).
#
# BENCH_AB_ITERATIONS   alternating measure runs per side (default 3)
# BENCH_AB_ROUNDS       rounds per run (default 2)
# BENCH_AB_DURATION     ms measured per h2_get_10x10 round (default 2000)
#
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
base_ref="${1:-origin/main}"
head_ref="${2:-}"
iters="${BENCH_AB_ITERATIONS:-3}"
rounds="${BENCH_AB_ROUNDS:-2}"
duration="${BENCH_AB_DURATION:-2000}"
threshold="${BENCH_AB_THRESHOLD:-25}"

work="$root/_build/ab"
base="$work/base"
rm -rf "$work"
mkdir -p "$work"
git -C "$root" worktree prune
# A side is a worktree with this checkout's bench/ and test/stress/ copied
# over it, so the same harness measures both and only src/ differs.
stage() { # dir ref
  git -C "$root" worktree add -f --detach "$1" "$2" >/dev/null
  rm -rf "$1/bench" "$1/test/stress"
  cp -r "$root/bench" "$1/bench"
  cp -r "$root/test/stress" "$1/test/stress"
  rm -rf "$1/bench/http_node/_build"
}
stage "$base" "$base_ref"
pr="$root"
if [ -n "$head_ref" ]; then pr="$work/pr"; stage "$pr" "$head_ref"; fi

# The bench scripts build Bandit only when Elixir is present; the gate
# does not use it.
export BENCH_SKIP_BANDIT=1

echo "== main $(git -C "$base" rev-parse --short HEAD), PR $(git -C "$pr" rev-parse --short HEAD)"
measure() { # side dir
  "$2/bench/run.sh" bench_ab measure --rounds "$rounds" --duration "$duration" --out "$work/$1.jsonl"
}
# A first, discarded run per side builds everything and warms the caches.
for side in base pr; do
  d="$base"; [ "$side" = pr ] && d="$pr"
  "$d/bench/run.sh" bench_ab measure --rounds 1 --duration 500 --out "$work/warm-$side.jsonl" >/dev/null
done

for i in $(seq 1 "$iters"); do
  echo "== iteration $i of $iters"
  if [ $((i % 2)) -eq 1 ]; then order="base pr"; else order="pr base"; fi
  for side in $order; do
    d="$base"; [ "$side" = pr ] && d="$pr"
    echo " $side"
    measure "$side" "$d"
  done
done

summary=()
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && summary=(--summary "$GITHUB_STEP_SUMMARY")
status=0
BENCH_ROOT="$root" erl -noshell -pa "$pr/_build/bench/ebin" -s bench_ab main -extra \
  compare --threshold "$threshold" "${summary[@]}" --base "$work/base.jsonl" --pr "$work/pr.jsonl" || status=$?
exit $status
