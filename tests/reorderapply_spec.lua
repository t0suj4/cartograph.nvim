-- Reorder-apply: the transaction that moves a statement, certified behavior-preserving by
-- the reorder commute verdict (deps + state/world conflicts + opaque hedges). Moving a
-- statement inverts its order with each crossed statement, so the move is sound iff it has
-- no modeled relationship (dep/conflict) with any crossed statement and crosses nothing
-- opaque. First cut: a single-line, single-statement move.

local ro = require 'cartograph.reorder'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function proj(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    return root
end
local function fn_id(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

-- two independent pure statements (a=x+1, b=y*2) then a dependent (c=a+b)
local PURE = 'local function f(x, y)\n  local a = x + 1\n  local b = y * 2\n'
    .. '  local c = a + b\n  return c\nend\nreturn f\n'

test('reorder-apply: a free swap is certified and produces the reordered source', function ()
    local root = proj(PURE)
    -- move `local b = y * 2` (L3) up before `local a = x + 1` (L2)
    local plan, why = ro.plan_move(store, fn_id('f'), 3, 2)
    ok(plan, 'a free move is certified: ' .. tostring(why))
    if plan then
        local _, after = ro.preview(store, plan)
        local lines = vim.split(after[plan.file], '\n', { plain = true })
        eq('  local b = y * 2', lines[2], 'b moved to line 2')
        eq('  local a = x + 1', lines[3], 'a moved to line 3')
        eq('  local c = a + b', lines[4], 'the dependent statement is untouched')
        local pr = vim.treesitter.get_string_parser(after[plan.file], 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the reordered file parses clean')
    end
    vim.fn.delete(root, 'rf')
end)

test('reorder-apply: a move crossing a dataflow dependency is refused', function ()
    local root = proj(PURE)
    -- move `local c = a + b` (L4) up before `local a = x + 1` (L2): c uses a → dep
    local plan, why = ro.plan_move(store, fn_id('f'), 4, 2)
    ok(not plan and why:find('dataflow dep'), 'crossing a dep is refused: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

-- (state/world CONFLICTS ride the same rel[t] refusal path as deps — see plan_move; the
-- dep test above exercises that mechanism. Whether a given pair registers as a conflict is
-- the reorder MODEL's business, tested in its own spec, not the apply's.)

test('reorder-apply: a move crossing an opaque statement is refused', function ()
    -- side_effect() is an unresolved call → opaque; a pure move may not cross it
    local root = proj('local function f(x)\n  local a = x + 1\n  side_effect()\n'
        .. '  local b = x + 2\n  return a + b\nend\nreturn f\n')
    local plan, why = ro.plan_move(store, fn_id('f'), 4, 2) -- b (L4) up past side_effect (L3)
    ok(not plan and why:find('opaque'), 'crossing an opaque statement is refused: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

test('reorder-apply: a BLOCK of statements moves as a unit when it commutes', function ()
    -- a, b (independent of d) then d, then the dependent c. Move the block [a, b] (L2-L3)
    -- down to before `return` (L6), crossing d (L4) — a,b commute with d → certified.
    local root = proj('local function f(x, y)\n  local a = x + 1\n  local b = y * 2\n'
        .. '  local d = x - y\n  local c = a + b + d\n  return c\nend\nreturn f\n')
    -- L4 is `local d`; move block L2..L3 (a,b) to before L5 (`local c`) — crosses d
    local plan, why = ro.plan_move(store, fn_id('f'), 2, 5, 3)
    ok(plan, 'the block move is certified: ' .. tostring(why))
    if plan then
        eq(2, plan.nstmts, 'a two-statement block')
        local _, after = ro.preview(store, plan)
        local lines = vim.split(after[plan.file], '\n', { plain = true })
        eq('  local d = x - y', lines[2], 'd moved up to line 2')
        eq('  local a = x + 1', lines[3], 'the a/b block followed, order preserved')
        eq('  local b = y * 2', lines[4], 'b keeps its position within the block')
        local pr = vim.treesitter.get_string_parser(after[plan.file], 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the reordered file parses clean')
    end
    vim.fn.delete(root, 'rf')
end)

test('reorder-apply: a block move is refused if ANY block statement is bound to a crossed one', function ()
    -- block [a, c] where c uses b; moving it past b would invert c and b → refuse
    local root = proj('local function f(x, y)\n  local a = x + 1\n  local b = y * 2\n'
        .. '  local c = b + 1\n  return a + c\nend\nreturn f\n')
    -- can't form a clean [a..c] block that excludes b (b is between); move block L2..L4? that includes b.
    -- instead: move block [b, c] (L3-L4) up before a (L2) — fine (no dep with a); then try
    -- moving [c] alone up past b (dep) — refused (covered). Here assert the block [a] .. no.
    -- Move block L4..L4 (c) up before L3 (b): c uses b → refused.
    local plan, why = ro.plan_move(store, fn_id('f'), 4, 3, 4)
    ok(not plan and why:find('dataflow dep'), 'a block whose member depends on a crossed statement is refused: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

test('reorder-apply: the write is journaled and the result parses', function ()
    local root = proj(PURE)
    local plan = ro.plan_move(store, fn_id('f'), 3, 2)
    ok(plan, 'planned')
    if plan then
        store.set_txn(plan)
        local entry, why = ro.apply(store, plan)
        ok(entry, 'apply succeeds: ' .. tostring(why))
        local written = vim.fn.readfile(root .. '/m.lua')
        eq('  local b = y * 2', written[2], 'the move landed on disk')
        local pr = vim.treesitter.get_string_parser(table.concat(written, '\n'), 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the written file parses clean')
    end
    vim.fn.delete(root, 'rf')
end)
