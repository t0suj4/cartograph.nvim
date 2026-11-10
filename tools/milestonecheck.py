#!/usr/bin/env python3
"""milestonecheck — a commit that names a milestone should ask whether MILESTONES.md moved.

MILESTONES.md is the PUBLIC record of which charter gates are met; the tracker that holds the work is
private (CART-2001). Nothing in a ticket's prose makes anyone update the file, so this asks at the
one moment a milestone is demonstrably being touched: a commit message naming a milestone handle, or
a ticket filed under one, while MILESTONES.md is not staged.

  milestonecheck.py < commit-message

  handles   every ticket ID in MILESTONES.md's State table — the file is its own roster, so a
            milestone added there is covered here with no second list to keep in step.
  under     with tk on PATH, a named ticket whose `parent:` chain reaches a handle counts too.
            Without tk only a handle named outright is seen.

A WARNING, never a failure: it always exits 0. Most commits under a milestone move no gate, and the
file says so; this is the reminder, not the judge. Used by .githooks/commit-msg.
"""
import os, re, subprocess, sys

sys.dont_write_bytecode = True  # no tools/__pycache__ in the tree
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refcheck  # noqa: E402 — tk_tree / index: one way to find a ticket file, not two

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILE = 'MILESTONES.md'
ID = r'\b[A-Z][A-Z0-9]*-' + refcheck.ID_DIGITS + r'\b'


def handles(path):
    """{ticket ID: milestone name} from the State table: | **NAME** | `ID` | ..."""
    out = {}
    try:
        with open(path, encoding='utf-8') as fh:
            for line in fh:
                m = re.match(r'\|\s*\*\*([A-Z]+)\*\*\s*\|\s*`(' + ID[2:-2] + r')`\s*\|', line)
                if m:
                    out[m.group(2)] = m.group(1)
    except OSError:
        pass
    return out


def parent(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                if line.startswith('parent:'):
                    return line.split(':', 1)[1].strip() or None
                if line.startswith('## '):
                    break
    except OSError:
        pass
    return None


def milestone_of(tid, roster, idx):
    """the milestone a ticket is, or sits under; None when its parent chain reaches none."""
    seen = set()
    while tid and tid not in seen:
        if tid in roster:
            return roster[tid]
        seen.add(tid)
        tid = parent(idx[tid]) if tid in idx else None
    return None


def check(text, roster, idx, staged):
    """[(ticket ID, milestone)] the text touches while FILE is unstaged; [] when there is nothing to ask."""
    if FILE in staged:
        return []
    hits = []
    for tid in sorted(set(re.findall(ID, text))):
        name = milestone_of(tid, roster, idx)
        if name:
            hits.append((tid, name))
    return hits


def main():
    roster = handles(os.path.join(HERE, FILE))
    if not roster:
        return 0
    tree = refcheck.tk_tree()
    idx = refcheck.index(tree) if tree else {}
    staged = subprocess.run(['git', '-C', HERE, 'diff', '--cached', '--name-only'],
                            capture_output=True, text=True).stdout.split()
    hits = check(sys.stdin.read(), roster, idx, staged)
    if hits:
        names = sorted({n for _, n in hits})
        sys.stderr.write('[commit-msg] ⚠ this commit names %s (%s) and %s is not staged — did a gate clause get '
                         'measured, or the milestone close? If so update its row; if not, carry on\n'
                         % (', '.join(names), ', '.join(t if t in roster else t + ' under ' + n for t, n in hits), FILE))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:  # a reminder must never be the reason a commit fails
        sys.exit(0)
