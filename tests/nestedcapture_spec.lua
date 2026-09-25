-- CART-0997: `body_extractable` refused every nested function on "may capture enclosing
-- upvalues" — a SYNTACTIC test ("is anything wrapped around me") that never asked whether
-- the body reads a name the enclosing definition binds.
--
-- ★ THE ANSWER WAS ALREADY COMPUTED, BY THE INVERSE VERB. `hoistclosure`'s whole gate is
-- "captures nothing"; it is split out as `M.captures` and consulted rather than
-- reimplemented. MEASURED on lua/cartograph: 1388 nested refusals, 436 capture-free (31.4%),
-- of which 415 become extractable and 21 are caught by the self-recursion check.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local un = require 'cartograph.untangle'
local hc = require 'cartograph.hoistclosure'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end
local function proj(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    return root
end
local function fn_id(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name and n.name:match('[%w_]+$') == name
            and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

test('nested + capture-free is EXTRACTABLE, and still says it is nested', function ()
    if not ready() then return end
    proj('local M = {}\n\nfunction M.outer(a)\n  local function inner(x)\n'
        .. '    local y = norm(x)\n    return y\n  end\n  return inner(a)\nend\n\nreturn M\n')
    local v = un.body_extractable(store, fn_id('inner'))
    -- `inner` reads only `norm`, a global — exactly the docstring's own property:
    -- "its free reads are module/global names a same-scope helper also sees".
    eq(true, v.ok)
    eq(1, #v.params)
    -- ⚠ THE FLAG RIDES ON THE OK ANSWER. `family_admissibility` keys its capture
    -- reporting off `nested`; clearing it here would make this look top-level.
    eq(true, v.nested)
end)

test('nested + capturing is refused, and the refusal NAMES the locals', function ()
    if not ready() then return end
    proj('local M = {}\n\nfunction M.outer(a)\n  local cap = a + 1\n'
        .. '  local function inner(x)\n    local y = norm(x, cap)\n    return y\n  end\n'
        .. '  return inner(a)\nend\n\nreturn M\n')
    local v = un.body_extractable(store, fn_id('inner'))
    eq(false, v.ok)
    eq(true, v.nested)
    -- ★ "may capture" told a caller nothing it could act on. The SET is what a lift
    -- would have to turn into parameters, which is the next rung's input.
    ok(v.captured and #v.captured == 1, 'the captured set is reported')
    eq('cap', (v.captured or {})[1])
    ok(v.reason:match('captures 1 enclosing local'), v.reason)
    ok(v.reason:match('cap'), v.reason)
end)

test('nested + WRITES an enclosing local is refused as a write, not a read', function ()
    if not ready() then return end
    proj('local M = {}\n\nfunction M.outer(a)\n  local n = 0\n'
        .. '  local function inner(x)\n    n = n + x\n    return n\n  end\n'
        .. '  return inner(a)\nend\n\nreturn M\n')
    local v = un.body_extractable(store, fn_id('inner'))
    eq(false, v.ok)
    eq('n', v.writes)
    ok(v.reason:match('assigns the enclosing local'), v.reason)
end)

test('★★ the vararg check now RUNS for a nested function — it used to be skipped', function ()
    if not ready() then return end
    -- ⚠ THE EARLY RETURN WAS HIDING (b) AND (c). A nested function never reached them,
    -- so admitting capture-free ones without falling through would have traded a
    -- conservative refusal for an UNSOUND admission. This is the fixture that says so.
    proj('local M = {}\n\nfunction M.outer(a)\n  local function inner(...)\n'
        .. '    local y = norm(...)\n    return y\n  end\n  return inner(a)\nend\n\nreturn M\n')
    local v = un.body_extractable(store, fn_id('inner'))
    eq(false, v.ok)
    eq(true, v.vararg)
    -- and the nesting is still reported, so a consumer keyed on it is not blinded
    eq(true, v.nested)
end)

test('★ recursion stays refused for a helper, though the HOIST allows it', function ()
    if not ready() then return end
    -- two verbs, two answers: `hoistclosure` may keep a self-call because the NAME
    -- travels with the closure; a helper is given a FRESH name, so it would not.
    proj('local M = {}\n\nfunction M.outer(a)\n  local function inner(x)\n'
        .. '    if x > 0 then return inner(x - 1) end\n    return x\n  end\n'
        .. '  return inner(a)\nend\n\nreturn M\n')
    local v = un.body_extractable(store, fn_id('inner'))
    eq(false, v.ok)
    eq(true, v.recursive)
end)

test('hoistclosure.captures answers with FACTS, not a refusal', function ()
    if not ready() then return end
    proj('local M = {}\n\nfunction M.outer(a)\n  local cap = a + 1\n'
        .. '  local function inner(x)\n    local y = norm(x, cap)\n    return y\n  end\n'
        .. '  return inner(a)\nend\n\nreturn M\n')
    local c, why = hc.captures(store, fn_id('inner'))
    ok(c, 'it answers: ' .. tostring(why))
    if not c then return end
    eq(1, #c.captured)
    eq('cap', c.captured[1])
    eq(false, c.vararg)
    eq(nil, c.writes)
    -- ⚠ AND THE PLANNER STILL REFUSES, with the message its 17 specs assert
    local plan, pwhy = hc.plan(store, fn_id('inner'))
    eq(nil, plan)
    ok(pwhy:match('captures enclosing local `cap`'), tostring(pwhy))
end)

test('hoistclosure.captures reports a top-level function as NOT nested', function ()
    if not ready() then return end
    proj('local M = {}\n\nlocal function solo(x)\n  local y = norm(x)\n  return y\nend\n\nreturn M\n')
    local c, why = hc.captures(store, fn_id('solo'))
    -- the analysis declines where there is no enclosing function at all, and that
    -- message is the planner's own — unchanged by the split.
    eq(nil, c)
    ok(why and why:match('already at module scope'), tostring(why))
end)

test('★★ a name the enclosing fn binds AFTER the closure is NOT captured', function ()
    if not ready() then return end
    -- ⚠ THIS CONSUMER NEEDED ITS OWN FIXTURE. CART-0979's binding-order rule — a local
    -- is in scope from its DECLARATION onward, so one bound BELOW a nested closure is
    -- invisible inside it — was carried by hoistclosure's specs alone. Dropping the
    -- `def_line` filter left those 17 failing and these 7 GREEN, which means the second
    -- caller of `captures` had no test of the property it depends on.
    -- ⇒ HERE `later` READS AS A GLOBAL inside `inner`, so nothing is captured and the
    -- body IS extractable. Without the filter it would read as an enclosing local and
    -- this admission would flip to a refusal.
    proj('local M = {}\n\nfunction M.outer(a)\n  local function inner(x)\n'
        .. '    local y = norm(x, later)\n    return y\n  end\n'
        .. '  local later = 1\n  return inner(a) + later\nend\n\nreturn M\n')
    local c = hc.captures(store, fn_id('inner'))
    ok(c, 'the capture analysis answers')
    if not c then return end
    eq(0, #c.captured)
    local v = un.body_extractable(store, fn_id('inner'))
    eq(true, v.ok)
    eq(true, v.nested)
end)
