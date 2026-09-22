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
-- txn and no journal entry.
--
-- AND THE ORIGINAL VERSION OF THAT PARAGRAPH WENT ONE CLAUSE TOO FAR (CART-1018). It also
-- refused "no plan handle" -- and in this tree A PLAN IS THE PROPOSAL FORM. A plan is
-- staged, diffed, guarded, stamped and journalled before a byte moves; refusing to produce
-- one does not make the edit more reviewable, it makes it LESS, because the caller is then
-- handed bare text with no diff, no freshness check and no record. The fear in that
-- sentence is of a WRITE, and a plan is the opposite of one.
-- THE CONTRADICTION WAS LOAD-BEARING AND MEASURED: `replace` was built (CART-0977) exactly
-- because "`transplant` derives a real source edit and has nowhere to hand it", and a
-- census found `cartograph.replace` had TWO users -- the MCP verb and its own test. The
-- verb was built for a caller that declined to call it, and this paragraph was the reason.
-- `M.plan` below is the wire.
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
-- @langs any
-- The operator is the ALGEBRA's, and the algebra is grammar-agnostic: what
-- decides whether a language is servable is whether a READER is registered for
-- it, which `M.available` asks and answers by name. Today that is lua alone
-- (algebraread's audited grammar) — but that is a fact about the reader roster,
-- not a claim written into this seam, and a second reader widens it with no edit
-- here.
function M.available(lang)
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return false, 'algebra unavailable: ' .. tostring(why) end
    if type(A.transplant) ~= 'function' then
        return false, 'this algebra revision has no `transplant`'
    end
    -- @langs-ok the default is the caller's convenience; an unregistered language
    -- is REFUSED by name on the next line rather than silently read as lua
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
    lang = lang or 'lua'  -- @langs-ok the same default, checked by M.available below
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
    -- ⚠⚠ THE SIGNAL IS `kind`, NOT THE TEXT — and the first cut had it backwards.
    -- Guarding on `out == b` caught only the LOUD degenerate (the result IS the
    -- exemplar). There is a QUIETER one it let through: with a target that has an
    -- extra statement, the derivation keeps the TARGET's signature and splices the
    -- EXEMPLAR's variable into the body —
    --     a  local function f(x) return wrap(x) end
    --     c  local function g(y) local z = y return wrap(z) end
    --     -> local function g(y) return wrap(x, DEFAULT) end   <- `x` is not bound
    -- which is valid Lua referencing an undefined name, is NOT equal to b, and
    -- would have shipped.
    -- MEASURED over eight triples: every one of the six legitimate derivations
    -- classifies `template` — INCLUDING a pure value edit, which is the case one
    -- would expect to classify `value` — and both degenerates classify `value`.
    -- That reads off the operator's own definition: a `value` edit is a change
    -- confined to the context's hole VALUES, so when there is no context every
    -- change is a value change and the edit degenerates into a wholesale replace.
    -- ⚠ EIGHT SAMPLES, NOT A PROOF. `out == b_src` is kept as a second net.
    if (r.kind == 'value' or out == b_src) and c_src ~= a_src then
        return nil, ('transplant derived nothing usable (classify: %s): the exemplar'
            .. ' and the target do not agree structurally, so the edit has no context'
            .. ' to land in. The result would carry the exemplar\'s own names into the'
            .. ' target rather than editing it.'):format(tostring(r.kind))
    end
    return out, {
        kind = r.kind, route = r.route,
        applied = r.applied, lifted = r.lifted,
        replaced = r.replaced, dropped = r.dropped,
    }
end

--- THE WIRE: a derived edit as a REVIEWABLE PLAN (CART-1018).
--- Takes three definition ids -- the exemplar pair `a` -> `b` and the target `c` -- reads
--- their source from the tree, derives c-prime through `M.apply`, and hands it to
--- `replace.plan` with `origin = 'derived'`.
---
--- IT DERIVES NOTHING NEW. Every refusal is `M.apply`'s, passed through by name, and the
--- plan's guard is `replace`'s (`parses`). What the wire adds is PROVENANCE: the
--- replacement is marked derived and attributed to this operator, so the plan claims
--- `unreviewed` rather than `none`, and its hazard names the deriver instead of saying the
--- text was supplied -- which for this caller would have been false.
--- The language is taken from `c`, the definition being edited.
--- @return table|nil plan
--- @return string|nil why
function M.plan(store, opts)
    opts = opts or {}
    local txn = require 'cartograph.txn'
    local atr = require 'cartograph.at'
    local src, node = {}, {}
    for _, which in ipairs({ 'a', 'b', 'c' }) do
        local id = opts[which]
        if not id then return nil, ('transplant needs `%s` (a definition id)'):format(which) end
        local n = store.node(id)
        if not n then return nil, ('no definition %s for `%s`'):format(tostring(id), which) end
        if not (n.file and n.range) then
            return nil, ('`%s` (%s) carries no file range to read'):format(which, tostring(n.name))
        end
        local text = txn.read_file(store.data.root, n.file)
        if not text then return nil, ('cannot read %s'):format(n.file) end
        local lines = vim.split(text, '\n', { plain = true })
        local lo, hi = atr.sl(n.range), atr.el(n.range)
        if not lines[hi + 1] then
            return nil, ('`%s` (%s) spans lines %d..%d but %s has %d -- the graph is stale')
                :format(which, tostring(n.name), lo + 1, hi + 1, n.file, #lines)
        end
        local got = {}
        for i = lo, hi do got[#got + 1] = lines[i + 1] end
        src[which] = table.concat(got, '\n')
        node[which] = n
    end

    local ext = (node.c.file:match('%.(%w+)$') or ''):lower()
    local lang = opts.lang or ({ lua = 'lua', js = 'javascript', jsx = 'javascript',
        cjs = 'javascript', mjs = 'javascript' })[ext] or ext
    local out, info = M.apply(src.a, src.b, src.c, lang)
    if not out then return nil, tostring(info) end
    -- A NO-OP IS A REFUSAL, NOT A PLAN. `M.apply` kills the degenerate cases by name; this
    -- catches the remaining one, an edit that lands on `c` and changes nothing. Staging it
    -- would spend a review on a diff with no content.
    if out == src.c then
        return nil, ('the derived edit leaves `%s` unchanged -- the exemplar difference'
            .. ' does not reach it'):format(tostring(node.c.name))
    end

    local plan, why = require('cartograph.replace').plan(store, {
        node = opts.c, text = out, origin = 'derived', derived_by = 'transplant',
        derived_why = ('%s -> %s applied to %s, kind %s route %s'):format(
            tostring(node.a.name), tostring(node.b.name), tostring(node.c.name),
            tostring((info or {}).kind), tostring((info or {}).route)),
    })
    if not plan then return nil, why end
    -- the operator's own account rides along, so a reviewer sees WHAT it did and not only
    -- that something did
    plan.transplant = { a = opts.a, b = opts.b, c = opts.c, info = info }
    return plan
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
