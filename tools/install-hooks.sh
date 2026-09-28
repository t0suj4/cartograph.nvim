#!/usr/bin/env bash
# Activate the checked-in git hooks (.githooks/) for this clone by pointing
# core.hooksPath at them, and make the PROVENANCE LEDGER travel (CART-1180):
# the post-commit hook writes one git note per commit on refs/notes/cartograph,
# and notes only reach the remote when they are pushed. Run once after cloning:
#
#   bash tools/install-hooks.sh
#
# Undo with:  git config --unset core.hooksPath
#             git config --unset-all remote.origin.push
#             git config --unset remote.origin.fetch refs/notes/cartograph
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true
echo "hooks active: core.hooksPath -> .githooks"
echo "  pre-commit:  docaudit + navaudit + langaudit + dogfood seam fence + spec suite"
echo "               (bypass: git commit --no-verify)"
echo "  post-commit: the provenance ledger note (tools/provledger.lua write HEAD)"

# ── the ledger travels with a plain `git push` / `git fetch` ─────────────────
# PUSH: once remote.origin.push is set, `git push` pushes ONLY the listed
# refspecs — so HEAD (the current branch to its same-named remote branch, what
# the default does) is listed beside the notes.
# FETCH: NON-FORCED on purpose. A forced refspec (+) would OVERWRITE local notes
# written for commits the remote has no note for yet; a diverged notes ref must
# fail the fetch loudly (then: git fetch origin refs/notes/cartograph:refs/notes/origin-cartograph
# && git notes --ref=cartograph merge refs/notes/origin-cartograph).
add_once () { # key value
    git config --get-all "$1" 2>/dev/null | grep -qxF "$2" || git config --add "$1" "$2"
}
if git remote get-url origin >/dev/null 2>&1; then
    add_once remote.origin.push HEAD
    add_once remote.origin.push refs/notes/cartograph
    add_once remote.origin.fetch refs/notes/cartograph:refs/notes/cartograph
    echo "ledger: git push / git fetch carry refs/notes/cartograph (origin)"
fi
