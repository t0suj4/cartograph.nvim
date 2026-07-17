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
local at = require 'cartograph.at'

local M = {}

local spec = require('cartograph.providers.treesitter').spec
local EXT = {}
for lang, s in pairs(spec) do
    if s.body_field and s.exts then for _, e in ipairs(s.exts) do EXT[e] = lang end end
end
local function lang_of(file) return EXT[(file or ''):match('%.(%w+)$') or ''] end

-- ── hedge resolution ([[cartograph-hedge-resolution-writes]]) ─────────────────
-- A decline is a HEDGE; the caller DISCHARGES it by supplying the missing premise at
-- that site: opts.assume = { [line] = resolution_id | {resolution_id, …} }. A supplied
-- premise waives that JUDGMENT gate (never the mechanical floor — span-CAS/parse-clean/
-- CAS always run) and is RECORDED as the edit's `waived` provenance.
local function assumed(opts, line, id)
    local a = opts.assume and opts.assume[line]
    if not a then return false end
    if type(a) == 'string' then return a == id end
    for _, v in ipairs(a) do if v == id then return true end end
    return false
end
-- a name not already bound in the fn (for the MECHANICAL shadow resolution — rebind
-- under a fresh name rather than shadowing an existing binding)
local function fresh_name(base, bound)
    if not bound[base] then return base end
    for _, suf in ipairs({ '_', '2', '_l' }) do
        if not bound[base .. suf] then return base .. suf end
    end
    local i = 1
    while bound[base .. i] do i = i + 1 end
    return base .. i
end

local ASSIGN = { assignment_statement = true, assignment = true, assignment_expression = true }
local LOCALDECL = { variable_declaration = true, local_declaration = true }

-- the RHS expression node of a single-target assignment at `line` (one-line RHS only —
-- the token-replacement is single-line), else nil. `defname` optional: when given the
-- left must declare it (CSE reuse); when nil, the first single-target at the line (PRE,
-- which locates arm occurrences by line, not name).
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
                    and (not defname or vim.treesitter.get_node_text(left, src) == defname) then
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
--- `opts.line` (1-based) = TARGET a single finding — apply only the rewrite whose
--- recompute is on that line (targeted refactoring); omit for all clean reuses in the fn.
--- @return table? plan { verb, touched, generation, stamps, rel, reps, moves }
--- @return string? why  (set when plan is nil)
function M.plan_cse(store, fn_id, opts)
    opts = opts or {}
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

    local reps, moves, declined = {}, {}, {}
    for _, p in ipairs(cse.redundant) do
        local line = rows[p.second].l
        if not opts.line or line == opts.line then -- out-of-target candidates aren't "declined"
            local a = rows[p.first].def and rows[p.first].def[1]
            local b = rows[p.second].def and rows[p.second].def[1]
            local reason, class, res, evidence, waived
            if p.hedged then
                reason, class = 'hedged: an aliasing table read could change the value', 'risk'
            elseif not (a and b) then reason, class = 'not a single-target reuse', 'blocked'
            elseif #(rows[p.first].def or {}) ~= 1 or #(rows[p.second].def or {}) ~= 1 then
                reason, class = 'multi-target assignment', 'blocked'
            elseif defcount[a] ~= 1 then
                -- PROVENANCE for the likely-bug: WHERE `a` is (re)assigned besides the reuse
                -- source, so an override is informed (is any of these BETWEEN the two uses?).
                local elines = {}
                for r = 1, #rows do
                    if r ~= p.first then
                        for _, d in ipairs(rows[r].def or {}) do if d == a then elines[#elines + 1] = rows[r].l end end
                    end
                end
                evidence = ('`%s` is also assigned at L%s'):format(a, table.concat(elines, ', L'))
                if assumed(opts, line, 'stable') then
                    waived = ('`%s` is stable between the two (asserted)'):format(a)
                else
                    reason, class = ('reuse source `%s` is reassigned elsewhere'):format(a), 'wrong'
                    res = { { id = 'stable', premise = ('`%s` is not reassigned between the two uses'):format(a) } }
                end
            end
            local rn = not reason and rhs_node(root, src, line, b)
            if not reason and not rn then
                reason, class = 'recompute RHS is not a single-line expression', 'blocked'
            end
            if reason then
                declined[#declined + 1] = { line = line, what = p.expr, reason = reason,
                    class = class, resolutions = res, evidence = evidence }
            else
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
                moves[#moves + 1] = { line = line, reuse = a, was = old,
                    reuses_line = rows[p.first].l, removes_calls = ncalls, waived = waived }
            end
        end
    end
    return { verb = 'optimize-cse', touched = { rel }, generation = store.generation,
        stamps = { [rel] = txn.disk_stamp(store.data.root, rel) }, rel = rel,
        reps = reps, moves = moves, declined = declined }
end

-- ── localize-upvalue apply ───────────────────────────────────────────────────
-- global MODULE tables that ALWAYS exist and never error on a field read (`M.f` for a
-- non-nil table M returns the field or nil, never throws) — so inserting `local f = M.f`
-- ABOVE a loop is zero-trip-safe (can't raise where the original in-loop read wouldn't).
-- An arbitrary user global might be nil, so localize-APPLY is gated to this set (the
-- report still SUGGESTS the rest; only the write is gated). vim = the nvim runtime table.
local KNOWN_GLOBAL = { math = true, string = true, table = true, os = true, io = true,
    coroutine = true, debug = true, utf8 = true, bit = true, bit32 = true, vim = true }

local LOOPISH = { for_statement = true, for_in_statement = true, while_statement = true,
    repeat_statement = true, loop_statement = true, foreach_statement = true,
    for_numeric_statement = true, for_generic_statement = true }

-- the loop node whose header starts on `line` (1-based), else nil
local function loop_node(root, line)
    local found
    local function rec(n)
        if found then return end
        if n:start() + 1 == line and LOOPISH[n:type()] then found = n; return end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(root)
    return found
end
-- does the subtree contain a nested function definition? (localize-apply skips those —
-- a nested closure complicates scope/shadowing; conservative)
local FN_DEF = { function_definition = true, function_declaration = true,
    method_declaration = true, arrow_function = true }
local function has_nested_fn(n)
    for c in n:iter_children() do
        if c:named() then
            if FN_DEF[c:type()] then return true end
            if has_nested_fn(c) then return true end
        end
    end
    return false
end
-- ranges of every callee occurrence of the dotted name `full` inside `loopn`
local function callee_occurrences(loopn, src, full)
    local out = {}
    local function rec(n)
        if n:type() == 'function_call' or n:type() == 'call_expression' then
            local callee = n:named_child(0)
            if callee and vim.treesitter.get_node_text(callee, src) == full then
                local sr, sc, er, ec = callee:range()
                if sr == er then out[#out + 1] = { start = { line = sr, char = sc }, ['end'] = { line = er, char = ec } } end
            end
        end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(loopn)
    return out
end

--- Build a LOCALIZE-UPVALUE plan for the focused fn: bind each in-loop global/module
--- function to a `local` above its loop and rewrite the call sites. `opts.line` targets
--- one loop (by header line). SOUND-gated for the WRITE: the root must be a known
--- always-present global (`math`/`string`/`table`/`vim`/… — so the hoisted read can't
--- throw where the original wouldn't), the leaf name must be free in the fn (no shadow),
--- and the loop must not contain a nested function.
--- @return table? plan
--- @return string? why
function M.plan_localize(store, fn_id, opts)
    opts = opts or {}
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return nil, 'no such node' end
    local lang = lang_of(node.file)
    if not lang then return nil, 'unsupported language' end
    local loc = optimize.localize(store, fn_id)
    if #loc.loops == 0 then return nil, 'no loops with global lookups' end
    local flow = require 'cartograph.flow'
    local fl = flow.present(node) and flow.record(node)
    local bound = {}
    for _, p in ipairs((fl and fl.params) or {}) do bound[p] = true end
    for _, r in ipairs((fl and fl.stmts) or {}) do for _, d in ipairs(r.def or {}) do bound[d] = true end end
    local src = table.concat(store.content(node) or {}, '\n')
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return nil, 'cannot parse' end
    local root = parser:parse()[1]:root()
    local srclines = vim.split(src, '\n', { plain = true })

    local ins, reps, moves, declined = {}, {}, {}, {}
    for _, lp in ipairs(loc.loops) do
        if not opts.line or lp.line == opts.line then
            local ln = loop_node(root, lp.line)
            local nested = ln and has_nested_fn(ln)
            local indent = (srclines[lp.line] or ''):match('^(%s*)') or ''
            for _, c in ipairs(lp.cands) do
                local rootname = c.full:match('^([%w_]+)')
                local reason, class, res, waived, name = nil, nil, nil, nil, c.leaf
                if not ln then reason, class = 'could not locate the loop', 'blocked'
                elseif nested then reason, class = 'loop contains a nested function (scope-unsafe)', 'risk'
                elseif not (rootname and KNOWN_GLOBAL[rootname]) then
                    if assumed(opts, lp.line, 'present') then
                        waived = ('`%s` present (asserted)'):format(rootname)
                    else
                        reason, class = ('root `%s` is not a known always-present global (may be nil)')
                            :format(rootname or '?'), 'risk'
                        res = { { id = 'present', premise = ('`%s` is always defined here'):format(rootname or 'the global') } }
                    end
                end
                if not reason and bound[c.leaf] then
                    if assumed(opts, lp.line, 'rename') then
                        name = fresh_name(c.leaf, bound)
                        waived = (waived and waived .. '; ' or '') .. ('rebound as `%s`'):format(name)
                    else
                        reason, class = ('`%s` is already bound here — would shadow'):format(c.leaf), 'wrong'
                        res = { { id = 'rename',
                            premise = ('rebind under a fresh name (e.g. `%s`)'):format(fresh_name(c.leaf, bound)) } }
                    end
                end
                local occ = (not reason) and callee_occurrences(ln, src, c.full) or nil
                if not reason and (not occ or #occ == 0) then reason, class = 'no rewritable call site found', 'blocked' end
                if reason then
                    declined[#declined + 1] = { line = lp.line, what = c.full, reason = reason, class = class, resolutions = res }
                else
                    -- insert ABOVE the header: after = header(1-based) - 2 (0-based)
                    ins[#ins + 1] = { after = lp.line - 2,
                        lines = { indent .. ('local %s = %s'):format(name, c.full) } }
                    for _, atr in ipairs(occ) do reps[#reps + 1] = { at = atr, to = name, old = c.full } end
                    moves[#moves + 1] = { line = lp.line, leaf = name, full = c.full, sites = #occ, waived = waived }
                    bound[name] = true -- don't reuse the same local name twice
                end
            end
        end
    end
    return { verb = 'optimize-localize', touched = { node.file }, generation = store.generation,
        stamps = { [node.file] = txn.disk_stamp(store.data.root, node.file) }, rel = node.file,
        reps = reps, ins = ins, moves = moves, declined = declined }
end

-- POST-condition (repeat/do-while) or const-true loops run at least once → hoisting a
-- computation above them adds no execution on a zero-trip path (there is none), so it
-- can't raise where the original wouldn't. A PRE-loop (for/while) MAY be zero-trip, so
-- hoisting a possibly-throwing expr above it could introduce an error → not applied.
local POSTISH = { repeat_statement = true, do_statement = true }

--- Build a HOIST (LICM) plan for the focused fn: lift a clean-hoistable invariant above
--- its loop header. `opts.line` targets one loop. SOUND-gated for the WRITE beyond
--- hoist_plan's capture check: the loop must run AT LEAST ONCE (POST loop or const-true)
--- so no zero-trip path gains a computation, and the moved statement is single-line.
--- @return table? plan
--- @return string? why
function M.plan_hoist(store, fn_id, opts)
    opts = opts or {}
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return nil, 'no such node' end
    local res = optimize.hoist_plan(store, fn_id)
    if #res.plans == 0 then return nil, 'no loop-invariant computations' end
    local rows = res.rows
    local src = table.concat(store.content(node) or {}, '\n')
    local srclines = vim.split(src, '\n', { plain = true })
    local dels, ins, moves, declined = {}, {}, {}, {}
    for _, p in ipairs(res.plans) do
        if not opts.line or p.line == opts.line then
            local L = rows[p.loop]
            local iterates = L and (POSTISH[L.t or ''] or L.const == true)
            local waived
            if not iterates and assumed(opts, p.line, 'iterates') then
                iterates, waived = true, 'loop-always-iterates (asserted)'
            end
            -- per-loop refusal (hoist_plan marks the whole plan un/safe by capture)
            local loopreason, loopclass, loopres, loopev
            if not p.safe then
                loopreason, loopclass = 'capture-unsafe: a hoisted local collides with an outer binding', 'wrong'
                -- PROVENANCE: the exact collision site(s) hoist_plan found (rename resolution
                -- teed up, not yet wired — but the evidence explains the likely-bug now)
                local ev = {}
                for _, h in ipairs(p.hazards or {}) do ev[#ev + 1] = h.reason end
                loopev = #ev > 0 and table.concat(ev, '; ') or nil
            elseif not iterates then
                loopreason = 'loop may run zero times (for/while) — a zero-trip path could gain a throwing computation'
                loopclass = 'risk'
                loopres = { { id = 'iterates', premise = 'this loop always runs at least once' } }
            end
            local indent = (srclines[p.line] or ''):match('^(%s*)') or ''
            for _, m in ipairs(p.moves) do
                local reason, class, res, ev = loopreason, loopclass, loopres, loopev
                if not reason and m.text:find('\n') then
                    reason, class = 'multi-line statement (single-line only for now)', 'blocked'
                end
                if reason then
                    declined[#declined + 1] = { line = m.line, what = m.def or m.text, reason = reason,
                        class = class, resolutions = res, evidence = ev }
                else
                    local body = m.text:gsub('^%s*', '')
                    dels[#dels + 1] = { s = m.line - 1, e = m.line - 1, old = { srclines[m.line] } }
                    ins[#ins + 1] = { after = p.line - 2, lines = { indent .. body } }
                    moves[#moves + 1] = { line = m.line, to = p.line, text = body, def = m.def, waived = waived }
                end
            end
        end
    end
    return { verb = 'optimize-hoist', touched = { node.file }, generation = store.generation,
        stamps = { [node.file] = txn.disk_stamp(store.data.root, node.file) }, rel = node.file,
        dels = dels, ins = ins, moves = moves, declined = declined }
end

--- Build a PRE (partial-redundancy) plan: a pure computation in BOTH arms of an
--- exhaustive if/else over pre-branch operands → bind it to a `local` above the branch
--- and reuse in each arm. `opts.line` targets one branch. The SOUNDEST verb: an
--- exhaustive if/else always takes one arm, so hoisting the common computation above it
--- adds no work on any path (no zero-trip, no nilability) — optimize.pre already gated
--- pure + both-arms + operands-fixed-before. Only `hedged` (an aliasing table read) is
--- refused. @return table? plan @return string? why
function M.plan_pre(store, fn_id, opts)
    opts = opts or {}
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return nil, 'no such node' end
    local lang = lang_of(node.file)
    if not lang then return nil, 'unsupported language' end
    local pre = optimize.pre(store, fn_id)
    if #pre.hoists == 0 then return nil, 'no partial-redundancy candidates' end
    local flow = require 'cartograph.flow'
    local fl = flow.present(node) and flow.record(node)
    local bound = {}
    for _, p in ipairs((fl and fl.params) or {}) do bound[p] = true end
    for _, r in ipairs((fl and fl.stmts) or {}) do for _, d in ipairs(r.def or {}) do bound[d] = true end end
    local src = table.concat(store.content(node) or {}, '\n')
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return nil, 'cannot parse' end
    local root = parser:parse()[1]:root()
    local srclines = vim.split(src, '\n', { plain = true })

    local ins, reps, moves, declined = {}, {}, {}, {}
    for _, h in ipairs(pre.hoists) do
        if not opts.line or h.line == opts.line then
            if h.hedged then
                declined[#declined + 1] = { line = h.line, what = h.expr, class = 'risk',
                    reason = 'hedged: an aliasing table read could change the value between the arms' }
            else
                -- the arm occurrences (single-target assignments; the RHS = the shared expr)
                local rt = rhs_node(root, src, h.then_line, nil)
                local re = rhs_node(root, src, h.else_line, nil)
                if not (rt and re) then
                    declined[#declined + 1] = { line = h.line, what = h.expr, class = 'blocked',
                        reason = 'could not locate both arm occurrences' }
                else
                    local name = fresh_name('t', bound); bound[name] = true
                    local indent = (srclines[h.line] or ''):match('^(%s*)') or ''
                    ins[#ins + 1] = { after = h.line - 2, lines = { indent .. ('local %s = %s'):format(name, h.expr) } }
                    for _, rn in ipairs({ rt, re }) do
                        local sr, sc, er, ec = rn:range()
                        reps[#reps + 1] = { at = { start = { line = sr, char = sc }, ['end'] = { line = er, char = ec } },
                            to = name, old = (srclines[sr + 1] or ''):sub(sc + 1, ec) }
                    end
                    moves[#moves + 1] = { line = h.line, expr = h.expr, ['local'] = name,
                        then_line = h.then_line, else_line = h.else_line }
                end
            end
        end
    end
    return { verb = 'optimize-pre', touched = { node.file }, generation = store.generation,
        stamps = { [node.file] = txn.disk_stamp(store.data.root, node.file) }, rel = node.file,
        reps = reps, ins = ins, moves = moves, declined = declined }
end

-- the edit callback for txn (single file: apply this plan's token-replacements)
local function edit_of(plan)
    return function (rel, before)
        if rel ~= plan.rel then return before end
        return txn.edit_file(before, plan.dels or {}, plan.reps or {}, plan.ins or {})
    end
end

--- Dry-run: the unified diff the apply WOULD write (nothing written).
--- @return table lines
--- @return table? before
--- @return table? after
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
--- write + refresh).
--- @return boolean ok
--- @return any entry_or_reason  (journal entry on ok, refusal reason otherwise)
--- @return table? diff_lines
function M.apply(store, plan)
    if #(plan.reps or {}) == 0 and #(plan.dels or {}) == 0 and #(plan.ins or {}) == 0 then
        return false, ('nothing applicable (%d declined)'):format(#(plan.declined or {}))
    end
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
    for _, r in ipairs(plan.reps or {}) do
        local sl0 = r.at.start.line -- 0-based line
        local cur = (lines[sl0 + 1] or ''):sub(r.at.start.char + 1, r.at['end'].char)
        if cur ~= r.old then
            return false, ('span drifted at %s:%d (expected `%s`, found `%s`) — re-plan')
                :format(plan.rel, sl0 + 1, r.old, cur)
        end
    end
    for _, d in ipairs(plan.dels or {}) do -- d.s/d.e 0-based inclusive; d.old = captured lines
        for i = d.s, d.e do
            if (lines[i + 1] or '\0') ~= (d.old and d.old[i - d.s + 1]) then
                return false, ('span drifted at %s:%d (delete target changed) — re-plan')
                    :format(plan.rel, i + 1)
            end
        end
    end
    -- parse-clean on the dry-run result BEFORE committing anything
    local before, after, derr = txn.dryrun(store, plan, edit_of(plan))
    if not before then return false, derr or 'dry-run failed' end
    if not parses_clean(after[plan.rel], lang_of(plan.rel)) then
        return false, 'the edit would not parse cleanly — refused'
    end
    local diff = txn.difftext(before, after, plan.touched)
    -- journal desc: the verb + any WAIVED premises (the recorded provenance of an override)
    local waivers = {}
    for _, m in ipairs(plan.moves or {}) do if m.waived then waivers[#waivers + 1] = m.waived end end
    local desc = plan.verb .. (#waivers > 0 and (' under: ' .. table.concat(waivers, '; ')) or '')
    local entry, why = txn.execute(store, plan, desc, edit_of(plan))
    if not entry then return false, why end
    return true, entry, diff
end

-- shared: apply a (plan, why) pair → the structured result (never throws). Always
-- carries `declined` (the per-site refusal ledger) so a caller sees BOTH what was
-- applied and what was refused-with-reason — even when nothing applied.
local function run_plan(store, plan, why)
    if not plan then return { ok = false, applied = 0, declined = {}, reason = why } end
    local ok, entry_or_reason, diff = M.apply(store, plan)
    if not ok then
        return { ok = false, applied = 0, moves = plan.moves, declined = plan.declined,
            reason = entry_or_reason }
    end
    return { ok = true, applied = #plan.moves, moves = plan.moves, declined = plan.declined, diff = diff }
end

--- One-call agent entries (never throw): plan + apply the focused fn's clean rewrites
--- (`opts.line` targets one finding/loop). Result: { ok, applied, moves, declined, diff,
--- reason } — `declined` = the per-site ledger { {line, what, reason} }.
function M.run(store, fn_id, opts) return run_plan(store, M.plan_cse(store, fn_id, opts)) end
function M.run_localize(store, fn_id, opts) return run_plan(store, M.plan_localize(store, fn_id, opts)) end
function M.run_hoist(store, fn_id, opts) return run_plan(store, M.plan_hoist(store, fn_id, opts)) end
function M.run_pre(store, fn_id, opts) return run_plan(store, M.plan_pre(store, fn_id, opts)) end

-- ── location entry (targeted refactoring: point at a spot, not an id) ─────────
--- the INNERMOST function/method whose range encloses `file`:`line` (1-based), or nil.
--- `file` matches a node's stored rel path exactly or as a trailing `/`-segment (so a
--- suffix like a basename works). This is the "resolve the spot to a node" seam.
function M.at(store, file, line)
    if not (store.data and store.data.nodes and file and line) then return nil end
    local best, bestspan
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.range and n.file
            and (n.file == file or n.file:sub(-(#file + 1)) == '/' .. file) then
            local sl, el = at.sl(n.range) + 1, at.el(n.range) + 1 -- range is 0-based; make 1-based
            if sl <= line and line <= el then
                local span = el - sl
                if not bestspan or span < bestspan then best, bestspan = n.id, span end
            end
        end
    end
    return best
end

--- plan by LOCATION: resolve the fn at `file`:`line`, then plan its CSE reuses. Pass
--- `opts.line` to target a single finding (commonly = the location line).
--- @return table? plan
--- @return string? why  (set when plan is nil)
function M.plan_at(store, file, line, opts)
    local fid = M.at(store, file, line)
    if not fid then return nil, ('no function at %s:%d'):format(file, line) end
    return M.plan_cse(store, fid, opts)
end

--- run by LOCATION (the targeted one-call entry). Returns the same shape as M.run.
function M.run_at(store, file, line, opts)
    local fid = M.at(store, file, line)
    if not fid then return { ok = false, applied = 0, reason = ('no function at %s:%d'):format(file, line) } end
    return M.run(store, fid, opts)
end

--- Report lines (the thin surface): every apply the focused fn admits — CSE-reuse,
--- localize-upvalue, hoist — as DRY-RUN diffs (nothing written). The write is the API.
function M.report(store, fn_id)
    local name = (store.node(fn_id) or {}).name or fn_id
    local L, any = {}, false
    local sections = {
        { 'CSE-reuse', M.plan_cse(store, fn_id) },
        { 'localize-upvalue', M.plan_localize(store, fn_id) },
        { 'hoist (LICM)', M.plan_hoist(store, fn_id) },
        { 'PRE', M.plan_pre(store, fn_id) },
    }
    for _, s in ipairs(sections) do
        local label, plan = s[1], s[2]
        if plan and (#plan.moves > 0 or #(plan.declined or {}) > 0) then
            any = true
            L[#L + 1] = ('optimize-apply [%s]: %s — %d applicable, %d declined (dry-run):')
                :format(label, name, #plan.moves, #(plan.declined or {}))
            if #plan.moves > 0 then
                for _, l in ipairs(M.preview(store, plan)) do L[#L + 1] = l end
            end
            for _, d in ipairs(plan.declined or {}) do -- the refusal ledger: why NOT applied
                L[#L + 1] = ('  ✗ L%-4d %-22s [%s] %s'):format(d.line, tostring(d.what), d.class or '?', d.reason)
                if d.evidence then -- provenance: the fact(s) behind the verdict, so an override is informed
                    L[#L + 1] = ('       evidence: %s'):format(d.evidence)
                end
                for _, r in ipairs(d.resolutions or {}) do -- the menu: premises you can supply
                    L[#L + 1] = ('       → assume `%s`%s: %s'):format(r.id,
                        d.class == 'wrong' and ' (⚠ overrides a likely-bug)' or '', r.premise)
                end
            end
            L[#L + 1] = ''
        end
    end
    if not any then return { ('optimize-apply: %s — nothing to apply'):format(name) } end
    L[#L + 1] = '(dry-run — the API applies it: txn-journaled + undoable, guarded by'
    L[#L + 1] = ' generation + file-stamp CAS + span-CAS + parse-clean. Sound gates: CSE'
    L[#L + 1] = ' = non-hedged/single-assignment source; localize = stdlib-global root,'
    L[#L + 1] = ' free leaf name, no nested fn; hoist = run-once loop, single-line invariant.)'
    return L
end

return M
