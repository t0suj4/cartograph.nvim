-- CART-1018: the contradiction between two docstrings, resolved.
--
-- `replace` was built (CART-0977) because "`transplant` derives a real source edit and has
-- nowhere to hand it". `transplant`'s own header then refused to produce "no txn, no
-- journal entry, NO PLAN HANDLE" — so the verb was built for a caller that declined to
-- call it, and a census found `cartograph.replace` with exactly two users: the MCP verb and
-- its test.
--
-- ★★★ THE RESOLUTION IS THAT A PLAN IS THE PROPOSAL FORM. transplant's fear is of a WRITE;
-- a plan is staged, diffed, guarded, stamped and journalled before a byte moves. Handing
-- back bare text is the LESS reviewable option, not the safer one.
--
-- ⚠ AND THE WIRE CREATES THE SECOND VALUE OF `origin`. Before it, every write verb derived
-- its own bytes and exactly one (`replace`) took supplied ones — so a provenance field
-- would have been constant. This is the caller that makes the distinction real.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local tp = require 'cartograph.transplant'
local rp = require 'cartograph.replace'
local txn = require 'cartograph.txn'

local function ready()
    if not pcall(vim.treesitter.language.add, 'lua') then return false end
    return (require('cartograph.transplant').available('lua'))
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

-- a -> b demonstrates ONE change (the guard gains a `not`); c is the second site
local FIX = 'local M = {}\n\n'
    .. 'local function a_before(t)\n  if t.ok then\n    return t.v\n  end\n  return nil\nend\n\n'
    .. 'local function b_after(t)\n  if not t.ok then\n    return t.v\n  end\n  return nil\nend\n\n'
    .. 'local function c_target(u)\n  if u.ok then\n    return u.w\n  end\n  return nil\nend\n\n'
    .. 'return M\n'

test('★★★ a derived edit becomes a REVIEWABLE PLAN, not bare text', function ()
    if not ready() then return end
    proj(FIX)
    local plan, why = tp.plan(store, { a = fid('a_before'), b = fid('b_after'), c = fid('c_target') })
    if not plan then
        -- the operator refuses by name on some shapes; that is a legitimate outcome and
        -- NOT a pass — say which so the fixture can be fixed rather than the test relaxed
        skip('transplant refused this fixture: ' .. tostring(why))
        return
    end
    eq('replace', plan.verb)
    -- ★ THE POINT OF THE WIRE
    eq('derived', plan.origin)
    eq('transplant', plan.derived_by)
    -- ★★★ AND THE CLAIM MOVED. `none` means "nobody can be asked"; this plan has a deriver
    -- and names it, so it is REVIEWABLE — which is the bucket that exists for exactly this.
    eq('unreviewed', plan.preserves)
    ok(plan.preserves_why:match('derived by'), plan.preserves_why)
    -- the standing "supplied, not derived" hazard must NOT be on a derived plan: it would
    -- be a false statement about this text
    for _, h in ipairs(plan.hazards or {}) do
        eq(nil, h:match('was supplied, not derived'))
    end
    ok(plan.transplant and plan.transplant.info, 'the operator account rides along')
    -- and it is a real plan: it previews through the generic driver
    local _, after, dwhy = rp.preview(store, plan)
    ok(after, 'it previews: ' .. tostring(dwhy))
    if after then ok(after['m.lua']:match('if not u.ok then'), 'the edit landed:\n' .. after['m.lua']) end
end)

test('supplied text keeps the standing hazard and claims NOTHING', function ()
    if not ready() then return end
    proj(FIX)
    local plan, why = rp.plan(store, { node = fid('c_target'),
        text = 'local function c_target(u)\n  return 0\nend' })
    ok(plan, tostring(why))
    if not plan then return end
    -- ⚠ THE DEFAULT IS UNCHANGED. The origin field must not have quietly upgraded the
    -- weakest verb on the axis; every existing caller passes no `origin`.
    eq('supplied', plan.origin)
    eq('none', plan.preserves)
    local found
    for _, h in ipairs(plan.hazards or {}) do
        if h:match('was supplied, not derived') then found = true end
    end
    ok(found, 'the standing declaration is still unconditional for supplied text')
end)

test('★★★ a derived claim owes an author, and the vocabulary is closed', function ()
    if not ready() then return end
    proj(FIX)
    local id = fid('c_target')
    -- derived with nobody to attribute it to is `supplied` wearing a better word
    local r, why = rp.plan(store, { node = id, text = 'local function c_target() end',
        origin = 'derived' })
    eq(nil, r); ok(why:match('must name what derived it'), tostring(why))
    r, why = rp.plan(store, { node = id, text = 'local function c_target() end',
        origin = 'guessed' })
    eq(nil, r); ok(why:match('not one of supplied|derived'), tostring(why))
end)

test('transplant.plan refuses by name before it reaches replace', function ()
    if not ready() then return end
    proj(FIX)
    local r, why = tp.plan(store, { a = fid('a_before'), b = fid('b_after') })
    eq(nil, r); ok(why:match('needs `c`'), tostring(why))
    r, why = tp.plan(store, { a = fid('a_before'), b = fid('b_after'), c = 'no-such-node' })
    eq(nil, r); ok(why:match('no definition'), tostring(why))
    -- ★ A NO-OP IS A REFUSAL. a == b means the exemplar demonstrates nothing, so whatever
    -- comes back for `c` is `c` — staging it would spend a review on an empty diff.
    r, why = tp.plan(store, { a = fid('a_before'), b = fid('a_before'), c = fid('c_target') })
    eq(nil, r)
    ok(why and (why:match('unchanged') or why:match('derived nothing usable')
        or why:match('transplant refused')), tostring(why))
end)
