-- MERGE BY REPLAYING INTENTS (CART-1191 leaf 2). Two checkouts of ONE base (same origin), each person's work recorded
-- as invocations in the ledger notes; merging is replaying the other's invocations here. The oracle is the ARC's:
--   DISJOINT steps COMMUTE     A+replay(B) and B+replay(A) hold the same bytes
--   IDENTICAL steps are DONE   replaying a step this world already holds is empty, both ways
--   a CONFLICT stops exactly   only the conflicting step stops, as a decision; nothing after it is attempted
--   what did not travel        a sensitive step (a hash) or another world's paths is a FRONTIER, never skipped
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local tactic = require 'cartograph.tactic'
local P = require 'cartograph.provenance'
local R = require 'cartograph.replay'
local A = require 'cartograph.approvals'
local T = tactic.T

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') and vim.fn.executable('git') == 1 end

local ORIGIN = 'git@example.com:team/proj.git'
local function sh(root, ...) return vim.system({ 'git', '-C', root, ... }, { text = true }):wait() end
local function read(root, rel) local fd = assert(io.open(root .. '/' .. rel)); local s = fd:read('a'); fd:close(); return s end
local function ident(root) sh(root, 'config', 'user.email', 't@t'); sh(root, 'config', 'user.name', 't') end

--- the base, and a second checkout of it at another path with the SAME origin (so the same world id)
local function pair(origin_b)
    local a = vim.fn.tempname(); vim.fn.mkdir(a, 'p')
    for rel, t in pairs { ['m.lua'] = 'local M = {}\nreturn M\n', ['n.lua'] = 'local N = {}\nreturn N\n' } do
        local fd = assert(io.open(a .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    sh(a, 'init', '-q'); ident(a); sh(a, 'remote', 'add', 'origin', ORIGIN); sh(a, 'add', '.'); sh(a, 'commit', '-qm', 'base')
    local b = vim.fn.tempname()
    vim.system({ 'git', 'clone', '-q', a, b }):wait()
    ident(b); sh(b, 'remote', 'set-url', 'origin', origin_b or ORIGIN)
    return a, b
end

--- in `root`: run edit steps through the tactic runner (so each records its invocation), commit, write the note
local function work(root, edits)
    store.ingest(ts.extract(root))
    for _, e in ipairs(edits) do
        local r = tactic.run(store, T.step('edit', e), { apply = true })
        assert(r.status == 'done', vim.inspect(r.trace))
    end
    sh(root, 'commit', '-qam', 'work')
    assert(P.write_note(root))
end

local function replay_into(root, from, range)
    store.ingest(ts.extract(root))
    return R.run(store, R.from_notes(from, range or 'HEAD~1..HEAD'), { apply = true })
end

test('replay: DISJOINT steps commute — A+replay(B) and B+replay(A) hold the same bytes', function ()
    if not ready() then skip 'no lua parser / git' end
    local a, b = pair()
    work(a, { { file = 'm.lua', before = 'return M\n', after = 'M.a = 1\nreturn M\n' } })
    work(b, { { file = 'n.lua', before = 'return N\n', after = 'N.b = 2\nreturn N\n' } })
    local ra = replay_into(a, b)
    local rb = replay_into(b, a)
    eq('done', ra.status, vim.inspect(ra)); eq('done', rb.status, vim.inspect(rb))
    eq('applied', ra.steps[1].outcome); eq('applied', rb.steps[1].outcome)
    for _, rel in ipairs { 'm.lua', 'n.lua' } do eq(read(a, rel), read(b, rel), rel .. ' converges') end
    eq('local M = {}\nM.a = 1\nreturn M\n', read(b, 'm.lua'), 'the premise: B now holds A\'s change')
end)

test('replay: IDENTICAL steps are DONE — the same change on both sides replays empty, and a second replay is empty too', function ()
    if not ready() then skip 'no lua parser / git' end
    local a, b = pair()
    local same = { { file = 'm.lua', before = 'return M\n', after = 'M.a = 1\nreturn M\n' } }
    work(a, same); work(b, same)
    local r = replay_into(b, a)
    eq('done', r.status); eq('done', r.steps[1].outcome); eq(0, r.applied); eq(1, r.done)
    eq('local M = {}\nM.a = 1\nreturn M\n', read(b, 'm.lua'), 'applied once, not twice')
    local a2, b2 = pair()
    work(a2, { { file = 'n.lua', before = 'return N\n', after = 'N.x = 1\nreturn N\n' } })
    eq('applied', replay_into(b2, a2).steps[1].outcome)
    eq('done', replay_into(b2, a2).steps[1].outcome, 'replaying again is empty: the intent is already here')
end)

test('replay: a CONFLICT stops exactly at its step, as a decision — mine is untouched, a step that DEPENDS on it is not reached, an INDEPENDENT one still applies', function ()
    if not ready() then skip 'no lua parser / git' end
    local a, b = pair()
    work(a, { { file = 'm.lua', before = 'local M = {}\n', after = 'local M = { a = 1 }\n' },
        { file = 'n.lua', before = 'return N\n', after = 'N.later = 1\nreturn N\n' },
        { file = 'm.lua', before = 'local M = { a = 1 }\n', after = 'local M = { a = 1, c = 3 }\n' } })
    work(b, { { file = 'm.lua', before = 'local M = {}\n', after = 'local M = { b = 2 }\n' } })
    local r = replay_into(b, a)
    eq('conflict', r.status, vim.inspect(r))
    eq('conflict', r.steps[1].outcome); eq('decision', r.steps[1].class)
    ok(r.steps[1].options and #r.steps[1].options == 2, 'keep-mine / take-theirs')
    eq('applied', r.steps[2].outcome, 'n.lua shares no file with the conflict: it goes on (92% of later steps, measured)')
    eq('not reached', r.steps[3].outcome, 'the follow-up edit on m.lua may depend on the conflicting step')
    ok(r.steps[3].why:find('m.lua', 1, true), r.steps[3].why)
    eq('local M = { b = 2 }\nreturn M\n', read(b, 'm.lua'), 'mine is untouched')
    eq('local N = {}\nN.later = 1\nreturn N\n', read(b, 'n.lua'), 'the independent step ran')
    eq({ r.steps[1].id }, r.stops)
    -- stop_at_first: the old contract, on request
    local a2, b2 = pair()
    work(a2, { { file = 'm.lua', before = 'local M = {}\n', after = 'local M = { a = 1 }\n' },
        { file = 'n.lua', before = 'return N\n', after = 'N.later = 1\nreturn N\n' } })
    work(b2, { { file = 'm.lua', before = 'local M = {}\n', after = 'local M = { b = 2 }\n' } })
    store.ingest(ts.extract(b2))
    local r2 = R.run(store, R.from_notes(a2, 'HEAD~1..HEAD'), { apply = true, stop_at_first = true })
    eq('not reached', r2.steps[2].outcome)
end)

test('replay: a SUPERSEDED step (its lines overwritten before the commit) is still replayed — the follow-up was planned against it', function ()
    if not ready() then skip 'no lua parser / git' end
    local a, b = pair()
    work(a, { { file = 'm.lua', before = 'local M = {}\n', after = 'local M = { a = 1 }\n' },
        { file = 'm.lua', before = 'local M = { a = 1 }\n', after = 'local M = { a = 1, c = 3 }\n' } })
    local r = replay_into(b, a)
    eq('done', r.status, vim.inspect(r)); eq(2, #r.steps, 'both steps travel, though only the second explains a line')
    eq(read(a, 'm.lua'), read(b, 'm.lua'), 'the clean parent reaches the commit, byte for byte')
end)

test('replay: a step whose files are UNKNOWN never runs past a stop, and does not let one pass it', function ()
    if not ready() then skip 'no lua parser / git' end
    local a, b = pair()
    work(b, { { file = 'm.lua', before = 'local M = {}\n', after = 'local M = { b = 2 }\n' } })
    store.ingest(ts.extract(b))
    local conflict = { verb = 'edit', args = { file = 'm.lua', before = 'local M = {}\n', after = 'local M = { a = 1 }\n' }, touched = { 'm.lua' } }
    local indep = { verb = 'edit', args = { file = 'n.lua', before = 'return N\n', after = 'N.x = 1\nreturn N\n' }, touched = { 'n.lua' } }
    local unknown = { verb = 'edit', args = { file = 'n.lua', before = 'local N = {}\n', after = 'local N = { u = 1 }\n' } }
    local r = R.run(store, { { id = '1', invocation = conflict }, { id = '2', invocation = unknown }, { id = '3', invocation = indep } }, { apply = true })
    eq('conflict', r.steps[1].outcome)
    eq('not reached', r.steps[2].outcome, 'no touched set: assumed to touch everything')
    eq('not reached', r.steps[3].outcome, 'and once an unknown step is held back, it may be what step 3 depends on')
    eq('local N = {}\nreturn N\n', read(b, 'n.lua'))
end)

test('replay: what did not travel is a FRONTIER — a sensitive step\'s hash, another world\'s paths, a direct apply', function ()
    if not ready() then skip 'no lua parser / git' end
    local a, b = pair('git@example.com:someone-else/proj.git')
    store.ingest(ts.extract(b))
    local r = R.run(store, { { id = 's', invocation = { verb = 'edit', args = { ref = 'sha256:00', sensitive = true } } },
        { id = 't', invocation = { verb = 'edit', args = { file = 'm.lua', before = 'x', after = 'y' } } } }, { apply = true })
    eq('frontier', r.status); ok(r.steps[1].why:find('reference', 1, true), r.steps[1].why); eq('not reached', r.steps[2].outcome)
    eq('frontier', R.run(store, { { id = 'd', verb = 'probe' } }, { apply = true }).status, 'no invocation recorded')
    -- a path named by A's world, localized: into A it resolves, into B (another origin) it is refused by name
    local id = A.world_id(a)
    local args = { file = '@' .. id .. '/m.lua' }
    eq(a .. '/m.lua', R.localize(args, a).file)
    local none, why = R.localize(args, b)
    eq(nil, none); ok(why:find('names the world', 1, true), why)
end)
