# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0

# Standard Beamtalk project targets.
# See: https://beamtalk.dev/docs/tooling

# Build the project
build:
    beamtalk build

# Run the test suite
test:
    beamtalk test --warnings-as-errors

# Run the Phase 0 spikes (loopback sockets and timing; not part of `test`)
spikes:
    #!/usr/bin/env bash
    status=0
    # Also builds and runs the spikes/http2_streams package (spikes 5 and 6).
    beamtalk test spikes -j 1 --warnings-as-errors || status=$?
    for f in _build/spikes/*.txt; do cat "$f"; echo; done
    exit $status

# Spike 1: HTTP/1 GET against beamtalk-http on cowboy and Bandit, interleaved (bench/SPIKE.md)
spike-bench *ARGS:
    bench/spike.sh {{ARGS}}

# The release gate: beamtalk-http on Buccaneer against beamtalk-http on
# cowboy, with Buccaneer standalone and Bandit for context, interleaved
# (bench/README.md; results in bench/RESULTS.md). Not part of `test`.
bench *ARGS:
    bench/run.sh bench_main {{ARGS}}

# The PR speed gate (bench/README.md): build BASE (default origin/main)
# and this checkout, measure both on this machine, fail if this checkout
# is more than 25% slower. Optional HEAD compares two commits instead.
bench-ab base="origin/main" head="":
    bench/ab.sh {{base}} {{head}}

# Correctness under load and failure (test/stress/, bench/README.md). Not part of `test`.
stress *ARGS:
    bench/run.sh stress_main {{ARGS}}

# One short bench round on a few rows, as CI runs it (non-blocking)
bench-smoke:
    bench/run.sh bench_main --rounds 1 --duration 1000 --warmup 300 --rows smoke

# The stress tests at smoke sizes with a one-minute soak, as CI runs them (non-blocking)
stress-smoke:
    bench/run.sh stress_main --smoke

# Profile one bench row on one server (call-time tracing), plus class-process calls per GET
bench-profile *ARGS:
    bench/run.sh bench_profile {{ARGS}}

# Autobahn Testsuite fuzzingclient (needs docker): the full suite with
# the AUTOBAHN=1 gate open (scoped runs cannot see test fixtures).
# Non-blocking in CI until green; AUTOBAHN_CASES limits cases.
autobahn:
    AUTOBAHN=1 beamtalk test --warnings-as-errors

# h2spec conformance over TLS/ALPN h2 (needs docker or an h2spec
# binary): the full suite with the H2SPEC=1 gate open.
# Non-blocking in CI until green; H2SPEC_SECTION limits the section.
h2spec:
    H2SPEC=1 beamtalk test --warnings-as-errors

# Check formatting
fmt:
    beamtalk fmt-check

# Format in place
fmt-fix:
    beamtalk fmt

# Lint source files
# src and test only: bench/*_node are separate projects whose path deps
# exist only after bench/run.sh stages them.
lint:
    beamtalk lint src
    beamtalk lint test

# Lint the bench apps after staging their path deps (needs the toolchain
# bench/run.sh needs); fails on discarded updates. Not part of `lint`.
lint-bench:
    bench/run.sh lint_bench

# Remove build artifacts
clean:
    rm -rf _build

# Full CI check (fmt + lint + build + test)
ci: fmt lint build test

# Tag a release from beamtalk.toml version
release:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(grep '^version' beamtalk.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')
    git tag "v${version}"
    echo "Tagged v${version}"

# Push release tags to origin
publish:
    git push origin --tags
