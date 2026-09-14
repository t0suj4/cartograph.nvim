#!/bin/bash
# run sections one by one; stop at the first that is not green
cd /home/t0suj4/git/cartograph-adapt || exit 1

while IFS='|' read -r sec file; do
    [ -z "$sec" ] && continue
    echo "════ $file"
    if ! python3 "$(dirname "$0")"/split_section.py "$sec" "lua/cartograph/algebra/$file.lua" 2>&1 | tail -2; then
        echo "STOPPED: the driver refused $file"; exit 3
    fi
    res=$(./tests/run.sh 2>&1 | tail -1)
    echo "     $res"
    case "$res" in
        *", 0 failed"*) ;;
        *) echo "STOPPED: $file is not green"; exit 4 ;;
    esac
done <<'SECTIONS'
composition|composition
match|match
the algebra's negatives|negatives
demand over a family|demandfam
generalize: n-ary anti-unification|generalize
rewrite: the sixth edit|rewrite
templates and their holes|templates
paths and sites|paths
edits: moves in the order|edits
SECTIONS
echo "ALL CLEAR"
