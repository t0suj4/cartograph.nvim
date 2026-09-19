-- cartograph.transplant — APPLY THE EDIT a → b TO c (CART-0912; CART-0879 item 2).
--
-- THE SEAM THAT ABSORBS `A.transplant`. The operator has been vendored since the
-- 2026-09-19 re-vendor and had NO shipped consumer, which the absorption ledger
-- counts as unabsorbed — vendored code nothing calls is a copy, not a capability.
--
-- ★★★ AND THIS IS THE ABSORPTION THAT PAYS FOR THE OTHERS. The operation that
-- automates moving a prototype's work into a host was itself sitting in the donor
-- unabsorbed, so the only way in was to do by hand exactly what it automates.
-- Every later absorption can use it; this one could not.
--
-- WHAT IT IS (donor TRANSPLANT.md; Meng, Kim & McKinley, "Systematic Editing",
-- PLDI 2011): from ONE exemplar edit (a → b) derive the same edit for a DIFFERENT
-- target c. The three steps are operators that already exist —
--   context     join(a, c)              the lgg: abstraction + the 1:1 mapping
--   edit        classify(T_ac, V_a, b)  the exemplar's edit in that frame
--   application migrate / per-hole substitution
--
-- ⚠⚠ A PROPOSAL, NEVER A WRITE. Same law as every other verb on this axis: the
-- result is source to REVIEW. `transplant` itself records nothing on any edit log
-- ("it derives a term, it does not move a family") and this seam keeps that — no
-- txn, no journal entry, no plan handle. A verb that silently rewrote siblings
-- from one exemplar would be the least reviewable edit in the tool.
--
-- ⚠ THE READER IS THE PRECONDITION, AND IT IS WHY THIS WORKS AT ALL. Terms come
-- from `cartograph.algebraread`, whose law is `cst_print(read(src)) == src` byte
-- for byte — so a derived term prints back as real source rather than as a
-- pretty-printed approximation of it. Without the lossless reader this verb could
-- describe an edit but not emit one.
-- ⚠ PLAIN LUA, NO nvim GLOBALS. clones.lua states the rule where it bit: use a
-- local line splitter, "not `vim.split`: this module is plain Lua and the headless
-- index flows load it". The algebra's own suite runs under Lua 5.1 and LuaJIT with
-- no editor at all, so a seam onto it must not be the thing that drags one in.
-- luacheck's undefined-global warning was the guard that caught this, and I nearly
-- read it as lint noise.
local function as_lines(src)
    if type(src) == 'table' then return src end
    if type(src) ~= 'string' then return nil end
    local out, i = {}, 1
    while true do
        local j = src:find('\n', i, true)
        if not j then out[#out + 1] = src:sub(i); return out end
        out[#out + 1] = src:sub(i, j - 1)
        i = j + 1
    end
end

local M = {}

--- Is the operator reachable: the algebra loads AND a reader is registered for
--- `lang`. Returns (true) or (false, why) — never a bare false, because "the
--- algebra is absent" and "this language has no parser" are different repairs.
function M.available(lang)
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return false, 'algebra unavailable: ' .. tostring(why) end
    if type(A.transplant) ~= 'function' then
        return false, 'this algebra revision has no `transplant`'
    end
    lang = lang or 'lua'
    if type((A.parsers or {})[lang]) ~= 'function' then
        return false, ('no reader registered for `%s` (only an audited grammar is'):format(lang)
            .. ' registered; see algebraread\'s RESERVED note)'
    end
    return true
end

--- Apply the edit `a_src` → `b_src` to `c_src`, all in `lang`.
--- Returns (new_src, info) or (nil, why). `info` carries the operator's own
--- account: kind (value|template|both|straddle), route, and what it did.
---
--- ⚠ EVERY REFUSAL IS PASSED THROUGH BY NAME. The operator refuses a straddle
--- whose hole value also occurs in the shared part, because b's mentions of it
--- cannot be attributed — a real ambiguity, and turning it into "no change" would
--- hide an edit the caller asked for.
function M.apply(a_src, b_src, c_src, lang)
    lang = lang or 'lua'
    local ok, why = M.available(lang)
    if not ok then return nil, why end
    local A = require('cartograph.algebra').load()
    local reader = require 'cartograph.algebraread'
    local terms = {}
    for name, src in pairs { a = a_src, b = b_src, c = c_src } do
        local t, rwhy = reader.read(src, lang)
        if not t then return nil, ('could not read `%s`: %s'):format(name, tostring(rwhy)) end
        terms[name] = t
    end
    local r, twhy = A.transplant(terms.a, terms.b, terms.c)
    if not r then return nil, ('transplant refused: %s'):format(tostring(twhy)) end
    local out = A.cst_print(r.result)
    -- ⚠⚠ THE DEGENERATE, AND IT IS DANGEROUS IF IT REACHES A CALLER. The
    -- operator's context is TOTAL STRUCTURAL AGREEMENT between the exemplar and
    -- the target (the donor's header says so, against SYDIT's dependence-based
    -- PARTIAL context). When a and c do not agree there is no context: classify
    -- reports a pure `value` edit and the "derived" result is b VERBATIM — the
    -- exemplar's new body. Applying that would not edit the target, it would
    -- REPLACE it, silently, with someone else's function.
    -- Measured on a one-line exemplar against a four-line target with a comment:
    --     close   kind=template  out == b: false   <- a real derivation
    --     distant kind=value     out == b: TRUE    <- this
    -- The guard is exact rather than heuristic: reproducing the exemplar is only
    -- legitimate when the target WAS the exemplar.
    if out == b_src and c_src ~= a_src then
        return nil, 'transplant derived nothing: the exemplar and the target do not'
            .. ' agree structurally, so the result is the exemplar\'s own body.'
            .. ' Applying it would replace the target rather than edit it.'
    end
    return out, {
        kind = r.kind, route = r.route,
        applied = r.applied, lifted = r.lifted,
        replaced = r.replaced, dropped = r.dropped,
    }
end

--- Report lines for a derived edit — the reviewable scaffold, in the shape the
--- other proposal verbs use.
function M.report(a_src, b_src, c_src, lang)
    local out, info = M.apply(a_src, b_src, c_src, lang)
    if not out then
        return { 'transplant: ' .. tostring(info) }
    end
    local L = {
        ('transplant — the edit demonstrated once, derived for a second site (%s, route %s)')
            :format(tostring(info.kind), tostring(info.route)),
        '  the exemplar edit:',
    }
    for _, l in ipairs(as_lines(a_src)) do L[#L + 1] = '    - ' .. l end
    for _, l in ipairs(as_lines(b_src)) do L[#L + 1] = '    + ' .. l end
    L[#L + 1] = '  derived for the target:'
    for _, l in ipairs(as_lines(c_src)) do L[#L + 1] = '    - ' .. l end
    for _, l in ipairs(as_lines(out)) do L[#L + 1] = '    + ' .. l end
    L[#L + 1] = '  (proposal only — transplant derives a term, it moves nothing;'
    L[#L + 1] = '   review the text above and apply it yourself.)'
    return L
end

return M
