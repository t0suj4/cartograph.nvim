#!/usr/bin/env bash
# Parallel workers: an isolated checkout + baseline set + nvim profile, so two
# sessions can work on cartograph at once without contaminating each other.
#
# WHAT IS ACTUALLY SHARED, and what each part of this script does about it:
#
#   the repo tree      A background job that READS the tree is not isolated from
#                      a session that EDITS it. The `self` corpus IS this repo,
#                      so a self gate running while someone edits produces a
#                      diff of the edit, not of the change under test. Fixed by
#                      a git worktree: each worker gets its own checkout.
#
#   the baselines      ~/.cache/cartograph-tools holds one snapshot per corpus
#                      (663 MB / 37 corpora). Two workers running --save race.
#                      Fixed by CARTOGRAPH_TOOLS_CACHE + `cp -al`: the shared
#                      set is HARDLINKED in, so a worker reads the same bytes
#                      for free, and snapshot.lua's tmp+rename write breaks the
#                      link on first --save instead of overwriting the shared
#                      file. Divergence is then visible as a link count of 1.
#
#   the nvim profile   ~/.local/state/nvim/cartograph (192 MB journals/feedback)
#                      and ~/.cache/nvim/cartograph (429 MB extraction cache).
#                      Fixed by NVIM_APPNAME, which moves both. Only matters for
#                      the INTERACTIVE side: the headless harness runs -u NONE
#                      and resolves the repo from tools/bench.lua's own source
#                      path, so `nvim -l tools/gate.lua` inside a worktree is
#                      already worktree-native and needs no config at all.
#
#   RAM                NOT fixed by any of the above, and this is the real
#                      ceiling. An extract peak is 2.5-4.5 GB on a large corpus
#                      against ~11 GB available: two big gates at once, three at
#                      a stretch. Isolation changes what is SAFE to run in
#                      parallel, not what FITS. `worktree.sh gate` refuses a
#                      big-corpus run under the headroom rather than letting the
#                      OOM killer decide which of the two jobs dies.
#
# BOOTSTRAP. A worktree is checked out from a COMMITTED ref, so the override in
# snapshot.lua/ratchet.lua must be committed before any worker can honour it.
# Until then `new` refuses rather than producing a worker that writes the shared
# baselines while reporting isolation — which is how this script's own first test
# rewrote the shared synlua snapshot.
#
# NOT AUTOMATED, ON PURPOSE:
#   * Promotion. A worker's GATE: PASS is against ITS baselines. Promoting means
#     re-running from the main checkout against the shared dir, serialized. That
#     is the one genuinely serial step and it stays a deliberate act.
#   * `tools/gen.lua`. The synthetic corpora under ~/.cache/cartograph-tools/syn
#     are shared read-only by design (sha-pinned, deterministic). A worker that
#     regenerates them changes them for every other worker. Do not run gen in a
#     worker; run it from the main checkout.
#   * Committing. Each worker sits on its own `wt/<name>` branch because git
#     refuses to check out `main` twice. Merging back happens in the main
#     checkout, so commit and push stay where they always were.
#
# Usage:
#   tools/worktree.sh new <name> [ref]     create a worker (ref defaults to HEAD)
#   tools/worktree.sh ls                   workers, their rev, disk, divergence
#   tools/worktree.sh env <name>           print the line to eval in a shell
#   tools/worktree.sh gate <name> <corpus> [args...]   gate, with RAM admission
#   tools/worktree.sh rm <name>            remove (refuses on uncommitted work)

set -euo pipefail

WT_HOME="${CARTOGRAPH_WT_HOME:-$HOME/git/cartograph-wt}"
CACHE_HOME="${CARTOGRAPH_WT_CACHE_HOME:-$HOME/.cache/cartograph-wt}"
SHARED_CACHE="$HOME/.cache/cartograph-tools"
PARSERS="$HOME/.local/share/nvim/lazy/nvim-treesitter"
MAIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Corpora whose extract peak is measured in GB. Below the headroom these are
# refused rather than queued: a queue would hide the ceiling, and the ceiling is
# the thing the user needs to see.
BIG='server v8 openfirmware ghost odin libs gforth sylius zig wow desynced se factorio cpp cppmodern go'
HEADROOM_MB="${CARTOGRAPH_GATE_HEADROOM_MB:-5000}"

# Does THIS worktree's snapshot.lua honour the override? Asked behaviourally, not
# by grep: dofile the worktree's own copy with the env set and see where it says
# baselines live. A worktree is created from a COMMITTED ref, so a checkout that
# predates the override support writes the SHARED baseline while every message
# this script prints claims isolation. That failure is silent and it corrupts the
# one thing the whole protocol serializes, so it is checked, not assumed.
honours_override() {   # $1 = tree, $2 = intended cache dir
    local got
    got="$(CARTOGRAPH_TOOLS_CACHE="$2" nvim --headless -u NONE \
        -c "lua io.write(dofile('$1/tools/snapshot.lua').dir)" -c q 2>/dev/null)" || return 1
    [ "$got" = "$2" ]
}

die() { printf 'worktree: %s\n' "$*" >&2; exit 1; }
have() { [ -d "$WT_HOME/$1" ]; }

wt_new() {
    local name="${1:-}" ref="${2:-HEAD}"
    [ -n "$name" ] || die "usage: worktree.sh new <name> [ref]"
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "name must be lowercase alnum/dash: $name"
    have "$name" && die "worker '$name' already exists at $WT_HOME/$name"

    local tree="$WT_HOME/$name" cache="$CACHE_HOME/$name" cfg="$HOME/.config/cartograph-$name"

    # git refuses to check out a branch that is already checked out elsewhere,
    # and main lives in the primary checkout — so each worker gets its own.
    git -C "$MAIN" worktree add -b "wt/$name" "$tree" "$ref" >/dev/null
    printf 'worktree  %s  (branch wt/%s from %s)\n' "$tree" "$name" "$ref"

    if ! honours_override "$tree" "$cache"; then
        git -C "$MAIN" worktree remove --force "$tree" 2>/dev/null || true
        git -C "$MAIN" branch -D "wt/$name" >/dev/null 2>&1 || true
        die "ref '$ref' predates CARTOGRAPH_TOOLS_CACHE support in tools/snapshot.lua.
       A worker built from it would write the SHARED baselines while this script
       reported isolation. Commit that change (snapshot.lua + ratchet.lua) and
       create the worker from a ref that contains it. Nothing was left behind."
    fi

    # Hardlink, do not copy: 663 MB of baselines become ~0 bytes and stay
    # byte-identical until this worker saves over one.
    mkdir -p "$cache"
    if [ -d "$SHARED_CACHE" ]; then
        local n=0
        for f in "$SHARED_CACHE"/*.snapshot.mpack; do
            [ -e "$f" ] || continue
            cp -al "$f" "$cache/" && n=$((n + 1))
        done
        printf 'baselines %s  (%d hardlinked, 0 bytes until this worker saves)\n' "$cache" "$n"
    else
        printf 'baselines %s  (shared dir absent — nothing to link)\n' "$cache"
    fi

    # An nvim profile for the INTERACTIVE side only. NVIM_APPNAME moves the
    # state and cache dirs, which also moves the plugin out of reach of the
    # user's lazy.nvim setup — hence the explicit rtp lines. The parser
    # directory is prepended by absolute path for the same reason the headless
    # harness does it (tools/bench.lua:26): parsers live under the MAIN
    # profile's data dir and NVIM_APPNAME does not follow them there.
    mkdir -p "$cfg"
    cat > "$cfg/init.lua" <<LUA
-- Generated by tools/worktree.sh for worker '$name'. Regenerate by removing
-- and re-creating the worker; hand edits are not preserved.
--
-- Deliberately minimal: this profile exists to exercise cartograph in
-- isolation, not to reproduce the user's editing setup. No lazy.nvim, no other
-- plugins, so a failure here is cartograph's.
vim.opt.runtimepath:prepend('$PARSERS')   -- parsers live in the MAIN profile
vim.opt.runtimepath:prepend('$tree')      -- this worker's checkout
require('cartograph').setup({})
LUA

    cat > "$cfg/env.sh" <<ENV
# eval "\$(tools/worktree.sh env $name)" — or source this file directly.
export CARTOGRAPH_WT='$name'
export CARTOGRAPH_WT_ROOT='$tree'
export CARTOGRAPH_TOOLS_CACHE='$cache'   # snapshot.lua + ratchet.lua read this
export NVIM_APPNAME='cartograph-$name'   # moves nvim state/ and cache/
# TK_ROOT and KB_ROOT are deliberately NOT overridden: tickets and knowledge are
# shared across workers by design, and both tools take per-item locks.
ENV
    printf 'profile   %s  (NVIM_APPNAME=cartograph-%s)\n' "$cfg" "$name"

    # Smoke test on the smallest synthetic corpus. NOT :checkhealth — its parser
    # list is 15 of the 17 languages the engine registers, so it can report a
    # clean bill for a profile that extracts nothing (see kb note
    # health-parser-list-short-of-registered).
    printf 'smoke     '
    if CARTOGRAPH_TOOLS_CACHE="$cache" nvim --headless -u NONE \
        -l "$tree/tools/gate.lua" synlua 2>&1 | grep -q 'GATE: PASS'; then
        printf 'gate synlua PASS\n'
    else
        printf 'gate synlua FAILED — the worker exists but does not extract\n'
        return 1
    fi

    printf '\nenter it with:  eval "$(%s/tools/worktree.sh env %s)"\n' "$MAIN" "$name"
}

wt_ls() {
    [ -d "$WT_HOME" ] || { echo 'no workers'; return 0; }
    printf '%-12s %-10s %-9s %s\n' NAME REV BASELINES TREE
    local name tree cache rev diverged total f
    for tree in "$WT_HOME"/*/; do
        [ -d "$tree" ] || continue
        name="$(basename "$tree")"
        cache="$CACHE_HOME/$name"
        rev="$(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo '?')"
        # A link count of 1 means this worker wrote its own copy: the shared
        # baseline no longer backs it, so its PASS is private.
        diverged=0; total=0
        if [ -d "$cache" ]; then
            for f in "$cache"/*.snapshot.mpack; do
                [ -e "$f" ] || continue
                total=$((total + 1))
                [ "$(stat -c %h "$f")" = 1 ] && diverged=$((diverged + 1))
            done
        fi
        printf '%-12s %-10s %-9s %s\n' "$name" "$rev" "$diverged/$total" "${tree%/}"
    done
    [ -n "${diverged:-}" ] && printf '\nBASELINES is unshared/total, counted by hardlink: an unshared snapshot is no\nlonger the same inode as the shared one — usually because this worker --saved\nit, but a save in ANY other checkout has the same effect. Either way a PASS\nagainst it is private and does not transfer.\n'
}

wt_env() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: worktree.sh env <name>"
    have "$name" || die "no worker '$name'"
    printf 'source %s/.config/cartograph-%s/env.sh\n' "$HOME" "$name"
}

wt_gate() {
    local name="${1:-}" corpus="${2:-}"
    [ -n "$name" ] && [ -n "$corpus" ] || die "usage: worktree.sh gate <name> <corpus> [args...]"
    have "$name" || die "no worker '$name'"
    shift 2
    honours_override "$WT_HOME/$name" "$CACHE_HOME/$name" \
        || die "worker '$name' does not honour CARTOGRAPH_TOOLS_CACHE — its gate
       would write the shared baselines. Re-create it from a newer ref."

    # Admission, not queueing. A queue would make the ceiling invisible; the
    # point of the refusal is that the operator sees it.
    if [[ " $BIG " == *" $corpus "* ]]; then
        local avail; avail="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
        if [ "$avail" -lt "$HEADROOM_MB" ]; then
            die "$corpus needs ~2.5-4.5 GB and only ${avail} MB is available
       (headroom ${HEADROOM_MB} MB). Wait for the other gate to finish, pick a
       small corpus, or raise CARTOGRAPH_GATE_HEADROOM_MB if you mean it."
        fi
        printf '# admission: %s MB available, %s is a big corpus\n' "$avail" "$corpus" >&2
    fi

    CARTOGRAPH_TOOLS_CACHE="$CACHE_HOME/$name" \
        nvim --headless -u NONE -l "$WT_HOME/$name/tools/gate.lua" "$corpus" "$@"
}

wt_rm() {
    local name="${1:-}"
    [ -n "$name" ] || die "usage: worktree.sh rm <name>"
    have "$name" || die "no worker '$name'"
    # No --force: git refuses on uncommitted changes, and that refusal is the
    # feature. A worker with unmerged work should not vanish because a cleanup
    # loop ran.
    git -C "$MAIN" worktree remove "$WT_HOME/$name"
    rm -rf "$CACHE_HOME/$name" "$HOME/.config/cartograph-$name"
    printf 'removed worker %s (branch wt/%s kept — delete it yourself if done)\n' "$name" "$name"
}

case "${1:-}" in
    new)  shift; wt_new "$@" ;;
    ls)   shift; wt_ls "$@" ;;
    env)  shift; wt_env "$@" ;;
    gate) shift; wt_gate "$@" ;;
    rm)   shift; wt_rm "$@" ;;
    *)    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
