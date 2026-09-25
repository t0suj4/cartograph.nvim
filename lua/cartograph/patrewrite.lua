-- patrewrite.lua — REWRITE A BACKTRACKING PATTERN INTO ITS LINEAR EQUIVALENT, verified (CART-1057).
--
-- USER (2026-09-25): "Can cartograph do something about those findings?" -> "do the pattern rewrite".
-- loopcost prices a search's pattern (spec/lua_patterns.lua) and reports a `backtrack` hole; this is
-- the first REMEDY. It is a CATALOG, not pattern surgery: each rule pairs an idiom that backtracks
-- with an expression that answers the same and does not, and a rule is only ever applied after
--   1. a DIFFERENTIAL check: both expressions run through Lua's own matcher over a generated corpus
--      (every string up to length 5 over whitespace/non-whitespace/punctuation, plus random longer
--      ones); ONE differing input refuses the rule (`M.verify`);
--   2. a MEASURED exponent for the new pattern, recorded on the rule (tools/patternjoin.lua), since
--      the static degree over-estimates both sides.
-- The write goes through txn (plan / preview / apply / undo, CAS + span + parse guards) like every
-- other verb. A site carrying `@cg-ignore: pattern-rewrite` (exprlint's marker convention) is declined,
-- which is how the catalog's own reference implementations below keep their idioms. ⚠ A METHOD call (`x:match(p)`) is rewritten on the PREMISE that `x` is a string — a user
-- object with its own :match would change meaning — and the plan says so on every such site.

local txn = require 'cartograph.txn'

local M = {}

-- ── THE CATALOG ───────────────────────────────────────────────────────────────────
-- from     the pattern literal's VALUE (after unescaping) at the call site
-- fn       'match' | 'gsub'   (method or string.<fn> form)
-- repl     (gsub) the replacement literal that makes it a trim
-- expr     the new expression, `%s` = the subject's text (twice, for a `twice` rule)
-- twice    the new expression evaluates the subject twice: a plain name or field only
-- single   (gsub) only a parenthesized, single-value site
-- old      the ORIGINAL expression as a function of the subject (the reference); `new` is compiled
--          from `expr` below, so the checks exercise exactly the text that is written
-- measured growth exponents, old and new (M.measure, on the inputs that broke the obvious rewrite)
-- ⚠ THE OBVIOUS REWRITE WAS WRONG, and only the measurement said so. `(s:match('^%s*(.*%S)') or '')`
-- answers exactly like the trim idiom on all 22,608 corpus inputs — and is QUADRATIC on an
-- ALL-WHITESPACE string (0.16 s at 2,000 spaces, 2.88 s at 8,000; the original: 0.0008 s): with no
-- %S anywhere, the leading %s* backtracks every length and `.*` runs to the end and back each time.
-- The differential check cannot see cost; the measured exponent is part of acceptance for that reason.
-- The trim therefore tests for all-whitespace FIRST (`^()%s*$`, linear), and runs `^%s*(.*%S)` only
-- when a %S exists — then %s* stops at the first %S and never backtracks. That evaluates the subject
-- TWICE, so `twice` rules apply only where the subject is a plain name or a field/index of one.
M.RULES = {
    {
        id = 'trim', fn = 'match', from = '^%s*(.-)%s*$', twice = true,
        expr = "(%s:match('^()%%s*$') and '' or %s:match('^%%s*(.*%%S)'))",
        why = 'the trim idiom backtracks: `.-` retries every length against `%s*$` (quadratic on "x" .. spaces .. "y")',
        measured = { old = 2.19, new = 1.02 },
        old = function(s) return s:match('^%s*(.-)%s*$') end, -- @cg-ignore: pattern-rewrite (the reference)
    },
    {
        id = 'rtrim', fn = 'match', from = '^(.-)%s*$',
        expr = "(%s:match('^(.*%%S)') or '')",
        why = '`^(.-)%s*$` backtracks the same way (quadratic on "x" .. spaces .. "y")',
        measured = { old = 2.02, new = 1.0 },
        old = function(s) return s:match('^(.-)%s*$') end, -- @cg-ignore: pattern-rewrite (the reference)
    },
    {
        id = 'trim-gsub', fn = 'gsub', repl = '%1', from = '^%s*(.-)%s*$', single = true, twice = true,
        expr = "(%s:match('^()%%s*$') and '' or %s:match('^%%s*(.*%%S)'))",
        why = 'a trim written as gsub(..., "%1"); gsub returns TWO values, so only a parenthesized (single-value) site is rewritten',
        measured = { old = 2.19, new = 1.02 },
        old = function(s) return (s:gsub('^%s*(.-)%s*$', '%1')) end, -- @cg-ignore: pattern-rewrite (the reference)
    },
}

-- ★ ONE SOURCE OF TRUTH: the function the differential check and the timing exercise is COMPILED
-- FROM `expr`, the very text written into the source. The first cut carried a hand-written twin, and
-- a mutation that made `expr` the quadratic rewrite passed every test: the checks verified the twin.
for _, rule in ipairs(M.RULES) do
    local body = rule.expr:format('s', 's')
    rule.new = assert(loadstring('return function(s) return ' .. body .. ' end'))()
end

--- the new expression's growth, timed on the inputs that broke the obvious rewrite (all whitespace,
--- bracketed runs, runs with one non-space at either end); used by tools/patternjoin.lua --rules
--- @return number exponent (least squares over 1000..8000 characters)
function M.measure(rule, fn)
    fn = fn or rule.new
    local fams = {
        function(n) return (' '):rep(n) end,
        function(n) return 'x' .. (' '):rep(n - 2) .. 'y' end,
        function(n) return (' '):rep(n - 1) .. 'x' end,
        function(n) return 'x' .. (' '):rep(n - 1) end,
        function(n) return ('x '):rep(math.floor(n / 2)) end,
    }
    local worst = 0
    for _, f in ipairs(fams) do
        local xs, ys = {}, {}
        for _, n in ipairs({ 1000, 2000, 4000, 8000 }) do
            local s, reps, t = f(n), 1, 0
            repeat
                local t0 = os.clock()
                for _ = 1, reps do fn(s) end
                t = os.clock() - t0
                reps = reps * 4
            until t > 0.01 or reps > 4 ^ 7
            t = t / (reps / 4)
            if t > 1e-6 then xs[#xs + 1] = math.log(n); ys[#ys + 1] = math.log(t) end
        end
        if #xs >= 3 then
            local mx, my = 0, 0
            for i = 1, #xs do mx, my = mx + xs[i], my + ys[i] end
            mx, my = mx / #xs, my / #xs
            local num, den = 0, 0
            for i = 1, #xs do num = num + (xs[i] - mx) * (ys[i] - my); den = den + (xs[i] - mx) ^ 2 end
            local e = num / den
            if e > worst then worst = e end
        end
    end
    return worst
end

-- ── THE DIFFERENTIAL CHECK ────────────────────────────────────────────────────────
local CORPUS
local function corpus()
    if CORPUS then return CORPUS end
    -- every class the patterns distinguish: %s is space, \t \n \v \f \r; a byte above 127 is %S
    local alpha = { ' ', '\t', '\n', '\r', '\v', '\f', 'x', '.', '%', '\200' }
    local out, cur = { '' }, { '' }
    for _ = 1, 5 do
        local nxt = {}
        for _, p in ipairs(cur) do
            for _, a in ipairs(alpha) do nxt[#nxt + 1] = p .. a end
        end
        for _, s in ipairs(nxt) do out[#out + 1] = s end
        cur = nxt
    end
    -- random longer strings, a fixed seed so the check is reproducible
    local seed = 1057
    local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
    for _ = 1, 3000 do
        local len, t = 6 + rnd(60), {}
        for k = 1, len do t[k] = alpha[1 + rnd(#alpha)] end
        out[#out + 1] = table.concat(t)
    end
    CORPUS = out
    return out
end

--- @return boolean ok, string|nil the first input on which the two expressions differ
function M.verify(rule)
    if rule._verified ~= nil then return rule._verified, rule._witness end
    for _, s in ipairs(corpus()) do
        local a, b = rule.old(s), rule.new(s)
        if a ~= b then
            rule._verified, rule._witness = false, s
            return false, s
        end
    end
    rule._verified = true
    return true
end
M._corpus = corpus

-- ── SITES ─────────────────────────────────────────────────────────────────────────
local function unescape(text)
    local ok, P = pcall(require, 'cartograph.spec.lua_patterns')
    return ok and P.unescape and P.unescape(text) or text
end

local function text_of(src, node)
    return vim.treesitter.get_node_text(node, src)
end

-- a call's shape: { fn, recv_text, args = { string nodes... }, method = bool }
local function call_shape(node, src)
    if node:type() ~= 'function_call' then return nil end
    local name = node:field('name')[1]
    local args = node:field('arguments')[1]
    if not (name and args) then return nil end
    local list = {}
    for c in args:iter_children() do if c:named() then list[#list + 1] = c end end
    local nt = name:type()
    if nt == 'method_index_expression' then
        local m = name:field('method')[1]
        local t = name:field('table')[1]
        if not (m and t) then return nil end
        return { fn = text_of(src, m), recv = text_of(src, t), args = list, method = true }
    elseif nt == 'dot_index_expression' then
        local t, f = name:field('table')[1], name:field('field')[1]
        if not (t and f) or text_of(src, t) ~= 'string' then return nil end
        local recv = list[1] and text_of(src, list[1])
        local rest = {}
        for k = 2, #list do rest[#rest + 1] = list[k] end
        return { fn = text_of(src, f), recv = recv, args = rest, method = false, recv_node = list[1] }
    end
    return nil
end

-- the VALUE of a string literal node, or nil (long strings `[[...]]` carry no escapes)
local function literal(node, src)
    if not node or node:type() ~= 'string' then return nil end
    local raw = text_of(src, node)
    local q = raw:sub(1, 1)
    if q == '"' or q == "'" then return unescape(raw:sub(2, -2)) end
    local body = raw:match('^%[=*%[(.*)%]=*%]$')
    return body
end

--- every catalog site in one Lua source: { rule, range, old, new, premise? } and the declined ones
function M.sites(src)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not ok then return {}, { { reason = 'cannot parse' } } end
    local root = parser:parse()[1]:root()
    local srclines = vim.split(src, '\n', { plain = true })
    local found, declined = {}, {}
    local function visit(n)
        local sh = call_shape(n, src)
        if sh then
            for _, rule in ipairs(M.RULES) do
                if sh.fn == rule.fn and literal(sh.args[1], src) == rule.from
                    and (not rule.repl or literal(sh.args[2], src) == rule.repl)
                    and #sh.args == (rule.repl and 2 or 1) then
                    local sr, sc, er, ec = n:range()
                    local at = { start = { line = sr, char = sc }, ['end'] = { line = er, char = ec } }
                    local vok, witness = M.verify(rule)
                    local parent = n:parent()
                    local mark = srclines and require('cartograph.exprlint').suppressed_at(srclines, sr + 1, 'pattern-rewrite')
                    if mark then
                        declined[#declined + 1] = { line = sr + 1, rule = rule.id, reason = 'suppressed: ' .. mark }
                    elseif not vok then
                        declined[#declined + 1] = { line = sr + 1, rule = rule.id,
                            reason = ('the rewrite differs from the original on %q'):format(witness) }
                    elseif rule.single and not (parent and parent:type() == 'parenthesized_expression') then
                        declined[#declined + 1] = { line = sr + 1, rule = rule.id,
                            reason = 'gsub returns two values and this site is not parenthesized (a single-value position)' }
                    elseif rule.twice and not (sh.recv or ''):match('^[%a_][%w_]*[%w_%.%[%]\'"]*$') then
                        declined[#declined + 1] = { line = sr + 1, rule = rule.id,
                            reason = ('the rewrite evaluates the subject twice; `%s` is not a plain name or field (a call or expression would be duplicated)'):format(sh.recv or '?') }
                    else
                        -- the string.<fn>(s, p) form is rewritten in METHOD form on the same subject
                        local recv = sh.recv
                        local call = rule.expr:format(recv, recv)
                        local target, tat = n, at
                        if rule.single then -- replace the parentheses too: `(x:gsub(p, '%1'))` -> `(x:match(q) or '')`
                            target = parent
                            local pr, pc, per, pec = parent:range()
                            tat = { start = { line = pr, char = pc }, ['end'] = { line = per, char = pec } }
                        end
                        found[#found + 1] = { rule = rule.id, line = sr + 1, at = tat, old = text_of(src, target),
                            new = call,
                            premise = sh.method and ('`%s` is a string (the method is believed by name)'):format(recv) or nil,
                            why = rule.why }
                    end
                end
            end
        end
        for c in n:iter_children() do if c:named() then visit(c) end end
    end
    visit(root)
    table.sort(found, function(a, b) return a.line < b.line end)
    return found, declined
end

--- a txn PLAN rewriting every catalog site in one file (rel to the store root)
--- @return table? plan, string? why, string? code
function M.plan(store, rel)
    local node = { file = rel }
    local lines = store.content and store.content(node)
    if not lines then return nil, 'cannot read ' .. rel, 'unreadable' end
    local found, declined = M.sites(table.concat(lines, '\n'))
    if #found == 0 then return nil, 'no catalog site in ' .. rel, 'no-candidates' end
    local reps, moves = {}, {}
    for _, s in ipairs(found) do
        reps[#reps + 1] = { at = s.at, to = s.new, old = s.old }
        moves[#moves + 1] = { line = s.line, rule = s.rule, from = s.old, to = s.new, premise = s.premise }
    end
    local plan = txn.protocol({ verb = 'pattern-rewrite', guards = { 'parses', 'spans-unchanged' }, refspecs = {},
        touched = { rel }, generation = store.generation,
        stamps = { [rel] = txn.disk_stamp(store.data.root, rel) }, rel = rel,
        reps = reps, ins = {}, moves = moves, declined = declined },
        function(p)
            return function(r, before)
                if r ~= p.rel then return before end
                return txn.edit_file(before, {}, p.reps, {})
            end
        end)
    return plan
end

--- dry-run lines for the cockpit: the sites, their premises, the declined, and the diff
function M.report(store, rel)
    local plan, why = M.plan(store, rel)
    local out = { ('pattern-rewrite — %s   (verified by a differential check over %d inputs)'):format(rel, #corpus()), '' }
    if not plan then out[#out + 1] = why; return out end
    for _, m in ipairs(plan.moves) do
        out[#out + 1] = ('  %s:%d  [%s]  %s  ->  %s'):format(rel, m.line, m.rule, m.from, m.to)
        if m.premise then out[#out + 1] = '        premise: ' .. m.premise end
    end
    for _, d in ipairs(plan.declined or {}) do
        out[#out + 1] = ('  %s:%d  [%s] DECLINED: %s'):format(rel, d.line or 0, d.rule or '?', d.reason)
    end
    out[#out + 1] = ''
    local before, after, err = txn.dryrun(store, plan)
    if not before then out[#out + 1] = 'dry-run failed: ' .. tostring(err); return out end
    for _, l in ipairs(txn.difftext(before, after, plan.touched)) do out[#out + 1] = l end
    return out
end

return M
