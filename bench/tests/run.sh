#!/usr/bin/env bash
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the bench harness's OS-limit handling (BT-4856; `just
# bench-test`): the shell pre-flight and bench_env. They need Erlang/OTP
# only: no beamtalk build, no servers, no network, no system change.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"

"$root/bench/tests/preflight_test.sh"

out="$root/_build/bench-test"
mkdir -p "$out"
erlc -o "$out" "$root"/bench/harness/bench_env.erl "$root"/bench/harness/bench_load.erl \
  "$root"/bench/harness/bench_conn.erl "$root"/bench/harness/bench_http.erl \
  "$root"/bench/harness/hb_hist.erl "$root"/bench/tests/*.erl
erlc -DTEST -o "$out" "$root"/bench/harness/bench_main.erl
erl -noshell -pa "$out" -eval '
  case eunit:test([bench_env_tests, bench_main_tests], []) of
    ok -> halt(0);
    _ -> halt(1)
  end'
