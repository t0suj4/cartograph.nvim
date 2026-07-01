#!/usr/bin/env bash
# Run the cartograph test suite headlessly. Exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."
exec nvim --headless -u NONE --noplugin \
    -c "set rtp+=$PWD" \
    -c "luafile tests/run.lua"
