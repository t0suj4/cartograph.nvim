-- CART-1884: the self MCP host answered from a worktree five weeks behind main (7eb6e492, 2026-09-27) and nothing in an
-- answer said so — the envelope carried `graph.root`, not the commit or its age. Every envelope now carries
-- `graph.revision` (the commit the root's checkout was at when the graph arrived) and `graph.drift` (how far the
-- repository moved since, read at answer time); an answer from a graph the repository moved past carries a
-- `graph-behind` note. The self host is a DETACHED linked worktree — its HEAD never moves — so the drift is also
-- measured against the branch the main worktree has checked out: that case is the third test.

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local agent = require 'cartograph.agent'
local prov  = require 'cartograph.provenance'

-- every git call goes through the SCRUBBED environment: the pre-commit hook exports GIT_INDEX_FILE, and a spec's
-- `git add` must never write the index of the repository being committed
local function git(dir, ...)
    local out = prov.git_at(dir, { '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', ... })
    assert(out, 'git ' .. table.concat({ ... }, ' ') .. ' failed in ' .. dir)
    return vim.trim(out)
end
local function write(path, text) local fd = assert(io.open(path, 'w')); fd:write(text); fd:close() end

local function repo()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    git(root, 'init', '-q', '-b', 'main')
    write(root .. '/m.lua', 'local M = {}\nfunction M.f(x)\n  return x\nend\nreturn M\n')
    git(root, 'add', 'm.lua'); git(root, 'commit', '-qm', 'one')
    return root, git(root, 'rev-parse', 'HEAD')
end
local function open(root)
    local data = ts.extract(root); data.root = root
    store.ingest(data)
end
local function note(a, kind)
    for _, n in ipairs(a.notes or {}) do if n.kind == kind then return n end end
end

test('revision: every envelope names the commit its graph describes; a checkout that has not moved carries no note (CART-1884)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root, sha = repo()
    open(root)
    local a = agent.answer(store, 'node_find', { query = 'M.f' })
    eq(true, a.ok)
    eq(sha, a.graph.revision.commit)
    eq('main', a.graph.revision.branch)
    eq(0, a.graph.revision.dirty)
    ok(type(a.graph.revision.committed_at) == 'string' and a.graph.revision.committed_at:match('^%d%d%d%d%-'), 'the commit DATE: the age is answerable')
    eq({ head = sha, moved = false, ref = 'main', behind = 0, changed = 0, stale = 0, examples = {} }, a.graph.drift)
    eq(nil, note(a, 'graph-behind'), 'nothing moved, nothing said')
    vim.fn.delete(root, 'rf')
end)

test('revision: a commit after the graph arrived — the answer carries graph-behind with the commits it lacks (CART-1884)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root, sha = repo()
    open(root)
    agent.answer(store, 'node_find', { query = 'M.f' }) -- the drift memo is filled …
    write(root .. '/n.lua', 'return 1\n')
    git(root, 'add', 'n.lua'); git(root, 'commit', '-qm', 'two')
    local ttl = agent.DRIFT_TTL_MS
    agent.DRIFT_TTL_MS = 0 -- … and expires: the next answer reads git again
    local a = agent.answer(store, 'node_find', { query = 'M.f' })
    agent.DRIFT_TTL_MS = ttl
    eq(sha, a.graph.revision.commit, 'the revision is the graph\'s, it does not follow the checkout')
    eq(true, a.graph.drift.moved); eq('main', a.graph.drift.ref)
    eq(1, a.graph.drift.stale, 'n.lua: a source file the graph never read')
    local n = note(a, 'graph-behind')
    ok(n, 'an answer from a graph the repository moved past says so: ' .. vim.inspect(a.notes))
    eq(sha, n.evidence.commit); eq({ 'n.lua' }, n.evidence.examples)
    vim.fn.delete(root, 'rf')
end)

test('revision: an edit the graph already READ, then committed, moves HEAD but makes no note — the graph has that content (CART-1884)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = repo()
    open(root)
    vim.uv.sleep(1100) -- (an mtime stamp: the edit must land in a later second)
    write(root .. '/m.lua', 'local M = {}\nfunction M.f(x)\n  return x + 1\nend\nreturn M\n')
    require('cartograph.refresh').file('m.lua') -- what a save in the editor (or a txn_apply) does: the graph re-reads it
    git(root, 'commit', '-qam', 'two')
    local ttl = agent.DRIFT_TTL_MS
    agent.DRIFT_TTL_MS = 0
    local a = agent.answer(store, 'node_find', { query = 'M.f' })
    agent.DRIFT_TTL_MS = ttl
    eq(true, a.graph.drift.moved); eq(1, a.graph.drift.changed)
    eq(0, a.graph.drift.stale, 'the committed content is what the graph read')
    eq(nil, note(a, 'graph-behind'), 'no false alarm: ' .. vim.inspect(a.notes))
    vim.fn.delete(root, 'rf')
end)

test('revision: an UNCOMMITTED edit after the graph arrived moves no commit and still makes the note (CART-1884)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root, sha = repo()
    open(root)
    vim.uv.sleep(1100)
    write(root .. '/m.lua', 'local M = {}\nfunction M.f(x)\n  return x + 1\nend\nreturn M\n')
    local ttl = agent.DRIFT_TTL_MS
    agent.DRIFT_TTL_MS = 0
    local a = agent.answer(store, 'node_find', { query = 'M.f' })
    agent.DRIFT_TTL_MS = ttl
    eq(false, a.graph.drift.moved); eq(sha, a.graph.drift.head)
    eq(1, a.graph.drift.stale)
    local n = note(a, 'graph-behind')
    ok(n, 'the graph differs from the disk: ' .. vim.inspect(a.notes))
    eq({ 'm.lua' }, n.evidence.examples)
    vim.fn.delete(root, 'rf')
end)

test('revision: a DETACHED linked worktree (the self host) — its HEAD never moves, and it is still behind the main worktree\'s branch (CART-1884)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root, sha = repo()
    local wt = vim.fn.tempname()
    git(root, 'worktree', 'add', '-q', '--detach', wt, sha)
    open(wt)
    write(root .. '/n.lua', 'return 1\n')
    git(root, 'add', 'n.lua'); git(root, 'commit', '-qm', 'two')
    write(root .. '/n.lua', 'return 2\n')
    git(root, 'commit', '-qam', 'three')
    local ttl = agent.DRIFT_TTL_MS
    agent.DRIFT_TTL_MS = 0
    local a = agent.answer(store, 'node_find', { query = 'M.f' })
    agent.DRIFT_TTL_MS = ttl
    eq(sha, a.graph.revision.commit)
    eq(nil, a.graph.revision.branch, 'detached: no branch of its own')
    eq(false, a.graph.drift.moved, 'the worktree\'s own HEAD did not move — that alone would stay silent for ever')
    eq('main', a.graph.drift.ref, 'measured against the branch the main worktree has checked out')
    eq(2, a.graph.drift.behind); eq(0, a.graph.drift.stale, 'its own files are what the graph read')
    ok(note(a, 'graph-behind'), 'and the answer says so')
    git(root, 'worktree', 'remove', '--force', wt)
    vim.fn.delete(root, 'rf')
end)

test('revision: outside git, and a loaded dump with none — revision and drift are null, never the current HEAD (CART-1884)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root .. '/m.lua', 'local M = {}\nfunction M.f(x)\n  return x\nend\nreturn M\n')
    open(root)
    local a = agent.answer(store, 'node_find', { query = 'M.f' })
    eq(vim.NIL, a.graph.revision); eq(vim.NIL, a.graph.drift); eq(nil, note(a, 'graph-behind'))
    -- a dump of a graph INSIDE a checkout: the checkout's commit now says nothing about when the dump was made
    local groot, gsha = repo()
    local data = ts.extract(groot); data.root = groot
    local dump = vim.fn.tempname() .. '.json'
    write(dump, vim.json.encode(data))
    store.load(dump)
    a = agent.answer(store, 'node_find', { query = 'M.f' })
    eq(vim.NIL, a.graph.revision, 'unknown, not ' .. gsha)
    vim.fn.delete(root, 'rf'); vim.fn.delete(groot, 'rf'); vim.fn.delete(dump)
end)

test('revision: graph_info counts the files edited on disk since the graph read them — an edit moves no commit (CART-1884)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = repo()
    open(root)
    local before = note(agent.answer(store, 'graph_info', {}), 'stale-files')
    ok(before, 'graph_info reports the per-file check')
    eq(0, before.evidence.stale); ok(before.evidence.checked >= 1)
    vim.uv.sleep(1100) -- (an mtime stamp: the edit must land in a later second)
    write(root .. '/m.lua', 'local M = {}\nfunction M.f(x)\n  return x + 1\nend\nreturn M\n')
    local after = note(agent.answer(store, 'graph_info', {}), 'stale-files')
    eq(1, after.evidence.stale); eq({ 'm.lua' }, after.evidence.examples)
    vim.fn.delete(root, 'rf')
end)
