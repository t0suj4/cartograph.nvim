#!/usr/bin/env bash
# Activate the checked-in git hooks (.githooks/) for this clone by pointing
# core.hooksPath at them. Run once after cloning:
#
#   bash tools/install-hooks.sh
#
# Undo with:  git config --unset core.hooksPath
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true
echo "hooks active: core.hooksPath -> .githooks"
echo "  pre-commit: docaudit + navaudit + dogfood seam fence + spec suite"
echo "              (bypass: git commit --no-verify)"
