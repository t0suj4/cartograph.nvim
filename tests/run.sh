#!/usr/bin/env bash
# Run the cartograph test suite headlessly. Exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

# ── GIT ISOLATION (CART-1530) ───────────────────────────────────────────────
# `git commit <paths>` runs the pre-commit hook with GIT_INDEX_FILE at a TEMPORARY index of this repo; a spec that
# runs git inside its own temp repo would read cartograph's index through it (oraclejoin, replay failed only there).
# Specs find their repository from their cwd.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES


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
# … with ONE exception: the content-stamped answer store (cartograph.stampcache, CART-1303/1299). A spec's derive over
# a vim.fn.tempname() tree writes entries keyed by a tree that stops existing — the journal's 27794 dead roots again,
# in the cache this time. The suite's store lives and dies with its state home.
CARTOGRAPH_STAMPCACHE_DIR="$XDG_STATE_HOME/stamped"
export CARTOGRAPH_STAMPCACHE_DIR
# no `exec` — the trap has to survive to clean up, and the suite's exit code
# has to survive the trap
trap 'rm -rf "$XDG_STATE_HOME"' EXIT

# JOBS=N: the spec files split across N worker processes (tests/prun.lua — each worker its own throwaway state home, balanced by the measured time of the last parallel run, the summary line unchanged)
# The DEFAULT is parallel (JOBS unset = derived: min(cores, total / slowest spec)); JOBS=1 is the serial runner, and so
# is a SPEC= run that names no JOBS (one or two specs gain nothing from workers)
if [ "${JOBS:-}" != 1 ] && { [ -z "${SPEC:-}" ] || [ -n "${JOBS:-}" ]; }; then
    nvim --headless -u NONE --noplugin -l tests/prun.lua
else
    nvim --headless -u NONE --noplugin \
        -c "set rtp+=$PWD" \
        -c "luafile tests/run.lua"
fi
