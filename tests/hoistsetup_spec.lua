-- hoistsetup.lua: the WRITE STEP of redundancy.lua — the hoisted fact inserted once into the prelude, the redundant
-- copies deleted (with an emptied guard and an unused local), declines by name. Runs on a COPY of
-- tests/fixtures/redundancy/plain (the plan writes files), then re-analyses the result.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local txn = require 'cartograph.txn'
local hoistsetup = require 'cartograph.hoistsetup'
local redundancy = require 'cartograph.redundancy'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/redundancy/plain'

local function has_lua()
    return pcall(vim.treesitter.language.add, 'lua')
end
local function copy_fixture()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, 'p')
    for _, f in ipairs(vim.fn.readdir(FIX)) do vim.fn.writefile(vim.fn.readfile(FIX .. '/' .. f), d .. '/' .. f) end
    return d
end
local function load(d)
    local data = ts.extract(d)
    store.ingest(data)
    return data
end

test('hoistsetup: the plan inserts the modal statement ONCE before the prelude\'s load loop and deletes every copy', function ()
    if not has_lua() then skip 'no lua parser' end
    local d = copy_fixture()
    load(d)
    local plan, why = hoistsetup.plan(store)
    ok(plan, tostring(why))
    eq('run.lua', plan.prelude)
    eq({ 'a_spec.lua', 'b_spec.lua', 'e_spec.lua', 'run.lua' }, plan.touched)
    eq(0, #plan.declined)
    local before, after = txn.dryrun(store, plan)
    ok(before, tostring(after))
    local run = after['run.lua']
    local blk = run:find('COMMON SETUP', 1, true)
    ok(blk and blk > run:find('function _G.test', 1, true) and blk < run:find('for _, f in ipairs', 1, true),
        'the block sits between the entry and the load loop:\n' .. run)
    ok(run:find("local TSDIR = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')", 1, true), 'its argument\'s local, inside do..end')
    local a = after['a_spec.lua']
    eq(nil, a:find('rtp:append(TSDIR)', 1, true), 'every copy in a_spec is gone:\n' .. a)
    ok(a:find("vim.opt.rtp:append(vim.fn.expand('~/other'))", 1, true), 'another fact stays')
    ok(a:find('return pcall(vim.treesitter.language.add', 1, true), 'ready() keeps its probe')
    eq(nil, a:find('local TSDIR', 1, true), 'the file-level local nothing reads any more is gone')
    eq(nil, a:find("if os.getenv('X') then\n", 1, true), 'a8: an if whose every statement was a step goes whole')
    local b = after['b_spec.lua']
    eq(nil, b:find('rtp:append', 1, true))
    eq(nil, b:find('local TSDIR', 1, true))
    vim.fn.delete(d, 'rf')
end)

test('hoistsetup: ★ APPLIED, the tree re-analyses clean — the prelude sets it up, no copy and no hoist remain', function ()
    if not has_lua() then skip 'no lua parser' end
    local d = copy_fixture()
    load(d)
    local plan = assert(hoistsetup.plan(store))
    local okk, err = txn.apply(store, plan)
    ok(okk, tostring(err))
    local data = load(d)
    local R = redundancy.analyze(store, data)
    for _, f in ipairs(R.findings) do
        ok(f.kind ~= 'hoist' or not f.fact.key:find('nvim%-treesitter'), 'nothing left to hoist: ' .. redundancy.text(f))
    end
    local unit_steps = 0
    for _, fact in pairs(R.facts) do
        if fact.key:find('nvim%-treesitter') then
            for _, s in ipairs(fact.steps) do if s.file ~= 'run.lua' then unit_steps = unit_steps + 1 end end
        end
    end
    eq(0, unit_steps, 'no unit sets it up any more')
    local chunk = loadfile(d .. '/run.lua')
    ok(chunk, 'the edited prelude still compiles')
    vim.fn.delete(d, 'rf')
end)

test('hoistsetup: declines by name — a shared line, an effectful guard, a step inside an expression', function ()
    if not has_lua() then skip 'no lua parser' end
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, 'p')
    vim.fn.writefile({ 'local reg = {}', 'function _G.test(n, f) reg[#reg + 1] = f end',
        "for _, f in ipairs(vim.fn.glob('*_spec.lua', false, true)) do dofile(f) end" }, d .. '/run.lua')
    local T = "vim.fn.expand('~/x')"
    vim.fn.writefile({ 'local function touch() return true end',
        "test('p', function()", '    vim.opt.rtp:append(' .. T .. '); touch()', 'end)',
        "test('q', function()", '    if touch() then vim.opt.rtp:append(' .. T .. ') end', 'end)',
        "test('r', function()", '    local r = vim.opt.rtp:append(' .. T .. ')', 'end)',
        "test('s', function()", '    vim.opt.rtp:append(' .. T .. ')', 'end)' }, d .. '/p_spec.lua')
    vim.fn.writefile({ "test('t', function()", '    vim.opt.rtp:append(' .. T .. ')', 'end)' }, d .. '/t_spec.lua')
    load(d)
    local plan, why = hoistsetup.plan(store)
    ok(plan, tostring(why))
    local reasons = {}
    for _, x in ipairs(plan.declined) do reasons[x.line] = x.reason end
    ok(reasons[3] and reasons[3]:find('shares its line', 1, true), 'line 3: ' .. tostring(reasons[3]))
    ok(reasons[6] and reasons[6]:find('condition has an effect', 1, true), 'line 6: ' .. tostring(reasons[6]))
    ok(reasons[9] and reasons[9]:find('inside an expression', 1, true), 'line 9: ' .. tostring(reasons[9]))
    local _, after = txn.dryrun(store, plan)
    ok(after['p_spec.lua']:find('touch()', 1, true) and not after['p_spec.lua']:find("test('s', function()\n    vim.opt", 1, true),
        'the declined sites stay, the clean one goes:\n' .. after['p_spec.lua'])
    vim.fn.delete(d, 'rf')
end)
