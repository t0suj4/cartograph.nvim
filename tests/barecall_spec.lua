-- BARE CALLS AND MULTI-ASSIGNMENT ALIASES (CART-1487, CART-1488). Lua has no implicit receiver: a bare `tonumber(x)` is
-- the builtin, never some file's `T.tonumber` field function — the resolver's tail join linked 714 such calls on lua/
-- to a wrong definition and refused ~3,100 more as ambiguous. And a multi-assignment handed every name the FIRST
-- value, so `local pack, getter = lib.pack, lib.reader` aliased getter to pack. Pinned both ways: a single-name alias
-- still resolves. (`lib.FAMILIES.tonumber(s)` — a nested field through the alias — is refused `blocked`: CART-1489.)

local ts = require 'cartograph.providers.treesitter'

local FILES = {
    ['lib.lua'] = table.concat({
        'local M = {}',
        'M.FAMILIES = {}',
        'function M.FAMILIES.tonumber(x) return x end',
        'function M.pack(x) return x end',
        'function M.reader(x) return x end',
        'function M.make() return 1, 2 end',
        'function M.shut(h) return h end',
        'local P = {}',
        'function P:open() return self end',
        'return M', '' }, '\n'),
    ['use.lua'] = table.concat({
        'local lib = require("lib")',
        'local pack, getter = lib.pack, lib.reader',
        'local one = lib.reader',
        'local first, second = lib.make()',
        'local M = {}',
        'function M.go(s)',
        '  local n = tonumber(s)',
        '  local q = lib.FAMILIES.tonumber(s)',
        '  local fd = io.open(s); fd:shut(); fd:open()',
        '  return pack(n), getter(n), one(n), second(n)',
        'end',
        'return M', '' }, '\n'),
}

local function extract()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, src in pairs(FILES) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close() end
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local cv = require('cartograph.callview').of(data)
    local by = {}
    for i = 1, cv.n do
        local k = cv.get(i, 'full') or cv.get(i, 'callee')
        local r = cv.get(i, 'refused')
        by[k] = { to = cv.get(i, 'to'), refused = type(r) == 'table' and r.rule or r, ext = cv.get(i, 'ext') }
    end
    return by
end

test('bare call: Lua `tonumber(x)` is the builtin — never a qualified `T.tonumber` of another file: no link, no ambiguity, an EXTERNAL disposition (CART-1487)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local by = extract()
    eq(nil, by.tonumber.to, 'the bare builtin links to no project definition')
    eq(nil, by.tonumber.refused, 'and is not refused as ambiguous either')
    ok(by.tonumber.ext ~= nil, 'it is disposed as external')
end)

test('multi-assignment: name i takes value i — `local pack, getter = lib.pack, lib.reader` aliases each to its own member; a name past the last value is no alias (CART-1488)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local by = extract()
    eq('lib.lua::M.pack@3', by.pack.to)
    eq('lib.lua::M.reader@4', by.getter.to, 'the SECOND name, the second value')
    eq('lib.lua::M.reader@4', by.one.to, 'a single-name alias still resolves')
    eq(nil, by.second.to, '`local first, second = lib.make()`: second is make\'s second return, no alias')
end)
test('method call: Lua `fd:shut()` cannot reach a plain `M.shut(h)` — the colon passes fd as self — so the name-only link is VETOED to a blocked refusal; a real method `P:open` is still reached (CART-1491)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local by = extract()
    eq(nil, by['fd:shut'].to, 'no edge to a plain function')
    eq('blocked', by['fd:shut'].refused, 'refused by name: a candidate exists and cannot receive the call')
    eq('lib.lua::P:open@8', by['fd:open'].to)
end)

test('method call and bare call: an INCREMENTAL refresh decides the same way — the relink path is a second copy of the resolver (CART-1487, CART-1491)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, src in pairs(FILES) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close() end
    store.ingest(ts.extract(root))
    local fd = assert(io.open(root .. '/use.lua', 'w')); fd:write((FILES['use.lua']:gsub('return M', '-- edited\nreturn M'))); fd:close()
    assert(require('cartograph.refresh').files({ 'use.lua' }, { incremental = true }))
    local cv = require('cartograph.callview').of(store.data)
    local by = {}
    for i = 1, cv.n do
        local r = cv.get(i, 'refused')
        by[cv.get(i, 'full') or cv.get(i, 'callee')] = { to = cv.get(i, 'to'), refused = type(r) == 'table' and r.rule or r }
    end
    vim.fn.delete(root, 'rf')
    eq(nil, by['fd:shut'].to); eq('blocked', by['fd:shut'].refused)
    eq(nil, by.tonumber.to); eq(nil, by.tonumber.refused)
end)
