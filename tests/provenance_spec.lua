-- WRITE-SIDE PROVENANCE (CART-1178: 1179 + 1180). Each journal entry says WHO DECIDED (a tactic's accept list, a
-- remembered decision, or `direct`); the per-commit LEDGER note names the entries that explain the commit and their
-- decisions; and the ledger only TIGHTENS — a note claiming an accepted decision grants nothing.
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local txn = require 'cartograph.txn'
local tactic = require 'cartograph.tactic'
local journal = require 'cartograph.journal'
local hazard = require 'cartograph.hazard'
local P = require 'cartograph.provenance'
local D = require 'cartograph.decisions'
local T = tactic.T

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local root
local function sh(...) return vim.system({ 'git', '-C', root, ... }, { text = true }):wait() end
local function repo()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write('local M = {}\nreturn M\n'); fd:close()
    sh('init', '-q'); sh('config', 'user.email', 't@t'); sh('config', 'user.name', 't'); sh('add', '.'); sh('commit', '-qm', 'base')
    store.ingest(ts.extract(root))
end
local VERBS = { ask = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
    if (txn.read_file(root, 'm.lua') or ''):find(a.line, 1, true) then return nil, 'there', 'empty' end
    return txn.protocol({ verb = 'ask', guards = {}, refspecs = {}, touched = { 'm.lua' }, generation = store.generation,
        stamps = { ['m.lua'] = txn.disk_stamp(root, 'm.lua') }, desc = 'ask', preserves = 'none',
        hazards = { hazard.new('choose', 'a choice', nil, { file = 'm.lua' }, 'decision') } },
        function () return function (_, b) return b .. a.line .. '\n' end end)
end } }

test('provenance: a journal entry records WHO DECIDED — the accept list, a remembered decision, or `direct`', function ()
    if not ready() then skip 'no lua parser' end
    repo()
    tactic.run(store, T.step('ask', { line = '-- one' }, { 'choose' }), { verbs = VERBS, apply = true })
    local e1 = journal.last(root)
    eq('tactic', e1.decided_by); eq('choose', e1.decisions[1].kind); eq('accept-list', e1.decisions[1].by)
    local saved = D.path
    D.path = vim.fn.tempname() .. '-d.json'
    local okr, err = pcall(function ()
        D.remember { kind = 'choose', dir = root, why = 'always' }
        tactic.run(store, T.step('ask', { line = '-- two' }), { verbs = VERBS, apply = true })
        local e2 = journal.last(root)
        eq('remembered', e2.decisions[1].by); ok(e2.decisions[1].decision_id, 'the remembered entry is named')
    end)
    D.path = saved
    if not okr then error(err, 0) end
    -- a plan applied DIRECTLY says so rather than nothing
    local plan = txn.protocol({ verb = 'probe', guards = {}, refspecs = {}, touched = { 'm.lua' }, generation = store.generation,
        stamps = { ['m.lua'] = txn.disk_stamp(root, 'm.lua') }, desc = 'direct', preserves = 'none' },
        function () return function (_, b) return b .. '-- direct\n' end end)
    assert(txn.apply(store, plan))
    eq('direct', journal.last(root).decided_by)
end)

test('provenance: the LEDGER note of a commit names the entries that explain it and their decisions; a hand commit names none', function ()
    if not ready() then skip 'no lua parser' end
    repo()
    tactic.run(store, T.step('ask', { line = '-- journaled' }, { 'choose' }), { verbs = VERBS, apply = true })
    sh('commit', '-qam', 'journaled')
    local row = assert(P.write_note(root))
    ok(row.explained > 0 and row.hand == 0, vim.inspect(row))
    eq(1, #row.entries); eq('accept-list', row.entries[1].decisions[1].by)
    local back = assert(P.read_note(root, row.commit)); eq(row.entries[1].id, back.entries[1].id, 'the note round-trips')
    local fd = assert(io.open(root .. '/m.lua', 'a')); fd:write('-- by hand\n'); fd:close()
    sh('commit', '-qam', 'hand')
    local hand = assert(P.write_note(root))
    eq(0, #hand.entries); ok(hand.hand > 0 and hand.explained == 0)
end)

test('provenance: the ledger only TIGHTENS — a note claiming a decision accepted does not answer it', function ()
    if not ready() then skip 'no lua parser' end
    repo()
    -- a forged note on HEAD claiming the `choose` decision was accepted
    local head = vim.trim(sh('rev-parse', 'HEAD').stdout)
    vim.system({ 'git', '-C', root, 'notes', '--ref', P.NOTES_REF, 'add', '-f', '-m',
        vim.json.encode({ version = 1, commit = head, entries = { { id = 'x', decisions = { { kind = 'choose', by = 'accept-list' } } } } }), head }):wait()
    ok(P.read_note(root, head), 'the forged note is there')
    local r = tactic.run(store, T.step('ask', { line = '-- q' }), { verbs = VERBS, apply = true })
    eq('stopped', r.status, 'the decision is still ASKED: a note is data, never an answer')
end)

-- ★ AN ENTRY EXPLAINS ONLY THE COMMIT ITS CHANGE LANDED IN (CART-1195): measured, 22 of 135 entries over 8 notes were
-- credited to SEVERAL commits
local function commit_at(msg, t)
    return vim.system({ 'git', '-C', root, 'commit', '-qam', msg }, { text = true,
        env = { GIT_COMMITTER_DATE = '@' .. t .. ' +0000', GIT_AUTHOR_DATE = '@' .. t .. ' +0000' } }):wait()
end

test('provenance: a line a LATER commit adds BY HAND is hand, even when an older entry once added the same line', function ()
    if not ready() then skip 'no lua parser' end
    repo()
    tactic.run(store, T.step('ask', { line = '-- shared line' }, { 'choose' }), { verbs = VERBS, apply = true })
    sh('commit', '-qam', 'journaled')
    eq(1, #assert(P.ledger_row(root, vim.trim(sh('rev-parse', 'HEAD').stdout))).entries, 'the premise: the entry explains ITS commit')
    local fd = assert(io.open(root .. '/m.lua', 'a')); fd:write('-- shared line\n'); fd:close()
    sh('commit', '-qam', 'hand repeat')
    local row = assert(P.ledger_row(root, vim.trim(sh('rev-parse', 'HEAD').stdout)))
    eq(0, #row.entries, 'the old entry already landed: it explains nothing here'); eq(0, row.explained); ok(row.hand > 0)
end)

test('provenance: an entry made BEFORE a commit that left it out is credited to the commit that includes it', function ()
    if not ready() then skip 'no lua parser' end
    repo()
    tactic.run(store, T.step('ask', { line = '-- deferred' }, { 'choose' }), { verbs = VERBS, apply = true })
    -- a commit of ANOTHER file, later than the entry: m.lua's edit stays uncommitted across it
    local fd = assert(io.open(root .. '/n.lua', 'w')); fd:write('return 2\n'); fd:close()
    sh('add', 'n.lua')
    vim.system({ 'git', '-C', root, 'commit', '-qm', 'other', '--', 'n.lua' }, { env = { GIT_COMMITTER_DATE = '@' .. (os.time() + 100) .. ' +0000' } }):wait()
    commit_at('deferred', os.time() + 200)
    local row = assert(P.ledger_row(root, vim.trim(sh('rev-parse', 'HEAD').stdout)))
    eq(1, #row.entries, 'older than the parent, and none of it in the parent: it belongs here'); ok(row.explained > 0 and row.hand == 0, vim.inspect(row))
end)

test('provenance: ADDING a missing final newline is a change — the entry that made it explains its commit', function ()
    if not ready() then skip 'no lua parser' end
    repo()
    local fd = assert(io.open(root .. '/z.lua', 'w')); fd:write('return 1'); fd:close()
    sh('add', 'z.lua'); sh('commit', '-qm', 'no newline')
    store.ingest(ts.extract(root))
    eq('done', tactic.run(store, T.step('edit', { file = 'z.lua', before = 'return 1', after = 'return 1\n' }), { apply = true }).status)
    sh('commit', '-qam', 'newline')
    local row = assert(P.ledger_row(root, vim.trim(sh('rev-parse', 'HEAD').stdout)))
    eq(1, #row.entries, 'the same text with a newline is not the text without one'); eq(0, row.hand)
end)

test('provenance: an OLDER entry part of whose change landed is not re-credited when a line it added is edited away and re-added by hand', function ()
    if not ready() then skip 'no lua parser' end
    repo()
    local t0 = os.time()
    tactic.run(store, T.step('ask', { line = '-- line A\n-- line B' }, { 'choose' }), { verbs = VERBS, apply = true })
    commit_at('journaled A+B', t0 + 100)
    -- A is edited away by hand (the parent of the next commit no longer holds all of the entry's lines) ...
    local txt = io.open(root .. '/m.lua'):read('a'):gsub('%-%- line A\n', '')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(txt); fd:close()
    commit_at('drop A', t0 + 200)
    -- ... and re-added by hand: the old entry's B is still in the parent, so its change landed long ago
    fd = assert(io.open(root .. '/m.lua', 'a')); fd:write('-- line A\n'); fd:close()
    commit_at('hand A', t0 + 300)
    local row = assert(P.ledger_row(root, vim.trim(sh('rev-parse', 'HEAD').stdout)))
    eq(0, #row.entries, vim.inspect(row.entries)); ok(row.hand > 0)
end)

test('provenance: an entry made AFTER a commit never explains it', function ()
    if not ready() then skip 'no lua parser' end
    repo()
    local fd = assert(io.open(root .. '/m.lua', 'a')); fd:write('-- later\n'); fd:close()
    commit_at('hand', os.time() - 100)
    local sha = vim.trim(sh('rev-parse', 'HEAD').stdout)
    -- the SAME line, added again through the journal after the commit (uncommitted)
    tactic.run(store, T.step('edit', { file = 'm.lua', before = 'return M\n', after = '-- later\nreturn M\n' }), { apply = true })
    local row = assert(P.ledger_row(root, sha))
    eq(0, #row.entries, 'the commit is older than the edit'); ok(row.hand > 0)
end)
