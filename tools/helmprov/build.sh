#!/bin/sh
# Build helmprov OFFLINE (CART-0870) against a local helm checkout: the go.mod here names helm without a path, so a
# generated modfile beside the output adds `replace helm.sh/helm/v4 => $HELM_SRC`; GOPROXY=off — every module and the
# toolchain must already be in the module cache (a helm built there once is enough).
#   HELM_SRC   the helm checkout (default ~/git/helm)
#   OUT        the binary (default ~/.cache/nvim/cartograph/helmprov/helmprov)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
HELM_SRC=${HELM_SRC:-$HOME/git/helm}
OUT=${OUT:-$HOME/.cache/nvim/cartograph/helmprov/helmprov}
WORK=$(dirname "$OUT")
mkdir -p "$WORK"
{ cat "$HERE/go.mod"; printf '\nreplace helm.sh/helm/v4 => %s\n' "$HELM_SRC"; } > "$WORK/go.mod"
cd "$HERE"
GOTOOLCHAIN=${GOTOOLCHAIN:-go1.26.0} GOPROXY=off GOFLAGS=-mod=mod go build -modfile "$WORK/go.mod" -o "$OUT" ./cmd/helmprov
