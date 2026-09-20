-- Clone-merge: the first transaction. Merge a function's clones into it
-- — the twins found by the same WITNESS the reference layer trusts (df
-- shape + params + callee set) — by deleting the copies and rewriting
-- their call sites to the survivor's name.
--
-- The transaction contract, door by door:
--   plan   = REFS + witnesses + file stamps + the graph generation,
--            computed now, shown in the plan bar, applied LATE-BOUND;
--   apply  = refuses on ANY drift: generation changed, refs unresolved,
--            witness drifted, file stamps moved, buffers dirty — a
--            refusal names its reason and costs a re-plan, never a
--            corrupted write;
--   journal= before-content captured first (pending -> write ->
--            applied); :CartographUndo restores byte-exact, refusing if
--            files moved on since;
--   after  = the touched files splice back through refresh — the same
--            machinery every save uses.

local M = {}
local atr = require 'cartograph.at'

local txn = require 'cartograph.txn'
local callrec = require 'cartograph.callrec'
local read_file, disk_stamp = txn.read_file, txn.disk_stamp

--- Witness twins of `id`: same kind, equal behavior witness, elsewhere
--- in the graph. The clone detector's identity, reused as the merge's.
--- ★★★ THE STATEMENT-KIND SEQUENCE — the distinction every identity here drops.
---
--- `row_key` is `lhs=rhs;C:cond` and `refs.witness` is df shape + params +
--- callees. NEITHER encodes what KIND of statement a row is, so an `if` block
--- and a `while` loop over the same body are twins on both, and this verb plans
--- to DELETE one of them (CART-0892). Two independent derivations agreeing is
--- not corroboration when both sit downstream of a row model that never carried
--- the kind.
---
--- ⇒ The kind is not missing from the tree — it is on `fl.stmts[i].kind`, which
---   ~10 modules already read. It is dropped where the clone ladder flattens
---   statements into rows. So the fix is an INTERPRETATION at the consumer that
---   acts, not a wider key: keying it would move every clone count and force a
---   cache VERSION bump, and the census is a DISCOVERY mechanism that is
---   supposed to over-approximate (CART-0740).
---
--- ⚠ AND THIS IS THE CONSUMER THAT ACTS. The standing law says a write
--- authorised by a derived fact must RE-DERIVE it; re-deriving a blind witness
--- re-derives the blindness, so the re-derivation has to see something the
--- witness cannot.
--- ★★★ THE MINIMUM-BODY FLOOR (CART-0895), and `clones.lua` already states the
--- rule this verb was missing:
---
---     INDEX_FLOOR = 2   -- "a 0-1 stmt body can't be any tier's clone"
---
--- Every clone TIER floors trivial bodies. This verb did not, because it uses a
--- DIFFERENT IDENTITY (`refs.witness` = df shape + params + callees) and never
--- passes through the clone index. MEASURED on our own tree before the floor:
--- 318 merge plans SUCCEEDED and 216 of them (68%) had a ONE-ROW survivor; the
--- largest deleted 50 FUNCTIONS, among them `M.argv_of`, `M.argn` and `get` from
--- three unrelated files. One-line functions collide on the witness because
--- there is almost nothing in them to tell apart.
---
--- ⚠ THE KIND GATE BELOW DOES NOT CATCH THIS: a 1-row body has a 1-element kind
--- sequence, so every one of those 216 passes it. Two different blind spots in
--- one verb, and fixing either alone leaves the other.
local BODY_FLOOR = 2

--- the statement-KIND sequence of a function body — the distinction every
--- identity in this file drops.
local function kind_seq(store, id)
    local eo = require('cartograph.expr').of(store, id)
    if not eo or not eo.fl then return nil end
    local out = {}
    for _, s in ipairs(eo.fl.stmts or {}) do out[#out + 1] = tostring(s.kind or '?') end
    -- the row COUNT rides with the sequence: it is its length, so the floor
    -- costs no second parse
    return table.concat(out, ','), #out
end

function M.twins(store, id)
    local refs = require 'cartograph.refs'
    local n = store.node(id)
    if not n then return {} end
    local function callees(x)
        local out = {}
        for _, c in ipairs(store.topo():sites(x.id)) do
            out[#out + 1] = callrec.callee(c)
        end
        return out
    end
    local w = refs.witness(n, callees(n))
    if not w then return {}, 'no data-flow witness (blocks/vars cannot merge)' end
    -- ⚠ THE KIND CHECK RUNS *AFTER* THE WITNESS, and the order is the whole
    -- cost story: `expr.of` is one whole-file reparse per call, while the
    -- witness is a cheap comparison. Filtering first means the expensive call
    -- runs only on the handful that already matched.
    local ks, rejected, rows = nil, 0, nil
    local out = {}
    for _, x in ipairs(store.data.nodes) do
        if x.id ~= id and x.kind == n.kind and not x.db and not x.sql
            and refs.witness(x, callees(x)) == w then
            if ks == nil then
                -- checked HERE rather than up front so a function with no
                -- witness match never pays the parse
                local k, r = kind_seq(store, id)
                -- ⚠ UNREADABLE IS NOT "ZERO ROWS". Ordering the floor first
                -- reported "a 0-row body is below the floor", which is a claim
                -- about a body nobody read. Absence gets its own refusal.
                if not k then
                    return {}, 'the survivor body cannot be read, so its shape'
                        .. ' cannot be compared — refused rather than merged on'
                        .. ' the data-flow witness alone'
                end
                if r < BODY_FLOOR then
                    return {}, ('a %d-row body is below the merge floor of %d rows'
                        .. ' — too little structure for the data-flow witness to'
                        .. ' tell it from an unrelated function'):format(r, BODY_FLOOR)
                end
                ks, rows = k, r
            end
            local xs = kind_seq(store, x.id)
            -- ABSENCE IS NOT PERMISSION. A kind sequence we cannot compute is
            -- not evidence the two agree, and this authorises a DELETION, so an
            -- unreadable side refuses the twin rather than passing it through.
            if ks and xs and xs == ks then out[#out + 1] = x
            else rejected = rejected + 1 end
        end
    end
    return out, nil, rejected
end

--- Build the plan: survivor = the focused function, removed = its
--- twins. Everything the apply needs to verify rides along.
function M.plan(store, id)
    local survivor = store.node(id)
    if not survivor then return nil, 'no function under focus' end
    local twins, why, rejected = M.twins(store, id)
    if #twins == 0 then
        -- ⚠ NAME WHICH GATE REFUSED. "no twin" and "a twin the kind check threw
        -- out" are different facts, and the second one is the interesting one:
        -- it means the data-flow witness MATCHED and the statement kinds did
        -- not, which is exactly the `if`-vs-`while` case (CART-0892). Reporting
        -- both as "no twin" hides the only evidence that the witness is coarse.
        if (rejected or 0) > 0 then
            return nil, ('%d candidate(s) matched the data-flow witness of %s but'
                .. ' differ in STATEMENT KINDS (an `if` and a `while` over the same'
                .. ' body have the same witness) — refused rather than merged')
                :format(rejected, survivor.name)
        end
        return nil, why or ('no clones of %s found (witness has no twin)')
            :format(survivor.name)
    end
    local root = store.data.root
    local plan = {
        verb = 'clone-merge',
        guards = { 'parses' }, -- CART-0769: every text-editing verb owes rung 0
        generation = store.generation,
        survivor = { id = id, name = survivor.name, file = survivor.file,
            ref = store.ref_of(id) },
        removed = {}, rewrites = {}, hazards = {}, stamps = {},
        touched = {},
    }
    local touched = { [survivor.file] = true }
    local lines_cache, text_cache = {}, {}
    local function file_text(rel)
        if text_cache[rel] == nil then text_cache[rel] = read_file(root, rel) or false end
        return text_cache[rel] or nil
    end
    local function file_lines(rel)
        if lines_cache[rel] == nil then
            local t = file_text(rel)
            lines_cache[rel] = t and vim.split(t, '\n', { plain = true }) or false
        end
        return lines_cache[rel]
    end

    for _, t in ipairs(twins) do
        -- comment adhesion: the doc lines above a removed twin go too —
        -- unless the block touches the top of the file (a header stays)
        local s, header = atr.sl(t.range), false
        local tls = file_lines(t.file)
        if tls then
            local okp, ts = pcall(require, 'cartograph.providers.treesitter')
            s, header = txn.attach_above(tls, s,
                okp and ts.attach_pats(t.file) or {})
        end

        -- ★★ CART-0770's HOLE SEEN FROM THE DELETE SIDE (CART-0773): the deletion
        -- range is a DEFINITION, not necessarily a standalone statement, so taking
        -- it out can leave its container unclosed. MEASURED, hand-read on
        -- tools/matrix.lua after a merge:
        --     500|         local shim = { data = data,
        --     501|             node = function (id) return index[id] end,
        --     502|         local findings = require(...).run(shim,
        -- — a NEW statement, with the table never closed. ~31 plans over two
        -- corpora, before-text confirmed clean on every one.
        -- (The module name in the witness is elided on purpose: the lint-caller
        -- audit greps for call sites and cannot tell a QUOTED witness from a real
        -- one, so a comment that shows code reads as code trips the fence.)
        --
        -- ⚠⚠ AND IT IS *NOT* THE SAME PREDICATE AS THE MOVE, WHICH IS WHAT THE
        -- MEASUREMENT SAID AFTER THE FIRST CUT SHIPPED `enclosing_syntax` HERE.
        -- On the LIFT side, sitting inside a container is ALWAYS fatal — the text
        -- cannot stand alone at the destination. On the DELETE side it is usually
        -- FINE: removing one whole element of a list leaves a valid list. Measured
        -- on our own tree, `enclosing_syntax` as the decision refused 50 merge
        -- plans of which only 16 would actually have broken — precision 32%, where
        -- the same predicate on the move side caught 368 for a cost of 42. It lost
        -- more than it saved.
        --
        -- ★ SO THE DECISION IS THE REMOVAL, SIMULATED, and `enclosing_syntax` is
        -- demoted to the EXPLANATION. Cut the lines and ask whether the file still
        -- parses — precise by construction, and it REUSES THE SHIPPED GUARD rather
        -- than adding a fourth predicate, so container formats come back NO-CLAIM
        -- and are not refused (CART-0769's delta form, applied early). Measured
        -- after the change: 16 refused on our own tree, which is EXACTLY the 16
        -- that would have broken — precision 32% -> 100%.
        --
        -- ⚠ AND ITS LIMIT, STATED RATHER THAN IMPLIED: this simulates ONE removal
        -- at a time, while the plan removes every twin and rewrites call sites.
        -- Measured on desynced, 2 of 82 plans still fail at execute and both are
        -- the same shape — THREE removals from one file, none of which breaks it
        -- alone. The `parses` guard sees the combined edit and catches them, which
        -- is what a backstop is for; the cost is a less specific message for 2.4%
        -- of plans. Grouping the removals per file here would close it and is the
        -- obvious next increment, not a correctness gap.
        if tls then
            local cut = {}
            for i, line in ipairs(tls) do
                if i - 1 < s or i - 1 > atr.el(t.range) then cut[#cut + 1] = line end
            end
            local pg = require 'cartograph.planguards'
            local rows = pg.GUARDS.parses(nil, nil,
                { [t.file] = file_text(t.file) },
                { [t.file] = table.concat(cut, '\n') })
            if rows[1] and rows[1].verdict == pg.FAIL then
                -- the explanation, not the decision: naming the container is what
                -- makes this actionable, and "does not parse" alone would not be
                local encl = txn.enclosing_syntax(t.file, t.range, file_text(t.file))
                return nil, ('removing %s from %s would leave the file unparseable%s'
                    .. ' — the merge is refused whole rather than skipping this'
                    .. ' twin, because a partial merge rewrites the callers of a'
                    .. ' twin that still exists')
                    :format(t.name, t.file,
                        encl and (', because it sits inside ' .. encl) or '')
            end
        end
        if header then
            plan.hazards[#plan.hazards + 1] = ('the comment block above %s'
                .. ' touches the top of %s (file header) — left behind')
                :format(t.name, t.file)
        end
        plan.removed[#plan.removed + 1] = {
            id = t.id, name = t.name, file = t.file,
            lines = { s = s, e = atr.el(t.range) },
            ref = store.ref_of(t.id),
        }
        touched[t.file] = true
        -- the `reg` edge IS "referenced from data" (see moveapply: n.cbarg
        -- conflated this with table-field defs and callback args)
        if store.topo():n_registrants(t.id) > 0 then
            plan.hazards[#plan.hazards + 1] = ('%s is referenced from data'
                .. ' (dispatch table / registry) — those references are NOT'
                .. ' rewritten'):format(t.name)
        end
        -- call sites into this twin: rewrite the callee token when it is
        -- exactly the twin's name; anything else is a hazard, not a write
        for _, c in ipairs(store.calls_to[t.id] or {}) do
            local at = c.at
            local ls = file_lines(callrec.file(c))
            local token = at and ls and atr.oneline(at)
                and (ls[atr.sl(at) + 1] or '')
                    :sub(atr.sc(at) + 1, atr.ec(at))
            if token == t.name then
                plan.rewrites[#plan.rewrites + 1] = { file = callrec.file(c),
                    at = at, from = t.name, to = survivor.name }
                touched[callrec.file(c)] = true
            else
                plan.hazards[#plan.hazards + 1] = ('%s:%d calls %s in a form'
                    .. " that isn't its bare name (%s) — rewrite it yourself")
                    :format(callrec.file(c), callrec.line(c) + 1, t.name, tostring(token or callrec.callee(c)))
            end
        end
        -- non-call references (the id pass's dispatch-table finds): they
        -- would still NAME the removed twin — disclosed, never rewritten
        local nonrefs = 0
        for _, from in ipairs(store.topo():callers(t.id)) do
            local calls = 0
            for _, c in ipairs(store.calls_to[t.id] or {}) do
                if callrec.fn(c) == from then calls = calls + 1 end
            end
            local occs = #(store.occurrences(from, t.id) or {})
            if occs > calls then nonrefs = nonrefs + (occs - calls) end
        end
        if nonrefs > 0 then
            plan.hazards[#plan.hazards + 1] = ('%d non-call reference(s) to'
                .. ' %s (identifier mentions) keep the old name')
                :format(nonrefs, t.name)
        end
    end
    -- rewritten call sites OUTSIDE the survivor's file will reference it
    -- by name from there — visibility (imports, linkage) is the user's
    -- to verify; cartograph won't guess a language's import wiring
    local foreign = {}
    for _, r in ipairs(plan.rewrites) do
        if r.file ~= survivor.file and not foreign[r.file] then
            foreign[r.file] = true
            plan.hazards[#plan.hazards + 1] = ('callers in %s will reference'
                .. ' %s by name — verify it is visible there (imports)')
                :format(r.file, survivor.name)
        end
    end
    for f in pairs(touched) do
        plan.touched[#plan.touched + 1] = f
        plan.stamps[f] = disk_stamp(root, f)
    end
    table.sort(plan.touched)
    plan.refspecs = { { id = plan.survivor.id, name = plan.survivor.name,
        ref = plan.survivor.ref, what = 'survivor' } }
    for _, r in ipairs(plan.removed) do
        plan.refspecs[#plan.refspecs + 1] = { id = r.id, name = r.name,
            ref = r.ref, what = 'clone' }
    end
    -- the host precondition this verb owes, declared rather than written into an
    -- `apply` the driver would have to dispatch to (CART-0982)
    plan.precheck = function (st)
        if next(st.moveset or {}) then
            return 'a move-set is staged — apply or clear it first'
        end
    end
    plan.desc = {
        survivor = plan.survivor.ref, survivor_name = plan.survivor.name,
        removed = vim.tbl_map(function (r) return r.ref end, plan.removed),
        rewrites = #plan.rewrites,
    }
    return txn.protocol(plan, M.edits_for)
end

-- one file's edits, bottom-up: the shared implementation in txn
local edit_file = txn.edit_file

--- Apply a plan. Every verification failure REFUSES with its reason.
--- The ladder and the journaled write loop live in cartograph.txn —
--- this verb contributes its refs, its edits, its one extra rung.
--- Kept as the module's face on the generic driver (CART-0982).
function M.apply(store, plan) return txn.apply(store, plan) end

--- What :CartographApply would write, nothing written: the dry-run
--- feeding the pre-apply diff.
function M.preview(store, plan)
    return txn.dryrun(store, plan)
end

--- The verb's edit callback — shared verbatim by apply and preview.
function M.edits_for(plan)
    return function (rel, before)
        local dels, reps = {}, {}
        for _, r in ipairs(plan.removed) do
            if r.file == rel then dels[#dels + 1] = r.lines end
        end
        for _, r in ipairs(plan.rewrites) do
            if r.file == rel then reps[#reps + 1] = r end
        end
        return edit_file(before, dels, reps)
    end
end

return M
