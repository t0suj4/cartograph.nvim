-- PROMISES THE SUITE NEVER MADE FIRE (CART-0990, the parameter-forked queue).
--
-- ★★★ EVERY REFUSAL IS A PROMISE: `return nil, "<reason>"` says IN THIS CASE I WILL
-- REFUSE, AND THIS IS WHY. The refusal census joined every `return` line in the write
-- path against every line the suite executes and found 58 of 189 named promises had
-- NEVER FIRED — believed rather than driven. `--partition` then split them by what
-- their guard hinges on: 10 turn on an ARGUMENT (reachable by calling the verb badly)
-- and 48 on DERIVED ANALYSIS (each needs a constructed tree).
--
-- These are six of the ten. Each was reviewed by reading its guard, and each is PROVEN
-- to reach its site: re-running the census after adding this file moves exactly these
-- lines from NEVER to fired. That proof is the point — a test whose fixture never
-- reaches the refusal passes for the wrong reason, which is the failure mode the whole
-- census exists to find.
--
-- ⚠ FOUR OF THE TEN ARE NOT HERE, and not because they are unreachable: `collect`'s
-- function-local refusal, `txn.execute`'s unreadable-file path, `reorder.plan_move`'s
-- position guard and `characterize`'s condition-inversion internals each need a fixture
-- I could not review with confidence from the guard alone. An unreviewed test is worth
-- less than an absent one.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local mv = require 'cartograph.moveapply'
local declare = require 'cartograph.declare'
local txn = require 'cartograph.txn'

local function ready() return pcall(vim.treesitter.language.add, 'lua') end

local function proj(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    return root
end
local SRC = 'local M = {}\n\nfunction M.f(x)\n  return x + 1\nend\n\nreturn M\n'
local function some_id()
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'M.f' then return n.id end
    end
end

test('promise: a move-set with no destination refuses, naming the call', function ()
    if not ready() then skip('no lua parser') end
    local root = proj(SRC)
    local plan, why = mv.plan_moveset(store, { some_id() }, '')
    eq(nil, plan, 'it refuses')
    eq('no destination — plan_moveset(store, seed_ids, dest)', why,
        'and the reason names the argument it wanted')
    vim.fn.delete(root, 'rf')
end)

test('promise: a move-set with no seed symbols refuses, naming the call', function ()
    if not ready() then skip('no lua parser') end
    local root = proj(SRC)
    local plan, why = mv.plan_moveset(store, {}, 'lib/new.lua')
    eq(nil, plan, 'it refuses')
    eq('no seed symbols — plan_moveset(store, seed_ids, dest)', why,
        'and the reason names the argument it wanted')
    vim.fn.delete(root, 'rf')
end)

test('promise: extract-module with no path refuses with its usage line', function ()
    if not ready() then skip('no lua parser') end
    local root = proj(SRC)
    local plan, why = mv.plan_extract_ids(store, { some_id() }, '   ')
    -- ⚠ WHITESPACE IS EMPTY HERE: the guard trims before testing, so a path of spaces
    -- is the same refusal as a missing one. Asserting the trimmed case documents that.
    eq(nil, plan, 'it refuses')
    eq('usage: :CartographExtractModule <new-file-path>', why, 'with the usage line')
    vim.fn.delete(root, 'rf')
end)

test('promise: arming something that is not a move-set plan refuses by name', function ()
    if not ready() then skip('no lua parser') end
    local root = proj(SRC)
    local ok1, why1 = mv.arm(store, {})
    eq(nil, ok1, 'a table with no `moves` is not a plan')
    eq('not a move-set plan', why1)
    local ok2, why2 = mv.arm(store, 'not a table at all')
    eq(nil, ok2, 'and neither is a string')
    eq('not a move-set plan', why2)
    vim.fn.delete(root, 'rf')
end)

test('promise: declare with neither `member` nor `subs` refuses, naming both', function ()
    if not ready() then skip('no lua parser') end
    local root = proj('local M = {}\n\nlocal T = { a = true, b = true }\n\nreturn M\n')
    local id
    for _, n in ipairs(store.data.nodes) do if n.name == 'T' then id = n.id end end
    if not id then skip('no container node') end
    local plan, why = declare.plan(store, { node = id })
    eq(nil, plan, 'it refuses')
    ok(tostring(why):find('supply `member`', 1, true)
        and tostring(why):find('`subs`', 1, true),
        'and names BOTH ways to supply the payload: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

test('promise: pricing a STALE plan refuses rather than scoring moved text', function ()
    if not ready() then skip('no lua parser') end
    local root = proj(SRC)
    -- ⚠ NEUTRALISE A VALUE, NOT A STRUCTURE: a well-formed plan that claims a
    -- generation the store has moved past. `txn.delta` reads DISK NOW, so a stale plan
    -- would score fresh text against stale offsets and report a confident number for an
    -- edit that can no longer be applied — which is why this refuses instead.
    local plan = { verb = 'test', generation = (store.generation or 0) + 7,
        touched = { 'm.lua' }, edit_of = function (_, before) return before end }
    local n, why = txn.delta(store, plan)
    eq(nil, n, 'it refuses to price it')
    ok(tostring(why):find('stale', 1, true) and tostring(why):find('re-plan', 1, true),
        'naming the staleness and the remedy: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)
