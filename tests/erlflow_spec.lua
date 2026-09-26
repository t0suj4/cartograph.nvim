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

-- ── A `fun` IS A SCOPE OF ITS OWN (CART-1106) ─────────────────────────────────────────────────────────────
-- Before, a fun was folded into the row carrying it: its head names were DEFS of that row, its body's bindings
-- leaked into what came after (a later real binding read as a match test), and a match test inside it against
-- an outer name was invisible to the IR. ejabberd/src's self-gate: 138 rows, 33 after, every one a match test.

test('erlflow/fun: a fun gets rows of its own — its head binds in its ARM, not in the row carrying it', function ()
    need()
    local fl = rows_of('f(L) ->\n    lists:foreach(fun({_Id, Pid, _T}) -> s(Pid) end, L).\n')
    local carry = fl.stmts[1]
    eq({}, carry.def, 'the call row binds nothing')
    local head = row(fl, function (s) return s.t == 'anonymous_fun' end)
    ok(head, 'the fun is a row')
    local arm = row(fl, function (s) return s.t == 'fun_clause' end)
    ok(arm and arm.pol == 'arm', 'each clause is an arm')
    eq({ '_Id', 'Pid', '_T' }, arm.def)
    local body = row(fl, function (s) return s.parent and fl.stmts[s.parent] == arm end)
    ok(body and has(body.use, 'Pid'), 'the body reads Pid in the fun scope')
end)

test('erlflow/fun: a fun head SHADOWS an outer name — it binds fresh, it is not a match test', function ()
    need()
    local fl = rows_of('f(X, L) ->\n    lists:map(fun(X) -> X + 1 end, L).\n')
    local arm = row(fl, function (s) return s.t == 'fun_clause' end)
    eq({ 'X' }, arm.def); ok(not has(arm.use, 'X'), 'not a use of the outer X')
    eq(nil, arm.match)
end)

test('erlflow/fun: nothing a fun binds is visible after it', function ()
    need()
    local fl = rows_of('f(L) ->\n    lists:foreach(fun(E) -> Y = E, Y end, L),\n    Y = 1,\n    Y.\n')
    local after = row(fl, function (s) return s.l == 3 end)
    eq({ 'Y' }, after.def, 'Y = 1 binds: the fun\'s Y never left the fun')
    eq(nil, after.match)
end)

test('erlflow/fun: a fun sees the names bound BEFORE its row, not the row\'s own binding', function ()
    need()
    -- erlang matches after evaluating the value: the inner Set is a fresh local (ejabberd_auth.erl:559)
    local fl = rows_of('f(P) ->\n    Set = lists:foldl(fun(S, R) -> Set = g(S), [Set | R] end, [], P),\n    Set.\n')
    eq({ 'Set' }, fl.stmts[1].def)
    local inner = row(fl, function (s) return s.t == 'match_expr' and s.parent and s.parent > 1 end)
    eq({ 'Set' }, inner.def, 'a fresh binding inside the fun')
    eq(nil, inner.match)
end)

test('erlflow/fun: a pattern inside a fun naming an OUTER bound variable is a match test, a use', function ()
    need()
    local fl = rows_of('host_down(Host) ->\n    lists:foreach(fun(P) -> case r(P) of Host -> ok; _ -> no end end, l()).\n')
    local arm = row(fl, function (s) return s.t == 'cr_clause' end)
    eq({}, arm.def); ok(has(arm.use, 'Host'), 'Host is matched, not rebound')
    eq({ 'Host' }, arm.match)
end)

test('erlflow: a case in a case SUBJECT keeps its arms on the head row (du and the IR agree)', function ()
    need()
    local E = require 'cartograph.expr'
    local eo = E.of_text('f(Tlv) ->\n    case (case Tlv of [C] -> C; _ -> Tlv end) of\n        {1, V} -> V\n    end.\n', 'erlang')
    local head = eo.fl.stmts[1]
    eq({ 'C' }, head.def); ok(has(head.use, 'Tlv'))
    eq({}, E.gate(eo.fl, 'erlang'))
end)

test('erlflow/fun: the self-gate agrees on every fun shape; a top-level match test is named `match`', function ()
    need()
    local E = require 'cartograph.expr'
    for _, src in ipairs({
        'f(P) ->\n    Set = lists:foldl(fun({S, U}, R) -> Set = g(S), [Set | R] end, [], P),\n    Set.\n',
        'h(Host) ->\n    lists:foreach(fun(#s2s{pid = P}) -> case r(P) of Host -> ok; _ -> no end end, l()).\n',
        'g() ->\n    case lists:filter(fun(Host) -> ok(Host) end, a()) of\n        [] -> ok\n    end.\n',
    }) do
        local eo = E.of_text(src, 'erlang')
        eq({}, E.gate(eo.fl, 'erlang'), src)
    end
    local eo = E.of_text('f(F) ->\n    {ok, Mod, Bin} = c(F),\n    {module, Mod} = l(Bin).\n', 'erlang')
    local bad = E.gate(eo.fl, 'erlang')
    eq(1, #bad); eq({ 'Mod' }, bad[1].missing); eq({ 'Mod' }, bad[1].match)
end)

test('erlflow/fun: the CFG runs a fun 0..n times, ONE clause per run (head -> each arm, no arm -> arm)', function ()
    need()
    local flow = require 'cartograph.flow'
    local fl = rows_of('f(L) ->\n    lists:map(fun(0) -> a; (N) -> N end, L),\n    done.\n')
    local S = flow.successors(fl).succ
    local h = select(2, row(fl, function (s) return s.t == 'anonymous_fun' end))
    local arms = {}
    for i, s in ipairs(fl.stmts) do if s.parent == h and s.pol == 'arm' then arms[#arms + 1] = i end end
    eq(2, #arms)
    local function edge(a, b) for _, x in ipairs(S[a] or {}) do if x == b then return true end end return false end
    ok(edge(h, arms[1]) and edge(h, arms[2]), 'the head reaches each arm')
    ok(not edge(arms[1], arms[2]), 'arm 1 does not fall into arm 2')
    local nxt = select(2, row(fl, function (s) return s.l == 3 end))
    ok(edge(h, nxt), 'zero trips: the head skips to the next statement')
    local b2 = select(2, row(fl, function (s) return s.parent == arms[2] end))
    ok(edge(b2, h), 'a clause body returns to the head (another call)')
end)

test('erlflow/fun: the STORED flow runs a fun 0..n times too, in a multi-clause function as well', function ()
    need()
    -- the stitched record (append_clause) is stored without its class table; flow.record must re-attach the spec's
    -- preloop, or the fun head falls back to the arm branch: exactly one run, no zero-trip, no back edge
    local by = extract('-module(m).\ng(0, L) -> lists:map(fun(Y) -> Y end, L), done;\ng(N, _) -> N.\n')
    local flow = require 'cartograph.flow'
    local rec = flow.record(by.g)
    local S = flow.successors(rec).succ
    local function edge(a, b) for _, x in ipairs(S[a] or {}) do if x == b then return true end end return false end
    local h, arm, body, nxt
    for i, s in ipairs(rec.stmts) do
        if s.t == 'anonymous_fun' then h = i
        elseif s.t == 'fun_clause' then arm = i
        elseif h and s.parent == arm then body = i
        elseif h and s.t == 'atom' then nxt = i end
    end
    ok(h and arm and body and nxt, 'the fun, its arm, its body and the statement after it are rows')
    ok(edge(h, arm), 'head -> arm'); ok(edge(body, h), 'body -> head (another run)')
    ok(edge(h, nxt), 'head -> the next statement (zero runs)')
end)

test('erlflow/fun: extraction and expr.of give a fun the same rows', function ()
    need()
    local by, store = extract('-module(m).\nf(L) -> lists:map(fun(X) -> X + 1 end, L).\n')
    local eo = require('cartograph.expr').of(store, by.f.id)
    local rec = require('cartograph.flow').record(by.f)
    eq(#eo.fl.stmts, #rec.stmts)
    local found = false
    for _, s in ipairs(rec.stmts) do if s.t == 'fun_clause' then found = true; eq({ 'X' }, s.def) end end
    ok(found, 'the stored flow has the fun clause as a row')
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

test('erlflow: a binary of plain string segments in a head is a constant; one with a size is opaque', function ()
    need()
    local s = require('cartograph.providers.treesitter').spec.erlang
    local src = 'f(#disco_info{node = <<"urn:x">>}, <<"a", "b">>, <<X:8>>) -> X.\n'
    local root = vim.treesitter.get_string_parser(src, 'erlang'):parse()[1]:root()
    local args = root:named_child(0):named_child(0):field('args')[1]
    local per = {}
    for a in args:iter_children() do if a:named() then per[#per + 1] = s.pattern.paths(a, src) end end
    eq('urn:x', per[1][1].value); eq('binary', per[1][1].ty)
    eq('ab', per[2][1].value)
    eq(0, #per[3], 'a sized segment claims nothing')
end)

test('erlflow: a record built in a value position is a TABLE with its record, an update reads its base', function ()
    need()
    local expr = require 'cartograph.expr'
    local fl = rows_of('f(IQ, Node) ->\n    R = IQ#iq{type = result},\n    xmpp:make_iq_result(R, #disco_info{node = Node}).\n')
    local tbl = {}
    for _, st in ipairs(fl.stmts) do
        expr.walk(st.expr.rhs[1], function (x) if x.k == 'table' and x.rec then tbl[#tbl + 1] = x end end)
    end
    eq(2, #tbl, 'the update and the construction')
    eq('iq', tbl[1].rec); ok(tbl[1].base and tbl[1].base.n == 'IQ', 'the update carries its base')
    eq('disco_info', tbl[2].rec)
    eq({}, expr.gate(fl, 'erlang'), 'the IR still reads what du reads (IQ, R, Node)')
end)
