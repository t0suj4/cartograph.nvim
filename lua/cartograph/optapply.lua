-- OPTAPPLY — the headless, verified APPLY verb for optimize's suggestions
-- ([[cartograph-apply-for-agent]]): turns a read-only optimize finding into a real
-- source edit through the shared txn substrate — plan → preview (dry-run diff) →
-- verified apply (journal + write). AGENT-DRIVABLE (no cockpit/panes): cartograph acting
-- on its own analysis, with a safety net hand-editing lacks.
--
-- FIRST verb: CSE-REUSE — rewrite a redundant recompute `local b = <expr>` to reuse the
-- earlier result: `local b = a`. SOUND BY CONSTRUCTION — the CSE analysis already proved
-- value-equality over reaching (same expression, same operand reaching-defs, earlier
-- DOMINATES later); this verb only applies the CLEAN (non-hedged) pairs whose reuse
-- source `a` is a SINGLE-ASSIGNMENT local (never rebound → safe to reference anywhere it
-- dominates). The apply's OWN witness, on top of txn's generation + file-stamp CAS:
--   • span-CAS  — the exact text at each edit range still equals what the plan captured
--   • parse-clean — the edited file re-parses with no ERROR node
-- A graph-CHANGING edit (the recompute — and any call inside it — is removed) is REPORTED,
-- not rejected: that is the whole point, and why move's graph-PRESERVING witness won't do.

local optimize = require 'cartograph.optimize'
local txn = require 'cartograph.txn'
local expr = require 'cartograph.expr'

local M = {}

local spec = require('cartograph.providers.treesitter').spec
local EXT = {}
for lang, s in pairs(spec) do
    if s.body_field and s.exts then for _, e in ipairs(s.exts) do EXT[e] = lang end end
end
local function lang_of(file) return EXT[(file or ''):match('%.(%w+)$') or ''] end

local ASSIGN = { assignment_statement = true, assignment = true, assignment_expression = true }
local LOCALDECL = { variable_declaration = true, local_declaration = true }

-- the RHS expression node of a single-target assignment at `line` declaring `defname`
-- (one-line RHS only — the token-replacement is single-line), else nil.
local function rhs_node(root, src, line, defname)
    local found
    local function rec(n)
        if found then return end
        if n:start() + 1 == line then -- n:start() is 0-based; `line` is a 1-based flow row line
            local t = n:type()
            local asg
            if ASSIGN[t] then asg = n
            elseif LOCALDECL[t] then
                for c in n:iter_children() do if c:named() and ASSIGN[c:type()] then asg = c end end
            end
            if asg then
                local left, right
                for c in asg:iter_children() do
                    local ct = c:type()
                    if ct == 'variable_list' and not left then left = c
                    elseif ct == 'expression_list' and not right then right = c end
                end
                left = left or asg:field('left')[1]
                right = right or asg:field('right')[1]
                if left and right
                    and vim.treesitter.get_node_text(left, src) == defname then
                    local sr, _, er = right:range()
                    if sr == er then found = right end
                end
            end
        end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(root)
    return found
end

--- Build a CSE-reuse plan for the focused fn: the CLEAN (non-hedged) redundant pairs
--- whose reuse source is a single-assignment local, as txn token-replacements.
--- @return table? plan { verb, touched, generation, stamps, rel, reps, moves }, or nil+why
function M.plan_cse(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return nil, 'no such node' end
    local lang = lang_of(node.file)
    if not lang then return nil, 'unsupported language' end
    local rel = node.file
    local cse = optimize.cse(store, fn_id)
    local rows = cse.rows
    if #cse.redundant == 0 then return nil, 'no redundant computations' end
    -- names assigned exactly ONCE in the fn — safe to reference (never rebound)
    local defcount = {}
    for _, r in ipairs(rows) do for _, d in ipairs(r.def or {}) do defcount[d] = (defcount[d] or 0) + 1 end end
    local src = table.concat(store.content(node) or {}, '\n')
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return nil, 'cannot parse ' .. rel end
    local root = parser:parse()[1]:root()
    local srclines = vim.split(src, '\n', { plain = true })

    local reps, moves = {}, {}
    for _, p in ipairs(cse.redundant) do
        local a = rows[p.first].def and rows[p.first].def[1]
        local b = rows[p.second].def and rows[p.second].def[1]
        if not p.hedged and a and b
            and #(rows[p.first].def or {}) == 1 and #(rows[p.second].def or {}) == 1
            and defcount[a] == 1 then
            local rn = rhs_node(root, src, rows[p.second].l, b)
            if rn then
                -- treesitter :range() is 0-BASED (start line/col, end line/col-exclusive),
                -- matching the `at` range txn.edit_file consumes — kept 0-based on purpose
                -- (NOT flow's 1-based rows). The 1-based Lua slice for `old` is sc+1..ec.
                local sr, sc, er, ec = rn:range()
                local old = (srclines[sr + 1] or ''):sub(sc + 1, ec)
                -- calls removed by the rewrite (the graph delta, reported)
                local ncalls = 0
                local e = rows[p.second].expr and rows[p.second].expr.rhs and rows[p.second].expr.rhs[1]
                if e then expr.walk(e, function (nd) if nd.k == 'call' then ncalls = ncalls + 1 end end) end
                reps[#reps + 1] = { at = { start = { line = sr, char = sc }, ['end'] = { line = er, char = ec } },
                    to = a, old = old }
                moves[#moves + 1] = { line = rows[p.second].l, reuse = a, was = old,
                    reuses_line = rows[p.first].l, removes_calls = ncalls }
            end
        end
    end
    if #reps == 0 then return nil, 'no clean CSE-reuse candidates (all hedged or rebound sources)' end
    return { verb = 'optimize-cse', touched = { rel }, generation = store.generation,
        stamps = { [rel] = txn.disk_stamp(store.data.root, rel) }, rel = rel,
        reps = reps, moves = moves }
end

-- the edit callback for txn (single file: apply this plan's token-replacements)
local function edit_of(plan)
    return function (rel, before)
        if rel ~= plan.rel then return before end
        return txn.edit_file(before, {}, plan.reps, {})
    end
end

--- Dry-run: the unified diff the apply WOULD write (nothing written). @return lines, before, after
function M.preview(store, plan)
    local before, after, err = txn.dryrun(store, plan, edit_of(plan))
    if not before then return { 'optapply: ' .. (err or 'dry-run failed') } end
    return txn.difftext(before, after, plan.touched), before, after
end

-- does `src` parse with no ERROR/MISSING node? (the edit didn't corrupt syntax)
local function parses_clean(src, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return false end
    local root = parser:parse()[1]:root()
    local bad = false
    local function rec(n)
        if bad then return end
        if n:type() == 'ERROR' or n:missing() then bad = true; return end
        for c in n:iter_children() do rec(c) end
    end
    rec(root)
    return not bad
end

--- Apply the plan — the FULL verified write. Checks (in order): txn.verify (live graph,
--- same generation, file-stamp CAS, no dirty buffers) → span-CAS (each edit's old text
--- still present) → parse-clean (the edited file re-parses) → txn.execute (journal +
--- write + refresh). @return ok:boolean, entry_or_reason, diff_lines
function M.apply(store, plan)
    local refuse = txn.verify(store, plan, {})
    if refuse then return false, refuse end
    local root = store.data.root
    -- span-CAS: the exact text at each range is still what the plan captured.
    -- NB the rep range is 0-BASED (treesitter/`at` convention, unlike flow's 1-based
    -- rows): `.start.line`/`.start.char`/`.end.char` are 0-based, so the 1-based Lua
    -- string index is char+1, and the line report is line+1.
    local text = txn.read_file(root, plan.rel)
    if not text then return false, 'cannot read ' .. plan.rel end
    local lines = vim.split(text, '\n', { plain = true })
    for _, r in ipairs(plan.reps) do
        local sl0 = r.at.start.line -- 0-based line
        local cur = (lines[sl0 + 1] or ''):sub(r.at.start.char + 1, r.at['end'].char)
        if cur ~= r.old then
            return false, ('span drifted at %s:%d (expected `%s`, found `%s`) — re-plan')
                :format(plan.rel, sl0 + 1, r.old, cur)
        end
    end
    -- parse-clean on the dry-run result BEFORE committing anything
    local before, after, derr = txn.dryrun(store, plan, edit_of(plan))
    if not before then return false, derr or 'dry-run failed' end
    if not parses_clean(after[plan.rel], lang_of(plan.rel)) then
        return false, 'the edit would not parse cleanly — refused'
    end
    local diff = txn.difftext(before, after, plan.touched)
    local entry, why = txn.execute(store, plan, 'optimize: CSE-reuse', edit_of(plan))
    if not entry then return false, why end
    return true, entry, diff
end

--- One-call agent entry: plan + apply the focused fn's clean CSE reuses. Returns a
--- structured result (never throws) — { ok, applied, moves, diff, reason }.
function M.run(store, fn_id)
    local plan, why = M.plan_cse(store, fn_id)
    if not plan then return { ok = false, applied = 0, reason = why } end
    local ok, entry_or_reason, diff = M.apply(store, plan)
    if not ok then return { ok = false, applied = 0, moves = plan.moves, reason = entry_or_reason } end
    return { ok = true, applied = #plan.reps, moves = plan.moves, diff = diff }
end

--- Report lines (the thin surface): what a CSE-reuse apply WOULD do (dry-run only).
function M.report(store, fn_id)
    local plan, why = M.plan_cse(store, fn_id)
    if not plan then return { 'optimize-apply: ' .. (why or 'nothing to apply') } end
    local L = { ('optimize-apply: %s — %d CSE-reuse rewrite(s) (dry-run):')
        :format((store.node(fn_id) or {}).name or fn_id, #plan.moves), '' }
    for _, m in ipairs(plan.moves) do
        L[#L + 1] = ('  L%-4d reuse `%s` (was `%s`, computed at L%d)%s')
            :format(m.line, m.reuse, m.was, m.reuses_line,
                m.removes_calls > 0 and (' — removes %d call(s)'):format(m.removes_calls) or '')
    end
    L[#L + 1] = ''
    for _, l in ipairs(M.preview(store, plan)) do L[#L + 1] = l end
    L[#L + 1] = ''
    L[#L + 1] = '(dry-run — call optapply.apply to write it: txn-journaled + undoable,'
    L[#L + 1] = ' guarded by generation + file-stamp CAS + span-CAS + parse-clean.)'
    return L
end

return M
