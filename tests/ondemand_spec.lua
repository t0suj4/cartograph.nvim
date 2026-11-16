-- CART-1938: profiles extracted ON DEMAND, not packaged per version. A Factorio NAME profile is the hand environment
-- over ONE api artifact, so `lua-factorio-<v>` is DERIVED wherever `lua-factorio-api-<v>` loads — shipped, or distilled
-- into the on-demand directory for a port (BNW: runtime-api.json 2.1.8). classmatch's api set is derived the same way
-- (it was a fixed three-name list), and a missing version OFFERS its distillation. Measured: BNW 2.0 -> 2.1 through
-- mcpserve returns exactly control.lua:709 / :711 as signature-changed / breaks.
-- ⚠ Every test points the on-demand directory at a TEMP dir: the default is the user's data dir.

local pm    = require 'cartograph.spec.profile'
local cm    = require 'cartograph.classmatch'
local port  = require 'cartograph.portability'
local agent = require 'cartograph.agent'
local store = require 'cartograph.store'
local ts    = require 'cartograph.providers.treesitter'

local function dec(path) local f = assert(io.open(path, 'rb')); local t = vim.mpack.decode(f:read('a')); f:close(); return t end
local function put(path, t) local f = assert(io.open(path, 'wb')); f:write(vim.mpack.encode(t)); f:close() end

-- a synthetic "2.7" api distilled on demand: the shipped 2.0 artifact with its version moved and one method's
-- parameters changed as 2.1 changed set_quick_bar_slot
local function with_ondemand(fn, mutate)
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
    local api = dec(pm.DIR .. '/lua-factorio-api-20.mpack')
    api.version, api.runtime = '2.7.0', 'lua-factorio-api-27'
    api.params['LuaPlayer::set_quick_bar_slot'] = { p = { { n = 'page_index', o = false }, { n = 'slot_index', o = false },
        { n = 'filter', o = false } }, tt = false, va = false }
    if mutate then mutate(api) end
    put(dir .. '/lua-factorio-api-27.mpack', api)
    local prev = pm.ONDEMAND
    pm.ONDEMAND = dir
    local ok, err = pcall(fn, dir)
    pm.ONDEMAND = prev
    vim.fn.delete(dir, 'rf')
    assert(ok, err)
end

test('ondemand: a name profile is DERIVED over an on-demand api artifact — loaded, listed, in its ecosystem, never an extraction environment (CART-1938)', function ()
    if not (pm.load('lua-factorio-api-20') or {}).params then skip 'no parameter lists in the shipped api' end
    with_ondemand(function ()
        local p = assert(pm.load('lua-factorio-27'), 'derived')
        eq('2.7.0', p.version); eq('lua-factorio-27', p.runtime)
        eq({ from = 'lua-factorio-api-27', base = 'lua-factorio' }, p.derived)
        eq('LuaGameScript', p.global2class.game, 'the api surface republished, as the base does')
        local okenv, why = pm.env_usable('lua-factorio-27')
        eq(nil, okenv); ok(why:match('DERIVED'), why)
        local _, econame = require('cartograph.spec.ecosystem').for_profile('lua-factorio-27')
        eq('lua-factorio', econame, 'its ecosystem by a declaration, not its spelling')
        ok(vim.tbl_contains(port.runtimes(), 'lua-factorio-27'), 'a target like a shipped one')
        ok(vim.tbl_contains(port.runtimes(), 'lua-factorio-api-27'))
        local arts = cm.artifacts()
        eq('lua-factorio-api', arts[1], 'the live api stays first')
        eq('lua-factorio-api-27', arts[#arts], 'the on-demand one after the shipped ones')
        eq('lua-factorio-api-27', (port.artifact_for('2.7.0')), 'and the class table for its minor is found')
    end)
end)

test('ondemand: the shipped 2.0 derives to the same profile as lua-factorio, only named differently (CART-1938)', function ()
    local a, b = pm.load('lua-factorio'), pm.load('lua-factorio-20')
    ok(a and b, 'both load')
    eq('lua-factorio-20', b.runtime); eq(a.version, b.version)
    eq(vim.tbl_count(a.api_members or {}), vim.tbl_count(b.api_members or {}))
    eq(a.global2class, b.global2class); eq(a.nsset, b.nsset); eq(a.free, b.free)
end)

test('ondemand: FENCED — an api whose global objects differ from the base\'s is not derived over the hand environment (CART-1938)', function ()
    with_ondemand(function ()
        eq(nil, pm.load('lua-factorio-27'))
        local _, why = pm.derive('lua-factorio-27')
        ok(why:match('hand delta'), why)
    end, function (api) api.global2class.quantum = 'LuaQuantum' end)
end)

test('ondemand: portability_sites 2.0 -> an on-demand version — a kept method whose parameters changed BREAKS at its site (CART-1938)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    if not (pm.load('lua-factorio-api-20') or {}).params then skip 'no parameter lists in the shipped api' end
    with_ondemand(function ()
        local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
        local fd = assert(io.open(root .. '/control.lua', 'w'))
        fd:write('local M = {}\nfunction M.bar(player)\n  player.set_quick_bar_slot(1, "iron-plate")\n  player.teleport({0, 0})\nend\nreturn M\n')
        fd:close()
        local data = ts.extract(root); data.root = root
        store.ingest(data)
        local a = agent.answer(store, 'portability_sites', { from = 'lua-factorio', to = 'lua-factorio-27' })
        eq(true, a.ok, vim.inspect(a.refusal))
        eq('2.7.0', a.subject.class_tables.to_version)
        local r = a.result[1]
        eq({ 3, 'signature-changed', 'breaks', '(page_index, slot_index, filter)' }, { r.line, r.verdict, r.arity, r.signature.to })
        eq('kept', a.result[2].verdict)
        vim.fn.delete(root, 'rf')
    end)
end)

test('ondemand: a version not distilled is unavailable and OFFERS the distillation, never a fetch (CART-1938)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    with_ondemand(function (dir)
        local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
        local fd = assert(io.open(root .. '/control.lua', 'w')); fd:write('game.print("x")\n'); fd:close()
        local data = ts.extract(root); data.root = root
        store.ingest(data)
        local a = agent.answer(store, 'portability_sites', { from = 'lua-factorio', to = 'lua-factorio-29' })
        eq('unavailable', a.absence); eq('no-such-profile', a.absence_why.premise)
        local o = a.absence_why.evidence.offers[1]
        eq({ 'lua-factorio-29', 'lua-factorio-api-29', dir }, { o.profile, o.api, o.ondemand })
        ok(o.from_file:match('factoriodistill%.lua') and o.from_file:find(dir, 1, true), o.from_file)
        vim.fn.delete(root, 'rf')
    end)
end)

test('ondemand: a derived profile\'s stamp is its api artifact\'s and its builder\'s — an edited on-demand api reloads it (CART-1938)', function ()
    with_ondemand(function (dir)
        local s1 = assert(pm.stamp_of('lua-factorio-27'))
        ok(s1:match('^derived:'), s1)
        local api = dec(dir .. '/lua-factorio-api-27.mpack')
        api.version = '2.7.1'
        api.pad = string.rep('x', 64) -- (a different size: the stamp is mtime + size)
        put(dir .. '/lua-factorio-api-27.mpack', api)
        ok(pm.stamp_of('lua-factorio-27') ~= s1, 'the stamp moved')
        eq('2.7.1', pm.load('lua-factorio-27').version, 'and the memo recomputed')
    end)
end)
