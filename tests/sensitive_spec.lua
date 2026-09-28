-- SENSITIVE INFORMATION in cartograph's own travelling records (CART-1192, leaf CART-1193). Sensitivity is DERIVED
-- (git's tracked set; user config overrides); a travelling record carries a REFERENCE in place of a sensitive value;
-- and the egress check — independent of the redaction — refuses a note that would carry a sensitive file's bytes,
-- naming the file and never the bytes. Every case is pinned BOTH ways: the tracked file's text DOES travel where the
-- design says it does (a dead predicate would pass the negative alone).
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local txn = require 'cartograph.txn'
local tactic = require 'cartograph.tactic'
local config = require 'cartograph.config'
local P = require 'cartograph.provenance'
local S = require 'cartograph.sensitive'
local T = tactic.T

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') and vim.fn.executable('git') == 1 end

local SECRET = 'API_TOKEN=supersecret-0123456789'
local root
local function sh(...) return vim.system({ 'git', '-C', root, ... }, { text = true }):wait() end
local function read(rel) local fd = assert(io.open(root .. '/' .. rel)); local s = fd:read('a'); fd:close(); return s end
--- a repo: m.lua TRACKED, .env UNTRACKED and ignored (the common secret-holding shape)
local function repo()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(rel, t) local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
    put('m.lua', 'local M = {}\nreturn M\n'); put('.gitignore', '.env\n'); put('.env', 'DB_HOST=localhost-db\n')
    sh('init', '-q'); sh('config', 'user.email', 't@t'); sh('config', 'user.name', 't'); sh('add', '.'); sh('commit', '-qm', 'base')
    store.ingest(ts.extract(root))
end

--- ONE plan touching BOTH files: the real path by which a sensitive file's bytes reach a commit's note (an entry that
--- touched only .env never explains a commit's lines)
local VERBS = { pair = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
    if read('m.lua'):find(a.line, 1, true) then return nil, 'there', 'empty' end
    return txn.protocol({ verb = 'pair', guards = {}, refspecs = {}, touched = { 'm.lua', '.env' }, generation = store.generation,
        stamps = { ['m.lua'] = txn.disk_stamp(root, 'm.lua'), ['.env'] = txn.disk_stamp(root, '.env') }, desc = 'pair', preserves = 'none' },
        function () return function (rel, b) return b .. (rel == '.env' and a.secret or a.line) .. '\n' end end)
end } }

test('sensitive: classify derives it from git — tracked is public, untracked/ignored is sensitive, no repo is all sensitive, config overrides', function ()
    if not ready() then skip 'no lua parser / git' end
    repo()
    local c = S.classify(root, { 'm.lua', '.env', 'new.lua' })
    eq(nil, c['m.lua'], 'tracked: public'); ok(c['.env'] and c['new.lua'], vim.inspect(c))
    local saved = config.scoped
    config.scoped = { [root .. '/m.lua'] = { sensitive = true }, [root .. '/new.lua'] = { sensitive = false } }
    local okr, err = pcall(function ()
        local o = S.classify(root, { 'm.lua', 'new.lua' })
        ok(o['m.lua'] and o['m.lua']:find('config', 1, true), 'config marks a tracked file sensitive'); eq(nil, o['new.lua'], 'config declares an untracked one public')
    end)
    config.scoped = saved
    if not okr then error(err, 0) end
    local bare = vim.fn.tempname(); vim.fn.mkdir(bare, 'p')
    ok(S.classify(bare, { 'x.lua' })['x.lua'], 'no repository decides: sensitive')
end)

test('sensitive: an invocation that touched a tracked file TRAVELS with its args; one that touched an untracked file travels as a HASH only', function ()
    if not ready() then skip 'no lua parser / git' end
    repo()
    -- tracked only: the edit verb, its args carried in the note (the replayable intent, CART-1191)
    eq('done', tactic.run(store, T.step('edit', { file = 'm.lua', before = 'return M\n', after = 'M.x = 1\nreturn M\n' }), { apply = true }).status)
    sh('commit', '-qam', 'tracked')
    local row = assert(P.write_note(root))
    local inv = row.entries[1] and row.entries[1].invocation
    ok(inv and inv.verb == 'edit' and inv.args.after == 'M.x = 1\nreturn M\n' and inv.args.file == 'm.lua', vim.inspect(row.entries))
    -- tracked + untracked in ONE plan: the args (which hold the secret) travel as a reference; the secret is nowhere
    eq('done', tactic.run(store, T.step('pair', { line = '-- tracked side', secret = SECRET }), { verbs = VERBS, apply = true }).status)
    ok(read('.env'):find(SECRET, 1, true), 'the premise: the secret was written to .env')
    sh('commit', '-qam', 'pair')
    local row2 = assert(P.write_note(root))
    local inv2 = row2.entries[1].invocation
    ok(inv2.args.ref and inv2.args.ref:match('^sha256:') and inv2.sensitive_files == 1 and inv2.args.secret == nil, vim.inspect(inv2))
    local note = vim.system({ 'git', '-C', root, 'notes', '--ref', P.NOTES_REF, 'show', 'HEAD' }, { text = true }):wait().stdout
    ok(note:find('sha256:', 1, true) and not note:find('supersecret', 1, true), 'the pushed note: the hash, never the secret')
end)

test('sensitive: the EGRESS check refuses a note that would carry a sensitive file\'s bytes — by name, and writes nothing', function ()
    if not ready() then skip 'no lua parser / git' end
    repo()
    -- a DIRECT apply whose decisions carry the secret verbatim (a field the redaction does not rewrite): only the
    -- independent boundary check stands between it and the note
    local plan = txn.protocol({ verb = 'pair', guards = {}, refspecs = {}, touched = { 'm.lua', '.env' }, generation = store.generation,
        stamps = { ['m.lua'] = txn.disk_stamp(root, 'm.lua'), ['.env'] = txn.disk_stamp(root, '.env') }, desc = 'pair', preserves = 'none',
        decisions = { { kind = 'x', by = 'accept-list', note = 'copied ' .. SECRET } } },
        function () return function (rel, b) return b .. (rel == '.env' and SECRET or '-- direct') .. '\n' end end)
    assert(txn.apply(store, plan))
    sh('commit', '-qam', 'direct')
    local row, why, class = P.write_note(root)
    eq(nil, row); eq('decision', class)
    ok(why:find('.env', 1, true) and not why:find('supersecret', 1, true), 'names the file, never the bytes: ' .. tostring(why))
    eq(nil, P.read_note(root, vim.trim(vim.system({ 'git', '-C', root, 'rev-parse', 'HEAD' }, { text = true }):wait().stdout)), 'nothing written')
    -- and the unit: short lines prove nothing, a long one is found in any string of the record
    eq(0, #S.leaks({ a = 'end' }, { ['.env'] = { 'end\n' } }))
    eq(1, #S.leaks({ a = { b = 'xx ' .. SECRET } }, { ['.env'] = { SECRET .. '\n' } }))
end)
