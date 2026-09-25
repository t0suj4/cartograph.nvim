-- CART-1057 remedy 4: INDEX A SCAN (lua/cartograph/idxrewrite.lua). An equality-filter loop over a list
-- that is scanned again and again iterates the key's bucket instead; the `if` stays, the key's type is
-- guarded, the cache is rebuilt when the list grows. Acceptance: a DIFFERENTIAL harness — the original
-- and the rewritten file, loaded side by side, answer the same on randomized workloads (appends between
-- calls, keys and fields of every type: strings, 1 vs 1.0, NaN, booleans, nil, tables).

local I = require 'cartograph.idxrewrite'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local txn = require 'cartograph.txn'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/idxrewrite'

local function has_lua()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local PLAN, BEFORE, AFTER
local function planned()
    if PLAN then return PLAN, BEFORE, AFTER end
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
    vim.fn.writefile(vim.fn.readfile(FIX .. '/scans.lua'), dir .. '/scans.lua')
    store.ingest(ts.extract(dir))
    PLAN = assert(I.plan(store, 'scans.lua'))
    local b, a = txn.dryrun(store, PLAN)
    BEFORE, AFTER = b['scans.lua'], a['scans.lua']
    return PLAN, BEFORE, AFTER
end

test('idxrewrite: the repeated scans of a SHARED or PARAMETER list are rewritten; every other near miss says why', function ()
    if not has_lua() then skip 'no lua parser' end
    local plan = planned()
    local got = {}
    for _, m in ipairs(plan.moves) do got[#got + 1] = m.line .. ':' .. m.sharing .. ':' .. m.field end
    eq({ '10:shared:name', '24:param:kind' }, got)
    local why = {}
    for _, d in ipairs(plan.declined) do why[d.line] = d.reason end
    ok(why[37] and why[37]:find('field of a parameter'), tostring(why[37]))
    ok(why[49] and why[49]:find('not repeated'), tostring(why[49]))
    ok(why[57] and why[57]:find('else'), tostring(why[57]))
    ok(why[64] and why[64]:find('reads the element'), tostring(why[64]))
    ok(why[73] and why[73]:find('reassigned'), 'the key field is reassigned in the file: ' .. tostring(why[73]))
    ok(why[83] and why[83]:find('replaced'), 'an element is replaced in place: ' .. tostring(why[83]))
end)

test('idxrewrite: ★ DIFFERENTIAL — the rewritten file answers like the original on randomized workloads', function ()
    if not has_lua() then skip 'no lua parser' end
    local _, before, after = planned()
    ok(after:find('cg_bucket(registry, "name", name) or registry', 1, true), 'the shared scan is rewritten')
    local A = assert(loadstring(before))()
    local B = assert(loadstring(after))()
    local seed = 1057
    local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
    local nan = 0 / 0
    local shared_tbl = {}
    local VALUES = { 'a', 'b', 'c', 1, 1.0, 2, -0, 0, true, false, nan, shared_tbl, {} }
    local function val() local k = rnd(#VALUES + 1); return VALUES[k] end -- k = #VALUES+1 -> nil
    local list = {}
    local function mk()
        return { name = val(), kind = val(), k = val(), alias = val() }
    end
    local compared = 0
    for round = 1, 60 do
        -- grow both registries and the shared parameter list with the SAME element objects
        for _ = 1, 1 + rnd(8) do
            local e = mk()
            A.register(e); B.register(e); list[#list + 1] = e
        end
        local keys = {}
        for _ = 1, 12 do keys[#keys + 1] = val() end
        local a1, b1 = A.first_each(keys), B.first_each(keys)
        local a2, b2 = A.count_each(list, keys), B.count_each(list, keys)
        for i = 1, #keys do
            if a1[i] ~= b1[i] then error(('first_each round %d key %s'):format(round, tostring(keys[i]))) end
            if a2[i] ~= b2[i] then error(('count_each round %d key %s: %s vs %s'):format(round, tostring(keys[i]), tostring(a2[i]), tostring(b2[i]))) end
            compared = compared + 2
        end
    end
    ok(compared >= 1000, 'answers compared: ' .. compared)
end)

test('idxrewrite: the cache is rebuilt when the list GROWS (a stale bucket would miss the new element)', function ()
    if not has_lua() then skip 'no lua parser' end
    local _, _, after = planned()
    local B = assert(loadstring(after))()
    local e1 = { name = 'x' }
    B.register(e1)
    eq(e1, B.first_each({ 'x' })[1])
    eq(false, B.first_each({ 'y' })[1])   -- builds and caches the 'name' buckets
    local e2 = { name = 'y' }
    B.register(e2)
    eq(e2, B.first_each({ 'y' })[1], 'the appended element is found: the length change rebuilt the index')
end)

test('idxrewrite: ★ PROFILE-GUIDED — the measured CPU-for-memory trade decides, not the static guess', function ()
    if not has_lua() then skip 'no lua parser' end
    local src = table.concat(vim.fn.readfile(FIX .. '/scans.lua'), '\n')
    local probed, sites = I.instrument(src)
    ok(#sites >= 4, 'candidate sites probed: ' .. #sites)
    rawset(_G, '__cg_idx_profile', nil)
    local M = assert(loadstring(probed))()
    -- the workload: a big shared registry looked up many times; a tiny parameter list counted a few
    -- times; `once` run once
    for i = 1, 400 do M.register({ name = 'n' .. i, kind = i % 3 }) end
    local keys = {}
    for i = 1, 300 do keys[#keys + 1] = 'n' .. (i * 7 % 450) end
    M.first_each(keys)
    M.count_each({ { kind = 1 }, { kind = 2 } }, { 1, 2 })
    M.once({ { name = 'a' } }, 'a')
    local prof = rawget(_G, '__cg_idx_profile')
    local big = prof[10]
    ok(big and big.calls == 300 and big.distinct == 1 and big.distinct_len == 400, vim.inspect(big and { big.calls, big.distinct, big.distinct_len }))
    local apply, d = I.decide(big)
    ok(apply and d.ratio > 4 and d.memory == 400, vim.inspect(d))
    local tiny_apply, tiny = I.decide(prof[24])
    ok(not tiny_apply and tiny.why:find('not worth'), 'a tiny list scanned twice is not worth an index: ' .. vim.inspect(tiny))
    local once_apply = I.decide(prof[49])
    ok(not once_apply, 'run once')
    -- and the plan follows the measurement: the big scan in, the tiny one out, with the numbers
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
    vim.fn.writefile(vim.fn.readfile(FIX .. '/scans.lua'), dir .. '/scans.lua')
    store.ingest(ts.extract(dir))
    local plan = assert(I.plan(store, 'scans.lua', { profile = prof }))
    eq(1, #plan.moves); eq(10, plan.moves[1].line)
    ok(plan.moves[1].repeated:find('measured: 300 calls'), plan.moves[1].repeated)
    local why = {}
    for _, dd in ipairs(plan.declined) do why[dd.line] = dd.reason end
    ok(why[24] and why[24]:find('^profile:'), tostring(why[24]))
    rawset(_G, '__cg_idx_profile', nil)
end)
