-- compose: a ladder of VERB INVOCATIONS, previewed as it goes (CART-0920).
--
-- ★★★ A RECIPE HOLDS INVOCATIONS, NOT PLANS. Applying a plan bumps the graph
-- generation, after which every id in a held plan may name a different symbol —
-- measured, the node stops resolving at all. An INVOCATION survives that; a PLAN
-- does not. Everything below follows from it, including why a step addresses
-- symbols by durable ref. (A dry run once saw only one step ahead; it now
-- plans each step in the OVERLAY world the previous one would produce.)

local compose = require 'cartograph.compose'
local schema = require 'cartograph.schema'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

local SRC = table.concat({
    'local M = {}',
    'function M.f(x) return x + 1 end',
    'function M.g(x) return x - 1 end',
    'return M',
}, '\n')

local function mk()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    store.ingest(ts.extract(root))
    return root
end

local function refof(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and n.kind == 'function' then return store.ref_of(n.id) end
    end
end

test('compose: a dry run previews EVERY step — step 2 plans against the overlay world step 1 would produce', function ()
    if not ready() then skip('no lua parser') end
    local root = mk()
    local caller = store.data
    local recipe = compose.recipe {
        { verb = 'moveset', args = { seed_refs = { refof('M.f') }, dest = 'sub/f.lua' } },
        { verb = 'moveset', args = { seed_refs = { refof('M.g') }, dest = 'sub/g.lua' } },
    }
    local rows = assert(compose.run(store, recipe))
    eq(2, #rows)
    eq(true, rows[1].ok, 'step 1 planned and previewed: ' .. tostring(rows[1].why))
    ok(rows[1].after['sub/f.lua'], 'and its effect is real text')
    -- ★ STEP 2 USED TO BE `underivable`: without applying step 1 its tree did not exist as a GRAPH. It does now — an
    -- overlay world (CART-1160 step 3) — so step 2 plans against the m.lua step 1 would leave
    eq(true, rows[2].ok, 'step 2 planned in the overlay world: ' .. tostring(rows[2].why))
    eq(nil, rows[2].underivable)
    eq(rows[1].after['m.lua'], rows[2].before['m.lua'], 'step 2 read the m.lua step 1 would write, not the disk\'s')
    eq(nil, rows[1].applied, 'and a dry run wrote nothing')
    eq(SRC, table.concat(vim.fn.readfile(root .. '/m.lua'), '\n'))
    eq(0, vim.fn.isdirectory(root .. '/sub'))
    eq(caller, store.data, 'the caller\'s graph is the lens again')
    -- ★ THE ORACLE: the dry run's final texts EQUAL what the apply writes
    local final = {}
    for _, r in ipairs(rows) do for rel, text in pairs(r.after) do final[rel] = text end end
    local done = assert(compose.run(store, recipe, { apply = true }))
    eq(true, done[2].applied, tostring(done[2].why))
    for rel, text in pairs(final) do
        local fd = assert(io.open(root .. '/' .. rel)); local got = fd:read('a'); fd:close()
        eq(text, got, rel .. ': the preview is the apply')
    end
end)

test('compose: applying re-derives each step against the tree the last one made', function ()
    if not ready() then skip('no lua parser') end
    local root = mk()
    local rows = assert(compose.run(store, compose.recipe {
        { verb = 'moveset', args = { seed_refs = { refof('M.f') }, dest = 'sub/f.lua' } },
        { verb = 'moveset', args = { seed_refs = { refof('M.g') }, dest = 'sub/g.lua' } },
    }, { apply = true }))

    eq(2, #rows)
    eq(true, rows[1].applied, 'step 1 applied: ' .. tostring(rows[1].why))
    -- ★ STEP 2'S REF RESOLVED AFTER THE GENERATION BUMP — the thing an id could
    -- not have done. Its plan was built against the tree step 1 produced.
    eq(true, rows[2].applied, 'step 2 applied: ' .. tostring(rows[2].why))

    local m = table.concat(vim.fn.readfile(root .. '/m.lua'), '\n')
    ok(not m:find('return x + 1', 1, true), 'f left m.lua')
    ok(not m:find('return x - 1', 1, true), 'and so did g')
    ok(vim.fn.filereadable(root .. '/sub/f.lua') == 1, 'f landed')
    ok(vim.fn.filereadable(root .. '/sub/g.lua') == 1, 'and g landed')
end)

test('compose: an ID seed is refused AT THE DOOR, not one step later', function ()
    if not ready() then skip('no lua parser') end
    mk()
    local id
    for _, n in ipairs(store.data.nodes) do if n.name == 'M.f' then id = n.id end end
    local rows = assert(compose.run(store, compose.recipe {
        { verb = 'moveset', args = { seed = { id }, dest = 'sub/f.lua' } },
    }))
    eq(false, rows[1].ok)
    -- an id WOULD work for step 1 and name a different symbol by step 2, which is
    -- the failure this design exists to prevent
    ok(tostring(rows[1].why):find('durable', 1, true), tostring(rows[1].why))
end)

test('compose: a mid-recipe failure ROLLS BACK what landed, and reports every step', function ()
    if not ready() then skip('no lua parser') end
    local root = mk()
    local before = table.concat(vim.fn.readfile(root .. '/m.lua'), '\n')
    local rows = assert(compose.run(store, compose.recipe {
        { verb = 'moveset', args = { seed_refs = { refof('M.f') }, dest = 'sub/f.lua' } },
        { verb = 'nonsuch', args = {} },
        { verb = 'moveset', args = { seed_refs = { refof('M.g') }, dest = 'sub/g.lua' } },
    }, { apply = true }))

    eq(3, #rows, 'every step is reported — a recipe that stops at 2 and returns 2 rows reads as a 2-step recipe')
    eq(true, rows[1].applied)
    eq(false, rows[2].ok)
    ok(tostring(rows[2].why):find('no such verb', 1, true), tostring(rows[2].why))
    eq(true, rows[3].skipped, 'the step after the failure is skipped, not attempted')

    -- ★ ALL-OR-NOTHING: a half-landed composition leaves the tree in a state no
    -- step described. Rollback restores BYTES from the journal, which is why it
    -- works across the generation bump when nothing else does.
    eq(1, rows.rolled_back)
    eq(before, table.concat(vim.fn.readfile(root .. '/m.lua'), '\n'),
        'the source file is byte-identical to before the recipe ran')
    ok(vim.fn.filereadable(root .. '/sub/f.lua') ~= 1, 'and the created file is gone')
end)

test('compose: a recipe is a VERSIONED artifact', function ()
    if not ready() then skip('no lua parser') end
    mk()
    local steps = { { verb = 'moveset', args = { seed_refs = { refof('M.f') }, dest = 'sub/f.lua' } } }
    eq(schema.RECIPE, compose.recipe(steps).version)
    -- a bare list is in-process and ungated; a table CLAIMING to be a recipe must prove it
    ok(compose.run(store, steps) ~= nil, 'a bare step list runs')
    local no, why = compose.run(store, { steps = steps })
    eq(nil, no)
    ok(tostring(why):find('no schema version', 1, true), tostring(why))
end)

--- ★★★ A STEP ADDRESSES WHAT AN EARLIER STEP CREATED, AND NOTHING RE-INGESTS.
--- I built the runner with a `reingest` hook and documented it as load-bearing:
--- without re-extraction, a later step's refs would resolve against a tree that no
--- longer exists. BOTH HALVES WERE WRONG. Dropping the hook broke no test, so I
--- measured instead of arguing:
---
---     before: gen=1  by_file['sub/f.lua']=false
---     after : gen=2  by_file['sub/f.lua']=true
---     ref to the new home resolves: true
---
--- `apply` SPLICES ITS RESULT INTO THE GRAPH. That is why a recipe of invocations
--- works at all — the write path keeps the graph current, so step k+1 re-derives
--- against what step k actually did. ⚠ And `apply` is also REF-ANCHORED: it
--- re-locates each symbol in the current file content rather than trusting the
--- line numbers the plan was built with, so even a stale plan cannot cut the
--- wrong lines. The hook was dead weight defended by a false mechanism.
test('compose: a step addresses what an earlier step CREATED, with no re-ingest', function ()
    if not ready() then skip('no lua parser') end
    local root = mk()
    local rows = assert(compose.run(store, compose.recipe {
        { verb = 'moveset', args = { seed_refs = { refof('M.f') }, dest = 'sub/f.lua' } },
        -- step 2 names M.f AT ITS NEW HOME, which exists only because step 1 ran
        { verb = 'moveset',
          args = { seed_refs = { { file = 'sub/f.lua', kind = 'function', name = 'M.f' } },
                   dest = 'sub/f2.lua' } },
    }, { apply = true }))
    eq(true, rows[1].applied, tostring(rows[1].why))
    eq(true, rows[2].applied, 'the second step found the symbol at its new home: '
        .. tostring(rows[2].why))
    ok(vim.fn.filereadable(root .. '/sub/f2.lua') == 1, 'and moved it on')
    ok(vim.fn.filereadable(root .. '/sub/f.lua') == 1, 'the intermediate file stayed')
end)
