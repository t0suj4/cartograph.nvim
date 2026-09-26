-- A USE WITH NO REQUIRE (lua/cartograph/userequire.lua + the `use-without-require`
-- lint), the reverse of `redundant-require` ([[cartograph-bidirectional-instruments]]).
--
-- ★ EVERY NEGATIVE HERE IS PINNED AGAINST A RESOLUTION THAT EXISTS. A "no finding"
-- on a call the resolver never linked passes whatever the rule does, so each
-- negative first asserts the cross-file edge is really there. Each guard was found
-- on a real corpus:
--   · a use that lands on a def its caller cannot NAME (`tostring` -> FUNCS.tostring)
--     — 4,000+ false "globals" on our own tree before the name had to match
--   · a def whose root the corpus never defines patches a HOST table (`vim.cmd =`)
--   · a `use` edge on a MEMBER read (`t.layer`) reaches no global — SE's data/control
--     stage collisions
--   · a local module table published globally by ANOTHER file (`Zone = require …`)
--     IS the finding — SE's whole control stage

local store = require 'cartograph.store'
local lint = require 'cartograph.lint'
local ts = require 'cartograph.providers.treesitter'
local ur = require 'cartograph.userequire'

local FILES = {
    ['base.lua'] = { 'function BaseRegister(x) return x end', 'layer = 1' },
    ['user.lua'] = { 'BaseRegister("a")' },                        -- FINDING
    ['user2.lua'] = { 'local b = require "base"', 'BaseRegister("b")' }, -- has the require
    ['loc.lua'] = { 'local function Hidden() return 1 end', 'local M = { Hidden = Hidden }', 'return M' },
    ['user3.lua'] = { 'Hidden()' },                                -- a LOCAL def: unreachable by name
    ['zone.lua'] = { 'local Zone = {}', 'function Zone.get() return 1 end', 'return Zone' },
    ['control.lua'] = { 'Zone = require("zone")' },                -- publishes zone.lua globally
    ['ship.lua'] = { 'local S = {}', 'function S.go() return Zone.get() end', 'return S' }, -- FINDING
    ['ship2.lua'] = { 'local T = {}', 'function T.take(Zone) return Zone.get() end', 'return T' },
    ['stub.lua'] = { 'vim.cmd = function (c) return c end' },      -- patches a host table
    ['user4.lua'] = { 'vim.cmd("x")', 'local t = {}', 'print(t.layer)' },
    ['user5.lua'] = { 'local y = layer + 1', 'return y' },         -- FINDING (a global read)
    ['lib.lua'] = { 'Lib = {}', 'function Lib.fmt(s) return s end' },
    ['user6.lua'] = { 'fmt("x")' },   -- lands on Lib.fmt, a name user6 never spells
}

local DATA, ROOT
local function graph()
    if not DATA then
        ROOT = vim.fn.tempname()
        vim.fn.mkdir(ROOT, 'p')
        for rel, lines in pairs(FILES) do write(ROOT, rel, lines) end
        DATA = ts.extract(ROOT)
    end
    store.ingest(DATA)
    return DATA
end

local function resolved(data, file, target)
    for _, c in ipairs(data.calls) do
        if c.file == file and c.to == target then return true end
    end
    return false
end

local function classify(data)
    return ur.classify(data, function (f)
        local fd = io.open(ROOT .. '/' .. f, 'r')
        if not fd then return nil end
        local t = fd:read('*a'); fd:close()
        return t
    end)
end

local function row(res, file)
    for _, r in ipairs(res.rows) do if r.file == file then return r end end
end

local function lint_files()
    local out = {}
    for _, f in ipairs(lint.run(store, { only = { ['use-without-require'] = true } })) do
        out[vim.fn.fnamemodify(f.file, ':t')] = f
    end
    return out
end

test('use-without-require: a global of another file used with no require is a finding', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local data = graph()
    ok(resolved(data, 'user.lua', 'base.lua::BaseRegister@0'), 'the fixture resolves the call')
    local f = lint_files()
    ok(f['user.lua'], 'user.lua is reported: ' .. vim.inspect(vim.tbl_keys(f)))
    ok(f['user.lua'].message:find("'base.lua'", 1, true)
        and f['user.lua'].message:find('BaseRegister', 1, true), f['user.lua'].message)
    eq('global', row(classify(data), 'user.lua').class)
end)

test('use-without-require: the same use WITH a require is not', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local data = graph()
    ok(resolved(data, 'user2.lua', 'base.lua::BaseRegister@0'), 'resolved')
    ok(not lint_files()['user2.lua'], 'user2.lua requires base.lua')
end)

test('use-without-require: a LOCAL def is not reachable by name, so it is no finding', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local data = graph()
    ok(resolved(data, 'user3.lua', 'loc.lua::Hidden@0'), 'the resolver did link it (a guess)')
    ok(not lint_files()['user3.lua'], 'but `local function Hidden` is not a global')
    local r = row(classify(data), 'user3.lua')
    eq('not-global', r.class)
    eq('unexplained', r.sub, 'and nothing in user3 names loc.lua')
end)

test('use-without-require: a module published GLOBALLY by another file is the finding', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local data = graph()
    ok(resolved(data, 'ship.lua', 'zone.lua::Zone.get@1'), 'resolved')
    local r = row(classify(data), 'ship.lua')
    eq('global', r.class, vim.inspect(r and { r.class, r.sub }))
    eq('via-global-alias', r.sub, 'control.lua publishes zone.lua as the global Zone')
    eq('control.lua', r.via, 'the row names the PUBLISHER')
    local f = lint_files()['ship.lua']
    ok(f, 'and the lint reports it')
    ok(f.message:find("'control.lua' publishes 'zone.lua'", 1, true),
        'naming both files — zone.lua\'s own table is local: ' .. f.message)
end)

test('use-without-require: an UNREADABLE file gives no verdict, never a finding', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local data = graph()
    -- with no text for base.lua its `local` set would be EMPTY, and every def in it
    -- would look global — the reporting direction
    local res = ur.classify(data, function (f)
        if f == 'base.lua' then return nil end
        local fd = io.open(ROOT .. '/' .. f, 'r')
        if not fd then return nil end
        local t = fd:read('*a'); fd:close()
        return t
    end)
    eq('unread', row(res, 'user.lua').class)
    for _, g in ipairs(ur.findings(res)) do
        ok(g.gfile ~= 'base.lua', 'no finding against an unread definer: ' .. g.file)
    end
end)

test('use-without-require: a use that lands on a def its caller cannot NAME is no finding', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local data = graph()
    ok(resolved(data, 'user6.lua', 'lib.lua::Lib.fmt@1'), 'bare fmt() was linked to Lib.fmt (a tail guess)')
    eq('other-name', row(classify(data), 'user6.lua').class,
        'the environment carries `fmt`, and lib.lua defines only `Lib.fmt`')
    ok(not lint_files()['user6.lua'])
end)

test('use-without-require: a PARAMETER is a value handed in, never a missing require', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local data = graph()
    ok(resolved(data, 'ship2.lua', 'zone.lua::Zone.get@1'), 'resolved')
    ok(not row(classify(data), 'ship2.lua'), 'no row at all: excluded before classifying')
    ok(not lint_files()['ship2.lua'])
end)

test('use-without-require: patching a HOST table defines nothing to require', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local data = graph()
    ok(resolved(data, 'user4.lua', 'stub.lua::vim.cmd@0'), 'vim.cmd("x") landed on the stub')
    eq('host-root', row(classify(data), 'user4.lua').class, 'nothing in the corpus defines `vim`')
    ok(not lint_files()['user4.lua'])
end)

test('use-without-require: a MEMBER read is not a global read; a free read is', function ()
    if not parser_available('lua') then skip('no lua parser') end
    local data = graph()
    local member_edge = false
    for _, e in ipairs(data.edges) do
        local src = e.from and e.from:match('^([^:]+)')
        if e.kind == 'use' and src == 'user4.lua' and e.to == 'base.lua::var:layer@1' then member_edge = true end
    end
    ok(member_edge, 'the graph DOES carry a use edge for `t.layer` into base.lua\'s global')
    local res = classify(data)
    ok((res.census['excluded:member-read'] or 0) >= 1, 'and it is excluded as a member read')
    local r = row(res, 'user5.lua')
    ok(r and r.class == 'global' and r.how == 'read', 'user5 reads the global `layer` freely')
end)

test('use-without-require: registered as a suggestive corpus promise', function ()
    local rule
    for _, r in ipairs(lint.rules) do if r.name == 'use-without-require' then rule = r end end
    ok(rule, 'registered')
    eq('suggestive', rule.disposition, 'a work list, never a verdict')
    eq('promise', rule.quantifier, '"nothing requires G" is an absence')
    eq('corpus', rule.closed_over, 'and a scope cut must refuse it, not clip it')
end)

test('use-without-require: local_names sees locals, parameters and loop variables', function ()
    local s = ur.local_names(table.concat({
        'local a, b = 1, 2', 'local function f(p, q) end', 'return function (M, SHARED) end',
        'for k, v in pairs(t) do end', 'for i = 1, 3 do end', 'x = 1' }, '\n'))
    for _, n in ipairs({ 'a', 'b', 'f', 'p', 'q', 'M', 'SHARED', 'k', 'v', 'i' }) do
        ok(s[n], n .. ' is bound')
    end
    ok(not s.x, 'a bare assignment is a global')
end)
