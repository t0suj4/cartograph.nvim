-- EXPRLINT — the RUNG-0 lints ([[cartograph-expression-layer]]): the analyzers that
-- ride the expression IR ALONE (no reaching, no purity fixpoint — pure structure +
-- loop ancestry + eval-of-literals). Each is a small, high-signal check that was
-- impossible before the IR because it needs OPERATOR/OPERAND structure the flow rows
-- didn't carry. All key-equality checks gate on `expr.is_pure` (comparing two
-- side-effecting operands is unsound). Read-only; a SUGGESTION, `~` where a runtime
-- subtlety (NaN, metamethods, truthy≠true) means it's a smell not a certainty.

-- @langs bash c cpp go java javascript lua php python ruby rust tsx typescript zig
-- It runs wherever `expr.of` succeeds — every language declaring body_field or
-- body_of — NOT lua, despite the "INC 1 = Lua" its report used to print. MEASURED
-- before this declaration: js 225 fns / 0 findings, php 73 / 0, python 267 / 0,
-- go 279 / 0, against lua 275 / 11 and rust 278 / 17. Those zeroes were not clean
-- code; three rules were gated on LUA'S node names and could not fire (CART-0304).
--
-- ★ FIXING THE NAMES WAS NECESSARY AND NOT SUFFICIENT. Measured with PLANTED
-- POSITIVES (one file per language holding a self-assignment and a duplicated
-- if/elseif condition), the name fix alone moved only ruby, [] -> [self-assignment];
-- python and js still reported nothing, blocked one layer DOWN in expr.lua. Both
-- blockers are now fixed there (CART-0314): an `expression_statement` wrapping a
-- plain assignment is unwrapped, so `lhs` is populated, and python's
-- `comparison_operator` is in the BIN table, so `x > 1` is no longer an
-- honest-unknown that every purity gate must refuse. The fixture now reads
--   lua [duplicated-condition self-assignment] · python [duplicated-condition
--   self-assignment] · ruby [self-assignment] · js [self-assignment]
-- js lacks duplicated-condition BY DESIGN: it is a NESTED-else grammar with no
-- elseif node at all, which spec/tsutil states as a refusal rather than a gap.
--
-- ★★ AND THE CORPUS CENSUS COULD NOT HAVE TOLD YOU ANY OF THIS. It read 0 on
-- js/php/python/go before the name fix, after it, AND after the IR fix — three
-- identical readings across two real repairs. What changed underneath was capability;
-- what the census measures is the corpus, and django/hugo/grocy simply contain no
-- self-assignment and no duplicated if-chain condition in the sampled functions. That
-- the two zeroes are now DIFFERENT — "these corpora are clean" rather than "these
-- rules cannot fire" — is invisible in the number and is the whole point: a zero has
-- to be interrogated with a planted positive, not with a bigger corpus. (rust's 17
-- constant-condition findings are the cross-check that the pipeline does fire on a
-- non-lua language when the pattern is actually present.)

local expr = require 'cartograph.expr'
local tsutil = require 'cartograph.spec.tsutil'

local M = {}

-- A PLAIN assignment `x = y`, per language. Deliberately NOT flow.lua's ASSIGN,
-- which also carries `augmented_assignment_expression` because it answers "where
-- are the def-position roots" — and `x += x` is emphatically not a self-assignment
-- no-op. Same shape, different question, so a separate table that says why (the
-- FNDECL test from CART-0308: do not unify on shape alone).
local PLAIN_ASSIGN = {
    assignment_statement = true,   -- lua
    assignment = true,             -- ruby, python
    assignment_expression = true,  -- php, js, c, cpp, java, go
    variable_assignment = true,    -- bash
    -- ★ AND THE WRAPPER, because the ROW keeps the wrapper's type. expr.harvest_row
    -- now unwraps an `expression_statement` holding a plain assignment (CART-0314),
    -- but `row.t` still comes from FLOW, which records the statement node — so a
    -- js/python `y = x` row reads `expression_statement` however well the IR split
    -- it. The real discriminator is the SHAPE the guards below already test
    -- (exactly one lhs and one rhs), which no bare call or augmented assignment
    -- has; this entry just stops the type test from vetoing the shape test.
    expression_statement = true,
}

-- ★ A DECLARED REFUSAL, not a table with holes. The concat-in-loop rule needs an
-- operator that means STRING CONCATENATION and nothing else. Lua's `..` and php's
-- `.` qualify. Everywhere else the spelling is `+`, which is overloaded with
-- arithmetic — `s = s + x` is an O(n²) accumulation only if both operands are
-- strings, and that is a TYPE question the expression IR does not answer. Listing
-- `+` here would fire the rule on every integer accumulator in the corpus, so the
-- rule declines those languages instead, and this comment is why (CART-0304).
local CONCAT_OP = { lua = '..', php = '.' }

-- ★ THE PRIVATE LOOPISH TABLE IS GONE (CART-0383). Four modules each kept one and every
-- PAIR of them disagreed; none knew the forms flow had opened; all four carried
-- `loop_statement`, which no grammar we support spells. flow.loops_of(fl) is the one answer,
-- and it is LANGUAGE-AWARE — js for-of and ruby while/until/for are loops only per spec.
-- self-comparison verdicts: op → (always true?) with the NaN caveat on ==/~=
local SELFCMP = {
    ['=='] = { v = true, nan = true }, ['~='] = { v = false, nan = true },
    ['!='] = { v = false, nan = true },
    ['<'] = { v = false }, ['>'] = { v = false },
    ['<='] = { v = true }, ['>='] = { v = true } }
local BOOLCMP = { ['=='] = true, ['~='] = true, ['!='] = true }

-- ── suppression ──────────────────────────────────────────────────────────────
-- A finding can be silenced FROM THE SOURCE IT IS ABOUT: `@cg-ignore` trailing the
-- reported line, or on a comment line directly above it, optionally naming rules
-- (`@cg-ignore: concat-in-loop`) so one marker does not silence everything the line
-- could ever be flagged for. In the source and not in a config file, because the
-- decision belongs where the code is: it moves with the function (txn.attach_above
-- already makes moveapply/clonemerge carry an attached comment along) and it is
-- reviewable in a diff.
--
-- Suppression is DISCLOSED, never silent. lint() returns the silenced findings
-- SEPARATELY and counts them, and every consumer reports the count, because a
-- linter that hides what it was told to ignore cannot be audited — and "0 findings"
-- would once again mean two different things.
M.MARK = '@cg-ignore'
local MARKPAT = '@cg%-ignore'
local COMMENT_LEADS = { '--', '#', '//', '/*', '*', ';' }

local function is_comment(line)
    local t = line and line:match('^%s*(%S.*)$')
    if not t then return false end
    for _, p in ipairs(COMMENT_LEADS) do
        if t:sub(1, #p) == p then return true end
    end
    return false
end

--- The marker silencing `rule` at 1-based `lnum`, or nil. Checks the reported line
--- itself, then the comment block directly above it (blank lines and code stop the
--- walk — the same adhesion rule txn.attach_above uses for a def's comments).
function M.suppressed_at(lines, lnum, rule)
    local function marks(line)
        if not line then return nil end
        local at = line:find(MARKPAT)
        if not at then return nil end
        local named = line:match(MARKPAT .. '%s*:%s*([%w%s,_-]+)')
        if not named then return vim.trim(line:sub(at)) end -- bare: silences all
        for r in named:gmatch('[%w_-]+') do
            if r == rule then return vim.trim(line:sub(at)) end
        end
        return nil
    end
    local own = marks(lines[lnum])
    if own then return own end
    local i = lnum - 1
    while i >= 1 and is_comment(lines[i]) do
        local m = marks(lines[i])
        if m then return m end
        i = i - 1
    end
    return nil
end

-- ── THE RULES, as a table (CART-0015) ───────────────────────────────────────
-- Each rule is { name, severity, on, fix_why, run }. A rule with an IDENTITY is what a finding's title can descend
-- into — the analyzer that produced it ([[cartograph-explaining-a-finding]]); eight inline call sites funnelling into
-- one add() had none. `on` says what the rule is handed, and the driver below walks the function ONCE per kind:
--   bin  run(e, row, x)   every binary expression inside a row's value / condition expressions
--   row  run(row, r, x)   every statement row that carries an expression
--   fn   run(x)           the whole function, once (a rule that relates rows to each other)
-- x = { add, rows, in_loop, concat_op, LOOPISH }. `add(line, msg, hedged, node)` files a finding under THE RULE
-- BEING RUN — a rule cannot file under another's name. `fix_why` says why the rule offers no MECHANICAL fix,
-- because "there is no safe rewrite" and "nobody has written one yet" are different facts, and an action list that
-- simply omits the option states neither. Order is significant: within a kind, rules run in table order, which is
-- the order findings were filed before the table existed.
M.RULES = {
    { name = 'self-compare', severity = 'warn', on = 'bin',
        fix_why = 'what the comparison SHOULD have said is not derivable',
        run = function (e, _, x)
            local sc = SELFCMP[e.op]
            if sc and expr.is_pure(e.l) and expr.key(e.l) == expr.key(e.r) then
                x.add(nil, ('both sides of `%s` are identical → always %s'):format(e.op, tostring(sc.v)),
                    sc.nan, e) -- ==/~= hedged: NaN self-comparison is the deliberate exception
            end
        end },
    { name = 'duplicated-operand', severity = 'warn', on = 'bin',
        fix_why = 'mechanical in principle; not implemented yet',
        run = function (e, _, x)
            if (e.op == 'and' or e.op == 'or') and expr.is_pure(e.l) and expr.key(e.l) == expr.key(e.r) then
                x.add(nil, ('`x %s x` — both operands identical, equals just `x`'):format(e.op), false, e)
            end
        end },
    { name = 'bool-comparison', severity = 'info', on = 'bin',
        fix_why = 'mechanical in principle; not implemented yet',
        run = function (e, _, x)
            if not BOOLCMP[e.op] then return end
            local lb = e.l.k == 'lit' and e.l.ty == 'bool'
            local rb = e.r.k == 'lit' and e.r.ty == 'bool'
            if lb ~= rb then -- exactly one side a boolean literal
                local bv = lb and e.l.v or e.r.v
                x.add(nil, ('comparison to boolean literal `%s` — drop it (a value is truthy, not necessarily `== %s`)')
                    :format(tostring(bv), tostring(bv)), true, e)
            end
        end },
    { name = 'pseudo-ternary', severity = 'warn', on = 'bin',
        fix_why = 'the intended value is not derivable',
        -- `(c and x) or y` where x is statically falsy
        run = function (e, _, x)
            if e.op == 'or' and e.l.k == 'bin' and e.l.op == 'and' then
                local okx, xv = expr.eval(e.l.r)
                if okx and not expr.truthy(xv) then
                    x.add(nil, 'lua `c and x or y` where `x` is falsy — the `or` ALWAYS falls through to `y`', false, e)
                end
            end
        end },
    { name = 'self-assignment', severity = 'warn', on = 'row',
        fix_why = 'deleting the line is unsafe when it carries other statements; not implemented yet',
        -- a REASSIGNMENT `x = x` (a `local x = x` is legitimate upvalue capture — excluded, it's a
        -- variable_declaration not assignment)
        run = function (row, _, x)
            if PLAIN_ASSIGN[row.t or ''] and #(row.expr.lhs or {}) == 1 and #(row.expr.rhs or {}) == 1 then
                local l, rr = row.expr.lhs[1], row.expr.rhs[1]
                if expr.is_pure(l) and expr.is_pure(rr) and expr.key(l) == expr.key(rr) then
                    x.add(nil, 'assignment of a value to itself — a no-op',
                        l.k ~= 'name', l) -- field/index target hedged (a metamethod could fire)
                end
            end
        end },
    { name = 'concat-in-loop', severity = 'info', on = 'row',
        fix_why = 'the rewrite restructures the loop into a table + table.concat — a judgement, not a substitution',
        -- `s = s .. x` accumulation → O(n²), use table.concat
        run = function (row, r, x)
            if PLAIN_ASSIGN[row.t or ''] and #(row.expr.lhs or {}) == 1
                and #(row.expr.rhs or {}) == 1 and x.in_loop(r) then
                local l, rr = row.expr.lhs[1], row.expr.rhs[1]
                if x.concat_op and l.k == 'name' and rr.k == 'bin' and rr.op == x.concat_op then
                    local reads = {}
                    for _, n in ipairs(expr.names({ rhs = { rr } })) do reads[n] = true end
                    if reads[l.n] then
                        x.add(nil, ('`%s = %s %s …` inside a loop is O(n²) — accumulate into a list and join once')
                            :format(l.n, l.n, x.concat_op), false, rr)
                    end
                end
            end
        end },
    { name = 'constant-condition', severity = 'warn', on = 'row',
        fix_why = 'which branch to keep is a judgement',
        run = function (row, _, x)
            if not row.expr.cond then return end
            local okc, cv = expr.eval(row.expr.cond)
            if not okc then return end
            local loop = x.LOOPISH[row.t or '']
            local tv = expr.truthy(cv)
            -- a bare `while true` is an idiomatic infinite loop — only flag a DEAD (false) loop; for if/elseif flag
            -- either way.
            if not (loop and tv) then
                x.add(nil, ('condition is constant — always %s%s'):format(tostring(tv),
                    (loop and not tv) and ' (loop body is dead)'
                        or (not loop and (tv and ' (then-branch always taken)' or ' (then-branch dead)')) or ''),
                    false, row.expr.cond)
            end
        end },
    { name = 'duplicated-condition', severity = 'warn', on = 'fn',
        fix_why = 'the intended condition is not derivable',
        -- within an if-chain (the head `if` cond + its `elseif` conds) a later duplicate of an earlier one is
        -- unreachable
        run = function (x)
            local rows = x.rows
            for r, row in ipairs(rows) do
                if tsutil.IF_HEAD[row.t or ''] and row.expr and row.expr.cond then
                    local chain = { { line = row.l, cond = row.expr.cond } }
                    for _, row2 in ipairs(rows) do
                        if row2.parent == r and (tsutil.ELSEIF[row2.t or ''] or tsutil.ELSEIF[row2.kind or ''])
                            and row2.expr and row2.expr.cond then
                            chain[#chain + 1] = { line = row2.l, cond = row2.expr.cond }
                        end
                    end
                    for i = 2, #chain do
                        for j = 1, i - 1 do
                            if expr.is_pure(chain[i].cond) and expr.is_pure(chain[j].cond)
                                and expr.key(chain[i].cond) == expr.key(chain[j].cond) then
                                x.add(chain[i].line,
                                    ('same condition as the branch at L%d — this branch is unreachable'):format(chain[j].line),
                                    false, chain[i].cond)
                                break
                            end
                        end
                    end
                end
            end
        end },
}
M.BY_NAME, M.FIX_WHY = {}, {}
for _, rule in ipairs(M.RULES) do M.BY_NAME[rule.name] = rule; M.FIX_WHY[rule.name] = rule.fix_why end
M.FIX_WHY_DEFAULT = 'no mechanical rewrite is implemented for this rule'

-- ── the analysis ─────────────────────────────────────────────────────────────
--- Rung-0 findings for the focused fn. @return table {
---   unsupported?, findings: { {line, rule, severity, msg, hedged, node} }[], census: {total, unknown, kinds} }
function M.lint(store, fn_id)
    local got = expr.of(store, fn_id)
    if not got then return { unsupported = true, findings = {}, census = { total = 0, unknown = 0, kinds = {} } } end
    local rows = got.fl.stmts
    local out, seen = {}, {}
    -- `node` is the OFFENDING EXPRESSION — the sub-expression the rule actually
    -- objected to, not the statement containing it. Every rule has it in hand when
    -- it fires, and every expr node carries `.at` (its source byte-range), so a
    -- consumer can mark the construct itself: constant-condition marks `false`, not
    -- the whole `if`. This is what lets an explanation BE the offending node instead
    -- of a paragraph about it ([[cartograph-explaining-a-finding]]).
    local cur, cur_line -- the rule being run, and the row line its finding defaults to
    local function add(line, msg, hedged, node)
        line = line or cur_line
        local key = line .. '\1' .. cur.name .. '\1' .. msg
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = { line = line, rule = cur.name, severity = cur.severity, msg = msg,
            hedged = hedged or false, node = node }
    end
    -- ancestry: is row r inside a loop?
    local LOOPISH = require('cartograph.flow').loops_of(got.fl)
    local function in_loop(r)
        local p = rows[r].parent
        while p and p ~= 0 do
            if LOOPISH[rows[p].t or ''] then return true end
            p = rows[p].parent
        end
        return false
    end
    local x = { add = add, rows = rows, in_loop = in_loop, concat_op = CONCAT_OP[got.lang or ''], LOOPISH = LOOPISH }
    local on = { bin = {}, row = {}, fn = {} }
    for _, rule in ipairs(M.RULES) do local t = on[rule.on]; t[#t + 1] = rule end
    -- the value/condition exprs to scan for the general (nested) checks
    local function scan_exprs(row)
        local es = {}
        for _, e in ipairs(row.expr.rhs or {}) do es[#es + 1] = e end
        if row.expr.cond and #(row.expr.rhs or {}) == 0 then es[#es + 1] = row.expr.cond end
        return es
    end

    for r, row in ipairs(rows) do
        if row.expr then
            cur_line = row.l
            for _, root in ipairs(scan_exprs(row)) do
                expr.walk(root, function (e)
                    if e.k ~= 'bin' then return end
                    for _, rule in ipairs(on.bin) do cur = rule; rule.run(e, row, x) end
                end)
            end
            for _, rule in ipairs(on.row) do cur = rule; rule.run(row, r, x) end
        end
    end
    cur_line = nil
    for _, rule in ipairs(on.fn) do cur = rule; rule.run(x) end

    -- census: expr-node coverage (the honest '?' rate)
    --
    -- ONE ROW PER (line, serialized rhs). MEASURED BUG, found by a user asking what
    -- `~ 52/56 read` meant: a for-loop header lands in fl.stmts TWICE with
    -- byte-identical expressions (verified expr.key(a) == expr.key(b) on the two
    -- rows at playerBonuses.lua:197), so every header sub-expression was counted
    -- twice — inflating the numerator AND the denominator. apply_bonuses reported 4
    -- unread where there are 2. The telling part: `add` above ALREADY dedupes
    -- findings on (line, rule, msg), so this function knew rows could repeat and
    -- only the census forgot. Deduping the ROW fixes the cause; deduping NODES
    -- would also collapse a genuinely repeated sub-expression within one row.
    --
    -- The unread set is KEPT, not just counted: a count nobody can open is a claim
    -- nobody can check, which is exactly how the double-count survived. Each entry
    -- carries the grammar node type with no IR case and its source range, so the
    -- browser can name it and mark it ([[cartograph-explaining-a-finding]]).
    local kinds, total, unknown, unread = {}, 0, 0, {}
    local seen_rows = {}
    for _, row in ipairs(rows) do
        if row.expr then
            local sig = { tostring(row.l) }
            for _, e in ipairs(row.expr.rhs or {}) do sig[#sig + 1] = expr.key(e) end
            local rsig = table.concat(sig, '\1')
            if not seen_rows[rsig] then
                seen_rows[rsig] = true
                for _, e in ipairs(row.expr.rhs or {}) do
                    expr.walk(e, function (n)
                        kinds[n.k] = (kinds[n.k] or 0) + 1
                        total = total + 1
                        if n.k == '?' then
                            unknown = unknown + 1
                            unread[#unread + 1] = { line = row.l, t = n.t,
                                at = n.at, kids = #(n.kids or {}) }
                        end
                    end)
                end
            end
        end
    end
    table.sort(out, function (a, b)
        if a.line ~= b.line then return a.line < b.line end
        return a.rule < b.rule
    end)
    -- split off what the source asked us to ignore (read once, per lint call)
    local node = store.node and store.node(fn_id)
    local src = {}
    if node and store.abs then
        local fd = io.open(store.abs(node.file), 'r')
        if fd then
            src = vim.split(fd:read('a') or '', '\n', { plain = true })
            fd:close()
        end
    end
    local kept, hushed = {}, {}
    for _, f in ipairs(out) do
        local m = #src > 0 and M.suppressed_at(src, f.line, f.rule) or nil
        if m then
            f.suppressed_by = m
            hushed[#hushed + 1] = f
        else
            kept[#kept + 1] = f
        end
    end
    out = kept
    -- The census is not decoration: it is the only honest thing a CONSUMER can
    -- say when there are no findings. MEASURED — with a python parser on the rtp,
    -- `def f(a): if a == a: …` harvests total=5 / unknown=1 and trips ZERO rules,
    -- because the rung-0 rules are Lua-authored. So "0 findings" means one of
    -- three things (nothing to read · read and clean · read but no rule applies)
    -- and a surface that renders it as "clean" fabricates a verdict. Every
    -- consumer must report WHAT WAS CHECKED alongside the count.
    return { findings = out, suppressed = hushed, unread = unread,
        census = { total = total, unknown = unknown, kinds = kinds,
            suppressed = #hushed } }
end

--- The lens surface (:CartographExpr): the focused fn's Rung-0 findings + an
--- expression-coverage line (the '?' rate = honest structural coverage).
function M.report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'expr: no such node' } end
    local res = M.lint(store, fn_id)
    if res.unsupported then
        -- NOT "INC 1 = Lua", which this said for months after the harvest had grown
        -- to fourteen languages — a measured claim with a shelf life, in a string a
        -- user reads (CART-0304). `unsupported` means expr.of declined the FILE, so
        -- name that: the language has no body_field/body_of and gets no rows at all.
        return { ('expr: %s not supported — this language declares no function body '
            .. 'the flow builder can reach, so there are no expression rows to lint')
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
    -- DISCLOSED: a silenced finding still gets a line, with the marker that
    -- silenced it. Otherwise "0 findings" means clean-or-hushed all over again.
    if #(res.suppressed or {}) > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('suppressed by the source: %d'):format(#res.suppressed)
        for _, f in ipairs(res.suppressed) do
            L[#L + 1] = ('    L%-4d %-20s %s'):format(f.line, f.rule, f.suppressed_by)
        end
    end
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
