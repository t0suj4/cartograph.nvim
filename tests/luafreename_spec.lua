-- CART-2128: a bare Lua name FREE at its call site — no binder in any enclosing scope — is a global, so it never
-- reaches a def whose syntax made it a LOCAL. The function-level picks could not see blocks: a call after
-- `if … local function h … end` reached that h with prov `base`, as did a call made before its `local function`, and
-- `lv()` inside `local lv = function () return lv() end` (which reads the OUTER lv). The scope model says FREE (cfree);
-- a forward declaration (`local walk; walk = function`) is BOUND by name, cb nil but not free, and keeps its edge.

local ts = require 'cartograph.providers.treesitter'

local SRC = table.concat({
    'local M = {}',                                                          -- 0
    'local function rec(n) if n > 0 then return rec(n - 1) end return 0 end', -- 1  bound: recursion
    'local fwd',                                                             -- 2
    'function fwd() return 1 end',                                           -- 3
    'local function user() return fwd() + rec(2) end',                       -- 4  fwd: forward-declared, bound
    'local lv = function () return lv() end',                                -- 5  FREE: the outer lv
    'local function early() return later() end',                             -- 6  FREE: later is declared below
    'local function later() return 2 end',                                   -- 7
    'function glob() return 3 end',                                          -- 8
    'local function useglob() return glob() end',                            -- 9  free, but glob is global: kept
    'for i = 1, 2 do',                                                       -- 10
    '    local function inloop() return i end',                              -- 11
    '    inloop()',                                                          -- 12 bound inside the loop
    'end',                                                                   -- 13
    'local function afterloop() return inloop() end',                        -- 14 FREE: after the loop
    'local walk',                                                            -- 15
    'walk = function (t) if t then return walk(nil) end end',                -- 16 forward-declared by assignment: bound
    'M.user, M.early, M.afterloop, M.useglob, M.walk = user, early, afterloop, useglob, walk',
    'return M',
}, '\n') .. '\n'

local function tree()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    return root
end
local function by_line(data)
    local out = {}
    for _, c in ipairs(data.calls) do out[c.line .. ' ' .. c.callee] = c end
    return out
end
local function check(data, how)
    local c = by_line(data)
    eq('m.lua::rec@1', c['1 rec'].to, how .. ': recursion inside local function')
    eq('m.lua::fwd@3', c['4 fwd'].to, how .. ': a forward declaration')
    eq('m.lua::rec@1', c['4 rec'].to, how)
    eq('m.lua::glob@8', c['9 glob'].to, how .. ': a free name reaches a GLOBAL def')
    eq('m.lua::inloop@11', c['12 inloop'].to, how .. ': inside the loop')
    eq('m.lua::walk@16', c['16 walk'].to, how .. ': `local walk; walk = function` is bound by name')
    for _, k in ipairs { '5 lv', '6 later', '14 inloop' } do
        eq(nil, c[k].to, how .. ': ' .. k .. ' is free there: ' .. tostring(c[k].to))
        eq('blocked', c[k].refused and c[k].refused.rule, how .. ': ' .. k)
    end
end

test('lua free name: a call where the name is unbound never reaches a block-local / later-local def (CART-2128)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree()
    local data = ts.extract(root); data.root = root
    local c = by_line(data)
    eq(true, c['14 inloop'].cfree, 'the scope model says free')
    eq(nil, c['16 walk'].cfree, 'a forward declaration is a binder')
    eq(nil, c['12 inloop'].cfree)
    check(data, 'extract')
    for _, x in ipairs(data.calls) do x.to = nil; x.refused = nil; x.prov = nil end
    ts.relink(data)
    check(data, 'relink')
    vim.fn.delete(root, 'rf')
end)

test('lua free name: parallel extraction agrees (CART-2128)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree()
    local done
    require('cartograph.parallel').extract(root, { workers = 2, on_done = function (d) done = d end })
    vim.wait(120000, function () return done ~= nil end, 50)
    ok(done, 'parallel finished')
    check(done, 'parallel')
    vim.fn.delete(root, 'rf')
end)

test('lua free name: only a spec that declares free_names_skip_locals vetoes (CART-2128)', function ()
    local t = { id = 'x.go::f@1', file = 'x.go', exported = false }
    eq(nil, ts._callee_veto(t, nil, nil, nil, 'x.go', true), 'go: exported == false is a lowercase name, visible package-wide')
    local l = { id = 'x.lua::f@1', file = 'x.lua', exported = false }
    eq('blocked', ts._callee_veto(l, nil, nil, nil, 'x.lua', true).rule)
    eq(nil, ts._callee_veto(l, nil, nil, nil, 'x.lua', nil), 'not free: no veto')
    eq(nil, ts._callee_veto({ id = 'x.lua::g@1', file = 'x.lua', exported = true }, nil, nil, nil, 'x.lua', true), 'a global def')
    eq(nil, ts._callee_veto(l, nil, nil, nil, 'y.lua', true), 'another file\'s local: CART-0230 confinement decides')
end)
