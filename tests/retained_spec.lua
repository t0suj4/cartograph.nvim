-- retained.lua: state outliving a call, grown by it, never shrunk (metric #3 after loopcost's two units).
-- Fixture: tests/fixtures/retained/{growth,other}.lua. ★ The positive arms are also RUN: after a full
-- collection, what a grower leaves behind must rise with the number of calls, and the weak table's
-- must not (a static "no finding" there is right for a reason the text alone does not show).

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local retained = require 'cartograph.retained'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/retained'

local function has_lua()
    return pcall(vim.treesitter.language.add, 'lua')
end

local R
local function analyze()
    if R then return R end
    local data = ts.extract(FIX)
    store.ingest(data)
    R = retained.analyze(store, data)
    return R
end
local function by_container(name)
    for _, f in ipairs(analyze().findings) do if f.container == name then return f end end
end

test('retained: a private log (append) and a private memo (keyed) grow and are never shrunk', function ()
    if not has_lua() then skip 'no lua parser' end
    local log = by_container('log')
    ok(log, 'log')
    eq('append', log.how)
    eq('private', log.class)
    local memo = by_container('cache')
    ok(memo, 'cache')
    eq('keyed', memo.how)
    eq('private', memo.class)
    ok(retained.text(log):find('M.record@7 append', 1, true), retained.text(log))
    local ev = by_container('events')
    ok(ev and ev.how == 'append', 'table.insert grows `events`')
end)

test('retained: a flush, an eviction, a weak table, the call\'s own table, a fixed slot — no finding', function ()
    if not has_lua() then skip 'no lua parser' end
    for _, name in ipairs({ 'pending', 'lru', 'weak', 't', 'state', 'q', 'out', 'idx', 'idx[]', 'path' }) do
        eq(nil, by_container(name), name)
    end
end)

test('retained: a returned module\'s field is exported; a reset of the same field NAME in another file suppresses', function ()
    if not has_lua() then skip 'no lua parser' end
    local reg = by_container('M.registry')
    ok(reg, 'M.registry')
    eq('exported', reg.class)
    eq(nil, by_container('M.handlers'), 'other.lua resets `handlers`')
    local g = by_container('seen_all')
    ok(g, 'seen_all')
    eq('global', g.class)
    eq(5, #analyze().findings, 'log, cache, M.registry, seen_all, events')
    ok(analyze().stats.suppressed >= 5, 'pending, lru, weak, M.handlers, q: ' .. analyze().stats.suppressed)
end)

test('retained: ★ the ORACLE — what a flagged grower retains after a full collection rises with its calls', function ()
    local F = dofile(FIX .. '/growth.lua')
    _G.seen_all = {}
    -- GROWTH BETWEEN BATCHES, not what is kept: a weak table keeps its hash CAPACITY after its keys
    -- are collected (~97 KB after 4000 at once), a high-water mark that does not climb. Four batches,
    -- a full collection after each; the growth is batch 4 minus batch 2.
    local function kept(call, n)
        local at = {}
        for b = 1, 4 do
            for i = 1, n do call(b * n + i) end
            collectgarbage('collect'); collectgarbage('collect')
            at[b] = collectgarbage('count')
        end
        return at[4] - at[2]
    end
    local per = {
        record = function(i) F.record('r' .. i) end,
        memo = function(i) F.memo('m' .. i) end,
        register = function(i) F.register('g' .. i) end,
        see = function(i) F.see('s' .. i) end,
        emit = function(i) F.emit('e' .. i) end,
        tag = function() F.tag({}) end,                 -- weak: the key is garbage at once
        build = function(i) F.build({ i, i + 1 }) end,  -- the call's own table
    }
    for name, call in pairs(per) do
        local kb = kept(call, 2000)
        local flagged = name ~= 'tag' and name ~= 'build'
        if flagged then ok(by_container(({ record = 'log', memo = 'cache', register = 'M.registry', see = 'seen_all', emit = 'events' })[name]),
            name .. ' is also flagged statically') end
        if flagged then ok(kb > 40, ('%s grew %.1f KB over two batches of 2000 calls: it should'):format(name, kb))
        else ok(kb < 8, ('%s grew %.1f KB over two batches of 2000 calls: it should not'):format(name, kb)) end
    end
    _G.seen_all = nil
end)
