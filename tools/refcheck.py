#!/usr/bin/env python3
"""refcheck — every ticket ID and commit hash a text names must be REAL before the text is written.

A note or a commit message that names a ticket or a hash before `tk new` / `git commit` returned it
names something that does not exist, or worse, someone else's (2026-11-05: a body named CART-1913,
which another session had filed minutes earlier — the third such slip). Memory did not stop it, so
this does. Reads the text on stdin, prints one line per bad reference, exits 1 if there was any.

  refcheck.py [--session <claude-session-uuid>] [--seen <file>] [--no-hashes] [--repo <path>]... < text

  IDs      every <PROJECT>-<nnnn> (projects from the tk tree's .projects) must be a filed ticket.
           With --session, a ticket created SINCE that session registered with tk must also have been
           filed BY it, or have been READ by it already (--seen: one token per line, the IDs and hex
           tokens of every tool result and user message so far — tools/claude-guard.py keeps it).
           A guessed ID was never read; another session's ticket that this one is working on was.
           What counts is which SESSION filed a ticket, never its project prefix: filing a FLOW
           ticket from a cartograph session, or a CART ticket from flowpath, is ordinary.
  hashes   every 7-40 hex token holding a digit and a letter must resolve to a commit in one of the
           repos (this one, the algebra donor, flowpath, plus --repo), or have been read already.
  override a deliberate reference the rules cannot see: `refs-ok: <ref>[,<ref>]` in the text (on a
           command line, as a shell comment).

Used by .githooks/commit-msg (no --session: a person commits too) and by the Claude Code
PreToolUse guard tools/claude-guard.py (with --session and --seen).
"""
import os, re, subprocess, sys
from datetime import datetime

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_REPOS = [HERE, os.path.expanduser('~/tools/templates'), os.path.expanduser('~/work/flowpath')]
ID_DIGITS = r'\d{4,}'  # tk zero-pads to 4: CART-05 / FLOW-01 are session aliases, not tickets
HEX = r'(?<![0-9A-Za-z_./:#@=+-])[0-9a-f]{7,40}(?![0-9A-Za-z_/-])'
UUID = r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'


def tk_tree():
    try:
        out = subprocess.run(['tk', 'where'], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r'^tree\s+(\S+)', out, re.M)
    return m and m.group(1)


def index(tree):
    ids = {}
    for d, subs, files in os.walk(tree):
        subs[:] = [s for s in subs if not s.startswith('.')]
        for f in files:
            m = re.match(r'([A-Z][A-Z0-9]*-\d+)-', f)
            if m and f.endswith('.md'):
                ids[m.group(1)] = os.path.join(d, f)
    return ids


def ts(s):
    return datetime.fromisoformat(s.strip())


def creation(path):
    created, creator = None, None
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            if created is None and line.startswith('created:'):
                created = line.split(':', 1)[1]
            m = re.match(r'- (\S+) \[([^\]]+)\] created\s*$', line)
            if m:
                creator = m.group(2)
                break
    return (ts(created) if created else None), creator


def sessions(tree):
    rows = []
    try:
        with open(os.path.join(tree, '.sessions'), encoding='utf-8') as fh:
            for line in fh:
                f = line.rstrip('\n').split('\t')
                if len(f) >= 4 and f[0].startswith('cc:'):
                    rows.append((f[0][3:], f[1], f[3]))
    except OSError:
        pass
    return rows


def missing_hashes(toks, repos):
    left = set(toks)
    for r in repos:
        if not left or not os.path.exists(os.path.join(r, '.git')):
            continue
        q = sorted(left)
        out = subprocess.run(['git', '-C', r, 'cat-file', '--batch-check'], input=''.join(t + '^{commit}\n' for t in q),
                             capture_output=True, text=True).stdout.splitlines()
        for t, o in zip(q, out):
            if not o.endswith(' missing'):  # found, or ambiguous (a real prefix of several)
                left.discard(t)
    return left


class Seen:
    """IDs and hex tokens already read; a hash counts as read when a longer or shorter form of it was."""
    def __init__(self, toks=()):
        self.toks, self.p7 = set(), {}
        for t in toks:
            self.add(t)

    def add(self, t):
        if t in self.toks:
            return
        self.toks.add(t)
        if re.fullmatch(r'[0-9a-f]{7,40}', t):
            self.p7.setdefault(t[:7], []).append(t)

    def has(self, t):
        if t in self.toks:
            return True
        return any(s.startswith(t) or t.startswith(s) for s in self.p7.get(t[:7], ()))


def tokens(text):
    """the reference-shaped tokens of a text: what a Seen set is built from."""
    return set(re.findall(r'\b[A-Z][A-Z0-9]*-' + ID_DIGITS + r'\b', text)) | set(re.findall(HEX, re.sub(UUID, ' ', text)))


def check(text, sid=None, seen=None, hashes=True, repos=None, tree=None):
    ok = set(re.findall(r'[A-Za-z0-9-]+', ' '.join(re.findall(r'refs-ok:\s*([A-Za-z0-9, -]+)', text))))
    tree = tree or tk_tree()
    bad = []
    sess = sessions(tree) if tree else []
    if tree:
        try:
            with open(os.path.join(tree, '.projects'), encoding='utf-8') as fh:
                keys = [l.split()[0] for l in fh if l.strip() and not l.startswith('#')]
        except OSError:
            keys = []
        if keys:
            pat = r'\b(?:%s)-%s\b' % ('|'.join(map(re.escape, keys)), ID_DIGITS)
            refs = sorted(set(re.findall(pat, text)) - ok)
            if refs:
                idx = index(tree)
                me = [(a, ts(s)) for u, a, s in sess if u == sid]
                alias, since = me[0] if me else (None, None)
                for r in refs:
                    if r not in idx:
                        bad.append('%s is not a filed ticket — name an ID only after `tk new` returned it' % r)
                    elif alias and not (seen and seen.has(r)):
                        created, creator = creation(idx[r])
                        if created and created >= since and creator != alias:
                            bad.append('%s was filed by %s at %s, and this session (%s) neither filed it nor has read it '
                                       '— a guessed ID? (deliberate: refs-ok: %s)'
                                       % (r, creator, created.isoformat(timespec='minutes'), alias, r))
    if hashes:
        repos = repos or DEFAULT_REPOS
        toks = set(re.findall(HEX, re.sub(UUID, ' ', text)))
        toks = {t for t in toks if re.search(r'\d', t) and re.search(r'[a-f]', t)} - ok
        toks = {t for t in toks if not any(u.startswith(t) for u, _, _ in sess) and not (sid and sid.startswith(t))}
        toks = {t for t in toks if not (seen and seen.has(t))}
        for t in sorted(missing_hashes(toks, repos)):
            bad.append('%s is not a commit in %s%s — name a hash only after `git commit` returned it (deliberate: refs-ok: %s)'
                       % (t, ', '.join(os.path.basename(r.rstrip('/')) for r in repos),
                          ', nor read by this session' if seen is not None else '', t))
    return bad


def main(argv):
    sid, seen, hashes, repos = None, None, True, list(DEFAULT_REPOS)
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--session': sid = argv[i + 1]; i += 1
        elif a == '--seen':
            with open(argv[i + 1], encoding='utf-8') as fh:
                seen = Seen(l.strip() for l in fh if l.strip())
            i += 1
        elif a == '--no-hashes': hashes = False
        elif a == '--repo': repos.append(argv[i + 1]); i += 1
        else: sys.exit('refcheck: unknown argument ' + a)
        i += 1
    bad = check(sys.stdin.read(), sid, seen, hashes, repos)
    for b in bad:
        print('refcheck: ' + b)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
