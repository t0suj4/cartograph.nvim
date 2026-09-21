-- CART-1004: a plan declares what its INVERSE would need. USER: "I guess we can do soft
-- deletes" — and the bytes were never lost. The journal has kept every touched file's
-- prior text since it shipped; what was missing is the ADDRESS into it.
--
-- ★★★ TWO SHAPES, ONE FIELD, DISCRIMINATED BY `kind`:
--   removed   a DESTRUCTIVE verb, whose inverse needs bytes that are gone from the tree
--             -> spans into the journal's own before-text. Not a copy: `before` has them.
--   relation  a CONSTRUCTIVE verb, whose inverse needs a RELATION that was never text
--             -> the parameter/argument correspondence, which no soft delete can supply
--                because nothing was deleted.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local cx = require 'cartograph.cloneextract'
local cm = require 'cartograph.clonemerge'
local journal = require 'cartograph.journal'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end
local function proj(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    store.ingest(ts.extract(root)); return root
end
local function fid(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name and n.name:match('[%w_]+$') == name
            and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

local TWINS = 'local M = {}\n\nlocal function one(x)\n  local a = prep(x)\n  local b = norm(a)\n'
    .. '  return b\nend\n\nlocal function two(x)\n  local a = prep(x)\n  local b = norm(a)\n'
    .. '  return b\nend\n\nreturn M\n'

test('★★★ a DESTRUCTIVE verb declares WHERE, and the journal already had WHAT', function ()
    if not ready() then return end
    local root = proj(TWINS)
    local plan, why = cm.plan(store, fid('one'))
    ok(plan, 'the twins merge: ' .. tostring(why))
    if not plan then return end
    ok(plan.undo, 'the plan declares an undo record')
    if not plan.undo then return end
    eq('removed', plan.undo.kind)
    ok(#plan.undo.spans >= 1, 'and it names at least one removed span')
    local sp = plan.undo.spans[1]
    ok(sp.file and sp.s and sp.e, 'each span carries file and line bounds')
    -- ⚠ A SPAN, NOT A COPY. Storing the text would duplicate what the journal's
    -- `before` already holds — in the half that can drift.
    eq(nil, sp.text)
end)

test('★★★ journal.recover resolves the span against the entry it was written with', function ()
    if not ready() then return end
    local root = proj(TWINS)
    local plan = cm.plan(store, fid('one'))
    if not plan then return end
    local txn = require 'cartograph.txn'
    local entry, awhy = txn.apply(store, plan)
    ok(entry, 'the merge applies: ' .. tostring(awhy))
    if not entry then return end
    ok(entry.undo, 'the entry carries the undo record')
    local got, rwhy = journal.recover(entry)
    ok(got, 'and recover resolves it: ' .. tostring(rwhy))
    if not got then return end
    -- ★ THE ROUND TRIP: what the transaction deleted comes back out of the bytes it
    -- never actually lost.
    local blob = table.concat(got[1].lines, '\n')
    ok(blob:match('local function two') or blob:match('local function one'),
        'the removed function is recovered:\n' .. blob)
    ok(blob:match('prep'), 'body and all')
end)

test('recover refuses by name where it cannot answer', function ()
    if not ready() then return end
    local r, why = journal.recover(nil)
    eq(nil, r); ok(why:match('not a journal entry'), tostring(why))
    -- an entry from before this existed is not an entry with nothing to recover
    local r2, why2 = journal.recover({ id = 'old', files = {} })
    eq(nil, r2); ok(why2:match('carries no undo record'), tostring(why2))
    -- and a relation record is not a removal
    local r3, why3 = journal.recover({ id = 'x', files = {}, undo = { kind = 'relation' } })
    eq(nil, r3); ok(why3:match('not a removal'), tostring(why3))
end)

test('★★★ a CONSTRUCTIVE verb declares the RELATION, which no soft delete supplies', function ()
    if not ready() then return end
    proj('local M = {}\n\nlocal function fmt_a(x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. "  local w = encode(z, 'json')\n  local o = wrap(w)\n  return o\nend\n\n"
        .. 'local function fmt_b(a)\n  local b = prep(a)\n  local c = norm(b)\n'
        .. "  local d = encode(c, 'yaml')\n  local e = wrap(d)\n  return e\nend\n\nreturn M\n")
    local p = clones.near_of(store, fid('fmt_a'), { max_dist = 2, min_rows = 4, min_shared = 3 })[1]
    ok(p, 'the fixture is a near pair')
    if not p then return end
    local plan, why = cx.plan(store, p)
    ok(plan, 'it plans: ' .. tostring(why))
    if not plan then return end
    ok(plan.undo, 'the plan declares an undo record')
    if not plan.undo then return end
    eq('relation', plan.undo.kind)
    eq(plan.helper, plan.undo.helper)
    ok(#plan.undo.params >= 1, 'the helper parameters are named')
    eq(2, #plan.undo.sites)
    -- ★ THE CORRESPONDENCE IS THE POINT: each site's arguments, positionally matching
    -- the parameters, so an inverse can substitute without re-parsing our own output.
    for _, s in ipairs(plan.undo.sites) do
        eq(#plan.undo.params, #s.args)
        ok(s.file and s.name, 'each site names its member')
    end
    local a1 = table.concat(plan.undo.sites[1].args, ',')
    local a2 = table.concat(plan.undo.sites[2].args, ',')
    ok(a1 ~= a2, 'and the two sites differ — that is what the parameter is for')
    ok((a1 .. a2):match('json') and (a1 .. a2):match('yaml'), 'the real values: ' .. a1 .. ' | ' .. a2)
end)
