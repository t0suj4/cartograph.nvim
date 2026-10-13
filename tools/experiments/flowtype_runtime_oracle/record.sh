#!/bin/bash
# the RUNTIME ORACLE, recording (CART-1672): <out dir> receives tree/ (a SNAPSHOT of lua/ and plugin/ — the join must
# read the lines the suite executed) and calls.tsv (the suite's observed site -> callee pairs). Serial, the JIT off:
# slow (tens of minutes). Then: nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/flowtype_runtime_oracle/join.lua <out>/tree <out>/calls.tsv [open|closed] [ctx=0]
set -e
out=${1:?usage: record.sh <out dir>}
repo=$(cd "$(dirname "$0")/../../.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -rf "$out/tree" && mkdir -p "$out/tree" && cp -r "$repo/lua" "$repo/plugin" "$out/tree/"
cd "$repo"
export XDG_STATE_HOME=$(mktemp -d)
trap 'rm -rf "$XDG_STATE_HOME"' EXIT
CARTOGRAPH_CALLS_OUT="$out/calls.tsv" nvim --headless -u NONE --noplugin \
    -c "set rtp+=$repo" \
    -c "luafile $repo/tools/experiments/flowtype_runtime_oracle/hook.lua" \
    -c "luafile tests/run.lua" > "$out/suite.log" 2>&1 || true
tail -1 "$out/suite.log"
echo "$(wc -l < "$out/calls.tsv") observed pairs in $out/calls.tsv"
