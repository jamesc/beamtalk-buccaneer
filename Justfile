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

# Spike 1: HTTP/1 GET against beamtalk-http on cowboy and Bandit, interleaved (bench/README.md)
spike-bench *ARGS:
    bench/run.sh {{ARGS}}

# Check formatting
fmt:
    beamtalk fmt-check

# Format in place
fmt-fix:
    beamtalk fmt

# Lint source files
lint:
    beamtalk lint

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
