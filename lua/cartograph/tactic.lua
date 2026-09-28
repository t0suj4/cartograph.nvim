-- cartograph.tactic — TACTICS: WRITE VERBS COMPOSED TOWARD A GOAL, STOPPING ONLY ON A DECISION (CART-1152 step 2).
--
-- USER (2026-09-28): "The only tactic limit should be a genuine decision". Step 1 gave every stop a CLASS
-- (hazard.CLASSES); this is its first consumer. A TACTIC is a term over verb invocations; a TACTICAL combines them
-- (LCF's vocabulary): `then` (sequence), `first` (the first alternative that does not fail), `try` (a failure is no
-- change), `repeat` (until it fails or finds nothing), `each` (one body per item). The LCF soundness rule is already
-- the architecture: tactics are untrusted, and the ORACLE (a caller's `opts.oracle`, the guards, the spec suite)
-- accepts the result.
--
-- WHAT EACH STOP CLASS DOES HERE:
--   decision       STOP, with the options — the ONE real limit. From a refusal of that class, or from a plan hazard
--                  of that class the step did not `accept` (an accepted one rides as informational residue)
--   empty          success with no change: `try` and `repeat` read it as done
--   frontier       a missing fact: `first` moves to its next alternative (an oracle, a different verb)
--   stale          the tree moved: RE-PLAN the step once (an invocation survives a generation bump, a plan does not)
--   unbuilt        fail, and the result carries a WORK ORDER (never auto-filed: a ticket is outward-facing)
--   ill-posed      fail (did-you-mean is CART-1152's next step)
--   informational  continue; rides as residue
--   environment    fail; the machine refused — retry outside
--   (anything else) fail as `unclassified`, BY NAME: an adapter outside the stopclass fence must not be read as a class
--
-- ★★★ FORWARD RECOVERY, NOT ATOMICITY. USER (2026-09-28): "atomicity is a strong guarantee we cannot make once we
-- leave the filesystem". A run that stops or fails KEEPS the steps it completed and reports them (`completed`, each
-- with its EFFECT); resuming is RE-RUNNING the same term with the decision answered — a completed step's goal check
-- makes it `empty` the second time (every compose.VERBS verb declares `rerun = 'empty'`, and a fence measures it).
-- Each verb declares its EFFECT: `journaled` (a local write the journal can undo), `compensable` (an inverse verb
-- exists), `irreversible` (external); an UNDECLARED effect is treated as irreversible. Undo is therefore a POLICY, not
-- a guarantee: `on_stop = 'rollback'` undoes a stopped run only when every completed step is journaled, and refuses
-- by name otherwise. Inside `first` / `try` / `repeat` a failed alternative is undone the same way — and when its
-- writes cannot be undone the runner does NOT move on over an unknown partial state: the failure propagates. An
-- irreversible step inside one of those scopes is refused before it runs (a point of no return cannot be an attempt).
--
-- ⚠ `each` takes a Lua function body (item -> term), so a term holding one is not serializable. Every other node is a
-- plain table with an `op` string, so terms can go through the plan optimizer later (CART-1142).
local M = {}

local hazard = require 'cartograph.hazard'

-- ── one step: plan -> (decision gate) -> arm -> stage -> apply ────────────────────────────────────────────────────
-- ★ THE SHARED STEP: compose's recipe loop and this runner's steps call the same function — two executors of one
-- invocation would be the two-copies defect CART-1153 just removed.

local function fail(class, why, phase, extra)
    local r = { ok = false, class = class, why = why, phase = phase }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

--- the decision hazards on `plan` the step did not accept: { plain rows }, and the accepted ones
local function decisions(plan, accept)
    local open, taken = {}, {}
    local acc = {}
    for _, k in ipairs(accept or {}) do acc[k] = true end
    for _, row in ipairs(hazard.plain(plan.hazards)) do
        if row.class == 'decision' then
            if acc[row.kind] then taken[#taken + 1] = row else open[#open + 1] = row end
        end
    end
    return open, taken
end

--- Run ONE invocation `st = { verb, args, accept? }` through `verbs[verb]` ({ plan, arm?, apply }).
--- opts: { verbs, apply = bool, decide = bool (gate on decision hazards), replan = bool (re-plan once on stale) }
--- -> { ok = true, plan, staged, entry?, empty?, accepted = {rows} }
---  | { ok = false, class, why, phase = 'verb'|'plan'|'decision'|'arm'|'stage'|'guard'|'apply', options? }
function M.step(store, st, opts)
    opts = opts or {}
    local txn = require 'cartograph.txn'
    local verbs = opts.verbs or require('cartograph.compose').VERBS
    local verb = type(st) == 'table' and st.verb or nil
    local spec = verb and verbs[verb]
    if not spec then
        return fail('ill-posed', ('no such verb `%s` — the recipe names one this cartograph does not run')
            :format(tostring(verb)), 'verb')
    end
    local tries = opts.replan and 2 or 1
    local last
    for _ = 1, tries do
        local plan, why, class = spec.plan(store, st.args or {})
        if not plan then
            if class == 'empty' then return { ok = true, empty = true, why = why } end
            last = fail(class, why, 'plan')
        else
            local accepted = {}
            if opts.decide then
                local open, taken = decisions(plan, st.accept)
                if #open > 0 then
                    local texts = {}
                    for _, r in ipairs(open) do texts[#texts + 1] = r.text end
                    return fail('decision', table.concat(texts, ' | '), 'decision',
                        { options = open, fixes = hazard.fixes(plan), plan = plan })
                end
                accepted = taken
            end
            local staged, swhy, sclass = txn.stage(store, plan)
            if not staged then
                if sclass == 'empty' then return { ok = true, empty = true, why = swhy, plan = plan } end
                last = fail(sclass, swhy, 'stage')
            elseif not opts.apply then
                -- ⚠ a FAILING guard verdict is data on `staged`, not a refusal here: a preview of a failing plan is how
                -- you see why (CART-0769), and `execute` refuses it on apply. The runner judges it in dry mode.
                return { ok = true, plan = plan, staged = staged, accepted = accepted }
            else
                if spec.arm then
                    local aok, awhy, aclass = spec.arm(store, plan)
                    if not aok then return fail(aclass or 'stale', awhy, 'arm', { plan = plan, staged = staged }) end
                end
                local entry, ewhy, eclass = (spec.apply or txn.apply)(store, plan)
                if entry then return { ok = true, plan = plan, staged = staged, entry = entry, accepted = accepted } end
                last = fail(eclass, ewhy, 'apply', { plan = plan, staged = staged })
            end
        end
        if last.class ~= 'stale' then break end
    end
    return last
end

-- ── rollback: newest first, identity-checked, graph re-read ───────────────────────────────────────────────────────

--- Undo `entries` (journal entries THIS run applied), newest first. ⚠ journal.rollback pops whatever entry is LAST,
--- so each pop is checked by id first: a count that is off by one inside a `first`/`try` would otherwise undo a
--- sibling's write. After each undo the touched files are re-read (the agent's txn_undo rule — compose's rollback
--- restored bytes and never refreshed the graph). -> undone, why (nil when all were undone)
function M.rollback(store, entries)
    local journal = require 'cartograph.journal'
    local root = store.data.root
    local undone = 0
    for i = #entries, 1, -1 do
        local want = entries[i]
        local last = journal.last(root)
        if not last or last.id ~= want.id then
            return undone, ('the newest journal entry is %s, not this run\'s %s — refusing to undo a write this run did not make')
                :format(last and tostring(last.id) or 'none', tostring(want.id))
        end
        local e, why = journal.rollback(root)
        if not e then return undone, why end
        undone = undone + 1
        local touched = {}
        for rel in pairs(e.files or {}) do touched[#touched + 1] = rel end
        table.sort(touched)
        local okr, rok, rwhy = pcall(require('cartograph.refresh').files, touched)
        if not okr or not rok then
            return undone, ('restored on disk, but the graph refresh refused: %s'):format(tostring(okr and rwhy or rok))
        end
    end
    return undone
end

-- ── terms ─────────────────────────────────────────────────────────────────────────────────────────────────────────
M.T = {}
function M.T.step(verb, args, accept) return { op = 'step', verb = verb, args = args or {}, accept = accept } end
function M.T.seq(...) return { op = 'then', ... } end
function M.T.first(...) return { op = 'first', ... } end
function M.T.try(t) return { op = 'try', t } end
function M.T.rep(t, limit) return { op = 'repeat', t, limit = limit } end
function M.T.each(items, body) return { op = 'each', items = items, body = body } end
M.T['then'], M.T['repeat'] = M.T.seq, M.T.rep

-- ── the runner ────────────────────────────────────────────────────────────────────────────────────────────────────
-- An OUTCOME: { ok, empty?, entries = { { entry, effect, rerun, where, verb } }, residue = { rows }, trace = { rows } }
-- or a failure/stop { ok = false, class, why, where, options?, entries, residue, trace }.

local function merge(into, from)
    for _, e in ipairs(from.entries or {}) do into.entries[#into.entries + 1] = e end
    for _, r in ipairs(from.residue or {}) do into.residue[#into.residue + 1] = r end
    for _, r in ipairs(from.trace or {}) do into.trace[#into.trace + 1] = r end
end

local function outcome() return { ok = true, empty = true, entries = {}, residue = {}, trace = {} } end

--- copy a failure/stop's fields onto `out`
local function adopt(out, o)
    out.ok, out.class, out.why, out.where, out.options, out.fixes = false, o.class, o.why, o.where, o.options, o.fixes
    out.unrecoverable = out.unrecoverable or o.unrecoverable
    return out
end

local EFFECTS = { journaled = true, compensable = true, irreversible = true }

local eval

local function eval_step(store, t, opts, where)
    local spec = (opts.verbs or require('cartograph.compose').VERBS)[t.verb] or {}
    local effect = EFFECTS[spec.effect] and spec.effect or 'irreversible'
    if opts.depth > 0 and effect == 'irreversible' then
        local out = outcome()
        out.trace[1] = { where = where, verb = t.verb, ok = false, class = 'ill-posed' }
        -- the TERM is malformed, not this alternative: it ends the run rather than handing `first` its next option
        out.unrecoverable = true
        return adopt(out, { class = 'ill-posed', where = where,
            why = ('`%s` has an irreversible effect and sits inside first/try/repeat — a point of no return cannot be an attempt'):format(tostring(t.verb)) })
    end
    if opts.previewing_blocked then
        -- dry mode: this step would plan against a tree the previewed step has not produced
        local out = outcome()
        out.empty, out.underivable = false, true
        out.trace[1] = { where = where, verb = t.verb, underivable = true,
            why = ('cannot be derived until %s is applied — its inputs do not exist yet'):format(opts.previewing_blocked) }
        return out
    end
    local r = M.step(store, t, { verbs = opts.verbs, apply = opts.apply, decide = true, replan = true })
    local out = outcome()
    local row = { where = where, verb = t.verb, ok = r.ok, class = r.class, why = r.why, phase = r.phase }
    out.trace[1] = row
    if not r.ok then
        out.options, out.fixes = r.options, r.fixes
        return adopt(out, { class = r.class, why = r.why, where = where, options = r.options, fixes = r.fixes })
    end
    if r.empty then row.empty = true; return out end
    if r.staged and r.staged.failed and not opts.apply then
        -- a dry run judges the guard the apply would: the verb produced an edit that breaks its own obligation
        row.ok, row.class, row.phase = false, 'unbuilt', 'guard'
        row.why = require('cartograph.planguards').refusal(r.staged.failed)
        return adopt(out, { class = 'unbuilt', why = row.why, where = where })
    end
    out.empty = false
    if r.entry then
        out.entries[1] = { entry = r.entry, effect = effect, rerun = spec.rerun, where = where, verb = t.verb }
    end
    if not opts.apply then row.previewed = true; opts.previewing_blocked = where end
    -- the residue: every hazard the step leaves, with accepted decisions demoted to informational (an answered
    -- question is a consequence of a choice already made)
    local accepted = {}
    for _, a in ipairs(r.accepted or {}) do accepted[a.kind] = true end
    for _, h in ipairs(hazard.plain(r.plan.hazards)) do
        if h.class == 'decision' and accepted[h.kind] then h.class = 'informational'; h.accepted = true end
        h.where, h.verb = where, t.verb
        out.residue[#out.residue + 1] = h
    end
    return out
end

local KNOWN = hazard.CLASSES

--- a failure's class, or `unclassified` BY NAME
local function classed(o)
    if not o.ok and o.class ~= 'decision' and not KNOWN[o.class] then
        o.why = ('step at %s refused with no known class (%s): %s'):format(tostring(o.where), tostring(o.class), tostring(o.why))
        o.class = 'unclassified'
    end
    return o
end

--- undo journaled records (newest first) — or say why not: only a JOURNALED write can be undone here
local function undo(store, records)
    for _, rec in ipairs(records) do
        if rec.effect ~= 'journaled' then
            return 0, ('%s at %s made a %s write, which the journal cannot undo'):format(tostring(rec.verb),
                tostring(rec.where), rec.effect)
        end
    end
    local entries = {}
    for i, rec in ipairs(records) do entries[i] = rec.entry end
    return M.rollback(store, entries)
end

--- run a sub-term as an ATTEMPT (an alternative / an iteration): on failure its writes are undone when they can be;
--- when they cannot, the failure is UNRECOVERABLE and the enclosing tactical must not move on over it
local function attempt(store, t, opts, where)
    opts.depth = opts.depth + 1
    local o = eval(store, t, opts, where)
    opts.depth = opts.depth - 1
    if not o.ok and #o.entries > 0 then
        local undone, why = undo(store, o.entries)
        opts.undone = (opts.undone or 0) + undone
        if why then
            o.unrecoverable = true
            o.why = ('%s — and the attempt cannot be undone: %s'):format(tostring(o.why), why)
        else
            o.entries = {}
        end
    end
    return o
end

--- does an attempt's outcome end the enclosing tactical? (success, a decision, or a state nobody can undo)
local function final(o) return o.ok or o.class == 'decision' or o.unrecoverable end

function eval(store, t, opts, where)
    where = where or 'root'
    local op = t.op
    if op == 'step' then return classed(eval_step(store, t, opts, where)) end
    local out = outcome()
    if op == 'then' or op == 'each' then
        local kids = t
        if op == 'each' then
            kids = {}
            for i, item in ipairs(t.items or {}) do kids[i] = t.body(item, i) end
        end
        for i, k in ipairs(kids) do
            local o = eval(store, k, opts, where .. '.' .. i)
            merge(out, o)
            if not o.ok then return adopt(out, o) end
            if not o.empty then out.empty = false end
        end
        return out
    elseif op == 'first' then
        local fails = {}
        for i, k in ipairs(t) do
            local o = attempt(store, k, opts, where .. '.' .. i)
            if final(o) then
                merge(out, o)
                for _, f in ipairs(fails) do out.residue[#out.residue + 1] = f end
                out.empty = o.empty
                if not o.ok then adopt(out, o) end
                return out
            end
            for _, r in ipairs(o.trace) do out.trace[#out.trace + 1] = r end
            -- the alternative that failed is an attempted subgoal, not residue of the result: it rides as informational
            fails[#fails + 1] = { text = ('alternative %d failed (%s): %s'):format(i, tostring(o.class), tostring(o.why)),
                kind = 'alternative', class = 'informational', where = o.where, failed_class = o.class }
        end
        local texts = {}
        for _, f in ipairs(fails) do texts[#texts + 1] = f.text end
        return adopt(out, { class = (#fails > 0 and fails[#fails].failed_class) or 'ill-posed', where = where,
            why = ('every alternative failed: %s'):format(table.concat(texts, ' | ')) })
    elseif op == 'try' then
        local o = attempt(store, t[1], opts, where .. '.1')
        if final(o) then
            merge(out, o); out.empty = o.empty
            if not o.ok then adopt(out, o) end
            return out
        end
        for _, r in ipairs(o.trace) do out.trace[#out.trace + 1] = r end
        out.residue[#out.residue + 1] = { text = ('try: %s'):format(tostring(o.why)), kind = 'try', class = 'informational',
            where = o.where, failed_class = o.class }
        return out
    elseif op == 'repeat' then
        local limit = t.limit or 50
        for n = 1, limit do
            local o = attempt(store, t[1], opts, ('%s.%d'):format(where, n))
            if not o.ok then
                if final(o) then merge(out, o); return adopt(out, o) end
                for _, r in ipairs(o.trace) do out.trace[#out.trace + 1] = r end
                return out -- a failed iteration ends the repetition; its own writes are undone
            end
            merge(out, o)
            if o.empty then return out end
            out.empty = false
            if not opts.apply then return out end -- a dry repeat cannot see its own effect
        end
        return adopt(out, { class = 'ill-posed', where = where,
            why = ('repeat did not converge within %d iterations — each made a change, none ran out of work'):format(limit) })
    end
    return adopt(outcome(), { class = 'ill-posed', where = where,
        why = ('no tactical `%s` (then|first|try|repeat|each|step)'):format(tostring(op)) })
end

--- Run a tactic. opts: { apply = bool (default false: preview up to the first write), verbs (default compose.VERBS),
--- oracle = fn(store, result) -> ok, why (the kernel: runs after a finished APPLY run),
--- on_stop = 'keep' (default: forward recovery) | 'rollback' (undo a run that does not finish — journaled writes only) }
--- -> { status = 'done' | 'previewed' | 'stopped' | 'failed', class?, why?, where?, options?, fixes?,
---      completed = { { where, verb, effect, rerun, journal } }, resumable, residue, work_orders, applied,
---      rolled_back, rollback_refused?, rollback_failed?, trace }
function M.run(store, term, opts)
    opts = opts or {}
    local eopts = { apply = opts.apply and true or false, verbs = opts.verbs, depth = 0 }
    local o = eval(store, term, eopts, 'root')
    local res = { residue = o.residue, trace = o.trace, rolled_back = eopts.undone or 0,
        options = o.options, fixes = o.fixes }
    if o.ok and opts.apply and opts.oracle then
        local ook, owhy = opts.oracle(store, res)
        if not ook then
            adopt(o, { class = 'unbuilt', where = 'oracle', why = ('the oracle rejected the result: %s'):format(tostring(owhy)) })
        end
    end
    local kept = o.entries
    if o.ok then
        res.status = (not opts.apply and eopts.previewing_blocked) and 'previewed' or 'done'
    else
        res.status = o.class == 'decision' and 'stopped' or 'failed'
        res.class, res.why, res.where = o.class, o.why, o.where
        if opts.on_stop == 'rollback' and #kept > 0 then
            local undone, why = undo(store, kept)
            res.rolled_back = res.rolled_back + undone
            if why and undone == 0 then res.rollback_refused = why
            elseif why then res.rollback_failed = why end
            if undone == #kept then kept = {} end
        end
    end
    -- what the run leaves behind, and whether re-running is how to resume it
    res.completed, res.resumable = {}, true
    for _, rec in ipairs(kept) do
        res.completed[#res.completed + 1] = { where = rec.where, verb = rec.verb, effect = rec.effect, rerun = rec.rerun,
            journal = rec.entry and rec.entry.id }
        if rec.rerun ~= 'empty' then res.resumable = false end
    end
    res.applied = #res.completed
    -- the work orders: every UNBUILT stop — the failure itself, a failed alternative, residue a verb left undone
    res.work_orders = {}
    local function order(where, verb, why) res.work_orders[#res.work_orders + 1] = { where = where, verb = verb, why = why } end
    if res.class == 'unbuilt' then order(res.where, nil, res.why) end
    for _, r in ipairs(res.residue) do
        if r.class == 'unbuilt' or r.failed_class == 'unbuilt' then order(r.where, r.verb, r.text) end
    end
    return res
end

return M
