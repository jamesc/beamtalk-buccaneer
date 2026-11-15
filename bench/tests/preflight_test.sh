#!/usr/bin/env bash
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# Tests for bench/preflight.sh (BT-4856): the OS-limit checks run on any
# OS with the sysctl / ulimit answers injected, so the macOS path is
# exercised here from the values in the issue, not on macOS.
#   bench/tests/preflight_test.sh        (just bench-test)
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=bench/preflight.sh
. "$root/bench/preflight.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/    /'; }

# check NAME EXPECTED_STATUS EXPECTED_SUBSTRING... -- COMMAND ARGS...
check() {
  local name="$1" want="$2" subs=() out rc
  shift 2
  while [ "$1" != -- ]; do subs+=("$1"); shift; done
  shift
  out="$("$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$want" ]; then bad "$name: status $rc, wanted $want" "$out"; return; fi
  local s
  for s in ${subs[@]+"${subs[@]}"}; do
    case "$out" in *"$s"*) ;; *) bad "$name: output lacks '$s'" "$out"; return ;; esac
  done
  ok
}

# A fake sysctl: the values come from FAKE_SYSCTL_* variables, as the
# macOS names in the issue; an unset one answers nothing and fails, like
# an unknown name.
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
cat > "$fake/sysctl" <<'SH'
#!/usr/bin/env bash
[ "$1" = -n ] || exit 2
case "$2" in
  net.inet.ip.portrange.first) v="${FAKE_FIRST-}" ;;
  net.inet.ip.portrange.last)  v="${FAKE_LAST-}" ;;
  net.inet.tcp.msl)            v="${FAKE_MSL-}" ;;
  net.ipv4.ip_local_port_range) v="${FAKE_RANGE-}" ;;
  *) exit 1 ;;
esac
[ -n "$v" ] || exit 1
echo "$v"
SH
chmod +x "$fake/sysctl"
export PREFLIGHT_SYSCTL="$fake/sysctl"

# --- which rows need which limits ---
check "full run needs nofile and ports" 0 "nofile" "ports" -- pf_needs
needs() { pf_needs "$@" | tr '\n' ' '; }
[ "$(needs)" = "nofile ports " ] && ok || bad "default (full) needs: $(needs)"
[ "$(needs --rows full)" = "nofile ports " ] && ok || bad "--rows full: $(needs --rows full)"
[ -z "$(needs --rows smoke)" ] && ok || bad "smoke must need nothing: $(needs --rows smoke)"
[ -z "$(needs --rounds 1 --duration 1000 --warmup 300 --rows smoke)" ] && ok || bad "bench-smoke args must need nothing"
[ "$(needs --only get_c10,churn_close_w32)" = "ports " ] && ok || bad "--only churn: $(needs --only get_c10,churn_close_w32)"
[ "$(needs --only idle_10k)" = "nofile ports " ] && ok || bad "--only idle_10k"
[ -z "$(needs --only get_c10,tls_get_c100)" ] && ok || bad "--only get rows must need nothing"

# The ids in PF_ROW_NEEDS are real rows, and the smoke rows are not among them.
for entry in $PF_ROW_NEEDS; do
  id="${entry%%:*}"
  grep -q "\"$id\"" "$root/bench/harness/bench_main.erl" && ok || bad "row $id is not in bench_main.erl"
  smoke="$(sed -n '/^rows(smoke)/,/^impls_for/p' "$root/bench/harness/bench_main.erl")"
  case "$smoke" in *"\"$id\""*) bad "row $id is a smoke row" ;; *) ok ;; esac
done

# --- ulimit -n ---
check "nofile low" 1 "ulimit -n is 256" "20000" "emfile" "fix: ulimit -n 20000" -- pf_check_nofile 256 unlimited
check "nofile low, hard low too" 1 "hard limit is 10240" "launchctl" -- pf_check_nofile 256 10240
check "nofile exact" 0 -- pf_check_nofile 20000 20000
check "nofile high" 0 -- pf_check_nofile 65536 65536
check "nofile unlimited" 0 -- pf_check_nofile unlimited unlimited

# --- macOS, from the issue's values ---
check "macOS defaults fail" 1 \
  "49152-65535 (16384 client ports)" "sudo sysctl -w net.inet.ip.portrange.first=32768" \
  "net.inet.tcp.msl is 15000 ms" "sudo sysctl -w net.inet.tcp.msl=1000" \
  -- pf_check_ports_macos 49152 65535 15000
check "macOS issue's fixed values pass" 0 -- pf_check_ports_macos 32768 65535 1000
check "macOS only msl wrong" 1 "msl" -- pf_check_ports_macos 32768 65535 15000
check "macOS only range wrong" 1 "portrange" -- pf_check_ports_macos 49152 65535 1000
check "macOS unreadable sysctl" 1 "could not read net.inet.ip.portrange" "could not read net.inet.tcp.msl" -- pf_check_ports_macos "" "" ""

# --- Linux ---
check "Linux default range passes" 0 -- pf_check_ports_linux "32768 60999"
check "Linux narrow range fails" 1 "10001 client ports" "net.ipv4.ip_local_port_range" -- pf_check_ports_linux "50000 60000"
check "Linux unreadable range" 1 "could not read" -- pf_check_ports_linux ""

# --- pf_run end to end, with injected sysctl and ulimit ---
export PREFLIGHT_NOFILE_HARD=unlimited
run_mac() { PREFLIGHT_OS=Darwin PREFLIGHT_NOFILE="$1" FAKE_FIRST="$2" FAKE_LAST=65535 FAKE_MSL="$3" pf_run nofile ports; }
check "pf_run macOS defaults" 1 "ulimit -n is 256" "49152-65535" "msl is 15000" -- run_mac 256 49152 15000
check "pf_run macOS all set" 0 -- run_mac 20000 32768 1000
run_linux() { PREFLIGHT_OS=Linux PREFLIGHT_NOFILE="$1" FAKE_RANGE="$2" pf_run nofile ports; }
check "pf_run Linux defaults but low ulimit" 1 "ulimit -n is 1024" -- run_linux 1024 "32768 60999"
check "pf_run Linux ok" 0 -- run_linux 20000 "32768 60999"

# --- pf_preflight: the message, --force, and the smoke rows ---
mac_defaults() { PREFLIGHT_OS=Darwin PREFLIGHT_NOFILE=256 FAKE_FIRST=49152 FAKE_LAST=65535 FAKE_MSL=15000 pf_preflight "$@"; }
check "stops with the commands named" 2 "OS limits too low" "stopping before the run" \
  "ulimit -n 20000" "sudo sysctl -w net.inet.tcp.msl=1000" "changes no system setting" "--force" \
  -- mac_defaults 0 --rounds 5
check "--force warns and goes on" 0 "WARNING" "continuing: --force" "ulimit -n 20000" -- mac_defaults 1 --rounds 5
check "smoke rows: no check, no output" 0 -- mac_defaults 0 --rounds 1 --duration 1000 --warmup 300 --rows smoke
out="$(mac_defaults 0 --rows smoke 2>&1)"
[ -z "$out" ] && ok || bad "smoke must print nothing" "$out"
check "limits ok: one line" 0 "OS limits ok" -- bash -c '. "$0"; PREFLIGHT_OS=Darwin PREFLIGHT_NOFILE=20000 FAKE_FIRST=32768 FAKE_LAST=65535 FAKE_MSL=1000 pf_preflight 0 --rows full' "$root/bench/preflight.sh"

# Smoke must not even run sysctl: a sysctl that fails the test if called.
cat > "$fake/sysctl_tripwire" <<'SH'
#!/usr/bin/env bash
echo "sysctl was called" >&2
exit 99
SH
chmod +x "$fake/sysctl_tripwire"
smoke_no_sysctl() { PREFLIGHT_SYSCTL="$fake/sysctl_tripwire" pf_preflight 0 --rounds 1 --rows smoke; }
check "smoke never runs sysctl" 0 -- smoke_no_sysctl

echo "preflight: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
