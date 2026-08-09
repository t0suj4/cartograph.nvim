-- FOLD RANKING (CART-0371): join the two passes that have always been separate — DISCOVERY
-- (which duplications exist) and PLANNING (which of them a verb will actually perform) —
-- and rank the result by what the fold would COST, not by how big the duplication looks.
--
-- WHY THE JOIN IS THE WHOLE IDEA. The clone tiers rank by SIZE, which answers "what is the
-- biggest duplication" — a question nobody asked. Under a stated intent to FOLD, the
-- question is "what should I fold next", and the answer is the plan's own arithmetic:
-- lines removed minus lines added, hazards to verify, parameters introduced. Measured on
-- this tree the two orders disagree, which is the argument for the report existing.
--
-- ★ A REFUSAL IS A ROW, NOT AN ABSENCE — AND THE ROW MUST NAME THE BINDING CONSTRAINT.
-- Measured on this repo, 59 near-clone pairs: 6 plan, 53 refuse. The first reading of that
-- refusal set said 14 were waiting on ONE ARGUMENT ("cross-file: pass a destination module
-- path") — a third of the work, apparently cheap. Supplying a destination unblocked ONE.
-- The other 13 then said "reads file-local `store` — cannot move it to another module",
-- which is a wall. **A refusal naming a missing INPUT can hide a refusal naming a real
-- CONSTRAINT**, so this re-asks with a destination and carries whatever comes back. A work
-- list that mis-states its own unblocking cost is worse than no list: you would budget 13
-- cheap wins and get none.
--
-- ★ THE DELTA IS A PREDICTION AND IT IS CHECKABLE. `net` is what the plan says it would do
-- to the line count, derived from the ops the apply path will really run — not an estimate.
-- If a fold campaign's total predicted `net` does not show up in the tree after applying, the
-- campaign was wrong, which is the property [[cartograph-goal-vm-linker]] asks an intent to
-- have. Nothing here writes; this is the ranking, not the verb.

local M = {}

--- What a plan would do to the line count. Ops are { from0b, to0b, new }: a pure INSERT has
--- to0b < from0b (0 lines removed), a replacement removes to0b-from0b+1. Returns
--- (added, removed, net) where net < 0 means the tree shrinks.
---@param plan table
---@return integer added, integer removed, integer net
function M.delta(plan)
    local added, removed = 0, 0
    for _, fe in pairs(plan.files or {}) do
        for _, op in ipairs(fe.ops or {}) do
            added = added + #(op.new or {})
            if op.to0b >= op.from0b then removed = removed + (op.to0b - op.from0b + 1) end
        end
    end
    if plan.create then added = added + #(plan.create.lines or {}) end
    return added, removed, added - removed
end

--- Rank near-clone pairs by what folding them would COST.
--- Returns (rows, refused) where a row is
---   { a, b, helper, net, added, removed, nparams, hazards, xfile }
--- sorted by net ascending (most shrinkage first), and `refused` is
---   { [reason] = count } — the honest other half.
---@param store table
---@param opts table|nil  { max_dist = 2, limit = <pairs to examine> }
function M.rank(store, opts)
    opts = opts or {}
    local clones = require 'cartograph.clones'
    local ce = require 'cartograph.cloneextract'
    local pairs_ = clones.near(store, { max_dist = opts.max_dist or 2 })
    local rows, refused = {}, {}
    for i, p in ipairs(pairs_) do
        if opts.limit and i > opts.limit then break end
        -- ★ pcall, BECAUSE A VERB THAT THROWS MUST NOT KILL THE QUEUE. Measured: plan
        -- raises on at least one pair of this tree (at.sl on a nil range, via call_line ->
        -- span_text). A ranking report exists to survey EVERY candidate, so a raise is a
        -- row with a reason like any other refusal — and it is louder as a counted row than
        -- as a stack trace that hides the other 58. Filed as its own defect: a plan verb
        -- should refuse, not throw.
        local ok, plan, why = pcall(ce.plan, store, p, {})
        if not ok then plan, why = nil, 'the plan verb RAISED: ' .. tostring(plan):gsub('^.*/', '') end
        -- ★ REPORT THE BINDING REFUSAL, NOT THE FIRST ONE. "cross-file: pass a destination
        -- module path" reads like a work item costing ONE ARGUMENT. Measured on this tree it
        -- is not: supplying a destination unblocked 1 of 14, and the other 13 then said
        -- "reads file-local `ts` — cannot move it to another module", which is a wall, not a
        -- decision. A refusal naming a missing INPUT can hide a refusal naming a real
        -- CONSTRAINT, and a work list that mis-states its own unblocking cost is worse than
        -- no list — you would budget 13 cheap wins and get none. So when the verb asks for a
        -- destination, ask again WITH one and carry whatever it says next.
        if not plan and (why or ''):find('destination module', 1, true) then
            local ok2, p2, why2 = pcall(ce.plan, store, p, { dest = opts.dest or 'lua/cartograph/core.lua' })
            if ok2 and p2 then plan = p2
            elseif ok2 then why = (why2 or why) .. '  [survives a supplied destination]' end
        end
        if plan then
            local added, removed, net = M.delta(plan)
            rows[#rows + 1] = { a = p.a and p.a.name, b = p.b and p.b.name,
                file = p.a and p.a.file, helper = plan.helper, net = net,
                added = added, removed = removed, nparams = plan.nparams or 0,
                hazards = #(plan.hazards or {}), xfile = plan.xfile or false }
        else
            -- COLLAPSE THE VARIABLE PART of a reason so the tally groups: several refusals
            -- embed the subject's own name ("`ser` body not liftable: …"), and counting
            -- those separately turns one class into N classes of 1.
            local key = (why or 'unknown'):gsub('^`?[%w_%.]+`?%s+body', 'body')
            refused[key] = (refused[key] or 0) + 1
        end
    end
    table.sort(rows, function (x, y)
        if x.net ~= y.net then return x.net < y.net end        -- most shrinkage first
        if x.hazards ~= y.hazards then return x.hazards < y.hazards end -- then least to verify
        return tostring(x.helper) < tostring(y.helper)          -- total, so a rank is a fact
    end)
    return rows, refused
end

--- Human-readable report lines.
function M.report(rows, refused)
    local L = {}
    local planned_net = 0
    for _, r in ipairs(rows) do planned_net = planned_net + r.net end
    L[#L + 1] = ('fold queue — %d pair(s) a verb will plan, predicted net %+d line(s)')
        :format(#rows, planned_net)
    L[#L + 1] = '(ranked by what the FOLD costs, not by how big the duplication looks;'
    L[#L + 1] = ' net is the plan\'s own arithmetic over the ops apply would run)'
    L[#L + 1] = ''
    for i, r in ipairs(rows) do
        L[#L + 1] = ('%2d. %+4d  %-22s %s <-> %s%s%s'):format(i, r.net, r.helper or '?',
            tostring(r.a), tostring(r.b),
            r.nparams > 0 and ('  [%d param]'):format(r.nparams) or '',
            r.hazards > 0 and ('  [%d hazard]'):format(r.hazards) or '')
        L[#L + 1] = ('       +%d/-%d in %s%s'):format(r.added, r.removed,
            tostring(r.file), r.xfile and ' (cross-file)' or '')
    end
    local tot, ord = 0, {}
    for w, c in pairs(refused) do tot = tot + c; ord[#ord + 1] = { w = w, c = c } end
    table.sort(ord, function (a, b) if a.c ~= b.c then return a.c > b.c end return a.w < b.w end)
    if tot > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('REFUSED — %d pair(s), and this is most of the work.'):format(tot)
        L[#L + 1] = 'A reason marked [survives a supplied destination] was RE-ASKED with one'
        L[#L + 1] = 'and is the BINDING constraint, not the first thing the verb wanted.'
        for _, e in ipairs(ord) do L[#L + 1] = ('  %4d  %s'):format(e.c, e.w) end
    end
    return L
end

return M
