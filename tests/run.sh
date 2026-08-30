#!/usr/bin/env bash
# Run the cartograph test suite headlessly. Exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

# ── STATE ISOLATION (CART-0644) ─────────────────────────────────────────────
# The suite exercises write verbs against `vim.fn.tempname()` roots, and three
# modules persist per-root records under `stdpath('state')`: the txn JOURNAL
# (journal.lua), the working-set (store.lua) and cockpit FEEDBACK. Those are
# deliberately a USER RECORD rather than a derived cache — an apply's
# before-content is the only thing between a bad edit and a lost file, so a
# clearable cache is the wrong home for it.
#
# ⚠ THAT RULE IS RIGHT FOR A PROJECT ROOT AND WRONG FOR A FIXTURE. Measured
# before this landed: 27798 journal directories in the user's real state dir,
# 27794 of them under /tmp for roots that stopped existing long ago — ~1949
# suite runs' worth — plus 1242 stray working-set files. 237 MB.
#
# So the SUITE gets its own state home, thrown away with the run. Nothing else
# is redirected: `stdpath('cache')` still points at the real corpus cache and
# the gate snapshots, which the suite does not write and other tools rely on.
XDG_STATE_HOME="$(mktemp -d -t cartograph-test-state-XXXXXX)"
export XDG_STATE_HOME
# no `exec` — the trap has to survive to clean up, and the suite's exit code
# has to survive the trap
trap 'rm -rf "$XDG_STATE_HOME"' EXIT

nvim --headless -u NONE --noplugin \
    -c "set rtp+=$PWD" \
    -c "luafile tests/run.lua"
