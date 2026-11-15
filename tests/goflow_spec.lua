-- CART-1896: NO GO VARIABLE WAS EVER DEFINED. du's ASSIGN branch made an assignment's `left` def-position, but go's
-- left is an `expression_list` (go assigns lists: `a, b = b, a`) and def-position did not pass through it, so every
-- target fell to a USE: `a = a + b` was def={} use={a,b}. `:=`, `var`, `const`, `for … := range` and `i++` were not
-- writes at all. Reaching definitions saw no kill at any go assignment and a loop counter had no definition.
-- Measured on hugo: 23322 of 59034 du rows moved; python / lua (django-oscar, bnw, cartograph's own 140593 rows)
-- byte-identical. The expression IR then read what du now binds, so its side moved too (go spec `binders`).

local expr = require 'cartograph.expr'

local SRC = table.concat({
    'package m',
    'func f(a, b int, s *S, p []int, m map[int]int) int {',
    '\ta = a + b',              -- 3
    '\ta += b',                 -- 4
    '\tx, y := a, b',           -- 5
    '\tx, y = y, x',            -- 6
    '\ts.f = a',                -- 7   a FIELD target: the receiver is read, as lua's `s.f = a`
    '\tp[x] = b',               -- 8
    '\tvar t = 5',              -- 9
    '\tconst c = 2',            -- 10
    '\tfor i := 0; i < t; i++ {', -- 11
    '\t\tt = t + i',            -- 12
    '\t}',
    '\tfor k, w := range m {',  -- 14
    '\t\tt += k + w + c',       -- 15
    '\t}',
    '\ty++',                    -- 17
    '\treturn t + y',           -- 18
    '}', '' }, '\n')

local function rows()
    local e = assert(expr.of_text(SRC, 'go'))
    local out = {}
    for _, s in ipairs(e.fl.stmts) do
        local function j(t) local c = vim.deepcopy(t or {}); table.sort(c); return table.concat(c, ',') end
        out[#out + 1] = ('%d %s def={%s} use={%s} rmw={%s}'):format(s.l, s.t, j(s.def), j(s.use), j(s.rmw))
    end
    return out, e
end

test('go flow: assignment, :=, var / const, range and ++ DEFINE their targets (CART-1896)', function ()
    if not parser_available('go') then skip 'no go parser' end
    local got = rows()
    local want = {
        '3 assignment_statement def={a} use={b} rmw={a}',
        '4 assignment_statement def={a} use={b} rmw={a}',
        '5 short_var_declaration def={x,y} use={a,b} rmw={}',
        '6 assignment_statement def={x,y} use={} rmw={x,y}',
        '7 assignment_statement def={} use={a,s} rmw={}',
        '8 assignment_statement def={} use={b,p,x} rmw={}',
        '9 var_declaration def={t} use={} rmw={}',
        '10 const_declaration def={c} use={} rmw={}',
        '11 for_statement def={i} use={t} rmw={i}',
        '11 for_clause def={i} use={t} rmw={i}',
        '12 assignment_statement def={t} use={i} rmw={t}',
        '14 for_statement def={k,w} use={m} rmw={}',
        '14 range_clause def={k,w} use={m} rmw={}',
        '15 assignment_statement def={t} use={c,k,w} rmw={t}',
        '17 inc_statement def={y} use={} rmw={y}',
        '18 return_statement def={} use={t,y} rmw={}',
    }
    eq(want, got)
end)

test('go flow: the expression IR reads exactly what du reads on every one of those rows — the gate is silent (CART-1896)', function ()
    if not parser_available('go') then skip 'no go parser' end
    local _, e = rows()
    local bad = {}
    for _, d in ipairs(expr.gate(e.fl, 'go')) do
        bad[#bad + 1] = ('L%d missing={%s} extra={%s}'):format(d.line, table.concat(d.missing, ','), table.concat(d.extra, ','))
    end
    eq({}, bad)
end)

test('go flow: a MULTI-target `:=` in an if initializer writes both names — the IR does not read them (CART-1896)', function ()
    if not parser_available('go') then skip 'no go parser' end
    local src = 'package m\nfunc g(v interface{}) string {\n\tif str, ok := v.(string); ok {\n\t\treturn str\n\t}\n\treturn ""\n}\n'
    local e = assert(expr.of_text(src, 'go'))
    local head = e.fl.stmts[1]
    eq('if_statement', head.t)
    local d = vim.deepcopy(head.def); table.sort(d)
    eq({ 'ok', 'str' }, d, 'the initializer defines both')
    local bad = {}
    for _, g in ipairs(expr.gate(e.fl, 'go')) do
        bad[#bad + 1] = ('L%d missing={%s} extra={%s}'):format(g.line, table.concat(g.missing, ','), table.concat(g.extra, ','))
    end
    eq({}, bad, 'the IR reads v and ok, never str')
end)

