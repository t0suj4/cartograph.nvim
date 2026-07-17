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
    local node = store.node and store.node(fn_id)
    if not node then return { rows = {}, heads = {}, loops = {} } end
    local fl = flow.present(node) and flow.record(node)
    if not fl or not fl.stmts or #fl.stmts == 0 then return { rows = {}, heads = {}, loops = {} } end
    local rows, n = fl.stmts, #fl.stmts

    local kids = {}
    for i = 1, n do
        local p = rows[i].parent
        if p and p ~= 0 then kids[p] = kids[p] or {}; kids[p][#kids[p] + 1] = i end
    end
    -- is row r inside loop head L's body (a proper descendant of L)?
    local function within(L, r)
        local p = rows[r].parent
        while p and p ~= 0 do if p == L then return true end; p = rows[p].parent end
        return false
    end
    local heads = {}
    for i = 1, n do if LOOPISH[rows[i].t or ''] then heads[#heads + 1] = i end end

    -- per-LINE impurity: a call whose effects are non-empty or hedged makes its
    -- line impure (side-effectful → not safe to move). Also the PURE callee names
    -- per line (skipped as invariance inputs — a pure fn value doesn't vary).
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

    -- CONTENT-READ gate (soundness): a row that INDEXES / FIELDS / LENGTH-reads a
    -- table reads the table's CONTENTS, which an in-loop mutation can change even
    -- when the table VARIABLE binding is invariant (e.g. `fr = frames[#frames]`
    -- where the loop pushes/pops frames). du's use list can't see index/length
    -- reads (no name), so detect them from the row's SOURCE SPAN and HEDGE — a
    -- clean hoist requires a scalar/pure computation. Conservative (over-hedges a
    -- float/comment/module-call `.`); sound = never a false clean hoist.
    local lines = (store.content and store.content(node)) or {}
    local fn_end = node.range and require('cartograph.at').el(node.range) or #lines
    local function span_text(r) -- the row's source, through to the next statement line
        local rl, e = rows[r].l, fn_end
        for _, s in ipairs(rows) do if s.l > rl and s.l - 1 < e then e = s.l - 1 end end
        local parts = {}
        for ln = rl, e do parts[#parts + 1] = lines[ln] or '' end
        return table.concat(parts, '\n')
    end
    -- ALLOCATION: a table constructor `{…}` or a closure `function` produces a FRESH
    -- object each iteration — loop-independent as an EXPRESSION but NOT hoistable
    -- (hoisting shares one object across iterations, changing identity semantics).
    -- Excluded from invariance entirely (not even ~ — it's not a hoist candidate).
    local function allocates(r)
        local t = span_text(r)
        return t:find('{') ~= nil or t:find('%f[%a]function%f[%A]') ~= nil
    end
    -- CONTENT-READ: indexes / fields / length-reads a table → reads contents an
    -- in-loop mutation can change (du can't see index/length reads). HEDGES a clean
    -- hoist. Conservative (over-hedges a float/comment/module-call `.`); sound.
    local function reads_table(r)
        local t = span_text(r)
        return t:find('[%[%]#]') ~= nil or t:find('[%w_]%s*[%.:]%s*[%a_]') ~= nil
    end

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

--- The lens surface (:CartographOptimize): the focused fn's loop-invariant
--- computations, per loop, in source order — each with its inputs and whether it's
--- unconditionally hoistable (a `*`) or invariant-but-conditional (`~`, hoisting
--- rides a branch). A SUGGESTION: the residual ~ is aliasing / mutable-global reads
--- (left out of the invariant set) + speculative hoisting over a zero-trip loop.
function M.report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'optimize: no such node' } end
    local res = M.licm(store, fn_id)
    if #res.heads == 0 then
        return { ('optimize: %s has no loops'):format(node.name or fn_id) }
    end
    local rows = res.rows
    local L = {}
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
    return L
end

return M
