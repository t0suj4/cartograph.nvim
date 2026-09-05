-- CART-0762. Findings referenceable WHILE READING — and the whole design is the
-- ABSENCE, not the attachment.
--
-- ★★ A node with no finding must distinguish "every census that ran looked here
-- and said nothing" (a RESULT) from "no census has been run" (UNAVAILABLE).
-- Conflate them and the READ SURFACE MANUFACTURES CLEAN BILLS OF HEALTH at the
-- moment a caller is deciding whether code is safe. The tree already refuses that
-- one rung over — on an index-only graph a call verb REFUSES rather than
-- answering "none" — and this is the same rule on a new axis.

local F = require 'cartograph.findings'
local sl = require 'cartograph.shortlist'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local DEAD = {
    'local function neverCalled(x) return x + 1 end',
    'local M = {}',
    'function M.entry() return 3 end',
    'return M',
}

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

local function proj(lines)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    vim.fn.writefile(lines, root .. '/d.lua')
    store.ingest(ts.extract(root))
    return root
end

test('findings: an empty list means two different things, and says which', function ()
    if not ready() then return skip 'no lua parser' end
    local root = proj(DEAD)
    local fn
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' and n.name:find('entry') then fn = n end
    end
    ok(fn, 'found the clean function')

    -- BEFORE any census: nobody looked
    local before = F.for_node(store, fn.id)
    eq(0, #before.findings)
    eq(1, #before.not_run, 'and `not_run` names the census that never ran')
    eq('lint', before.not_run[1])

    -- AFTER lint: it looked here and said nothing
    ok(F.record_lint(store), 'lint recorded')
    local after = F.for_node(store, fn.id)
    eq(0, #after.findings, 'still no finding on this node')
    eq(0, #after.not_run, '...but nothing is unasked now — THE DIFFERENCE IS THE POINT')
    vim.fn.delete(root, 'rf')
end)

test('findings: a node WITH a finding carries it, smallest enclosing def wins', function ()
    if not ready() then return skip 'no lua parser' end
    local root = proj(DEAD)
    eq(1, F.record_lint(store), 'one dead local')
    local dead
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' and n.name:find('neverCalled') then dead = n end
    end
    ok(dead, 'found the dead local')
    local f = F.for_node(store, dead.id)
    eq(1, #f.findings, 'the finding lands on the FUNCTION, not on its module')
    eq('lint', f.findings[1].census)
    ok(f.findings[1].text:find('dead'), 'and carries the rule: ' .. f.findings[1].text)
    -- ★ the finding states the completeness of the census that produced it, so a
    -- sampled census cannot be read as a cleared one
    eq(sl.EXHAUSTIVE, f.findings[1].complete)
    vim.fn.delete(root, 'rf')
end)

-- ⚠ A FINDING IS A CLAIM ABOUT THE TREE IT WAS COMPUTED AGAINST. After an edit
-- the graph moves and the claim describes a tree that is gone — the same rule the
-- write side states for a plan handle, which "dies with the generation it was
-- planned against" (CART-0761). Keying the record to the generation makes that
-- STRUCTURAL rather than a policy someone must remember.
test('findings: a record goes STALE when the generation moves, never silently current', function ()
    if not ready() then return skip 'no lua parser' end
    local root = proj(DEAD)
    ok(F.record_lint(store), 'recorded')
    eq(1, #F.manifest(store).current, 'lint is current')
    eq(0, #F.manifest(store).stale)
    store.ingest(ts.extract(root))          -- a re-ingest bumps the generation
    local man = F.manifest(store)
    eq(0, #man.current, 'the record no longer speaks for this graph')
    eq(1, #man.stale, '...and is reported STALE rather than dropped or trusted')
    eq('lint', man.stale[1])
    vim.fn.delete(root, 'rf')
end)

-- ★ THE REFUSALS. A census that cannot say what it covered, or that nothing
-- declares, must not be recordable — `not_run` is computed against the ROSTER, so
-- an unlisted census would be invisible rather than reported missing.
test('findings: record refuses an unknown census and an undeclared completeness', function ()
    if not ready() then return skip 'no lua parser' end
    local root = proj(DEAD)
    local okr, why = F.record(store, 'nosuchcensus',
        { complete = sl.EXHAUSTIVE, by_id = {} })
    eq(nil, okr)
    ok(why:find('CENSUSES'), 'the refusal says where to declare it: ' .. tostring(why))
    local ok2, why2 = F.record(store, 'lint', { by_id = {} })
    eq(nil, ok2)
    ok(why2:find('complete'), 'and a census with no stated coverage is refused too')
    vim.fn.delete(root, 'rf')
end)
