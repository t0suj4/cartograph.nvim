-- OPTIMIZE lens (pure, read-only). The OPTIMIZING sibling of untangle: where
-- untangle asks "which statements are independent", this asks "which computations
-- are REDUNDANT or HOISTABLE". INC 1 = LICM (loop-invariant code motion): a pure
-- computation inside a loop whose inputs are all loop-invariant can be hoisted
-- above the loop (computed once, not every iteration). A SUGGESTION with a sound
-- verdict — never a silent transform. Rides shipped substrate only: flow loops +
-- reaching_cfg (now correct for accumulators/rmw + block-local reassignments —
-- [[flow-precision-gaps]], the prerequisite) + effects purity ([[cartograph-licm-cse]]).

local flow = require 'cartograph.flow'
local effects = require 'cartograph.effects'

local M = {}

-- loop control heads (by raw node type `t`) — the set untangle.extract_candidates uses
local LOOPISH = { for_statement = true, for_in_statement = true,
    while_statement = true, repeat_statement = true, loop_statement = true,
    loop_expression = true, foreach_statement = true }

-- Shared per-fn context for the optimize analyses: the flow rows + reaching, a
-- per-line purity/callee map, and the SOURCE-SPAN gates (allocation / content-read)
-- that keep both LICM and CSE sound where du's def/use can't see index/length reads
-- or allocations. Returns nil when the fn has no fine flow.
local function context(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return nil end
    local fl = flow.present(node) and flow.record(node)
    if not fl or not fl.stmts or #fl.stmts == 0 then return nil end
    local rows, n = fl.stmts, #fl.stmts
    local function within(L, r) -- is r a proper descendant of L?
        local p = rows[r].parent
        while p and p ~= 0 do if p == L then return true end; p = rows[p].parent end
        return false
    end
    local heads = {}
    for i = 1, n do if LOOPISH[rows[i].t or ''] then heads[#heads + 1] = i end end
    -- per-LINE impurity (a call with effects/hedges) + pure-callee names per line
    local impure_line, callee_line = {}, {}
    for _, c in ipairs((store.calls_by_fn and store.calls_by_fn[fn_id]) or {}) do
        local ln = (c.line or 0) + 1
        local ce = effects.call_effects(store, c, node.file)
        local pure = (next(ce.w) == nil) and not ce.hedges
        if not pure then impure_line[ln] = true end
        if c.callee then callee_line[ln] = callee_line[ln] or {}; callee_line[ln][c.callee] = pure end
    end
    -- reaching: reach[at][var] = { def rows } (0 = param/outside)
    local reach = {}
    for _, e in ipairs(flow.reaching_cfg(fl)) do
        reach[e.at] = reach[e.at] or {}; reach[e.at][e.var] = e.from
    end
    local lines = (store.content and store.content(node)) or {}
    local fn_end = node.range and require('cartograph.at').el(node.range) or #lines
    local function span_text(r) -- the row's source, through to the next statement line
        local rl, e = rows[r].l, fn_end
        for _, s in ipairs(rows) do if s.l > rl and s.l - 1 < e then e = s.l - 1 end end
        local parts = {}
        for ln = rl, e do parts[#parts + 1] = lines[ln] or '' end
        return table.concat(parts, '\n')
    end
    -- ALLOCATION: `{…}` / closure = fresh identity each time → never a safe hoist/reuse
    local function allocates(r)
        local t = span_text(r)
        return t:find('{') ~= nil or t:find('%f[%a]function%f[%A]') ~= nil
    end
    -- CONTENT-READ: index/field/length read → contents a mutation can change (du can't
    -- see it). HEDGES. Conservative (over-hedges a float/comment/module-call `.`); sound.
    local function reads_table(r)
        local t = span_text(r)
        return t:find('[%[%]#]') ~= nil or t:find('[%w_]%s*[%.:]%s*[%a_]') ~= nil
    end
    -- EXACT statement text via (line,col) bounds: from a row's own start to the start
    -- of the next row by position — handles multiple statements on one line AND
    -- multi-line statements precisely (a whole-line span over-captures a neighbour).
    -- rows[].c is 1-BASED (col of the first char); the next statement starts at nc, so
    -- this one's text runs [c .. nc-1].
    local order = {}
    for r = 1, n do order[r] = r end
    table.sort(order, function (a, b)
        if rows[a].l ~= rows[b].l then return rows[a].l < rows[b].l end
        return (rows[a].c or 1) < (rows[b].c or 1)
    end)
    local nextpos = {}
    for i = 1, #order - 1 do nextpos[order[i]] = { rows[order[i + 1]].l, rows[order[i + 1]].c or 1 } end
    local function stmt_text(r)
        local l, c = rows[r].l, rows[r].c or 1
        local el, ec = fn_end, #(lines[fn_end] or '') + 1
        if nextpos[r] then el, ec = nextpos[r][1], nextpos[r][2] end
        if l == el then return (lines[l] or ''):sub(c, ec - 1) end
        local parts = { (lines[l] or ''):sub(c) }
        for ln = l + 1, el - 1 do parts[#parts + 1] = lines[ln] or '' end
        parts[#parts + 1] = (lines[el] or ''):sub(1, ec - 1)
        return table.concat(parts, '\n')
    end
    return { node = node, rows = rows, n = n, within = within, heads = heads,
        impure_line = impure_line, callee_line = callee_line, reach = reach,
        lines = lines, fn_end = fn_end, span_text = span_text, stmt_text = stmt_text,
        allocates = allocates, reads_table = reads_table }
end

--- LICM analysis of the focused fn. For each loop, the rows whose value is
--- invariant across iterations (pure + every input defined OUTSIDE the loop or
--- itself invariant + a single def in the loop). Returns per-loop results; a row
--- is `hoistable` (safe to lift above the loop header) when it is invariant AND
--- unconditionally executed each iteration (directly in the loop body). Sound for
--- LOCAL value flow; aliasing / mutable-global reads are the residual (~), left
--- OUT of the invariant set (conservative — a free non-callee read is not certified).
--- @return table { rows, heads:integer[], loops: { [head]: { head, line, kind,
---   members:set, invariant:set, hoistable:set, inputs: {[row]:string[]} } } }
function M.licm(store, fn_id)
    local ctx = context(store, fn_id)
    if not ctx then return { rows = {}, heads = {}, loops = {} } end
    local rows, n, within, heads = ctx.rows, ctx.n, ctx.within, ctx.heads
    local impure_line, callee_line, reach = ctx.impure_line, ctx.callee_line, ctx.reach
    local allocates, reads_table, lines = ctx.allocates, ctx.reads_table, ctx.lines

    local loops = {}
    for _, L in ipairs(heads) do
        local mem = {}
        for r = 1, n do if within(L, r) then mem[r] = true end end
        -- a var defined more than once in the loop is loop-carried → not invariant
        local defcount = {}
        for r in pairs(mem) do
            for _, v in ipairs(rows[r].def or {}) do defcount[v] = (defcount[v] or 0) + 1 end
        end
        -- LOOP INDUCTION VARS: the `i`/`x` bound by the loop clause each iteration —
        -- a use of one is loop-VARYING (disqualify), unlike a field selector / free
        -- global (which only HEDGES). Extracted STRUCTURALLY from the header text
        -- (the names before `in` in a generic for, or before `=` in a numeric for) —
        -- NOT via reaching, which spuriously resolves a rebinding loop var to a prior
        -- same-named def (flow models loop vars as uses of the clause).
        local loopvar = {}
        local hdr = lines[rows[L].l] or ''
        local vars = hdr:match('%f[%w]for%s+(.-)%s+in%f[%W]') or hdr:match('%f[%w]for%s+(.-)%s*=')
        if vars then
            for name in vars:gmatch('[%a_][%w_]*') do loopvar[name] = true end
        end
        -- invariance fixpoint. `hedged[r]` = invariant but its certification rests on
        -- an aliasing/global-stability assumption (a field or free-global read, or a
        -- transitively-hedged input) — reported `~`, never a clean hoist.
        local inv, inputs, hedged = {}, {}, {}
        local changed = true
        while changed do
            changed = false
            for r in pairs(mem) do
                -- candidate = a fresh DECLARATION binding a value. A REASSIGNMENT
                -- (`x = …` of a var declared outside) is excluded: hoisting it is
                -- unsafe when x is read earlier in the loop body (the first-iteration
                -- flag `first = false` trap — needs liveness we don't do in INC 1).
                local decl = (rows[r].t or ''):find('declaration') ~= nil
                if not inv[r] and decl and #(rows[r].def or {}) > 0
                    and not impure_line[rows[r].l] and not allocates(r) then
                    local singledef = true
                    for _, v in ipairs(rows[r].def) do
                        if (defcount[v] or 0) > 1 then singledef = false; break end
                    end
                    if singledef then
                        local allinv, hed, ins = true, false, {}
                        -- reads = uses PLUS rmw self-reads (an accumulator's rmw read
                        -- of its own var is defined IN the loop → correctly disqualified)
                        local reads = rows[r].use or {}
                        if rows[r].rmw then
                            reads = {}
                            for _, v in ipairs(rows[r].use or {}) do reads[#reads + 1] = v end
                            for _, v in ipairs(rows[r].rmw) do reads[#reads + 1] = v end
                        end
                        local cl = callee_line[rows[r].l]
                        for _, v in ipairs(reads) do
                            if cl and cl[v] ~= nil then -- a callee name: value doesn't vary
                                if cl[v] == false then hed = true end -- an IMPURE callee (row already excluded, belt+braces)
                            elseif loopvar[v] then
                                allinv = false -- a loop induction var → varying
                            else
                                local froms = reach[r] and reach[r][v]
                                if not froms or #froms == 0 then
                                    hed = true -- field selector / free global → aliasing-hedged
                                else
                                    for _, d in ipairs(froms) do
                                        if d ~= 0 and mem[d] then
                                            if not inv[d] then allinv = false
                                            elseif hedged[d] then hed = true end -- inherit input's hedge
                                        end
                                    end
                                    if allinv then ins[#ins + 1] = v end
                                end
                            end
                        end
                        if allinv then
                            inv[r] = true; inputs[r] = ins
                            if hed or reads_table(r) then hedged[r] = true end
                            changed = true
                        end
                    end
                end
            end
        end
        local hoistable = {}
        for r in pairs(inv) do
            -- certified: invariant, unconditional in the body, and not aliasing-hedged
            if rows[r].parent == L and not hedged[r] then hoistable[r] = true end
        end
        loops[L] = { head = L, line = rows[L].l, kind = rows[L].t, members = mem,
            invariant = inv, hoistable = hoistable, hedged = hedged, inputs = inputs }
    end
    return { rows = rows, heads = heads, loops = loops }
end

--- CSE INC 1: redundant-computation pairs. Two rows in the SAME block computing the
--- SAME expression (identical normalized RHS text) over the SAME operand reaching-
--- defs, where the earlier lexically precedes (and so dominates) the later — the
--- later recomputes a value already available, so it can reuse the earlier result.
--- A redefinition of any operand BETWEEN them changes its reaching set → excluded
--- (soundness rides the reachset equality). `~` when either reads a table (an
--- aliasing write between could change the value). Only pure, non-allocating rows.
--- Same-block only (conservative — cross-block/PRE is a later increment).
--- @return table { rows, redundant: { first, second, expr, hedged }[] }
function M.cse(store, fn_id)
    local ctx = context(store, fn_id)
    if not ctx then return { rows = {}, redundant = {} } end
    local rows, reach, impure_line = ctx.rows, ctx.reach, ctx.impure_line
    local allocates, reads_table, stmt_text = ctx.allocates, ctx.reads_table, ctx.stmt_text
    -- RHS of a single-target row, ws-normalized (trailing `;` stripped); nil unless a
    -- real COMPUTATION (a bare literal / identifier / copy has nothing to CSE)
    local function rhs_of(r)
        if #(rows[r].def or {}) ~= 1 then return nil end
        local t = stmt_text(r)
        local eq = t:find('=')
        if not eq then return nil end
        local rhs = t:sub(eq + 1):gsub(';%s*$', ''):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
        if not (rhs:find('[%(%[%.:]') or rhs:find('[%+%-%*/%%<>~]') or rhs:find('%.%.')) then
            return nil -- not a computation
        end
        return rhs
    end
    -- do the two rows read the SAME operand values? (same reaching-def set per var —
    -- a redefinition between them would differ; same RHS text ⇒ same var set)
    local function same_values(r1, r2)
        for _, v in ipairs(rows[r1].use or {}) do
            local sa, sb = {}, {}
            for _, d in ipairs((reach[r1] or {})[v] or {}) do sa[d] = true end
            for _, d in ipairs((reach[r2] or {})[v] or {}) do sb[d] = true end
            for d in pairs(sa) do if not sb[d] then return false end end
            for d in pairs(sb) do if not sa[d] then return false end end
        end
        return true
    end
    -- group candidate rows by (block, RHS text)
    local groups = {}
    for r = 1, #rows do
        if not impure_line[rows[r].l] and not allocates(r) then
            local rhs = rhs_of(r)
            if rhs then
                local key = tostring(rows[r].parent) .. '\1' .. rhs
                groups[key] = groups[key] or {}
                groups[key][#groups[key] + 1] = { r = r, rhs = rhs }
            end
        end
    end
    local redundant = {}
    for _, grp in pairs(groups) do
        if #grp >= 2 then
            table.sort(grp, function (a, b)
                if rows[a.r].l ~= rows[b.r].l then return rows[a.r].l < rows[b.r].l end
                return a.r < b.r
            end)
            local first = grp[1]
            for i = 2, #grp do -- first (earliest) dominates each later occurrence
                if same_values(first.r, grp[i].r) then
                    redundant[#redundant + 1] = { first = first.r, second = grp[i].r,
                        expr = first.rhs, hedged = reads_table(first.r) or reads_table(grp[i].r) }
                end
            end
        end
    end
    table.sort(redundant, function (a, b) return rows[a.second].l < rows[b.second].l end)
    return { rows = rows, redundant = redundant }
end

--- LICM INC 2 — the HOIST PLAN. For each loop, the clean-hoistable rows (from INC 1)
--- to lift above the loop header, with an INDEPENDENT capture/scope check: a hoisted
--- `local x` is safe only if x occurs ONLY inside the loop body — otherwise lifting
--- its declaration above the header could capture or collide with an outer binding of
--- the same name. This is the disagreement oracle for the optimize arc: INC 1 asserts
--- value-invariance, INC 2 independently checks the MOVE is mechanically sound; a
--- clean-hoistable row that fails the capture check is a real disagreement worth
--- surfacing. Hoisted rows keep source order (a hoistable row's invariant inputs are
--- themselves hoistable or pre-loop, so dependencies are preserved). Read-only.
--- @return table { rows, plans: { loop, line, insert_before, moves, hazards, safe }[] }
function M.hoist_plan(store, fn_id)
    local ctx = context(store, fn_id)
    if not ctx then return { rows = {}, plans = {} } end
    local res = M.licm(store, fn_id)
    local rows, stmt_text = res.rows, ctx.stmt_text
    local plans = {}
    for _, L in ipairs(res.heads) do
        local lp = res.loops[L]
        local hoist = {}
        for r in pairs(lp.hoistable) do hoist[#hoist + 1] = r end
        if #hoist > 0 then
            table.sort(hoist, function (a, b) return rows[a].l < rows[b].l end)
            local moves, hazards = {}, {}
            for _, r in ipairs(hoist) do
                for _, v in ipairs(rows[r].def or {}) do
                    local outside -- v occurring in a row NOT in this loop's body → collision risk
                    for r2 = 1, #rows do
                        if r2 ~= L and not lp.members[r2] then
                            for _, d in ipairs(rows[r2].def or {}) do if d == v then outside = rows[r2].l end end
                            for _, u in ipairs(rows[r2].use or {}) do if u == v then outside = outside or rows[r2].l end end
                        end
                    end
                    if outside then
                        hazards[#hazards + 1] = { line = rows[r].l, var = v, reason =
                            ('`%s` also occurs at L%d outside the loop — hoisting could capture/collide')
                            :format(v, outside) }
                    end
                end
                moves[#moves + 1] = { line = rows[r].l,
                    def = table.concat(rows[r].def or {}, ', '),
                    text = (stmt_text(r):gsub('%s+$', '')) }
            end
            plans[#plans + 1] = { loop = L, line = rows[L].l, insert_before = rows[L].l,
                moves = moves, hazards = hazards, safe = (#hazards == 0) }
        end
    end
    return { rows = rows, plans = plans }
end

--- The lens surface (:CartographOptimize): the focused fn's loop-invariant
--- computations, per loop, in source order — each with its inputs and whether it's
--- unconditionally hoistable (a `*`) or invariant-but-conditional (`~`, hoisting
--- rides a branch). A SUGGESTION: the residual ~ is aliasing / mutable-global reads
--- (left out of the invariant set) + speculative hoisting over a zero-trip loop.
function M.report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'optimize: no such node' } end
    local res = M.licm(store, fn_id)
    local rows = res.rows
    if #rows == 0 then
        return { ('optimize: %s has no fine flow'):format(node.name or fn_id) }
    end
    local L = {}
    if #res.heads == 0 then
        L[#L + 1] = ('optimize: %s — no loops'):format(node.name or fn_id)
    else
        local total_inv, total_hoist = 0, 0
        for _, h in ipairs(res.heads) do
            local lp = res.loops[h]
            local invrows = {}
            for r in pairs(lp.invariant) do invrows[#invrows + 1] = r end
            table.sort(invrows, function (a, b) return rows[a].l < rows[b].l end)
            L[#L + 1] = ('%s loop @L%-4d — %d loop-invariant computation(s)')
                :format((lp.kind or 'loop'):gsub('_statement', ''), lp.line, #invrows)
            for _, r in ipairs(invrows) do
                total_inv = total_inv + 1
                local hoist = lp.hoistable[r]
                if hoist then total_hoist = total_hoist + 1 end
                L[#L + 1] = ('  %s L%-4d %s  <- (%s)'):format(
                    hoist and '*' or '~', rows[r].l,
                    table.concat(rows[r].def or {}, ', '),
                    table.concat(lp.inputs[r] or {}, ', '))
            end
        end
        L[#L + 1] = ''
        L[#L + 1] = ('%d invariant computation(s), %d unconditionally hoistable (*)')
            :format(total_inv, total_hoist)
        L[#L + 1] = '(* = safe to lift above the loop header; ~ = invariant but not a clean'
        L[#L + 1] = ' hoist — either branch-guarded, or its invariance rests on an aliasing /'
        L[#L + 1] = ' field / mutable-global stability assumption we cannot certify. Hoisting'
        L[#L + 1] = ' is a suggestion; a may-throw hoist over a zero-trip loop changes errors.)'

        -- INC 2: the hoist plan — the * rows lifted above the header, with the
        -- independent capture/scope check (⚠ = INC 1 said hoistable but the MOVE
        -- would collide with an outer binding — a real disagreement to resolve).
        for _, p in ipairs(M.hoist_plan(store, fn_id).plans) do
            L[#L + 1] = ''
            L[#L + 1] = ('hoist plan @ loop L%d — lift %d computation(s) above the header%s:')
                :format(p.line, #p.moves, p.safe and '' or ' — ⚠ NOT safe')
            for _, m in ipairs(p.moves) do L[#L + 1] = ('  L%-4d %s'):format(m.line, m.text) end
            if p.safe then
                L[#L + 1] = '  (validated: each hoisted local occurs only inside the loop — no capture)'
            else
                for _, h in ipairs(p.hazards) do L[#L + 1] = ('  ⚠ %s'):format(h.reason) end
            end
        end
    end

    -- CSE: redundant recomputations (same expression, same operand values, earlier
    -- dominates later). A suggestion to reuse the first result; `~` = aliasing-hedged.
    local cse = M.cse(store, fn_id)
    if #cse.redundant > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('redundant computations (CSE) — %d:'):format(#cse.redundant)
        for _, p in ipairs(cse.redundant) do
            L[#L + 1] = ('  %s L%-4d recomputes L%-4d: %s'):format(
                p.hedged and '~' or ' ', rows[p.second].l, rows[p.first].l, p.expr)
        end
        L[#L + 1] = '(the later can reuse the earlier result; ~ = a table read whose'
        L[#L + 1] = ' value an aliasing write between the two could change — unverified)'
    end
    return L
end

return M
