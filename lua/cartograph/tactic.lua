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

--- the decision hazards on `plan` the step did not accept: { plain rows }, and the accepted ones. Every row carries
--- its identity `key` (cartograph.decisions.key) — what the user remembers to answer THIS question on later runs. An
--- open decision a REMEMBERED answer covers is taken, and says so (`remembered` = the provenance) — unless
--- `remembered == false` (opts.remembered), which asks every question again.
local function decisions(store, plan, accept, remembered, approvals)
    local D = require 'cartograph.decisions'
    -- ★ SIGNED APPROVALS (CART-1183): a teammate's token answers a question when its signature verifies against the
    -- USER's roster and the deciders policy routes that kind, for every subject, to its principal. Every decision row
    -- carries its PORTABLE key — what a teammate signs from their own checkout
    local A = require 'cartograph.approvals'
    local tokens = approvals and A.gather(approvals) or nil
    local open, taken = {}, {}
    local acc = {}
    for _, k in ipairs(accept or {}) do acc[k] = true end
    local raw = plan.hazards or {}
    local subjects
    for i, row in ipairs(hazard.plain(raw)) do
        if row.class == 'decision' then
            row.key = D.key(store, plan, hazard.row(raw[i]))
            if acc[row.kind] then taken[#taken + 1] = row
            else
                subjects = subjects or D.subjects(store, plan)
                local e, why = nil, nil
                if remembered ~= false then e, why = D.lookup(row.key, row.kind, subjects) end
                local pk, pwhy = A.portable_key(store, plan, hazard.row(raw[i]))
                row.portable_key, row.portable_why = pk, pwhy
                if e then row.remembered, row.decision_id = why, e.id; taken[#taken + 1] = row
                elseif tokens and pk then
                    local t, refused = A.lookup(tokens, pk, row.kind, subjects)
                    if t then
                        row.signed = { principal = t.payload.principal, token = A.id(t), at = t.payload.at, why = t.payload.why }
                        taken[#taken + 1] = row
                    else
                        -- ★ a token that was FOUND and did not answer says why, by name — never a plain stop
                        if #refused > 0 then row.refused_approvals = refused end
                        open[#open + 1] = row
                    end
                else open[#open + 1] = row end
            end
        end
    end
    return open, taken
end

--- a value as plain data (functions, userdata and cycles dropped): what an invocation record may hold
local function plain(v, seen)
    if type(v) ~= 'table' then
        return (type(v) == 'function' or type(v) == 'userdata' or type(v) == 'thread') and nil or v
    end
    seen = seen or {}
    if seen[v] then return nil end
    seen[v] = true
    local o = {}
    for k, x in pairs(v) do if type(k) == 'string' or type(k) == 'number' then o[k] = plain(x, seen) end end
    seen[v] = nil
    return o
end

--- Run ONE invocation `st = { verb, args, accept? }` through `verbs[verb]` ({ plan, arm?, apply }).
--- opts: { verbs, apply = bool, decide = bool (gate on decision hazards), replan = bool (re-plan once on stale),
---         ns = the namespace the step writes with (a cross-world plan needs its target mounted rw; an ACCEPTED decision
---         naming the target grants it — txn.grant) }
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
            if class == 'empty' then
                -- ★ RECONCILE (CART-1185): an OPEN intent for this very invocation whose goal check now says "already
                -- there" took effect after all — close it as such
                local I = require 'cartograph.intents'
                local root = store.data and store.data.root
                local open = root and I.get(root, I.identity(verb, st.args))
                if open then I.close(root, open.id, 'reconciled-done') end
                return { ok = true, empty = true, why = why, reconciled = open and 'done' or nil }
            end
            last = fail(class, why, 'plan')
        else
            local accepted = {}
            local acc = {}
            for _, k in ipairs(st.accept or {}) do acc[k] = true end
            if opts.decide then
                local open, taken = decisions(store, plan, st.accept, opts.remembered, opts.approvals)
                if #open > 0 then
                    local texts = {}
                    for _, r in ipairs(open) do texts[#texts + 1] = r.text end
                    return fail('decision', table.concat(texts, ' | '), 'decision',
                        { options = open, fixes = hazard.fixes(plan), plan = plan })
                end
                accepted = taken
                -- a REMEMBERED answer is an accepted one for everything downstream (the grant of a target mount included)
                for _, r in ipairs(taken) do acc[r.kind] = true end
            end
            -- ★ the namespace this step writes with: a cross-world target is mounted rw only by an ACCEPTED decision
            local ns = txn.grant(opts.ns, plan, acc)
            local staged, swhy, sclass = txn.stage(store, plan, nil, { ns = ns })
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
                -- ★ AN EFFECT THE JOURNAL CANNOT HOLD records its INTENT first (CART-1185): if the apply raises or the
                -- world cannot say whether it took effect (environment), the outcome is INDETERMINATE — never "failed"
                -- (a retry might then duplicate it) and never "done" (it might not have happened). The intent stays
                -- open, and re-running the step reconciles it through the verb's own goal check.
                local I = require 'cartograph.intents'
                local root = store.data and store.data.root
                local journaled = spec.effect == 'journaled'
                local intent = (not journaled and root) and I.open(root, verb, st.args, opts.where) or nil
                -- ★ WHO DECIDED (CART-1179): the plan carries the decisions this step was applied under into its journal
                -- entry — each accepted question, and whether the term's accept list or a REMEMBERED decision answered it
                plan.decided_by, plan.decisions = 'tactic', {}
                for _, a in ipairs(accepted) do
                    plan.decisions[#plan.decisions + 1] = { kind = a.kind, key = a.key,
                        by = a.remembered and 'remembered' or a.signed and 'signed' or 'accept-list', decision_id = a.decision_id,
                        principal = a.signed and a.signed.principal or nil, token = a.signed and a.signed.token or nil }
                end
                -- ★ THE INVOCATION (CART-1191 leaf 1): what was ASKED, so the step can be replayed on another world — the
                -- args as given (as plain data). The journal is LOCAL; a travelling record carries it only through
                -- cartograph.sensitive (CART-1193: an invocation touching an untracked file travels as a hash)
                -- + the files it TOUCHED in its own world (CART-1191 leaf 3: a replay continues past a conflict with the
                -- steps that share no file with it); a cross-world step's files are another world's — left unknown
                plan.invocation = { verb = verb, args = plain(st.args or {}), where = opts.where,
                    touched = not plan.target and plain(plan.touched or {}) or nil }
                local okc, entry, ewhy, eclass = pcall(spec.apply or txn.apply, store, plan, { ns = ns })
                if not okc then entry, ewhy, eclass = nil, tostring(entry), 'environment' end
                if entry then
                    if intent then I.close(root, intent.id, 'applied') end
                    return { ok = true, plan = plan, staged = staged, entry = entry, accepted = accepted }
                end
                if intent and eclass == 'environment' then
                    I.unknown(root, intent.id, ewhy)
                    return fail('frontier', ('the outcome of `%s` is UNKNOWN (%s) — it may have taken effect. Re-running reconciles it: the step is goal-checked, so "already there" is empty and "not there" is retried under the same edit identity')
                        :format(tostring(verb), tostring(ewhy)), 'apply', { plan = plan, staged = staged, indeterminate = intent.id })
                end
                if intent then I.close(root, intent.id, 'refused') end
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
    local undone = 0
    for i = #entries, 1, -1 do
        local want = entries[i]
        -- a cross-world write lives in ITS world's journal (txn.execute journals the target root)
        local root = want.root or store.data.root
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
        -- restored in ANOTHER world: this graph holds none of those files
        if root == store.data.root then
            local okr, rok, rwhy = pcall(require('cartograph.refresh').files, touched)
            if not okr or not rok then
                return undone, ('restored on disk, but the graph refresh refused: %s'):format(tostring(okr and rwhy or rok))
            end
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
--- ★ A BODY AS DATA (CART-1645): `each`'s body may be a TERM in place of a function — instantiated per item, every
--- `T.hole(path[, fmt])` in it replaced by the item's value at `path` (`.` the item itself, `#` its index, `a.b` a
--- field; `fmt` formats it into a string, `%s`). The term stays plain data, so a PLAN is data: serializable, and two
--- plans generalize as terms (their holes are the decisions). A path the item does not have refuses BY NAME — unless
--- the hole carries a `default` (an optional field: `args` only some corpora pass).
function M.T.hole(path, fmt, default) return { op = 'hole', path = path, fmt = fmt, default = default } end
local function hole_value(item, i, path)
    if path == '.' then return item end
    if path == '#' then return i end
    local v = item
    for seg in tostring(path):gmatch('[^.]+') do
        if type(v) ~= 'table' then return nil end
        v = v[tonumber(seg) or seg]
    end
    return v
end
--- one `each` body for one item -> term (raises when a hole names what the item lacks)
function M.each_body(t, item, i)
    if type(t.body) == 'function' then return t.body(item, i) end
    local function inst(x)
        if type(x) ~= 'table' then return x end
        if x.op == 'hole' then
            local v = hole_value(item, i, x.path)
            if v == nil then v = x.default end
            if v == nil then error(('each: the item has no `%s` for a hole'):format(tostring(x.path)), 0) end
            return x.fmt and x.fmt:format(tostring(v)) or v
        end
        local o = {}
        for k, v in pairs(x) do o[k] = inst(v) end
        return o
    end
    return inst(t.body)
end
--- a NAMED toolbelt entry as a step (cartograph.toolbelt): a write entry runs its own term, a discovery is a PREMISE
--- gate — it passes when its claim holds and fails ill-posed, by name, when it does not. `name` may be a QUERY
--- { tag, at?, kind? }: the one tactic so tagged that APPLIES at the subject (CART-1448; several = a decision)
function M.T.use(name, params) return { op = 'use', name = name, params = params or {} } end
--- ★ DATA FLOW (CART-1444): run the NAMED discovery and hand its VALUE to `body(value) -> term | nil, why, class` — the
--- next step is built from what was measured (an optimization loop: profile -> advise -> rewrite). Gates like `use`:
--- a claim that does not hold stops the run by name. A body that returns nil stops with its class (`decision` = the
--- choice the measurement left open). ⚠ the body is a Lua function, so (like `each`) the term is not serializable.
--- `opts.ungated`: the body gets the value whether or not the claim holds (a check that a rewrite REMOVED what the
--- discovery finds: its claim failing is the success)
function M.T.bind(name, params, body, opts)
    return { op = 'bind', name = name, params = params or {}, body = body, ungated = opts and opts.ungated or nil }
end
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

--- a symbol's address, as the provenance map keys it
local function key(file, name) return tostring(file) .. '::' .. tostring(name) end

local eval

--- ★ A PREVIEWED STEP'S WORLD (CART-1160 step 3): the overlay world its staged edit would produce, so the NEXT step
--- plans against the text this one would write instead of refusing as underivable. Only a JOURNALED step chains:
--- `journaled` means the journal can undo the write by restoring the touched files' bytes, so the staged texts ARE the
--- whole effect. A compensable or irreversible step does something the text does not show, and a world that omitted
--- it would be a preview of something else. -> overlay data | nil, why, class
function M.next_world(store, effect, r)
    if r.plan and require('cartograph.txn').cross_world(store, r.plan) then
        return nil, ('it writes ANOTHER world (%s), not the one this preview derives'):format(tostring(r.plan.target.root)), 'frontier'
    end
    if effect ~= 'journaled' then return nil, ('its effect is %s, which an overlay of the staged text does not capture'):format(tostring(effect)), 'frontier' end
    local edits, n = {}, 0
    for rel, text in pairs(r.staged.after or {}) do
        if type(text) ~= 'string' then return nil, ('it removes %s, and an overlay world has no removals yet'):format(rel), 'unbuilt' end
        if text ~= r.staged.before[rel] then edits[rel] = text; n = n + 1 end
    end
    if n == 0 then return nil, 'its staged edit changes no file', 'empty' end
    return require('cartograph.world').edit(store.data, edits)
end

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
    local r = M.step(store, t, { verbs = opts.verbs, apply = opts.apply, decide = true, replan = true, ns = opts.ns,
        remembered = opts.remembered, approvals = opts.approvals })
    local corrected
    if not r.ok and (r.class == 'ill-posed' or r.class == 'stale') and r.phase == 'plan' and spec.correct
        and opts.correct ~= 'off' then
        r, corrected = M.correct(store, t, spec, r, opts)
    end
    local out = outcome()
    if corrected then
        out.residue[1] = { kind = 'corrected', class = 'informational', where = where, verb = t.verb,
            text = ('corrected `%s`: %s'):format(corrected.arg, corrected.why), change = corrected }
    end
    local row = { where = where, verb = t.verb, ok = r.ok, class = r.class, why = r.why, phase = r.phase,
        indeterminate = r.indeterminate }
    out.trace[1] = row
    if not r.ok then
        out.options, out.fixes = r.options, r.fixes
        -- ★ an INDETERMINATE effect may have happened: no enclosing first/try/repeat may move on over it (CART-1185)
        if r.indeterminate then out.unrecoverable = true end
        return adopt(out, { class = r.class, why = r.why, where = where, options = r.options, fixes = r.fixes })
    end
    -- ★ PROVENANCE: what this step made true (it applied, or its goal check found it done), for a later correction
    if spec.provides and (r.entry or r.empty) then
        opts.moved = opts.moved or {}
        for _, p in ipairs(spec.provides(t.args or {})) do opts.moved[key(p.from.file, p.from.name)] = p.to end
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
        out.entries[1] = { entry = r.entry, effect = effect, rerun = spec.rerun, where = where, verb = t.verb,
            -- a COMPENSABLE step's inverse, as an invocation the verb derives from its args and the entry (CART-1186)
            compensation = effect == 'compensable' and spec.compensate and spec.compensate(t.args or {}, r.entry) or nil }
    end
    if not opts.apply then
        row.previewed = true
        opts.previewed = true
        -- the rest of the run plans against the world this step would produce; without one, it is underivable
        local over, wwhy = M.next_world(store, effect, r)
        if over then
            store.ingest(over)
            opts.worlds = (opts.worlds or 0) + 1
            row.world = opts.worlds
        else
            opts.previewing_blocked = where
            row.why = ('the preview stops here: %s'):format(tostring(wwhy))
        end
    end
    -- the residue: every hazard the step leaves, with accepted decisions demoted to informational (an answered
    -- question is a consequence of a choice already made)
    local accepted = {}
    for _, a in ipairs(r.accepted or {}) do accepted[a.kind] = a end
    for _, h in ipairs(hazard.plain(r.plan.hazards)) do
        if h.class == 'decision' and accepted[h.kind] then
            h.class = 'informational'; h.accepted = true
            -- ★ never silent: WHO answered it — the term's accept list, or a remembered decision (which one, when)
            if accepted[h.kind].remembered then
                h.remembered, h.decision_id = accepted[h.kind].remembered, accepted[h.kind].decision_id
                h.text = ('%s — answered: %s'):format(h.text, h.remembered)
            elseif accepted[h.kind].signed then
                local sg = accepted[h.kind].signed
                h.signed = sg
                h.text = ('%s — approved by %s (signed %s, token %s)'):format(h.text, sg.principal, tostring(sg.at), sg.token)
            end
        end
        h.where, h.verb = where, t.verb
        out.residue[#out.residue + 1] = h
    end
    return out
end

--- ★ DID YOU MEAN (CART-1152). A step refused at PLAN time as ill-posed, or stale after its re-plan: ask
--- cartograph.correct for single-argument corrections, and keep those the VERB accepts, meaning a dry step plans and
--- stages with no failing guard. The corrector proposes and the verb decides whether the call is well-formed; neither
--- knows what the caller MEANT. USER (2026-09-28): "I wonder if the corrections can be surprising". MEASURED yes: a
--- hand-typed M.get was applied to M.set, one edit away with the opposite meaning, and a deleted a.lua::M.setup was
--- "moved" onto an unrelated b.lua::M.setup, reusing the caller's `accept` for a function they never saw. So:
---   AUTOMATIC only on PROVENANCE: the candidate is where THIS run's own completed step put the symbol (`provides`).
---     That is known, not inferred, it is the same symbol, and the step's `accept` rightly carries over.
---   a WITNESSED ref whose symbol is GONE -> a stale failure that says so; near names are information, not the answer
---   anything else inferred (edit distance, shape, the same name elsewhere) -> a DECISION whose options carry the
---     corrected args. Which symbol a name means, on inferred evidence, is a genuine decision.
---   none survive -> the original refusal, saying how many candidates were tried
--- opts.correct = 'ask' makes even a provenance correction a decision; 'off' disables correction.
--- -> r (the step result to use), corrected (the change applied, or nil)
function M.correct(store, t, spec, r, opts)
    local C = require 'cartograph.correct'
    local cands = C.suggest(store, spec, t.args or {})
    if #cands == 0 then return r end
    local moved = opts.moved or {}
    local function proven(c)
        local was, now = c.was, c.now
        if type(was) ~= 'table' or type(now) ~= 'table' then return false end
        local to = moved[key(was.file, was.name)]
        return to ~= nil and to.file == now.file and to.name == now.name
    end
    local live = {}
    for _, c in ipairs(cands) do
        local d = M.step(store, { verb = t.verb, args = c.args, accept = t.accept }, { verbs = opts.verbs, apply = false })
        if d.ok and not d.empty and d.staged and not d.staged.failed then c.proven = proven(c); live[#live + 1] = c end
    end
    local proofs = {}
    for _, c in ipairs(live) do if c.proven then proofs[#proofs + 1] = c end end
    if #proofs == 1 and opts.correct ~= 'ask' then
        local c = proofs[1]
        local again = M.step(store, { verb = t.verb, args = c.args, accept = t.accept },
            { verbs = opts.verbs, apply = opts.apply, decide = true, replan = true })
        c.why = ('%s — this run moved it there'):format(c.why)
        return again, c
    end
    -- the symbol a WITNESSED ref names is gone: say so; near names are information, never the answer
    local gone
    for arg, kind in pairs(spec.correct or {}) do
        local v = (t.args or {})[arg]
        local refs = kind == 'refs' and (v or {}) or { v }
        for _, ref in ipairs(refs) do
            if C.gone(store, ref) then gone = ref; break end
        end
    end
    if gone and #proofs == 0 then
        local names = {}
        for _, c in ipairs(live) do
            local now = c.now
            names[#names + 1] = type(now) == 'table' and (tostring(now.file) .. '::' .. tostring(now.name)) or tostring(now)
        end
        r.class = 'stale'
        r.why = ('%s::%s is GONE (no function of that name in its file, none of its shape elsewhere) — nothing was corrected%s')
            :format(tostring(gone.file), tostring(gone.name), #names > 0 and ('; near names, for information: ' .. table.concat(names, ', ')) or '')
        return r
    end
    if #live == 0 then
        r.why = ('%s (no correction survived: %d candidate(s) tried)'):format(tostring(r.why), #cands)
        return r
    end
    local options, texts = {}, {}
    for _, c in ipairs(live) do
        local now = c.now
        local to = type(now) == 'table' and (tostring(now.file) .. '::' .. tostring(now.name)) or tostring(now)
        options[#options + 1] = { kind = 'correction', class = 'decision', arg = c.arg, args = c.args, source = c.source,
            proven = c.proven or nil,
            text = ('did you mean %s = %s? (%s%s)'):format(c.arg, to, c.why,
                c.contradicts and '; its shape CONTRADICTS the ref\'s witness' or '') }
        texts[#texts + 1] = options[#options].text
    end
    return { ok = false, class = 'decision', phase = 'correct', options = options,
        why = ('%s — %s'):format(tostring(r.why), table.concat(texts, ' | ')) }
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
local function undo(store, records, verbs)
    -- ★ COMPENSATION (CART-1186): a COMPENSABLE step recorded its inverse as an INVOCATION { verb, args } (derived by
    -- its verb, `spec.compensate(args, entry)`); rollback runs it through the SAME step executor as any step, so a
    -- compensation is planned, staged, guarded, journaled and traced like everything else — never a closure hidden in
    -- an entry. All-or-nothing PRECHECK first: an irreversible record, or a compensable one with no compensation,
    -- refuses the whole rollback by name before anything is undone.
    for _, rec in ipairs(records) do
        if rec.effect == 'irreversible' or (rec.effect == 'compensable' and not rec.compensation) then
            return 0, ('%s at %s made a %s write%s, which nothing can undo'):format(tostring(rec.verb), tostring(rec.where),
                rec.effect, rec.effect == 'compensable' and ' and declared no compensation' or ''), 'refused'
        elseif rec.effect ~= 'journaled' and rec.effect ~= 'compensable' then
            return 0, ('%s at %s made a %s write, which the journal cannot undo'):format(tostring(rec.verb),
                tostring(rec.where), tostring(rec.effect)), 'refused'
        end
    end
    -- newest first, each kind by its own inverse: a journal entry by the journal (identity-checked), a compensation by
    -- running it
    local undone = 0
    for i = #records, 1, -1 do
        local rec = records[i]
        if rec.effect == 'journaled' then
            local n, why = M.rollback(store, { rec.entry })
            undone = undone + (n or 0)
            if why then return undone, why, 'failed' end
        else
            local r = M.step(store, rec.compensation, { verbs = verbs, apply = true })
            if not r.ok then
                -- an ATTEMPTED undo that did not succeed — `failed`, never `refused` (nothing was attempted there)
                return undone, ('the compensation of %s at %s (%s) failed: %s'):format(tostring(rec.verb), tostring(rec.where),
                    tostring(rec.compensation.verb), tostring(r.why)), 'failed'
            end
            undone = undone + 1
        end
    end
    return undone
end

--- run a sub-term as an ATTEMPT (an alternative / an iteration): on failure its writes are undone when they can be;
--- when they cannot, the failure is UNRECOVERABLE and the enclosing tactical must not move on over it
local function attempt(store, t, opts, where)
    -- a DRY attempt's undo: the world it previewed into is dropped, and the lens returns to the world before it
    local world = not opts.apply and { rec = store.capture(), blocked = opts.previewing_blocked, n = opts.worlds }
    opts.depth = opts.depth + 1
    local o = eval(store, t, opts, where)
    opts.depth = opts.depth - 1
    if world and not o.ok then
        if opts.worlds ~= world.n then store.restore(world.rec) end
        opts.previewing_blocked, opts.worlds = world.blocked, world.n
    end
    if not o.ok and #o.entries > 0 then
        local undone, why = undo(store, o.entries, opts.verbs)
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
            for i, item in ipairs(t.items or {}) do
                local okb, k = pcall(M.each_body, t, item, i)
                if not okb then return adopt(out, { class = 'ill-posed', where = where .. '.' .. i, why = tostring(k) }) end
                kids[i] = k
            end
        end
        local outer = opts.tail_can_stop
        for i, k in ipairs(kids) do
            -- (what follows THIS child — inside this sequence or after it — can it still stop the run? a term built at
            -- run time is checked against it: CART-1470)
            local later = outer
            for j = i + 1, #kids do if not later and M._can_stop(kids[j]) then later = true end end
            opts.tail_can_stop = later
            local o = eval(store, k, opts, where .. '.' .. i)
            opts.tail_can_stop = outer
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
            -- a dry repeat sees its own effect through the world its iteration previewed; without one it cannot
            if not opts.apply and opts.previewing_blocked then return out end
        end
        return adopt(out, { class = 'ill-posed', where = where,
            why = ('repeat did not converge within %d iterations — each made a change, none ran out of work'):format(limit) })
    end
    if op == 'use' or op == 'bind' then
        -- ★ TACTICS COMPOSE BY NAME: the toolbelt is a library, not a flat list. Params are coerced by the entry's
        -- own declaration (the same function the CLI and the MCP verb use), and a cycle of uses refuses.
        local tb = require 'cartograph.toolbelt'
        -- ★ RESOLVED AT A SUBJECT (CART-1448): `name` may be a QUERY { tag, at?, kind? } — "the tactic tagged X that
        -- applies here", found through the same lookup scope as `toolbelt find` (mounts, scoped tags, applies()) at `at`
        -- (default: the graph's root). Exactly one applicable runs; several are a DECISION (which one is a choice the
        -- term should name); none refuses BY NAME, with every tagged one that does not apply and why.
        if type(t.name) == 'table' then
            local q = t.name
            local root = store.data and store.data.root
            local at = q.at or root
            local kind = q.kind or (op == 'bind' and 'discovery' or nil)
            local rows = tb.find({ tag = q.tag }, { d = opts.toolbelt_dir, root = root, at = at })
            local fits, not_here = {}, {}
            for _, r in ipairs(rows) do
                if r.applicable and not r.broken and (not kind or r.kind == kind) then fits[#fits + 1] = r.name
                else not_here[#not_here + 1] = ('%s (%s)'):format(r.name, tostring(r.why_not or r.broken or ('a ' .. tostring(r.kind)))) end
            end
            local label = ('%s.%s(tag=%s)'):format(where, op, tostring(q.tag))
            if #fits == 0 then
                return adopt(outcome(), { class = 'ill-posed', where = label, why = ('no %stactic tagged `%s` applies at %s%s'):format(kind and (kind .. ' ') or '',
                    tostring(q.tag), tostring(at), #not_here > 0 and (' — not here: ' .. table.concat(not_here, '; ')) or '') })
            end
            if #fits > 1 then
                return adopt(outcome(), { class = 'decision', where = label, why = ('%d tactics tagged `%s` apply at %s: %s — which one? (name it in the term)')
                    :format(#fits, tostring(q.tag), tostring(at), table.concat(fits, ', ')) })
            end
            t = { op = t.op, name = fits[1], params = t.params, body = t.body, ungated = t.ungated }
        end
        local here = ('%s.%s(%s)'):format(where, op, tostring(t.name))
        opts.using = opts.using or {}
        if opts.using[t.name] then
            return adopt(outcome(), { class = 'ill-posed', where = here,
                why = ('toolbelt tactic `%s` uses itself — a cycle of uses never terminates'):format(tostring(t.name)) })
        end
        local e, lwhy = tb.load(t.name, opts.toolbelt_dir, store.data and store.data.root)
        if not e then return adopt(outcome(), { class = 'ill-posed', where = here, why = lwhy }) end
        local p, pwhy, pclass = tb.coerce(store, e, t.params)
        if not p then return adopt(outcome(), { class = pclass or 'ill-posed', where = here, why = pwhy }) end
        if t.op == 'bind' and e.kind ~= 'discovery' then
            return adopt(outcome(), { class = 'ill-posed', where = here, why = ('bind needs a DISCOVERY to measure; `%s` is a %s'):format(t.name, tostring(e.kind)) })
        end
        if e.kind == 'discovery' then
            local okm, value = pcall(e.measure, store, p)
            if not okm then return adopt(outcome(), { class = 'unbuilt', where = here, why = 'the measurement raised: ' .. tostring(value) }) end
            local holds, cwhy = e.claim(value)
            local o = outcome()
            o.trace[1] = { where = here, verb = (t.op == 'bind' and 'bind:' or 'use:') .. t.name, ok = holds and true or false, why = cwhy }
            if not holds and not t.ungated then
                return adopt(o, { class = 'ill-posed', where = here,
                    why = ('the premise `%s` does not hold: %s'):format(t.name, tostring(cwhy)) })
            end
            o.residue[1] = { kind = 'premise', class = 'informational', where = here,
                text = ('premise `%s` %s: %s'):format(t.name, holds and 'holds' or 'does not hold (ungated)', tostring(cwhy)) }
            if t.op ~= 'bind' then return o end
            local okb, next_t, bwhy, bclass = pcall(t.body, value)
            if not okb then return adopt(o, { class = 'unbuilt', where = here, why = 'the bind body raised: ' .. tostring(next_t) }) end
            if not next_t then return adopt(o, { class = bclass or 'ill-posed', where = here, why = tostring(bwhy) }) end
            -- ★ the BUILT term gets the point-of-no-return walk the run's own term got (CART-1187): built at run time,
            -- it was never seen by the static check
            local nr = M.no_return_check(next_t, opts.verbs)
            if nr then return adopt(o, { class = 'ill-posed', where = here .. '.' .. tostring(nr.gate), why = nr.why }) end
            local irr = opts.tail_can_stop and M._irreversible_in(next_t, opts.verbs or require('cartograph.compose').VERBS)
            if irr then
                return adopt(o, { class = 'ill-posed', where = here, why = ('the term `%s` built holds the irreversible step `%s`, and what follows it can still stop the run — past a point of no return across the boundary (CART-1470). Move the check BEFORE it, or wrap what follows in `try`'):format(tostring(t.name), irr) })
            end
            local k = eval(store, next_t, opts, here .. '.1')
            merge(o, k)
            o.empty = k.empty
            if not k.ok then adopt(o, k) end
            return o
        end
        opts.using[t.name] = true
        -- (build sees the STORE: a write built from the code it rewrites — memoize reads the function's header. A build
        -- that cannot build returns nil, why, class and stops by name)
        local built, bwhy, bclass = e.build(p, store)
        if not built then
            opts.using[t.name] = nil
            return adopt(outcome(), { class = bclass or 'ill-posed', where = here, why = tostring(bwhy) })
        end
        -- (the built term's own point-of-no-return walk, CART-1187 — promised by no_return_check's header, never run)
        local nr = M.no_return_check(built, opts.verbs, e.oracle ~= nil)
        if nr then
            opts.using[t.name] = nil
            return adopt(outcome(), { class = 'ill-posed', where = here .. '.' .. tostring(nr.gate), why = nr.why })
        end
        -- ★ ACROSS THE BOUNDARY (CART-1470): the built term's own walk cannot see what follows it OUTSIDE — an
        -- irreversible step in here, with something after this `use` that can still stop the run, is the same point
        -- of no return the run-start walk refuses
        local irr = opts.tail_can_stop and M._irreversible_in(built, opts.verbs or require('cartograph.compose').VERBS)
        if irr then
            opts.using[t.name] = nil
            return adopt(outcome(), { class = 'ill-posed', where = here, why = ('`%s` builds the irreversible step `%s`, and what follows it can still stop the run — past a point of no return across the boundary (CART-1470). Move the check BEFORE it, or wrap what follows in `try`'):format(tostring(t.name), irr) })
        end
        local o = eval(store, built, opts, here)
        opts.using[t.name] = nil
        if o.ok and opts.apply and e.oracle then
            local ook, owhy = e.oracle(store, o, p)
            if not ook then adopt(o, { class = 'unbuilt', where = here, why = ('%s\'s oracle rejected it: %s'):format(t.name, tostring(owhy)) }) end
        end
        return o
    end
    return adopt(outcome(), { class = 'ill-posed', where = where,
        why = ('no tactical `%s` (then|first|try|repeat|each|step|use|bind)'):format(tostring(op)) })
end

--- CAN `t` STOP THE RUN? (a refusal, a decision, a failed premise) — the same reading no_return_check uses: every
--- step, use and bind can; `first` / `repeat` can as a whole; `try` cannot (it turns a failure into no change)
function M._can_stop(t)
    local op = t and t.op
    if op == 'step' or op == 'use' or op == 'bind' or op == 'first' or op == 'repeat' then return true end
    if op == 'then' then for _, k in ipairs(t) do if M._can_stop(k) then return true end end return false end
    if op == 'each' then return #(t.items or {}) > 0 end
    return false
end

--- the first IRREVERSIBLE step `t` holds (by the verbs' declared effects), or nil — a built term's own `use` / `bind`
--- are checked when THEY run
function M._irreversible_in(t, verbs)
    local op = t and t.op
    if op == 'step' then
        local spec = verbs[t.verb] or {}
        return (not EFFECTS[spec.effect] or spec.effect == 'irreversible') and t.verb or nil
    end
    if op == 'then' or op == 'first' or op == 'try' or op == 'repeat' then
        for _, k in ipairs(t) do local v = M._irreversible_in(k, verbs); if v then return v end end
    end
    if op == 'each' then
        for i, item in ipairs(t.items or {}) do
            local ok, k = pcall(M.each_body, t, item, i)
            local v = ok and M._irreversible_in(k, verbs)
            if v then return v end
        end
    end
    return nil
end

--- ★ NO POINT OF NO RETURN BEFORE A CHECK (CART-1187): walk the term in EXECUTION ORDER before anything runs. Each
--- step can STOP the run (a refusal, a decision) before its effect happens, and an IRREVERSIBLE step's effect cannot be
--- undone by anything; so an irreversible step followed by anything that can still stop the run — a later step, a
--- premise, `first`, `repeat`, the tactic's own oracle — would leave the world past a point of no return with the plan
--- refused. Only `try` cannot stop the run (it turns a failure into no change), so it may follow.
--- The effect is the verb's declared one, undeclared = irreversible (the runner's own rule). `use` expands at run time:
--- it counts as a step that can stop, and its INSIDE is checked when it runs (the same walk, on the built term).
--- -> nil | { irreversible = where, gate = where, why }
function M.no_return_check(term, verbs, has_oracle)
    verbs = verbs or require('cartograph.compose').VERBS
    local events = {}
    local function walk(t, where, safe)
        local op = t and t.op
        if op == 'step' then
            local spec = verbs[t.verb] or {}
            local eff = EFFECTS[spec.effect] and spec.effect or 'irreversible'
            if not safe then events[#events + 1] = { kind = 'stop', where = where, what = 'step `' .. tostring(t.verb) .. '`' } end
            if eff == 'irreversible' then events[#events + 1] = { kind = 'irreversible', where = where, verb = t.verb } end
        elseif op == 'then' then
            for i, k in ipairs(t) do walk(k, where .. '.' .. i, safe) end
        elseif op == 'each' then
            for i, item in ipairs(t.items or {}) do
                local ok, k = pcall(M.each_body, t, item, i)
                if ok then walk(k, where .. '.' .. i, safe) end
            end
        elseif op == 'try' then
            walk(t[1], where .. '.1', true)
        elseif op == 'first' or op == 'repeat' then
            -- an irreversible step inside is refused by the runner itself; the tactical as a whole can stop the run
            if not safe then events[#events + 1] = { kind = 'stop', where = where, what = '`' .. op .. '`' } end
        elseif op == 'use' or op == 'bind' then
            if not safe then events[#events + 1] = { kind = 'stop', where = where, what = op .. ' `' .. tostring(t.name) .. '`' } end
        end
    end
    walk(term, 'root', false)
    if has_oracle then events[#events + 1] = { kind = 'stop', where = 'oracle', what = 'the oracle' } end
    local irr
    for _, e in ipairs(events) do
        if e.kind == 'irreversible' and not irr then irr = e
        elseif e.kind == 'stop' and irr then
            return { irreversible = irr.where, gate = e.where,
                why = ('the irreversible step `%s` at %s is followed by %s at %s, which can still stop the run — past a point of no return, and nothing can undo it. Move the check BEFORE the irreversible step, or wrap what follows in `try`')
                    :format(tostring(irr.verb), irr.where, e.what, e.where) }
        end
    end
    return nil
end

--- the files an overlay world holds that differ from its base: { [rel] = text }
function M.preview_of(data)
    local out
    for _, layer in ipairs((data and data.transport) or {}) do
        if layer.kind == 'overlay' then
            local root = data.base_root or data.root
            for abs, text in pairs(layer.files or {}) do
                out = out or {}
                out[abs:sub(1, #root + 1) == root .. '/' and abs:sub(#root + 2) or abs] = text
            end
        end
    end
    return out
end

--- Run a tactic. opts: { apply = bool (default false: preview up to the first write), verbs (default compose.VERBS),
--- oracle = fn(store, result) -> ok, why (the kernel: runs after a finished APPLY run),
--- on_stop = 'keep' (default: forward recovery) | 'rollback' (undo a run that does not finish — journaled writes only) }
--- -> { status = 'done' | 'previewed' | 'stopped' | 'failed', class?, why?, where?, options?, fixes?,
---      completed = { { where, verb, effect, rerun, journal } }, resumable, residue, work_orders, applied,
---      rolled_back, rollback_refused?, rollback_failed?, trace }
function M.run(store, term, opts)
    opts = opts or {}
    local eopts = { apply = opts.apply and true or false, verbs = opts.verbs, depth = 0, correct = opts.correct,
        tail_can_stop = opts.oracle ~= nil, -- (the oracle runs after everything: it can stop the run)
        toolbelt_dir = opts.toolbelt_dir, ns = opts.ns, remembered = opts.remembered,
        -- signed approvals (CART-1183): a directory store, a list of tokens, or a list of directories
        approvals = opts.approvals }
    -- ★ the static check first: a malformed term is refused before ANYTHING runs, dry or not (CART-1187)
    local nr = M.no_return_check(term, opts.verbs, opts.oracle ~= nil)
    if nr then
        return { status = 'failed', class = 'ill-posed', why = nr.why, where = nr.gate, residue = {}, trace = {},
            completed = {}, resumable = true, applied = 0, rolled_back = 0, corrections = {}, work_orders = {}, worlds = 0 }
    end
    -- ★ A DRY RUN CHAINS OVERLAY WORLDS (CART-1160 step 3) and the caller's graph comes back afterwards, raise or not
    local rec = not eopts.apply and store.capture()
    local okr, o = pcall(eval, store, term, eopts, 'root')
    local preview
    if rec then
        preview = eopts.worlds and M.preview_of(store.data) or nil
        store.restore(rec)
    end
    if not okr then error(o, 0) end
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
        res.status = (not opts.apply and eopts.previewed) and 'previewed' or 'done'
    else
        res.status = o.class == 'decision' and 'stopped' or 'failed'
        res.class, res.why, res.where = o.class, o.why, o.where
        if opts.on_stop == 'rollback' and #kept > 0 then
            local undone, why, kind = undo(store, kept, eopts.verbs)
            res.rolled_back = res.rolled_back + undone
            -- REFUSED = the precheck declined before undoing anything; FAILED = an undo was attempted and did not succeed
            if why and kind == 'refused' then res.rollback_refused = why
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
    -- ★ WHAT MAY BE IN FLIGHT (CART-1185): this run's indeterminate steps, and every intent still OPEN for this world —
    -- including a previous run's that crashed. Re-running the term reconciles each.
    res.indeterminate = {}
    for _, t in ipairs(res.trace or {}) do
        if t.indeterminate then res.indeterminate[#res.indeterminate + 1] = { where = t.where, verb = t.verb, intent = t.indeterminate, why = t.why } end
    end
    res.open_intents = (store.data and store.data.root) and require('cartograph.intents').open_intents(store.data.root) or {}
    -- a dry run's result: every file the chain would write, at its final text, and how many worlds it stacked
    res.preview, res.worlds = preview, eopts.worlds or 0
    -- every correction the run applied, at the top of the result: a correction is never only a residue line
    res.corrections = {}
    for _, h in ipairs(res.residue) do if h.kind == 'corrected' then res.corrections[#res.corrections + 1] = h end end
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
