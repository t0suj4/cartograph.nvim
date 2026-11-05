#!/usr/bin/env python3
"""claude-guard — a Claude Code PreToolUse hook: the harness-side half of the commit fence.

Git hooks cannot stop what an agent's session did twice (the-harness-is-unguarded #44/#57): an amend
with --no-verify skips every git hook, and `-F .git/COMMIT_EDITMSG` after a blocked commit re-uses the
PREVIOUS commit's message. And ticket IDs are written into tk, which no git hook sees. So, for an agent
only (a person keeps the documented WIP bypass):

  1. `git commit` in cartograph.nvim with --no-verify / -n, or a message read from .git/COMMIT_EDITMSG
     -> denied.
  2. a tk write (new/note/done/block/set/retitle/rel/dep) or a `git commit`: every ticket ID and hash in
     the command text goes through tools/refcheck.py for THIS session — a ticket filed since the session
     registered with tk must have been filed by it or READ by it (a tool result or user message in its
     transcript), a hash must be a commit or have been read. A guessed reference was never read.
     Cross-filing is fine: what counts is which SESSION filed a ticket, never its project prefix.
     For a cartograph commit the uncommitted diff's added ticket IDs get the same per-session check: an ID
     written into a file by an earlier call reaches the commit without being in its text.
  3. Edit / Write: ticket IDs the edit ADDS (IDs only — code is full of hex) go through the same check.
  4. Edit / Write on a file with MORE THAN ONE HARD LINK is denied (the-harness-is-unguarded #53/#59): tracked files are
     hard-linked into job snapshots, so an in-place write changes every copy. Break the link first —
     `cp -p f f.unlink.tmp && mv f.unlink.tmp f` — and retry. (A write made from a shell script is not seen here.)
  A denial's own text never counts as read (it names the refused reference: the retry would pass).

Register in .claude/settings*.json:
  {"hooks": {"PreToolUse": [{"matcher": "Bash|Edit|Write",
     "hooks": [{"type": "command", "command": "python3 <repo>/tools/claude-guard.py"}]}]}}
An internal error lets the call through with a warning on stderr: a broken guard must not brick a session.
"""
import json, os, re, shlex, subprocess, sys

sys.dont_write_bytecode = True  # no tools/__pycache__ in the tree
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refcheck  # noqa: E402

CACHE = os.path.expanduser('~/.cache/claude-guard')
TK_WRITE = re.compile(r'(?:^|[\s;&|(`$])tk\s+(?:new|note|done|block|set|retitle|rel|dep)\b')


def deny(why):
    json.dump({'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                                      'permissionDecisionReason': why}}, sys.stdout)
    sys.exit(0)


def strip_heredocs(cmd):
    out, lines, i = [], cmd.split('\n'), 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        delims = re.findall(r'<<-?\s*([\'"]?)(\w+)\1', line)
        i += 1
        for _, d in delims:
            while i < len(lines) and lines[i].strip() != d:
                i += 1
            i += 1
    return '\n'.join(out)


def commit_flags(cmd):
    """(is_commit, no_verify, stale_msg) over every segment of the command whose git SUBCOMMAND is commit (heredoc
    bodies removed; `git cat-file -e x^{commit}` is not one)."""
    found = nv = stale = False
    for seg in re.split(r'&&|\|\||[;\n|]', strip_heredocs(cmd)):
        try:
            tok = shlex.split(seg, comments=True)
        except ValueError:
            tok = seg.split()
        if 'git' not in tok:
            continue
        g = tok.index('git')
        rest = tok[g + 1:]
        # skip git's own options (-C <dir>, -c k=v, --git-dir=…) up to the subcommand
        j = 0
        while j < len(rest) and rest[j].startswith('-'):
            j += 2 if rest[j] in ('-C', '-c') else 1
        if j >= len(rest) or rest[j] != 'commit':
            continue
        found = True
        args, k = rest[j + 1:], 0
        while k < len(args):
            a = args[k]
            if a == '--no-verify':
                nv = True
            elif a in ('-F', '--file') and k + 1 < len(args):
                stale = stale or 'COMMIT_EDITMSG' in args[k + 1]
                k += 1
            elif a.startswith('--file='):
                stale = stale or 'COMMIT_EDITMSG' in a
            elif re.match(r'^-[A-Za-z]+$', a):
                flags = a[1:]
                for p, c in enumerate(flags):
                    if c == 'n':
                        nv = True
                    if c in 'mFCc' :  # takes a value: the rest of the cluster, or the next argument
                        if c == 'F':
                            v = flags[p + 1:] or (args[k + 1] if k + 1 < len(args) else '')
                            stale = stale or 'COMMIT_EDITMSG' in v
                        if p == len(flags) - 1:
                            k += 1
                        break
            k += 1
    return found, nv, stale


DENIAL = re.compile(r'refcheck:|refcheck \(|claude-guard:|hook error')


def read_text(t):
    """the tokens of a text the session was shown, minus every line that is (or quotes) a denial: a denial names the
    reference it refused, and counting it as read would let the identical retry through."""
    return refcheck.tokens('\n'.join(l for l in t.split('\n') if not DENIAL.search(l)))


def line_tokens(raw):
    """the reference tokens one transcript line shows the session — what it READ, never its own words: user
    messages and tool results, and the task notifications / mid-turn messages that arrive as queue entries.
    Not the `file` / `edited_text_file` attachments: they echo back what the session itself wrote."""
    if b'"type":"user"' in raw:
        try:
            c = (json.loads(raw).get('message') or {}).get('content')
        except ValueError:
            return set()
        out = set()
        for b in (c if isinstance(c, list) else [c]):
            if isinstance(b, str):
                out |= read_text(b)
            elif isinstance(b, dict):
                v = b.get('content') if b.get('type') == 'tool_result' else b.get('text')
                for x in (v if isinstance(v, list) else [v]):
                    t = x.get('text') if isinstance(x, dict) else x
                    if isinstance(t, str):
                        out |= read_text(t)
        return out
    if b'"queue-operation"' in raw or b'"queued_command"' in raw:
        try:
            o = json.loads(raw)
        except ValueError:
            return set()
        if o.get('type') == 'queue-operation' and o.get('operation') == 'enqueue':
            t = o.get('content')
        elif o.get('type') == 'attachment' and (o.get('attachment') or {}).get('type') == 'queued_command':
            t = o['attachment'].get('prompt')
        else:
            return set()
        return read_text(t) if isinstance(t, str) else set()
    return set()


def read_by_session(sid, transcript):
    """the Seen set: every ID / hex token in a tool result or user message of this session's transcript so far.
    Kept incrementally under ~/.cache/claude-guard/<sid>.{seen,off}: only the bytes past the last offset are read."""
    seen = refcheck.Seen()
    if not (sid and transcript and os.path.isfile(transcript)):
        return seen
    os.makedirs(CACHE, exist_ok=True)
    sp, op = os.path.join(CACHE, sid + '.seen'), os.path.join(CACHE, sid + '.off')
    off = 0
    try:
        with open(op) as fh:
            off = int(fh.read().strip() or 0)
        with open(sp, encoding='utf-8') as fh:
            for line in fh:
                seen.add(line.rstrip('\n'))
    except (OSError, ValueError):
        off = 0
    if os.path.getsize(transcript) < off:
        off = 0  # a rewritten transcript: start over
    new = set()
    with open(transcript, 'rb') as fh:
        fh.seek(off)
        for raw in fh:
            if not raw.endswith(b'\n'):
                break  # a line still being written: next time
            off += len(raw)
            new |= line_tokens(raw)
    new -= seen.toks
    with open(sp, 'a', encoding='utf-8') as fh:
        fh.writelines(t + '\n' for t in sorted(new))
    with open(op, 'w') as fh:
        fh.write(str(off))
    for t in new:
        seen.add(t)
    return seen


def check(text, ev, seen, hashes=True):
    bad = refcheck.check(text, ev.get('session_id'), seen(), hashes)
    return '\n'.join('refcheck: ' + b for b in bad)


def decide(ev, seen=None):
    """the denial reason for one PreToolUse event, or None. `seen` returns the session's Seen set (lazily:
    building it reads the transcript, which most calls never need)."""
    seen = seen or (lambda: read_by_session(ev.get('session_id'), ev.get('transcript_path')))
    tool, inp = ev.get('tool_name'), ev.get('tool_input') or {}
    if tool == 'Bash':
        cmd = inp.get('command') or ''
        is_commit, nv, stale = commit_flags(cmd)
        if is_commit and ('cartograph' in cmd or 'cartograph' in (ev.get('cwd') or '')):
            if nv:
                return ('claude-guard: `git commit --no-verify` / `-n` skips the pre-commit gates AND the commit-msg '
                        'refcheck; an amend that way committed a stale index once (harness #57). Fix what the hook '
                        'reports and commit normally.')
            if stale:
                return ('claude-guard: .git/COMMIT_EDITMSG is STALE after a blocked commit — it can hold the previous '
                        "commit's message (harness #57). Pass the message again through a quoted heredoc.")
        if is_commit or TK_WRITE.search(cmd):
            why = check(cmd, ev, seen)
            if not why and is_commit and 'cartograph' in cmd:
                # an ID written into a file by an EARLIER call reaches the commit without appearing in its text, and
                # commit-msg checks the diff for existence only — so the session rule runs on the diff here (against
                # HEAD, not the index: the same command often runs `git add` first)
                diff = subprocess.run(['git', '-C', refcheck.HERE, 'diff', 'HEAD', '-U0', '--no-color'],
                                      capture_output=True, text=True).stdout
                added = '\n'.join(l[1:] for l in diff.split('\n') if l.startswith('+') and not l.startswith('+++'))
                why = check(added, ev, seen, hashes=False)
                why = why and why.replace('refcheck: ', 'refcheck (uncommitted diff): ')
            return why or None
    elif tool in ('Edit', 'Write'):
        path = inp.get('file_path') or ''
        try:
            links = os.stat(path).st_nlink
        except OSError:
            links = 1  # a new file has no other copy
        if links > 1:
            q = shlex.quote(path)
            return ('claude-guard: %s has %d hard links — an in-place %s would change every copy (job snapshots share '
                    'the inode; harness #53/#59). Break the link first: cp -p %s %s.unlink.tmp && mv %s.unlink.tmp %s'
                    % (path, links, tool, q, q, q, q))
        new = inp.get('new_string') if tool == 'Edit' else inp.get('content')
        old = inp.get('old_string') if tool == 'Edit' else ''
        if tool == 'Write':
            try:
                with open(inp.get('file_path') or '', encoding='utf-8', errors='replace') as fh:
                    old = fh.read()
            except OSError:
                old = ''
        pat = r'\b[A-Z][A-Z0-9]*-' + refcheck.ID_DIGITS + r'\b'
        added = sorted(set(re.findall(pat, new or '')) - set(re.findall(pat, old or '')))
        if added:
            # keep any refs-ok marker the new text carries
            marks = ' '.join(re.findall(r'refs-ok:\s*[A-Za-z0-9, -]+', new or ''))
            return check(' '.join(added) + '\n' + marks, ev, seen, hashes=False) or None
    return None


def main():
    why = decide(json.load(sys.stdin))
    if why:
        deny(why)
    sys.exit(0)


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # a broken guard must not brick the session
        sys.stderr.write('claude-guard: internal error, call allowed: %r\n' % (e,))
        sys.exit(0)
