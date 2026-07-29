-- EXPRLINT — the RUNG-0 lints ([[cartograph-expression-layer]]): the analyzers that
-- ride the expression IR ALONE (no reaching, no purity fixpoint — pure structure +
-- loop ancestry + eval-of-literals). Each is a small, high-signal check that was
-- impossible before the IR because it needs OPERATOR/OPERAND structure the flow rows
-- didn't carry. All key-equality checks gate on `expr.is_pure` (comparing two
-- side-effecting operands is unsound). Read-only; a SUGGESTION, `~` where a runtime
-- subtlety (NaN, metamethods, truthy≠true) means it's a smell not a certainty.

local expr = require 'cartograph.expr'

local M = {}

-- loop control heads (by raw node `t`) — mirrors optimize.LOOPISH
local LOOPISH = { for_statement = true, for_in_statement = true,
    while_statement = true, repeat_statement = true, loop_statement = true,
    loop_expression = true, foreach_statement = true, for_numeric_statement = true,
    for_generic_statement = true }
-- self-comparison verdicts: op → (always true?) with the NaN caveat on ==/~=
local SELFCMP = {
    ['=='] = { v = true, nan = true }, ['~='] = { v = false, nan = true },
    ['!='] = { v = false, nan = true },
    ['<'] = { v = false }, ['>'] = { v = false },
    ['<='] = { v = true }, ['>='] = { v = true } }
local BOOLCMP = { ['=='] = true, ['~='] = true, ['!='] = true }

-- ── the analysis ─────────────────────────────────────────────────────────────
--- Rung-0 findings for the focused fn. @return table {
---   unsupported?, findings: { {line, rule, msg, hedged} }[], census: {total, unknown, kinds} }
function M.lint(store, fn_id)
    local got = expr.of(store, fn_id)
    if not got then return { unsupported = true, findings = {}, census = { total = 0, unknown = 0, kinds = {} } } end
    local rows = got.fl.stmts
    local out, seen = {}, {}
    local function add(line, rule, msg, hedged)
        local key = line .. '\1' .. rule .. '\1' .. msg
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = { line = line, rule = rule, msg = msg, hedged = hedged or false }
    end
    -- ancestry: is row r inside a loop?
    local function in_loop(r)
        local p = rows[r].parent
        while p and p ~= 0 do
            if LOOPISH[rows[p].t or ''] then return true end
            p = rows[p].parent
        end
        return false
    end
    -- the value/condition exprs to scan for the general (nested) checks
    local function scan_exprs(row)
        local es = {}
        for _, e in ipairs(row.expr.rhs or {}) do es[#es + 1] = e end
        if row.expr.cond and #(row.expr.rhs or {}) == 0 then es[#es + 1] = row.expr.cond end
        return es
    end

    for r, row in ipairs(rows) do
        if row.expr then
            -- (1) self-compare / (2) duplicated logical operand / (3) bool-literal
            --     comparison / (5) pseudo-ternary — all walk every bin in the row.
            for _, root in ipairs(scan_exprs(row)) do
                expr.walk(root, function (e)
                    if e.k ~= 'bin' then return end
                    local sc = SELFCMP[e.op]
                    if sc and expr.is_pure(e.l) and expr.key(e.l) == expr.key(e.r) then
                        add(row.l, 'self-compare',
                            ('both sides of `%s` are identical → always %s'):format(e.op, tostring(sc.v)),
                            sc.nan) -- ==/~= hedged: NaN self-comparison is the deliberate exception
                    end
                    if (e.op == 'and' or e.op == 'or')
                        and expr.is_pure(e.l) and expr.key(e.l) == expr.key(e.r) then
                        add(row.l, 'duplicated-operand',
                            ('`x %s x` — both operands identical, equals just `x`'):format(e.op))
                    end
                    if BOOLCMP[e.op] then
                        local lb = e.l.k == 'lit' and e.l.ty == 'bool'
                        local rb = e.r.k == 'lit' and e.r.ty == 'bool'
                        if lb ~= rb then -- exactly one side a boolean literal
                            local bv = lb and e.l.v or e.r.v
                            add(row.l, 'bool-comparison',
                                ('comparison to boolean literal `%s` — drop it (a value is truthy, not necessarily `== %s`)')
                                    :format(tostring(bv), tostring(bv)), true)
                        end
                    end
                    -- pseudo-ternary hazard: `(c and x) or y` where x is statically falsy
                    if e.op == 'or' and e.l.k == 'bin' and e.l.op == 'and' then
                        local okx, xv = expr.eval(e.l.r)
                        if okx and not expr.truthy(xv) then
                            add(row.l, 'pseudo-ternary',
                                'lua `c and x or y` where `x` is falsy — the `or` ALWAYS falls through to `y`', false)
                        end
                    end
                end)
            end
            -- (4) self-assignment: a REASSIGNMENT `x = x` (a `local x = x` is legitimate
            --     upvalue capture — excluded, it's a variable_declaration not assignment).
            if row.t == 'assignment_statement'
                and #(row.expr.lhs or {}) == 1 and #(row.expr.rhs or {}) == 1 then
                local l, rr = row.expr.lhs[1], row.expr.rhs[1]
                if expr.is_pure(l) and expr.is_pure(rr) and expr.key(l) == expr.key(rr) then
                    add(row.l, 'self-assignment',
                        'assignment of a value to itself — a no-op',
                        l.k ~= 'name') -- field/index target hedged (a metamethod could fire)
                end
            end
            -- (7) string-concat in a loop: `s = s .. x` accumulation → O(n²), use table.concat
            if row.t == 'assignment_statement' and #(row.expr.lhs or {}) == 1
                and #(row.expr.rhs or {}) == 1 and in_loop(r) then
                local l, rr = row.expr.lhs[1], row.expr.rhs[1]
                if l.k == 'name' and rr.k == 'bin' and rr.op == '..' then
                    local reads = {}
                    for _, n in ipairs(expr.names({ rhs = { rr } })) do reads[n] = true end
                    if reads[l.n] then
                        add(row.l, 'concat-in-loop',
                            ('`%s = %s .. …` inside a loop is O(n²) — accumulate into a table and table.concat once'):format(l.n, l.n))
                    end
                end
            end
            -- (6) constant condition: a control condition that folds to a constant
            if row.expr.cond then
                local okc, cv = expr.eval(row.expr.cond)
                if okc then
                    local loop = LOOPISH[row.t or '']
                    local tv = expr.truthy(cv)
                    -- a bare `while true` is an idiomatic infinite loop — only flag a
                    -- DEAD (false) loop; for if/elseif flag either way.
                    if not (loop and tv) then
                        add(row.l, 'constant-condition',
                            ('condition is constant — always %s%s'):format(tostring(tv),
                                (loop and not tv) and ' (loop body is dead)'
                                    or (not loop and (tv and ' (then-branch always taken)' or ' (then-branch dead)')) or ''))
                    end
                end
            end
        end
    end

    -- (8) duplicated condition within an if-chain: the head `if` cond + its `elseif`
    --     conds; a later duplicate of an earlier one is unreachable.
    for r, row in ipairs(rows) do
        if row.t == 'if_statement' and row.expr and row.expr.cond then
            local chain = { { line = row.l, cond = row.expr.cond } }
            for _, row2 in ipairs(rows) do
                if row2.parent == r and (row2.t == 'elseif_statement' or row2.kind == 'elseif_statement')
                    and row2.expr and row2.expr.cond then
                    chain[#chain + 1] = { line = row2.l, cond = row2.expr.cond }
                end
            end
            for i = 2, #chain do
                for j = 1, i - 1 do
                    if expr.is_pure(chain[i].cond) and expr.is_pure(chain[j].cond)
                        and expr.key(chain[i].cond) == expr.key(chain[j].cond) then
                        add(chain[i].line, 'duplicated-condition',
                            ('same condition as the branch at L%d — this branch is unreachable'):format(chain[j].line))
                        break
                    end
                end
            end
        end
    end

    -- census: expr-node coverage (the honest '?' rate)
    local kinds, total, unknown = {}, 0, 0
    for _, row in ipairs(rows) do
        if row.expr then
            for _, e in ipairs(row.expr.rhs or {}) do
                expr.walk(e, function (n) kinds[n.k] = (kinds[n.k] or 0) + 1; total = total + 1
                    if n.k == '?' then unknown = unknown + 1 end end)
            end
        end
    end
    table.sort(out, function (a, b)
        if a.line ~= b.line then return a.line < b.line end
        return a.rule < b.rule
    end)
    -- The census is not decoration: it is the only honest thing a CONSUMER can
    -- say when there are no findings. MEASURED — with a python parser on the rtp,
    -- `def f(a): if a == a: …` harvests total=5 / unknown=1 and trips ZERO rules,
    -- because the rung-0 rules are Lua-authored. So "0 findings" means one of
    -- three things (nothing to read · read and clean · read but no rule applies)
    -- and a surface that renders it as "clean" fabricates a verdict. Every
    -- consumer must report WHAT WAS CHECKED alongside the count.
    return { findings = out, census = { total = total, unknown = unknown, kinds = kinds } }
end

--- The lens surface (:CartographExpr): the focused fn's Rung-0 findings + an
--- expression-coverage line (the '?' rate = honest structural coverage).
function M.report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'expr: no such node' } end
    local res = M.lint(store, fn_id)
    if res.unsupported then
        return { ('expr: %s not supported (INC 1 = Lua; the harvest is language-agnostic, langs slot in)')
            :format(node.file and node.file:match('%.(%w+)$') or '?') }
    end
    local L = {}
    if #res.findings == 0 then
        -- not "clean": the count alone is a verdict the reading has not earned
        -- (the coverage line below is what qualifies it)
        L[#L + 1] = ('expr: %s — 0 findings of %d expression node(s) read')
            :format(node.name or fn_id, (res.census or {}).total or 0)
    else
        L[#L + 1] = ('expr: %s — %d finding(s)'):format(node.name or fn_id, #res.findings)
        L[#L + 1] = ''
        for _, f in ipairs(res.findings) do
            L[#L + 1] = ('  %s L%-4d %-20s %s'):format(f.hedged and '~' or ' ', f.line, f.rule, f.msg)
        end
    end
    local c = res.census
    L[#L + 1] = ''
    if c.total > 0 then
        L[#L + 1] = ('expression coverage: %d node(s), %d unknown (%.1f%% mapped)')
            :format(c.total, c.unknown, 100 * (c.total - c.unknown) / c.total)
    end
    L[#L + 1] = '(~ = a runtime subtlety makes it a smell, not a certainty: NaN self-compare,'
    L[#L + 1] = ' a metamethod on a field target, truthy≠true. The rest are exact no-ops/dead code.)'
    return L
end

return M
