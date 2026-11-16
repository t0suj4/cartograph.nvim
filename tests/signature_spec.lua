-- CART-1934: a name KEPT with a new signature scored `kept`. get/set_quick_bar_slot went (index[, filter]) ->
-- (page_index, slot_index[, filter]) in Factorio 2.1 (BNW's control.lua:709 / :711 break), and nothing said so. The api
-- artifacts now carry every class method's parameters in call order (tools/factoriodistill.lua `params`); portability
-- compares them and checks each call SITE's argument count. Measured on Von-Neumann 1.1 -> 2.0: two
-- `surface.spill_item_stack(pos, items, …)` calls BREAK (2.0 takes one table) — the hand-made port guide missed both.

local port  = require 'cartograph.portability'
local agent = require 'cartograph.agent'
local store = require 'cartograph.store'
local ts    = require 'cartograph.providers.treesitter'

local function P(spec, tt, va)
    local p = {}
    for name, opt in spec:gmatch('([%w_]+)(%??)') do p[#p + 1] = { n = name, o = opt == '?' } end
    return { p = p, tt = tt or false, va = va or false }
end

test('signature: the BNW break — (index, filter) -> (page_index, slot_index, filter) breaks a 2-argument call (CART-1934)', function ()
    -- the records as factoriodistill emits them from the 2.0.77 / 2.1.8 runtime-api.json (positions from `order`)
    local set20, set21 = P('index filter'), P('page_index slot_index filter')
    local v, d = port.signature_verdict(set20, set21)
    eq('signature-changed', v); eq('(index, filter)', d.from); eq('(page_index, slot_index, filter)', d.to)
    eq({ 'page_index', 'slot_index' }, d.added); eq({ 'index' }, d.removed); eq(false, d.compatible)
    eq('breaks', (port.arity_fit(set20, set21, 2)))
    eq('breaks', (port.arity_fit(P('index'), P('page_index slot_index'), 1)), 'get_quick_bar_slot(1)')
    eq('signature-same', (port.signature_verdict(P('a b?'), P('a b?'))))
end)

test('signature: what is NOT a break — an optional tail, a renamed argument in place; what is unknown (CART-1934)', function ()
    local tp11, tp20 = P('position surface? raise_teleported?'), P('position surface? raise_teleported? snap_to_grid? build_check_type?')
    local _, d = port.signature_verdict(tp11, tp20)
    eq(true, d.compatible, 'teleport only gained optional parameters')
    eq('fits', (port.arity_fit(tp11, tp20, nil)), 'compatible: any call that fit before fits now, whatever its count')
    eq('fits', (port.arity_fit(P('surface position'), P('surface chunk_position'), 2)), 'a parameter renamed in place is the same argument')
    eq('shifted', (port.arity_fit(P('a? b?'), P('x? a? b?'), 1)), 'an insertion BEFORE a written argument moves it')
    eq('breaks', (port.arity_fit(P('a b?'), P('x? a b?'), 1)), 'and when it makes the moved one required at a later position, a 1-argument call breaks')
    eq('unknown', (port.arity_fit(P('a b'), P('c d e'), 4)), 'a call that did not fit the OLD parameters either says nothing')
    eq('unknown', (port.arity_fit(P('a b'), P('a b c'), nil)), 'an unknown count decides nothing')
    -- tables: positional -> ONE table breaks a multi-argument call; table -> table compares keys
    eq('breaks', (port.arity_fit(P('position items enable_looted? force? allow_belts?'), P('position stack enable_looted?', true), 5)))
    eq('unknown', (port.arity_fit(P('position items'), P('position stack', true), 1)), 'one argument: whether it is the table, its keys decide')
    eq('fits', (port.arity_fit(P('type name?', true), P('type name? locked?', true), 1)), 'a table gaining an optional key breaks nothing')
    eq('unknown', (port.arity_fit(P('return_item_request_proxy? raise_revive?', true), P('raise_revive? overflow?', true), 1)), 'a key removed: only the call\'s keys can tell')
end)

test('signature: a method\'s parameters are found on the class or the nearest ancestor declaring it, in the shipped artifacts (CART-1934)', function ()
    local pm = require 'cartograph.spec.profile'
    local a20 = pm.load('lua-factorio-api-20')
    if not (a20 and a20.params) then skip 'the 2.0 api artifact carries no parameter lists' end
    local r, owner = port.method_params(a20, 'LuaPlayer', 'teleport')
    eq('LuaControl', owner, 'teleport is LuaControl\'s, inherited by LuaPlayer')
    eq('position', r.p[1].n); eq(false, r.p[1].o)
    local q = port.method_params(a20, 'LuaPlayer', 'set_quick_bar_slot')
    eq({ 'index', 'filter' }, { q.p[1].n, q.p[2].n }, 'in CALL order — v6 lists them alphabetically, `order` is the position')
    eq(true, port.method_params(a20, 'LuaSurface', 'spill_item_stack').tt, '2.0 takes one table')
end)

test('portability_sites: a kept method whose parameters changed is signature-changed at a site it breaks, kept where it still fits; the stdlib is not a method (CART-1934)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local pm = require 'cartograph.spec.profile'
    if not ((pm.load('lua-factorio-api-11') or {}).params and (pm.load('lua-factorio-api-20') or {}).params) then skip 'no parameter lists' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/control.lua', 'w'))
    fd:write(table.concat({
        'local M = {}',
        'function M.drop(surface, player, x, y)',
        '  surface.spill_item_stack({x, y}, {name = "iron-plate", count = 1}, false, nil, false)', -- 3: breaks (one table now)
        '  player.teleport({x, y})',                                                               -- 4: kept: only optional params added
        '  local i = string.find("ab", "b")',                                                      -- 5: the language's own library
        'end',
        'return M', '' }, '\n'))
    fd:close()
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local a = agent.answer(store, 'portability_sites', { from = 'lua-factorio-11', to = 'lua-factorio' })
    local by = {}
    for _, r in ipairs(a.result) do by[r.line] = r end
    eq({ 'signature-changed', 'breaks' }, { by[3].verdict, by[3].arity })
    ok(by[3].signature.to:match('^{position, stack'), 'the new form: ' .. tostring(by[3].signature.to))
    eq({ 'kept', vim.NIL }, { by[4].verdict, by[4].signature }, 'a compatible change is no signature finding')
    eq(vim.NIL, by[5].signature, 'string.find is no Factorio class\'s `find`')
    eq(1, a.subject.by_site['signature-changed'])
    eq(1, a.subject.signatures.by_arity.breaks)
    local g
    for _, n in ipairs(a.notes) do if n.kind == 'verdict-is-the-names' then g = n end end
    eq({ 'behaviour-changed' }, g.evidence.not_measured, 'signatures are measured now; behaviour is not')
    vim.fn.delete(root, 'rf')
end)

test('call_nargs: a multi-valued last argument is an unknown count; a `:` call\'s receiver is not an argument (CART-1934)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nfunction M.f(o, ...)\n  o.a(1, 2)\n  o.b(1, g())\n  o.c(...)\n  o:d(1)\nend\nreturn M\n'); fd:close()
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local n = {}
    for _, c in ipairs(store.data.calls) do if c.full and c.full:match('^o[.:]') then n[c.full:sub(3)] = port.call_nargs(c) or 'unknown' end end
    eq({ a = 2, b = 'unknown', c = 'unknown', d = 1 }, n)
    vim.fn.delete(root, 'rf')
end)

test('factoriodistill: parameters are emitted in CALL order (v6 `order`), not the document\'s alphabetical array order, into the directory asked (CART-1934)', function ()
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(dir .. '/api.json', 'w'))
    fd:write(vim.json.encode({ application = 'factorio', stage = 'runtime', application_version = '9.9.9', api_version = 6,
        classes = { { name = 'LuaThing', attributes = {}, methods = {
            { name = 'set_slot', format = { takes_table = false }, parameters = {
                { name = 'filter', order = 1, optional = false, type = 'string' },
                { name = 'index', order = 0, optional = false, type = 'uint' } } },
            { name = 'build', format = { takes_table = true }, parameters = { { name = 'name', order = 0, optional = false, type = 'string' } } } } } },
        global_objects = { { name = 'thing', type = 'LuaThing' } }, global_functions = {}, defines = {} }))
    fd:close()
    local r = vim.system({ 'nvim', '--headless', '-u', 'NONE', '-l', 'tools/factoriodistill.lua', dir .. '/api.json', 'spec', '', dir }, { text = true }):wait()
    eq(0, r.code, r.stderr)
    local f = assert(io.open(dir .. '/lua-factorio-api-spec.mpack', 'rb'))
    local art = vim.mpack.decode(f:read('a')); f:close()
    local p = art.params['LuaThing::set_slot']
    eq({ 'index', 'filter' }, { p.p[1].n, p.p[2].n })
    eq(true, art.params['LuaThing::build'].tt, 'v6 `format.takes_table`')
    vim.fn.delete(dir, 'rf')
end)

test('portability_sites: a name a PROFILE kept whose root is no api global is never matched to a class method by name (CART-1934)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/control.lua', 'w'))
    fd:write('local M = {}\nfunction M.f()\n  return string.find("ab", "b")\nend\nreturn M\n'); fd:close()
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    -- `find` IS a class method (LuaEquipmentGrid::find); made incompatible here so a by-name match would be a finding
    local real = port.method_params
    port.method_params = function (art, cls, m)
        if m == 'find' then return { p = { { n = art.version:match('^1') and 'a' or 'b', o = false } }, tt = false, va = false }, cls end
        return real(art, cls, m)
    end
    local okc, a = pcall(agent.answer, store, 'portability_sites', { from = 'lua-factorio-11', to = 'lua-factorio' })
    port.method_params = real
    assert(okc, a)
    local row = a.result[1]
    eq('string.find', row.name); eq('kept', row.verdict); eq(vim.NIL, row.signature)
    vim.fn.delete(root, 'rf')
end)
