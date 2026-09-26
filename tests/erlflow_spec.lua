-- ERLANG FLOW (CART-0957): a clause head is a pattern, a match binds its pattern, a case/receive/if arm is one
-- of several alternatives, a bound name in a pattern is a match test (a use), and a function of several
-- clauses is ONE record whose arms are the clauses. Before this, a whole `case` was one opaque row, the IQ
-- handlers' params were {} on 11 of 11, and expr.of returned nil for every multi-clause function.

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

local function rows_of(src)
    local eo = require('cartograph.expr').of_text(src, 'erlang')
    assert(eo, 'of_text returned nil')
    return eo.fl
end

local function row(fl, pred)
    for i, s in ipairs(fl.stmts) do if pred(s) then return s, i end end
end

local function has(list, x) for _, v in ipairs(list or {}) do if v == x then return true end end return false end

-- one extraction + ingest over a temp module
local function extract(content)
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.erl', 'w')); fd:write(content); fd:close()
    local data = ts.extract(root)
    store.ingest(data)
    -- the directory stays until the process exits: expr.of re-reads the file through the store
    local by = {}
    for _, n in ipairs(data.nodes) do if n.kind == 'function' then by[n.name] = n end end
    return by, store
end

test('erlflow: a clause head binds every name in its pattern, at any depth', function ()
    need()
    local fl = rows_of('f(#iq{type = get, to = To} = IQ, {ok, [X | _]}) -> {To, IQ, X}.\n')
    eq({ 'To', 'IQ', 'X' }, fl.params)
end)

test('erlflow: a match binds its pattern and reads its value; a bound name in a pattern is a USE', function ()
    need()
    local fl = rows_of('f(X) ->\n    {ok, Y} = g(X),\n    {ok, X} = h(Y),\n    Y.\n')
    local r1 = fl.stmts[1]
    eq({ 'Y' }, r1.def); ok(has(r1.use, 'X'), 'the value side reads X')
    local r2 = fl.stmts[2]
    eq({}, r2.def, 'X is already bound: the second match binds nothing')
    ok(has(r2.use, 'X') and has(r2.use, 'Y'), 'and reads both: X is a match test')
end)

test('erlflow: the wildcard binds nothing and reads nothing', function ()
    need()
    local fl = rows_of('f(A) ->\n    {_, B} = A,\n    B.\n')
    ok(not has(fl.stmts[1].def, '_') and not has(fl.stmts[1].use, '_'))
    eq({ 'B' }, fl.stmts[1].def)
end)

test('erlflow: a binary size and a map key inside a pattern are READ, not bound', function ()
    need()
    local fl = rows_of('f(Bin, Len, K) ->\n    <<Int:Len/signed-unit:8>> = Bin,\n    #{K := V} = Bin,\n    {Int, V}.\n')
    eq({ 'Int' }, fl.stmts[1].def); ok(has(fl.stmts[1].use, 'Len'), 'Len is the size: a read')
    eq({ 'V' }, fl.stmts[2].def); ok(has(fl.stmts[2].use, 'K'), 'K is the key: a read')
    -- du also gets there through single_assignment (a size/key must be bound); the IR has only the reads rule
    eq({}, require('cartograph.expr').gate(fl, 'erlang'), 'the expression IR reads the size and the key too')
end)

test('erlflow: case arms are rows under the head, each an ALTERNATIVE (head -> every arm, no arm -> arm)', function ()
    need()
    local src = 'f(X) ->\n    case X of\n        {a, Z} when Z > 0 -> g(Z);\n        X -> k(X);\n        _ -> none\n    end.\n'
    local fl = rows_of(src)
    local head, hi = row(fl, function (s) return s.t == 'case_expr' end)
    ok(head, 'the case is a control row'); eq({ 'X' }, head.use, 'the head reads only its subject')
    local arms = {}
    for i, s in ipairs(fl.stmts) do if s.parent == hi and s.pol == 'arm' then arms[#arms + 1] = i end end
    eq(3, #arms, 'three arm rows')
    eq({ 'Z' }, fl.stmts[arms[1]].def, 'arm 1 binds Z')
    eq({}, fl.stmts[arms[2]].def, 'arm 2 names the bound X: a match, not a binding')
    ok(has(fl.stmts[arms[2]].use, 'X'))
    local succ = require('cartograph.flow').successors(fl).succ
    table.sort(succ[hi])
    eq(arms, succ[hi], 'the head reaches every arm and nothing else')
    for _, a in ipairs(arms) do
        for _, b in ipairs(arms) do ok(not has(succ[a], b), 'no arm falls into another') end
    end
end)

test('erlflow: each arm is its own scope — a name bound in arm 1 is bound AGAIN in arm 2', function ()
    need()
    local fl = rows_of('f(X) ->\n    case X of\n        {a, Y} -> Y;\n        {b, Y} -> Y\n    end.\n')
    local defs = {}
    for _, s in ipairs(fl.stmts) do if s.pol == 'arm' then defs[#defs + 1] = s.def end end
    eq({ { 'Y' }, { 'Y' } }, defs)
end)

test('erlflow: a function of several clauses is ONE record, its clauses the arms (expr.of and extraction agree)', function ()
    need()
    local by, store = extract('-module(m).\nf(0) -> 1;\nf(N) when N > 0 -> N * f(N - 1).\ng(A) -> A.\n')
    local eo = require('cartograph.expr').of(store, by.f.id)
    ok(eo, 'expr.of answers a merged equation')
    eq(2, eo.clauses)
    local st = eo.fl.stmts
    eq('clauses', st[1].kind)
    local arms = {}
    for i, s in ipairs(st) do if s.parent == 1 and s.pol == 'arm' then arms[#arms + 1] = i end end
    eq(2, #arms)
    eq({}, st[arms[1]].def); eq({ 'N' }, st[arms[2]].def, 'the second head binds N')
    local guard = row(eo.fl, function (s) return s.t == 'guard' end)
    ok(guard and has(guard.use, 'N'), 'the guard is a row that reads N')
    eq({ 'N' }, eo.fl.params, 'params: the union of the heads')
    -- the graph's own flow (extraction) is stitched the same way, not the first clause alone
    local rec = require('cartograph.flow').record(by.f)
    eq(#st, #rec.stmts, 'extraction covers every clause')
    eq('clauses', rec.stmts[1].kind)
    -- a single-clause function is untouched: no head row
    local g = require('cartograph.flow').record(by.g)
    ok(g.stmts[1].kind ~= 'clauses')
end)

test('erlflow: a head is a READ SET — each bound name with its path, each constant the input must equal', function ()
    need()
    local by, store = extract('-module(m).\nh(#iq{type = get, sub_els = [#disco_info{node = Node}]} = IQ) -> {Node, IQ};\nh(#iq{type = set}) -> no.\n')
    local eo = require('cartograph.expr').of(store, by.h.id)
    local function show(f)
        local p = {}
        for _, s in ipairs(f.path) do
            p[#p + 1] = s.rec and ('#' .. s.rec .. '.' .. s.field) or s.elem and ('[' .. s.elem .. ']') or '?'
        end
        return (f.name and ('bind ' .. f.name) or ('const ' .. f.value)) .. ' ' .. table.concat(p, ' ')
    end
    local got = {}
    for _, f in ipairs(eo.heads[1].facts) do got[#got + 1] = show(f) end
    eq({ 'const get #iq.type', 'bind Node #iq.sub_els [1] #disco_info.node', 'bind IQ ' }, got)
    eq('const set #iq.type', show(eo.heads[2].facts[1]))
end)

test('erlflow: the expression IR reads `X#rec.f` as a field with its record, and a nested fun head as bound', function ()
    need()
    local expr = require 'cartograph.expr'
    local fl = rows_of('f(IQ) ->\n    L = IQ#iq.lang,\n    F = fun({_N, C}) -> C end,\n    {_, D} = F(L),\n    R = try F(D) catch _:_ -> none end,\n    {L, F, D, R}.\n')
    local fld
    expr.walk(fl.stmts[1].expr.rhs[1], function (x) if x.k == 'field' then fld = x end end)
    ok(fld, 'a field node'); eq('lang', fld.n); eq('iq', fld.rec)
    local reads = expr.reads(fl.stmts[2].expr)
    ok(not has(reads, '_N'), 'a fun head binds: the IR does not read _N (C is read by the fun body, on both sides)')
    eq({}, expr.gate(fl, 'erlang'), 'and the self-gate agrees with du on every row')
end)

test('erlang: mentions are off BY DECLARATION (an explicit empty set), not by the grammar lacking `identifier`', function ()
    local s = require('cartograph.providers.treesitter').spec.erlang
    ok(type(s.mention_types) == 'table', 'mention_types is a table, so `or { identifier = true }` never applies')
    eq(nil, next(s.mention_types), 'and it names no node type: atoms are not mentions (CART-0845)')
end)

test('erlflow: a head path says a list is closed and how long, and a field-less record pattern is a fact of its own', function ()
    need()
    local s = require('cartograph.providers.treesitter').spec.erlang
    local src = 'f(#iq{sub_els = [#disco_info{}]}, [A | _], [B, C]) -> ok.\n'
    local root = vim.treesitter.get_string_parser(src, 'erlang'):parse()[1]:root()
    local args = root:named_child(0):named_child(0):field('args')[1]
    local per = {}
    for a in args:iter_children() do if a:named() then per[#per + 1] = s.pattern.paths(a, src) end end
    local r = per[1][1]
    eq('disco_info', r.record, '`#disco_info{}` still says a disco_info sits there')
    eq({ elem = 1, len = 1, closed = true }, r.path[2], '`[X]` is exactly one element')
    eq({ head = true }, per[2][1].path[1], 'a cons is head/tail, not an element')
    eq({ elem = 2, len = 2, closed = true }, per[3][2].path[1])
end)

test('erlflow: the coarse df of a multi-clause function has every clause body\'s statements, not one head row', function ()
    need()
    local by = extract('-module(m).\nf(0) -> a(), b();\nf(N) -> c(N), d(N), e(N).\n')
    local df = require 'cartograph.df'
    eq(5, df.count(by.f), 'two + three statements: the clauses head and its arms are transparent')
end)
