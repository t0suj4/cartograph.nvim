#!/bin/sh
# The `yaml:helm` oracle (tools/oraclejoin.lua): Helm's values loader, built OFFLINE from the Go module cache (the
# modules a helm build fetched once). `go run` keeps its own content-keyed build cache — no binary to go stale.
cd "$(dirname "$0")" && exec env GOTOOLCHAIN=${GOTOOLCHAIN:-go1.26.0} GOPROXY=off GOFLAGS=-mod=mod go run .
