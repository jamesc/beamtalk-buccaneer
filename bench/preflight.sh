#!/usr/bin/env bash
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# OS-limit pre-flight for `just bench` (BT-4856; bench/README.md, "OS
# limits"). Sourced by bench/run.sh; bench/tests/preflight_test.sh tests it.
#
# A full run opens up to 10,000 sockets at once (idle_10k) and tens of
# thousands of short connections a second (churn_close_w32,
# tls_handshake_w32). With macOS's defaults that stops at `emfile`, then
# starves the client ports (`eaddrnotavail`), and every later server in the
# row fails for reasons that have nothing to do with it. This reports the
# limits the selected rows need and the commands to fix them. It never
# changes a system setting.
#
# Only the rows that need a limit ask for it: the smoke rows (`just
# bench-smoke`, CI) and every other entry module need none, so for them
# nothing here runs a command.
#
# Everything the checks read can be injected, so the logic is testable on
# any OS (bash 3.2 compatible; macOS ships it):
#   PREFLIGHT_OS            the `uname -s` answer (Darwin, Linux)
#   PREFLIGHT_SYSCTL        the sysctl command (default `sysctl`); called
#                           as `$PREFLIGHT_SYSCTL -n NAME`
#   PREFLIGHT_NOFILE        the soft `ulimit -n`  (default: ask the shell)
#   PREFLIGHT_NOFILE_HARD   the hard `ulimit -Hn` (default: ask the shell)

PF_NOFILE_NEEDED=20000     # idle_10k: 10,000 client + 10,000 server sockets
PF_PORTS_NEEDED=28000      # ephemeral ports; the validated settings give 32,768
PF_MSL_MAX_MS=1000         # net.inet.tcp.msl; macOS defaults to 15,000

# Rows that need a limit, as `row:need,need`. bench/tests/preflight_test.sh
# checks every row id is still in bench/harness/bench_main.erl.
PF_ROW_NEEDS="idle_10k:nofile,ports churn_close_w32:ports tls_handshake_w32:ports"

# pf_needs ARGS...: the needs ("nofile", "ports") of the rows selected by
# bench_main's --rows and --only arguments, one per line, sorted.
pf_needs() {
  local rows=full only="" a prev=""
  for a in "$@"; do
    case "$prev" in
      --rows) rows="$a" ;;
      --only) only="$a" ;;
    esac
    prev="$a"
  done
  [ "$rows" = full ] || return 0
  local entry id needs
  for entry in $PF_ROW_NEEDS; do
    id="${entry%%:*}"
    needs="${entry#*:}"
    if [ -n "$only" ]; then
      case ",$only," in *",$id,"*) ;; *) continue ;; esac
    fi
    echo "$needs" | tr ',' '\n'
  done | sort -u
}

pf_sysctl() { "${PREFLIGHT_SYSCTL:-sysctl}" -n "$1" 2>/dev/null; }

# pf_check_nofile SOFT HARD: problems and fixes on stdout; status 1 on a
# problem. "unlimited" passes.
pf_check_nofile() {
  local soft="$1" hard="$2"
  case "$soft" in unlimited) return 0 ;; esac
  [ "$soft" -ge "$PF_NOFILE_NEEDED" ] 2>/dev/null && return 0
  echo "  - ulimit -n is ${soft}; idle_10k needs at least ${PF_NOFILE_NEEDED} open files (it stops at about ${soft} connections with emfile)."
  case "$hard" in
    unlimited) echo "      fix: ulimit -n ${PF_NOFILE_NEEDED}" ;;
    *)
      if [ "$hard" -ge "$PF_NOFILE_NEEDED" ] 2>/dev/null; then
        echo "      fix: ulimit -n ${PF_NOFILE_NEEDED}"
      else
        echo "      fix: the hard limit is ${hard}, so raise that first (macOS: sudo launchctl limit maxfiles ${PF_NOFILE_NEEDED} 200000, then a new shell; Linux: nofile in /etc/security/limits.conf), then ulimit -n ${PF_NOFILE_NEEDED}"
      fi ;;
  esac
  return 1
}

# pf_check_ports_macos FIRST LAST MSL: ephemeral range and TIME_WAIT time.
pf_check_ports_macos() {
  local first="$1" last="$2" msl="$3" bad=0 size
  if [ -z "$first" ] || [ -z "$last" ]; then
    echo "  - could not read net.inet.ip.portrange.first/last with sysctl; cannot check the ephemeral port range."
    bad=1
  else
    size=$((last - first + 1))
    if [ "$size" -lt "$PF_PORTS_NEEDED" ]; then
      echo "  - net.inet.ip.portrange.first/last is ${first}-${last} (${size} client ports); the churn and idle rows need at least ${PF_PORTS_NEEDED}, or the first server's connections use them all and every later server in the row fails with eaddrnotavail."
      echo "      fix: sudo sysctl -w net.inet.ip.portrange.first=32768 net.inet.ip.portrange.last=65535"
      bad=1
    fi
  fi
  if [ -z "$msl" ]; then
    echo "  - could not read net.inet.tcp.msl with sysctl; cannot check how long closed ports stay held."
    bad=1
  elif [ "$msl" -gt "$PF_MSL_MAX_MS" ]; then
    echo "  - net.inet.tcp.msl is ${msl} ms, so a closed connection holds its port for $((msl * 2 / 1000)) s; the rows need ${PF_MSL_MAX_MS} ms or less."
    echo "      fix: sudo sysctl -w net.inet.tcp.msl=${PF_MSL_MAX_MS}"
    bad=1
  fi
  return $bad
}

# pf_check_ports_linux "LOW HIGH"
pf_check_ports_linux() {
  local low high size
  # shellcheck disable=SC2086
  set -- $1
  low="${1:-}"; high="${2:-}"
  if [ -z "$low" ] || [ -z "$high" ]; then
    echo "  - could not read net.ipv4.ip_local_port_range; cannot check the ephemeral port range."
    return 1
  fi
  size=$((high - low + 1))
  if [ "$size" -lt "$PF_PORTS_NEEDED" ]; then
    echo "  - net.ipv4.ip_local_port_range is ${low} ${high} (${size} client ports); the churn and idle rows need at least ${PF_PORTS_NEEDED}."
    echo "      fix: sudo sysctl -w net.ipv4.ip_local_port_range=\"32768 60999\""
    return 1
  fi
}

# pf_run NEEDS...: check the limits the needs name, reading them from this
# machine (or the PREFLIGHT_* injections). Problems on stdout, status 1.
pf_run() {
  local os="${PREFLIGHT_OS:-$(uname -s)}" bad=0 need soft hard
  for need in "$@"; do
    case "$need" in
      nofile)
        soft="${PREFLIGHT_NOFILE:-$(ulimit -n)}"
        hard="${PREFLIGHT_NOFILE_HARD:-$(ulimit -Hn)}"
        pf_check_nofile "$soft" "$hard" || bad=1 ;;
      ports)
        case "$os" in
          Darwin)
            pf_check_ports_macos "$(pf_sysctl net.inet.ip.portrange.first)" \
              "$(pf_sysctl net.inet.ip.portrange.last)" \
              "$(pf_sysctl net.inet.tcp.msl)" || bad=1 ;;
          Linux)
            pf_check_ports_linux "$(pf_sysctl net.ipv4.ip_local_port_range)" || bad=1 ;;
        esac ;;
    esac
  done
  return $bad
}

# pf_preflight FORCE ARGS...: the entry point for run.sh (ARGS are the
# entry module's arguments). Status 0 to go on, 2 to stop.
pf_preflight() {
  local force="$1" needs problems
  shift
  needs="$(pf_needs "$@" | tr '\n' ' ')"
  [ -n "${needs// /}" ] || return 0
  # shellcheck disable=SC2086
  if problems="$(pf_run $needs)"; then
    echo "bench: OS limits ok for these rows (${needs% })" >&2
    return 0
  fi
  {
    if [ "$force" = 1 ]; then
      echo "bench: WARNING: OS limits too low for these rows (continuing: --force):"
    else
      echo "bench: OS limits too low for these rows; stopping before the run:"
    fi
    echo "$problems"
    echo "bench: this script changes no system setting. Run the fix commands above"
    echo "bench: yourself (they last until reboot or the shell exits), then run again."
    if [ "$force" = 1 ]; then
      echo "bench: rows these limits hit will report an environment error naming the limit."
    else
      echo "bench: Or pass --force to run anyway; rows these limits hit then report"
      echo "bench: an environment error naming the limit (see bench/README.md)."
    fi
  } >&2
  [ "$force" = 1 ] && return 0
  return 2
}
