-- ERLANG VALUES AS TERMS (lua/cartograph/erlterms.lua, CART-1112): what a function BUILDS, in the decoded-record
-- encoding the wire merge unifies on — the encoding (step 1), patterns as the matched input (5), case/if as a join
-- (2), calls as the callee's clauses against the argument terms (3), parameters as named holes (4).

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

local RECS = {
    iq = { 'id', 'type', 'lang', 'from', 'to', 'sub_els', 'meta' },
    disco_info = { 'node', 'identities', 'features', 'xdata' },
}
local DEFAULTS = {
    iq = { id = '<<>>', lang = '<<>>', sub_els = '[]', meta = '#{}' },
    disco_info = { node = '<<>>', identities = '[]', features = '[]', xdata = '[]' },
}
local CTX = { module = 'mod_t',
    record_fields = function (r) return RECS[r] end,
    defaults = function (r) return DEFAULTS[r] end }

-- the term of the LAST expression of the only clause in `src`
local function last_term(src, ctx)
    local ET = require 'cartograph.erlterms'
    local root = vim.treesitter.get_string_parser(src, 'erlang'):parse()[1]:root()
    local body = root:named_child(0):named_child(0):field('body')[1]
    local last
    for c in body:iter_children() do if c:named() then last = c end end
    local term, holes, S = ET.term(last, src, ctx or CTX)
    return require('cartograph.algebra').load().show(term), holes, ET.status(term), S, term
end

local function reasons(holes)
    local out = {}
    for _, w in pairs(holes) do out[#out + 1] = w end
    table.sort(out)
    return out
end

test('erlterms: a record literal takes its declared defaults for the fields it does not set', function ()
    need()
    local shown, _, st = last_term('f() -> #disco_info{node = <<"x">>, features = [<<"urn:a">>]}.\n')
    eq('(rec:disco_info "x" (nil) (cons "urn:a" (nil)) (nil))', shown)
    eq('complete', st)
end)

test('erlterms: a variable is its single-assignment binding; an update keeps the base; macros read the vocabulary', function ()
    need()
    local shown, holes = last_term(table.concat({
        'f() ->',
        '    D = #disco_info{node = ?NS_DISCO_INFO},',
        '    I = #iq{type = result, sub_els = [D]},',
        '    I#iq{id = ?MODULE}.', '' }, '\n'))
    eq('(rec:iq "mod_t" "result" "" "undefined" "undefined" (cons (rec:disco_info "http://jabber.org/protocol/disco#info" (nil) (nil) (nil)) (nil)) (map))', shown)
    eq({}, reasons(holes))
end)

test('erlterms: a parameter is a NAMED hole; a pattern variable is the part of the parameter it names', function ()
    need()
    local shown, holes, st = last_term(table.concat({
        'f(P, #iq{lang = L}) ->',
        '    #disco_info{node = P, identities = L, features = g()}.', '' }, '\n'))
    eq('partial', st)
    local joined = table.concat(reasons(holes), ' | ')
    ok(joined:find('parameter 1 of f/2', 1, true), 'P: ' .. joined)
    ok(joined:find('L: part of parameter 2 of f/2', 1, true), 'L')
    ok(joined:find('no program', 1, true), 'g() without a program to summarize it')
    ok(shown:find('^%(rec:disco_info'), 'the structure is still known: ' .. shown)
end)

test('erlterms: a head alias is the PATTERN, and a field it does not mention is a wildcard, not its default', function ()
    need()
    local ET = require 'cartograph.erlterms'
    local src = 'f(#iq{type = get, id = I} = IQ) -> IQ#iq{type = result, to = I}.\n'
    local shown, holes = last_term(src)
    -- id is the pattern's I (so `to` is the same hole); lang, from, sub_els, meta are the request's unstated parts
    local lang_hole = shown:match('^%(rec:iq (%?%S+) "result" (%?%S+)')
    ok(lang_hole, 'id stays a hole and lang is a hole, not the default "": ' .. shown)
    local id_h, to_h = shown:match('^%(rec:iq %?(%S+) "result" %?%S+ %?%S+ %?(%S+) ')
    eq(id_h, to_h, 'to = I is the very hole the pattern bound to id: ' .. shown)
    local n = 0
    for _, w in pairs(holes) do if w:find('does not mention', 1, true) then n = n + 1 end end
    eq(4, n, 'lang, from, sub_els and meta')
    ET.OFF = { wildcards = true }
    local shown2 = last_term(src)
    ET.OFF = {}
    ok(shown2:find('^%(rec:iq %?%S+ "result" ""'), 'the guard observes: defaults would claim lang = "": ' .. shown2)
end)

test('erlterms: a case is the join of the arms its subject may take, first match wins, a guard only maybe', function ()
    need()
    local ET = require 'cartograph.erlterms'
    local function body(subject, arm1)
        return table.concat({ 'f(Q) ->', '    X = ' .. subject .. ',',
            '    case X of ' .. arm1 .. ' -> #disco_info{node = V}; _ -> #disco_info{node = <<"e">>} end.', '' }, '\n')
    end
    -- a known subject takes the first arm alone
    eq('(rec:disco_info "n" (nil) (nil) (nil))', (last_term(body('{ok, <<"n">>}', '{ok, V}'))))
    -- an unknown subject may take either: the join keeps what the arms share
    local shown, holes = last_term(body('Q', '{ok, V}'))
    ok(shown:find('^%(rec:disco_info %?%S+ %(nil%) %(nil%) %(nil%)%)$'), shown)
    ok(table.concat(reasons(holes), '|'):find('a join', 1, true), 'the differing field says it is a join')
    -- a guard makes the first arm only maybe: both arms join
    local g = last_term(body('{ok, <<"n">>}', '{ok, V} when V /= <<"x">>'))
    ok(g:find('^%(rec:disco_info %?'), 'a guarded arm does not end the match: ' .. g)
    ET.OFF = { guards = true }
    local g2 = last_term(body('{ok, <<"n">>}', '{ok, V} when V /= <<"x">>'))
    ET.OFF = {}
    eq('(rec:disco_info "n" (nil) (nil) (nil))', g2, 'the guard observes')
    -- literal kinds: the atom `get` does not match the binary <<"get">>, though the wire sees both as "get"
    local k = last_term('f() -> case <<"get">> of get -> #disco_info{node = <<"atom">>}; _ -> #disco_info{node = <<"bin">>} end.\n')
    eq('(rec:disco_info "bin" (nil) (nil) (nil))', k)
    ET.OFF = { kinds = true }
    local k2 = last_term('f() -> case <<"get">> of get -> #disco_info{node = <<"atom">>}; _ -> #disco_info{node = <<"bin">>} end.\n')
    ET.OFF = {}
    eq('(rec:disco_info "atom" (nil) (nil) (nil))', k2, 'the kind check observes')
end)

-- a two-module program in a temp dir; records come from RECS for every module
local function program(files)
    local ET = require 'cartograph.erlterms'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    for name, body in pairs(files) do
        local fd = assert(io.open(dir .. '/' .. name .. '.erl', 'w')); fd:write(body); fd:close()
    end
    local P
    P = ET.program { dirs = { dir }, ctx_of = function (src)
        return { module = src:match('%-module%(%s*([%w_]+)'), program = P,
            record_fields = CTX.record_fields, defaults = CTX.defaults }
    end }
    return P, dir
end

test('erlterms: a call is its callee\'s clauses against the argument terms — raises dropped, records are tuples', function ()
    need()
    local ET = require 'cartograph.erlterms'
    local P = program {
        lib = table.concat({
            '-module(lib).',
            'result(#iq{type = get} = IQ) -> IQ#iq{type = result};',
            'result(#iq{type = set} = IQ) -> IQ#iq{type = result};',
            'result(_) -> erlang:error(badarg).',
            'codec() -> lib_codec.',
            'dyn(X) -> Mod = codec(), Mod:build(X).',
            'loop(N) -> loop(N).',
            'ping(X) -> pong(X).', 'pong(X) -> ping(X).', '' }, '\n'),
        lib_codec = '-module(lib_codec).\nbuild(Id) -> {iq, Id, set, <<>>, undefined, undefined, [], #{}}.\n',
        user = table.concat({
            '-module(user).',
            'a(#iq{type = get} = Q) -> lib:result(Q).',
            'b(Q) -> lib:result(Q).',
            'c() -> lib:dyn(<<"x">>).',
            'd() -> lib:loop(1).',
            'e() -> lib:ping(1).', '' }, '\n'),
    }
    local m = P:module('user')
    local A = require('cartograph.algebra').load()
    local function at(fn, off)
        local cl = m.fns[fn][1]
        local body = cl:field('body')[1]
        local last
        for c in body:iter_children() do if c:named() then last = c end end
        local t, holes, S = ET.term(last, m.src, m.ctx)
        ET.OFF = off or {}
        local t2 = off and ET.term(last, m.src, m.ctx)
        ET.OFF = {}
        return A.show(t), holes, S, t2 and A.show(t2)
    end
    -- the head says get: result's first clause is a definite match, type becomes result
    local a = at('a/1')
    ok(a:find('^%(rec:iq %?%S+ "result"'), a)
    -- an unknown argument: the two #iq clauses join (type = result in both), the raising clause is DROPPED
    local b, _, _, b_raise = at('b/1', { raises = true })
    ok(b:find('^%(rec:iq %?%S+ "result"'), 'the raise arm does not generalize the join: ' .. b)
    ok(not b_raise:find('^%(rec:iq'), 'the guard observes: kept, the raise arm makes it a bare hole: ' .. b_raise)
    -- the module is a value that evaluates to one atom: the call is static; the tuple {iq, …} IS #iq{…}
    local c, _, _, c_tuple = at('c/0', { rectuple = true })
    eq('(rec:iq "x" "set" "" "undefined" "undefined" (nil) (map))', c)
    ok(c_tuple:find('^%(tuple "iq"'), 'the record-tuple identity observes: ' .. c_tuple)
    local _, _, _, c_dyn = at('c/0', { dynmod = true })
    ok(c_dyn:find('^%?'), 'the module evaluation observes: ' .. c_dyn)
    -- a loop no clause ever leaves never returns
    local d, dh = at('d/0')
    ok(d:find('^%?'), d)
    ok(table.concat(reasons(dh), '|'):find('never returns', 1, true), table.concat(reasons(dh), '|'))
    -- MUTUAL recursion is not a loop: it stays a cut, and the cut is counted
    local e, eh, S = at('e/0')
    ok(e:find('^%?'), e)
    ok(table.concat(reasons(eh), '|'):find('recursive call to lib:ping/1', 1, true), table.concat(reasons(eh), '|'))
    ok(S.stats.recursive >= 1, 'the cut is counted')
end)

test('erlterms: arms of different kinds keep the SET of kinds the join cannot represent', function ()
    need()
    local _, holes, _, S, term = last_term('f(Q) -> case Q of a -> #iq{}; b -> #disco_info{} end.\n')
    eq('hole', term.k)
    eq({ 'rec:disco_info', 'rec:iq' }, S.kinds[term.h])
    ok(table.concat(reasons(holes), '|'):find('one of rec:disco_info | rec:iq', 1, true))
end)

test('erlterms: a record matches a tuple pattern; a join keeps a shared hole\'s reason; a fun body binds', function ()
    need()
    local ET = require 'cartograph.erlterms'
    local A = require('cartograph.algebra').load()
    -- #iq{} IS {iq, _, …}: generated code matches records as tuples
    eq('(rec:disco_info "t" (nil) (nil) (nil))', (last_term(table.concat({
        'f(#iq{} = Q) ->',
        '    case Q of {iq, _, _, _, _, _, _, _} -> #disco_info{node = <<"t">>}; _ -> #disco_info{node = <<"o">>} end.',
        '' }, '\n'))))
    -- the same hole on both sides of a join is not a difference: it keeps its own reason
    local _, holes = last_term('f(P, Q) -> case Q of a -> #disco_info{node = P}; b -> #disco_info{node = P, features = [x]} end.\n')
    local r = table.concat(reasons(holes), ' | ')
    ok(r:find('parameter 1 of f/2', 1, true), 'P survives the join: ' .. r)
    -- a variable bound inside a fun's own body (the send inside lists:foreach)
    local src = 'f() -> lists:foreach(fun(R) -> IQ = #disco_info{node = <<"f">>}, send(IQ) end, []).\n'
    local root = vim.treesitter.get_string_parser(src, 'erlang'):parse()[1]:root()
    local use
    local function walk(n)
        for c in n:iter_children() do
            if c:type() == 'var' and vim.treesitter.get_node_text(c, src) == 'IQ' then use = c end
            walk(c)
        end
    end
    walk(root)
    eq('(rec:disco_info "f" (nil) (nil) (nil))', A.show((ET.term(use, src, CTX))))
end)

test('erlterms: simple recursion is a LOOP — the state and the value iterated to a fixpoint', function ()
    need()
    local ET = require 'cartograph.erlterms'
    local A = require('cartograph.algebra').load()
    local P = program {
        loops = table.concat({
            '-module(loops).',
            -- an accumulator loop: the value is the base clause under the loop state
            'build(L) -> build(L, []).',
            'build([], Acc) -> #disco_info{node = <<"n">>, features = Acc};',
            'build([H | T], Acc) -> build(T, [H | Acc]).',
            -- a counter, the self-call as a case arm's value
            'wait(N) -> case N of 0 -> #disco_info{node = <<"done">>}; _ -> wait(N - 1) end.',
            -- a list builder (a map)
            'ids([]) -> [];',
            'ids([H | T]) -> [#disco_info{node = H} | ids(T)].', '' }, '\n'),
        user = table.concat({
            '-module(user).',
            'a(L) -> loops:build(L).',
            'b() -> loops:wait(3).',
            'c(L) -> loops:ids(L).',
            'k() -> loops:build([<<"urn:a">>]).',
            'm() -> loops:ids([<<"x">>, <<"y">>]).', '' }, '\n'),
    }
    local m = P:module('user')
    local function at(fn)
        local cl = m.fns[fn][1]
        local last
        for c in cl:field('body')[1]:iter_children() do if c:named() then last = c end end
        local t, holes, S = ET.term(last, m.src, m.ctx)
        return A.show(t), holes, S
    end
    local a, ah, S = at('a/1')
    ok(a:find('^%(rec:disco_info "n" %(nil%) %?%S+ %(nil%)%)$'), 'the base clause under the loop state: ' .. a)
    -- features is what the accumulator became: [] on the first pass, a loop variable after — the join of the two
    local found = false
    for _, w in pairs(S.reasons) do if w:find('loop variable of loops:build/2', 1, true) then found = true end end
    ok(found, 'the accumulator is a loop variable: ' .. a .. ' ' .. table.concat(reasons(ah), '|'))
    ok(S.stats.loops >= 1 and S.stats.iterations >= 2, 'the loop is counted')
    eq('(rec:disco_info "done" (nil) (nil) (nil))', (at('b/0')))
    local c, ch, S3 = at('c/1')
    ok(c:find('^%?'), 'a list builder joins nil and cons: ' .. c)
    ok(table.concat(reasons(ch), '|'):find('one of cons | nil', 1, true), table.concat(reasons(ch), '|'))
    eq(0, S3.stats.unconverged)
    -- a KNOWN spine folds exactly: the recursion is structural (the Tail of a known list)
    eq('(rec:disco_info "n" (nil) (cons "urn:a" (nil)) (nil))', (at('k/0')))
    eq('(cons (rec:disco_info "x" (nil) (nil) (nil)) (cons (rec:disco_info "y" (nil) (nil) (nil)) (nil)))', (at('m/0')))
    ET.OFF = { spine = true }
    local m2 = at('m/0')
    ET.OFF = {}
    ok(m2:find('^%?'), 'the spine fold observes: joined into the loop it is only one of cons | nil: ' .. m2)
    -- the guard observes: without the loop the self-call is a cut and nothing comes back
    ET.OFF = { loops = true }
    local a2 = at('a/1')
    local b2 = at('b/0')
    ET.OFF = {}
    ok(a2:find('^%?'), 'no loop model: ' .. a2)
    ok(b2:find('^%?'), 'no loop model: ' .. b2)
end)

test('erlterms: yes means CERTAIN — a bound variable or a repeated one in a pattern only makes it maybe', function ()
    need()
    local ET = require 'cartograph.erlterms'
    -- T is already bound (a parameter): `X` matching `T` is an equality nobody knows, not a definite match
    local src = 'f(T, X) -> case X of T -> #disco_info{node = <<"a">>}; _ -> #disco_info{node = <<"b">>} end.\n'
    local shown = last_term(src)
    ok(shown:find('^%(rec:disco_info %?'), 'both arms may run: ' .. shown)
    -- a repeated variable identifies two unknowns: also only maybe
    local rep = last_term('f(X, Y) -> case {X, Y} of {Z, Z} -> #disco_info{node = <<"a">>}; _ -> #disco_info{node = <<"b">>} end.\n')
    ok(rep:find('^%(rec:disco_info %?'), 'both arms may run: ' .. rep)
    ET.OFF = { own = true }
    local s2 = last_term(src)
    local rep2 = last_term('f(X, Y) -> case {X, Y} of {Z, Z} -> #disco_info{node = <<"a">>}; _ -> #disco_info{node = <<"b">>} end.\n')
    ET.OFF = {}
    eq('(rec:disco_info "a" (nil) (nil) (nil))', s2, 'the guard observes (bound variable)')
    eq('(rec:disco_info "a" (nil) (nil) (nil))', rep2, 'the guard observes (repeated variable)')
end)

test('erlterms: a fun is a value — closures apply with their clauses and captured variables; lists folds run from source', function ()
    need()
    local ET = require 'cartograph.erlterms'
    local A = require('cartograph.algebra').load()
    local P = program {
        -- the shape of OTP's own lists.erl: a guarded entry, a foldr helper, a tail foldl, and a BIF stub
        mylists = table.concat({
            '-module(mylists).',
            'map(F, List) when is_function(F, 1) -> case List of [Hd | Tail] -> [F(Hd) | map_1(F, Tail)]; [] -> [] end.',
            'map_1(F, [Hd | Tail]) -> [F(Hd) | map_1(F, Tail)];',
            'map_1(_F, []) -> [].',
            'foldl(F, Acc, [H | T]) -> foldl(F, F(H, Acc), T);',
            'foldl(_F, Acc, []) -> Acc.',
            'reverse(_, _) -> erlang:nif_error(undef).', '' }, '\n'),
        user = table.concat({
            '-module(user).',
            'item(N) -> #disco_info{node = N}.',
            -- a closure over a variable of its creator
            'a() -> Ns = <<"urn:x">>, mylists:map(fun(F) -> #disco_info{node = Ns, features = [F]} end, [<<"f1">>, <<"f2">>]).',
            -- a named local function as a fun, and a remote one
            'b() -> mylists:map(fun item/1, [<<"n1">>]).',
            'c() -> mylists:map(fun user:item/1, [<<"n2">>]).',
            -- a foldl whose accumulator is built by the fun
            'd() -> mylists:foldl(fun(X, Acc) -> [X | Acc] end, [], [<<"p">>, <<"q">>]).',
            -- apply/2 and apply/3
            'e() -> F = fun(X) -> #disco_info{node = X} end, apply(F, [<<"ap">>]).',
            'g() -> apply(user, item, [<<"ap3">>]).',
            -- a named fun sees itself
            'h() -> L = fun Loop([]) -> done; Loop([_ | T]) -> Loop(T) end, L([1, 2]).',
            -- a BIF whose source is a stub is not its body
            'k() -> mylists:reverse([1], []).',
            -- a closure made inside a call keeps that call's variables
            'mk(N) -> fun(X) -> #disco_info{node = N, features = [X]} end.',
            'n() -> F = user:mk(<<"cap">>), F(<<"x">>).',
            -- a fun applied to the wrong number of arguments matches no clause
            'w() -> F = fun(X) -> X end, F(1, 2).', '' }, '\n'),
    }
    local m = P:module('user')
    local function at(fn, off)
        ET.OFF = off or {}
        local cl = m.fns[fn][1]
        local last
        for c in cl:field('body')[1]:iter_children() do if c:named() then last = c end end
        local t, holes = ET.term(last, m.src, m.ctx)
        ET.OFF = {}
        return A.show(t), holes
    end
    eq('(cons (rec:disco_info "urn:x" (nil) (cons "f1" (nil)) (nil)) (cons (rec:disco_info "urn:x" (nil) (cons "f2" (nil)) (nil)) (nil)))', (at('a/0')))
    eq('(cons (rec:disco_info "n1" (nil) (nil) (nil)) (nil))', (at('b/0')))
    eq('(cons (rec:disco_info "n2" (nil) (nil) (nil)) (nil))', (at('c/0')))
    eq('(cons "q" (cons "p" (nil)))', (at('d/0')))
    eq('(rec:disco_info "ap" (nil) (nil) (nil))', (at('e/0')))
    eq('(rec:disco_info "ap3" (nil) (nil) (nil))', (at('g/0')))
    eq('"done"', (at('h/0')))
    local k, kh = at('k/0')
    ok(k:find('^%?'), k)
    ok(table.concat(reasons(kh), '|'):find('a BIF (its source is a nif_error stub)', 1, true), table.concat(reasons(kh), '|'))
    eq('(rec:disco_info "cap" (nil) (cons "x" (nil)) (nil))', (at('n/0')))
    local w, wh = at('w/0')
    ok(w:find('^%?') and table.concat(reasons(wh), '|'):find('no clause', 1, true), 'arity: ' .. w .. ' ' .. table.concat(reasons(wh), '|'))
    -- the guards observe
    local nf = at('a/0', { funs = true })
    ok(nf:find('^%(cons %?%S+ %(cons %?%S+ %(nil%)%)%)$'), 'without fun values the spine is known, the elements are not: ' .. nf)
    local ks = at('k/0', { stubs = true })
    local _, ksh = at('k/0', { stubs = true })
    ok(not table.concat(reasons(ksh), '|'):find('stub', 1, true), 'without the stub rule the body is evaluated: ' .. ks)
end)
