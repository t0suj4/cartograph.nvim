-- THE HOLE CENSUS AS A LIBRARY (CART-0258/0261/0266, extracted CART-0262).
--
-- ONE function's holes, computed once and consumed by two surfaces: the measurement
-- harness (tools/holecensus.lua, which counts and rotates them) and the EMITTER
-- (cartograph.characterize, which turns them into a runnable spec). It lives here for
-- the reason portflow.lua does: a probe and a verb that compute the same thing
-- SEPARATELY will disagree, and the disagreement will be discovered by a reader who
-- trusts the wrong one.
--
-- hole = { kind, name, tier|nil, why, rule, hard?, stub?, hedged?, constraint? }
--   kind      input | oracle | dependency | fixture
--   tier nil  = FRONTIER (no evidence edge)
--   rule      which analysis OWNS filling it — recorded even when frontier, because
--             "nobody owns this" and "the owner failed" are different answers.
--   constraint  INPUT holes only: what the body says about the parameter, as
--             synth.summary's flat closed record { shape, fields, methods, tested,
--             why, domain? }. A THIRD STATE between filled and frontier (CART-0318) —
--             it never sets a tier, so a constrained hole still blocks and still
--             errors. TWO AXES (CART-0323): SHAPE is what the value must BE, DOMAIN
--             (`{ is, isnt }`, CART-0319) is which values were compared against — a
--             lower bound, never a closure, and never classified.
--
-- WHAT BLOCKS EMISSION IS NARROWER THAN "FRONTIER", and M.blocking is the one place
-- that decides it (the census and the emitter must agree on which functions are
-- emittable, or the headline measures a different population than the verb serves).

-- @langs lua
-- The emittability census is lua-shaped: `return_statement` is lua's name (ruby
-- says `return`, rust `return_expression`), and the annotation tiers it ranks are
-- LuaLS `---@` docblocks. Declared narrow so widening it is a decision someone
-- makes on purpose — see [[cartograph-characterization-arc]] first (CART-0304).
local M = {}

local annot = require 'cartograph.annot'
local argvm = require 'cartograph.argv'
local builtins = require 'cartograph.builtins'
local expr = require 'cartograph.expr'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'
local effects = require 'cartograph.effects'
local callrec = require 'cartograph.callrec'
local pm = require 'cartograph.spec.profile'

-- THE BASE RUNTIME'S SIGNATURES (CART-0266), loaded per call through the memoized
-- loader. nil when no artifact ships for the language, and every consumer must render
-- that differently from "this member has no signature".
local function stdprof_for(lang)
    local base = pm.base_for(lang or 'lua')
    return base and pm.load(base) or nil
end

-- ── the docblock above a def, as {params={name->type}, ret=bool} ─────────────
-- Mirrors lint.lua's annotation_findings walk (same reader, same adhesion rule).
function M.doc_of(node, lines, pat, pats)
    if not (pat and lines) then return nil end
    local s0 = at.sl(node.range)
    local first = txn.attach_above(lines, s0, pats)
    if not first or first >= s0 then return nil end
    local tags = annot.read_block(lines, first, pat)
    if not tags or #tags == 0 then return nil end
    local out = { params = {}, ret = false }
    for _, t in ipairs(tags) do
        if t.kind == 'param' and t.name then out.params[t.name] = t.type or true
        elseif t.kind == 'return' then out.ret = true end
    end
    return out
end

-- ── one function's holes ────────────────────────────────────────────────────
-- hole = { kind, name, tier|nil, why, rule }
--   tier nil  = FRONTIER (no evidence edge)
--   rule      = which analysis OWNS filling it (the rotation axis that becomes a
--               work-list); recorded even when the hole is frontier, because "nobody
--               owns this" and "the owner failed" are different answers.
function M.of(store, node, ctx)
    local stdprof = stdprof_for('lua')
    -- expr.of, NOT flow.record, and the difference is load-bearing (see below):
    -- it materializes rows carrying `.expr` AND returns the spec-driven `bound` set
    -- (expr.bound_names over the language's declared binders), which is the only
    -- source that knows about LOOP VARIABLES.
    local eo = expr.of(store, node.id)
    local fl = eo and eo.fl
    if not fl then return nil, 'no expression rows' end
    local params = fl.params
    -- TRI-STATE: nil means NOT ASKED, and treating it as {} is the bug CART-0125 was
    -- about. A fn we cannot get a param list for is UNMEASURABLE, not param-free.
    if params == nil then return nil, 'no param list (not asked)' end

    local H = {}
    local bound = {}
    for k in pairs(eo.bound or {}) do bound[k] = true end
    for _, p in ipairs(params) do bound[p] = true end
    for _, s in ipairs(fl.stmts or {}) do
        for _, d in ipairs(s.def or {}) do bound[d] = true end
    end

    -- 1. INPUT holes, one per parameter.
    -- A CONCRETE observed argument is k='lit' (a STRING literal — its `v` is always a
    -- string, per the constfold contract) OR k='scalar' (a number/boolean). Measured:
    -- `record("boot", 3)` yields lit then scalar. Checking only 'lit' silently
    -- under-counts every numeric input, and the distinction survives into an emitter,
    -- which must quote one and not the other. k='expr' (a table constructor) is NOT
    -- concrete — the value is a fresh allocation we cannot reproduce from the record.
    local CONCRETE = { lit = 'string', scalar = 'scalar' }
    local calls = store.calls_to and store.calls_to[node.id] or {}
    local litat, litk = {}, {}   -- param index → observed value, and its kind
    for _, c in ipairs(calls) do
        for i = 1, #params do
            if litat[i] == nil then
                local a = argvm.at(c, i)
                if a and CONCRETE[a.k] then litat[i], litk[i] = a.v or '', CONCRETE[a.k] end
            end
        end
    end
    -- LAZY, AND IT MUST STAY LAZY. holes -> synth -> runoracle -> characterize -> holes
    -- is a cycle, and a top-level require here re-enters this module mid-load. The same
    -- idiom synth.fill uses for characterize. Tidying it upward looks like housekeeping
    -- and breaks the load order — the CART-0326 lesson, recorded here so it is not
    -- re-learned.
    local synth = require 'cartograph.synth'
    for i, p in ipairs(params) do
        local h
        if litat[i] ~= nil then
            h = { kind = 'input', name = p, tier = 'measured',
                rule = 'argv', why = ('a call site passes the %s %s'):format(litk[i],
                    tostring(litat[i]):sub(1, 24)) }
        elseif ctx.doc and ctx.doc.params[p] then
            h = { kind = 'input', name = p, tier = 'claim', rule = 'annot',
                why = ('@param declares %s — a CLAIM, docblocks lie (CART-0240)')
                    :format(tostring(ctx.doc.params[p])) }
        else
            -- ★ WHAT `narrow` MEANS, now that it performs something (CART-0319).
            -- The three channels this rule names are NOT three ways to fill:
            --   argv    -> a tier (`measured`), an observed argument
            --   annot   -> a tier (`claim`), a declared type
            --   narrow  -> NO TIER, EVER. It describes and refuses: the constraint
            --              below, and the refusal sentence built from it.
            -- Narrowing was measured at 3.2% collapse-to-a-value, so selling it as a
            -- fill channel would be the over-projection this whole tree was filed on.
            h = { kind = 'input', name = p, rule = 'argv/annot/narrow',
                why = 'no observed literal, no declared type' }
        end
        -- ── WHAT THE BODY SAYS ABOUT THIS PARAMETER (CART-0318) ─────────────
        -- Carried on EVERY input hole, filled or not. On a frontier hole it is the
        -- whole point — "no observed literal, no declared type" and "no value, but it
        -- must answer .read() and be truthy" are different refusals, and the second is
        -- discharged in seconds. On a FILLED hole it is free evidence a reader can
        -- check the fill against, and on an `annot` one it is a docblock and a body
        -- side by side.
        --
        -- ★ IT IS NOT A FILL AND MUST NEVER BECOME ONE. M.blocking reads `tier`, and a
        -- constraint does not set one: a hole with a constraint is still a hole and
        -- still ERRORS. Narrowing improves the refusal; it never discharges it.
        h.constraint = synth.summary(synth.shape_of_rows(fl.stmts, p))
        H[#H + 1] = h
    end

    -- 2. ORACLE hole — the expected value. Absent when the function provably returns
    -- nothing: no `return` row at all, or every return row is a BARE `return` (an
    -- early exit). The bare test is TEXTUAL, deliberately conservative in the
    -- direction of claiming a hole (the flow row does not record arity).
    local retrows, valued = 0, false
    for _, s in ipairs(fl.stmts or {}) do
        if s.t == 'return_statement' then
            retrows = retrows + 1
            local l = ctx.lines and ctx.lines[(s.l or 0)]
            if not (l and (l:match('^%s*return%s*$') or l:match('^%s*return%s+end%s*$')
                or l:match('^%s*return%s*;%s*$'))) then valued = true end
        end
    end
    if retrows > 0 and valued then
        if ctx.doc and ctx.doc.ret then
            H[#H + 1] = { kind = 'oracle', name = '<return>', tier = 'claim',
                rule = 'annot', why = '@return constrains the shape, not the value' }
        else
            H[#H + 1] = { kind = 'oracle', name = '<return>', rule = 'execution',
                why = 'the value needs one RUN; no static tier can supply it' }
        end
    end

    -- 4. DEPENDENCY holes — calls to something ABSENT from the corpus (an
    -- unresolved/outside callee). THE KEY MOVE (user, 2026-08-03): an absent require
    -- does NOT disqualify a function, it becomes an INJECTION POINT. Short of globals
    -- and mutation we know what the body does with what it is given, so a stub makes
    -- it testable — the test then characterizes behaviour UNDER THAT STUB, and the
    -- stub is a SUPPLIED PREMISE the test header must disclose
    -- ([[cartograph-hedge-resolution-writes]]).
    --
    -- So a dependency hole is NON-BLOCKING, like the oracle: you can always inject
    -- something. UNLESS the function is not PURE MODULO INJECTION — a module-state
    -- write or an argument mutation means injection cannot isolate it, and then the
    -- dependency really does block. `hard` marks that case.
    local purity = effects.purity and effects.purity(store, node.id)
    local writes = purity and purity:match('^writes') ~= nil
    -- argument mutation: an lhs field/index rooted at a PARAMETER. effects.purity
    -- summarizes MODULE state, not writes through a parameter, so this is separate.
    local pset, mutates = {}, false
    for _, p in ipairs(params) do pset[p] = true end
    for _, s in ipairs(fl.stmts or {}) do
        for _, e in ipairs(s.expr and s.expr.lhs or {}) do
            if (e.k == 'field' or e.k == 'index') and pset[expr.rootname(e) or ''] then
                mutates = true
            end
        end
    end
    local hard = writes or mutates
    local sites = (store.topo and store.topo().sites) and store.topo():sites(node.id) or {}
    local seend = {}
    -- Roots of absent callees, so the FIXTURE pass does not charge them AGAIN. An
    -- absent `AbsentLib.transform(v)` surfaces twice — as this dependency hole and as a
    -- free read of `AbsentLib` — and the fixture copy is BLOCKING, which would defeat
    -- the injection frame with its own accounting. The root name IS the injection
    -- point, so it belongs to the dependency hole and nowhere else.
    -- `callee` is the BARE segment (`transform`), so the receiver root escapes it —
    -- `full` is the fully-qualified path the spec built (`AbsentLib.transform`) and is
    -- what names the injection point. Take both, plus `full`'s first segment.
    local injroot = {}
    for _, c in ipairs(sites) do
        if not callrec.to(c) then
            for _, nm in ipairs({ callrec.callee(c), callrec.full(c) }) do
                if nm then
                    injroot[nm] = true
                    local seg = nm:match('^([%w_]+)')
                    if seg then injroot[seg] = true end
                end
            end
        end
    end
    for _, c in ipairs(sites) do
        if not callrec.to(c) then             -- no resolved target = outside/unresolved
            local nm = callrec.callee(c) or '?'
            if not seend[nm] then
                seend[nm] = true
                -- THE STUB'S SHAPE, from the strongest source that answers (CART-0266).
                -- A REAL SIGNATURE now exists for the Lua stdlib — params AND returns,
                -- distilled from lua-language-server's @meta by tools/luadistill.lua —
                -- which is what a stub actually needs. READ-SIDE: the base runtime
                -- profile activates nowhere (every Lua repo is a Lua repo, so no shape
                -- marker selects it), so this ASKS rather than waiting for a resolution
                -- change that would move every Lua corpus's graph.
                --
                -- KEPT DISTINCT FROM THE EFFECT VOCABULARY, deliberately. Both are
                -- `claim` tier, and conflating them is what made this ticket's own
                -- caveat necessary: the vocabulary knows a name's EFFECT SHAPE and says
                -- nothing about what a stub RETURNS, so counting a vocabulary hit as a
                -- stubbable signature over-reported by exactly the population the real
                -- signatures now cover. `how` carries the soundness of the match.
                local ssig, how, owners = pm.member_sig(stdprof, nm, callrec.full(c))
                local sig = effects.sig_of and effects.sig_of('lua', nm, false)
                local why
                if ssig then
                    why = ('the %s stdlib declares %s%s'):format(
                        (stdprof or {}).runtime or 'base', ssig.sig,
                        how == 'unique' and ' — HEDGED: the only stdlib owner of this'
                            .. ' member name, receiver unverified' or '')
                elseif how == 'ambiguous' then
                    why = ('%d stdlib owner(s) declare a member named `%s` (%s) — a SET,'
                        .. ' not a signature: the receiver decides and we cannot'):format(
                        #owners, nm, table.concat(owners, ', '))
                elseif how == 'absent-member' then
                    why = 'the namespace IS the stdlib and does not hold this member —'
                        .. ' an absence, which is a stronger statement than an unknown'
                elseif sig then
                    why = 'the effect vocabulary declares this name — an EFFECT shape,'
                        .. ' not a return type: it cannot say what a stub returns'
                elseif hard then
                    why = ('absent, and the fn is not pure-modulo-injection (%s) —'
                        .. ' injection cannot isolate it'):format(
                        writes and 'writes module state' or 'mutates an argument')
                else
                    why = 'absent from the corpus — a stub is a HYPOTHESIS to disclose'
                end
                H[#H + 1] = { kind = 'dependency', name = nm, hard = hard,
                    tier = (ssig or sig) and 'claim' or nil,
                    rule = ssig and 'stdlib' or 'profile',
                    -- the OWNER SET when the name is ambiguous, carried as DATA rather
                    -- than only in the prose, so a consumer can act on it (the emitter
                    -- needs to know the runtime holds every candidate)
                    owners = (how == 'ambiguous') and owners or nil,
                    stub = ssig and ssig.sig or nil,
                    hedged = (how == 'unique') or nil,
                    why = why }
            end
        end
    end

    -- 3. FIXTURE holes — free non-builtin VARIABLE reads. `derived` when a same-file
    -- definition carries the name, so loading the module supplies it.
    --
    -- READS COME FROM `expr.names(row)`, NOT from the flow row's `use`. This is the
    -- difference between a measurement and a fiction: `use` is the du-faithful
    -- IDENTIFIER-LEAF census, in which a dot/method SELECTOR counts as a read — so
    -- `n.file` contributes `file`, and `('%s'):format(x)` contributes `format`. Using
    -- it inflated this corpus's fixture holes to 28,313, and the top "free reads" were
    -- `_` (930), `match`, `format`, `concat` — loop variables and field names, not
    -- unmet dependencies. expr.lua labels the two functions explicitly: `reads` is
    -- "NOT the semantic variable set (a field selector isn't a var)" and `names` is
    -- "names semantically READ … for lints / eval env". This is the second.
    local seen = {}
    for _, s in ipairs(fl.stmts or {}) do
        for _, u in ipairs(s.expr and expr.names(s.expr) or {}) do
            if not bound[u] and not seen[u] and not injroot[u] then
                seen[u] = true
                if not builtins.genuine('lua', u, bound) then
                    if ctx.samefile[u] then
                        H[#H + 1] = { kind = 'fixture', name = u, tier = 'derived',
                            rule = 'linker', why = 'a same-file definition carries this name' }
                    else
                        H[#H + 1] = { kind = 'fixture', name = u, rule = 'linker',
                            why = 'a free name with no definition we can see' }
                    end
                end
            end
        end
    end
    return H
end

--- THE REFUSAL SENTENCE for a hole: `why`, plus what the body already tells us.
---
--- A HEDGE IS A DOOR ([[cartograph-explaining-a-finding]]). "no observed literal, no
--- declared type" is a wall — it says only that we failed. "…but the body USES `node`
--- as a table answering :type(), :named_child()" is a door: a reader supplies one in
--- seconds. The hole still REFUSES; what changes is whether the refusal is actionable.
---
--- ★ THE CONSTRAINT IS RENDERED HERE AND NEVER APPENDED TO `why`, and that is not a
--- style choice. characterize.lua parses this field with ANCHORED patterns —
--- `h.why:match('passes the string (.*)$')` — to recover an observed argument. Growing
--- `why` would break that silently, and the breakage would surface as a resolution bug
--- rather than as the prose edit it was. The record keeps its shape; the sentence is a
--- projection of it.
---
--- USES, NOT REQUIRES (CART-0320): a constraint is a UNION over the body's usages, and
--- nothing here knows whether they can run on the same path.
function M.refusal(h)
    local base = h.why or 'no evidence'
    local c = h.constraint
    if not c then return base end
    local parts = {}
    if c.shape and c.shape ~= 'any' then parts[#parts + 1] = 'a ' .. c.shape end
    if #c.fields > 0 then
        parts[#parts + 1] = 'with .' .. table.concat(c.fields, ', .')
    end
    if #c.methods > 0 then
        parts[#parts + 1] = 'answering :' .. table.concat(c.methods, '(), :') .. '()'
    end
    -- THE DOMAIN, hedged in three words. `is`/`isnt` are what the body COMPARED
    -- against — a lower bound, not a closure. The long version of why lives on
    -- CART-0319, not on every HOLE() line a reader has to scan.
    local name = tostring(h.name)
    local said = {}
    if #parts > 0 then
        said[#said + 1] = ('USES `%s` as %s'):format(name, table.concat(parts, ' '))
    end
    local d = c.domain
    if d and #d.is > 0 then
        said[#said + 1] = ('compares `%s` against %s')
            :format(name, table.concat(d.is, ', '))
    end
    if d and #d.isnt > 0 then
        said[#said + 1] = ('tests `%s` ~= %s'):format(name, table.concat(d.isnt, ', '))
    end
    if #said == 0 then
        -- `any` with nothing under it, but the body TESTS the value — against another
        -- NAME, or through a `type()` we refused to read. Still a door, and a DIFFERENT
        -- one: it says our arbitrary choice is not free, it picks a path.
        if c.tested then
            return ('%s — the body TESTS `%s`, so any value we pick decides which path'
                .. ' runs'):format(base, name)
        end
        return base
    end
    return ('%s — but the body %s%s'):format(base, table.concat(said, ', '),
        d and ' (observed, not exhaustive)'
            or (c.tested and ', and TESTS it' or ''))
end

--- Does this hole BLOCK emitting a test? Narrower than "frontier" on purpose:
---  · ORACLE never blocks — it is the hole a single RUN fills, and no static tier can
---    ever supply it. Counting it made the first headline answer the wrong question,
---    since every value-returning function has one by construction.
---  · DEPENDENCY blocks only when `hard` — an absent require is an INJECTION POINT, so
---    a stub always exists; but a function that writes module state or mutates an
---    argument cannot be isolated by injection, and then it is a real wall.
---  · INPUT / FIXTURE always block: we can neither choose the value nor build the world.
---  · A HOLE WE OURSELVES FILL never blocks — see M.answered.
--- Does ANYTHING speak to this hole? `tier` is static evidence about what the hole IS;
--- `filled_tier` is the strength of a fill we SUPPLIED. Two fields on purpose (invariant 3:
--- the channel and the strength are separate), and every consumer wants the OR of them.
--- ★ IT LIVES HERE BECAUSE IT HAD FOUR COPIES (CART-0287): holes.blocking, and three more in
--- holecensus (the per-fn frontier count, the by-kind rotation, the evidence-tier rotation),
--- all reading `tier` alone. So the census reported `env 1372, frontier 1372 (100%)` while the
--- sandbox roster injected a fake for 246 of them — our own answer printed as the honest
--- frontier, inverting the one distinction the census exists to draw. Fixing one copy moved
--- nothing; that is what four copies buys you.
---@param h table
---@return string|nil  the tier that answers it, or nil if nothing does
function M.answered(h) return h.tier or h.filled_tier or nil end

function M.blocking(h)
    if M.answered(h) then return false end
    if h.kind == 'oracle' then return false end
    if h.kind == 'dependency' and not h.hard then return false end
    return true
end

--- The per-file context M.of needs: the source lines, the names DEFINED in this file
--- (the fixture tier's `derived` evidence) and the docblock above the node.
function M.ctx_for(store, node, lines, pat, pats)
    local rel = node.file
    local samefile = {}
    for _, x in ipairs(store.by_file and store.by_file[rel] or {}) do
        local nn = type(x) == 'table' and x or store.node(x)
        if nn and nn.name then samefile[nn.name] = true end
    end
    return { lines = lines, samefile = samefile,
        doc = M.doc_of(node, lines, pat, pats) }
end

return M
