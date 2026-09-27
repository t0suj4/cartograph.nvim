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
    eq('(rec:disco_info "x" (list) (list "urn:a") (list))', shown)
    eq('complete', st)
end)

test('erlterms: a variable is its single-assignment binding; an update keeps the base; macros read the vocabulary', function ()
    need()
    local shown, holes = last_term(table.concat({
        'f() ->',
        '    D = #disco_info{node = ?NS_DISCO_INFO},',
        '    I = #iq{type = result, sub_els = [D]},',
        '    I#iq{id = ?MODULE}.', '' }, '\n'))
    eq('(rec:iq "mod_t" "result" "" "undefined" "undefined" (list (rec:disco_info "http://jabber.org/protocol/disco#info" (list) (list) (list))) (map))', shown)
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
    eq('(rec:disco_info "n" (list) (list) (list))', (last_term(body('{ok, <<"n">>}', '{ok, V}'))))
    -- an unknown subject may take either: the join keeps what the arms share
    local shown, holes = last_term(body('Q', '{ok, V}'))
    ok(shown:find('^%(rec:disco_info %?%S+ %(list%) %(list%) %(list%)%)$'), shown)
    ok(table.concat(reasons(holes), '|'):find('a join', 1, true), 'the differing field says it is a join')
    -- a guard over an UNKNOWN makes the first arm only maybe: both arms join
    local g = last_term(body('{ok, Q}', '{ok, V} when V /= <<"x">>'))
    ok(g:find('^%(rec:disco_info %?'), 'a guard nobody can decide does not end the match: ' .. g)
    ET.OFF = { guards = true }
    local g2 = last_term(body('{ok, Q}', '{ok, V} when V /= <<"x">>'))
    ET.OFF = {}
    ok(g2:find('^%(rec:disco_info %?'), 'the guard observes (reading it as yes takes the first arm alone): ' .. g2)
    -- a guard over KNOWN values is evaluated: true takes the arm (first match), false skips it
    eq('(rec:disco_info "n" (list) (list) (list))', (last_term(body('{ok, <<"n">>}', '{ok, V} when V /= <<"x">>'))))
    eq('(rec:disco_info "e" (list) (list) (list))', (last_term(body('{ok, <<"x">>}', '{ok, V} when V /= <<"x">>'))))
    -- and the operators: andalso short-circuits on false, a comparison of two knowns decides, one of an unknown does not
    eq('(rec:disco_info "e" (list) (list) (list))', (last_term(body('{ok, <<"x">>}', '{ok, V} when is_binary(V) andalso V == <<"y">>'))))
    -- short-circuits: a false left side of andalso decides whatever the right is, and so does a false right side
    eq('(rec:disco_info "e" (list) (list) (list))', (last_term(body('{ok, <<"x">>}', '{ok, V} when is_atom(V) andalso Q'))))
    eq('(rec:disco_info "e" (list) (list) (list))', (last_term(body('{ok, <<"x">>}', '{ok, V} when Q andalso V == <<"y">>'))))
    -- a type test decides on a known term (the spec's guard_kinds)
    eq('(rec:disco_info "e" (list) (list) (list))', (last_term(body('{ok, <<"x">>}', '{ok, V} when is_atom(V)'))))
    eq('(rec:disco_info "x" (list) (list) (list))', (last_term(body('{ok, <<"x">>}', '{ok, V} when is_binary(V)'))))
    ET.OFF = { guardeval = true }
    local g3 = last_term(body('{ok, <<"x">>}', '{ok, V} when V /= <<"x">>'))
    ET.OFF = {}
    ok(g3:find('^%(rec:disco_info %?'), 'the evaluation observes: without it a decidable guard is maybe: ' .. g3)
    -- literal kinds: the atom `get` does not match the binary <<"get">>, though the wire sees both as "get"
    local k = last_term('f() -> case <<"get">> of get -> #disco_info{node = <<"atom">>}; _ -> #disco_info{node = <<"bin">>} end.\n')
    eq('(rec:disco_info "bin" (list) (list) (list))', k)
    ET.OFF = { kinds = true }
    local k2 = last_term('f() -> case <<"get">> of get -> #disco_info{node = <<"atom">>}; _ -> #disco_info{node = <<"bin">>} end.\n')
    ET.OFF = {}
    eq('(rec:disco_info "atom" (list) (list) (list))', k2, 'the kind check observes')
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
            'ping(X) -> pong(X).', 'pong(X) -> ping(X).',
            'pick(X) when X == a -> #iq{id = <<"one">>};',
            'pick(_) -> #iq{id = <<"two">>}.', '' }, '\n'),
        lib_codec = '-module(lib_codec).\nbuild(Id) -> {iq, Id, set, <<>>, undefined, undefined, [], #{}}.\n',
        user = table.concat({
            '-module(user).',
            'a(#iq{type = get} = Q) -> lib:result(Q).',
            'b(Q) -> lib:result(Q).',
            'c() -> lib:dyn(<<"x">>).',
            'd() -> lib:loop(1).',
            'e() -> lib:ping(1).',
            'p() -> lib:pick(b).', '' }, '\n'),
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
    eq('(rec:iq "x" "set" "" "undefined" "undefined" (list) (map))', c)
    ok(c_tuple:find('^%(tuple "iq"'), 'the record-tuple identity observes: ' .. c_tuple)
    local _, _, _, c_dyn = at('c/0', { dynmod = true })
    ok(c_dyn:find('^%?'), 'the module evaluation observes: ' .. c_dyn)
    -- a function head whose guard is FALSE for the argument is skipped: pick(b) is the second clause alone
    eq('(rec:iq "two" "undefined" "" "undefined" "undefined" (list) (map))', (at('p/0')))
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
    eq('(rec:disco_info "t" (list) (list) (list))', (last_term(table.concat({
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
    eq('(rec:disco_info "f" (list) (list) (list))', A.show((ET.term(use, src, CTX))))
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
    -- features is the accumulator: a list whose length the loop does not know
    ok(a:find('^%(rec:disco_info "n" %(list%) %(list %?%S+%.%.%.%) %(list%)%)$'), 'the base clause under the loop state: ' .. a)
    -- features is the ACCUMULATOR, and the control flow says so without iterating: build/2 is a tail loop whose
    -- positions are dec (the list, unknown here) and prepend (Acc), so it runs ONE pass under its closed-form state
    ok(table.concat(reasons(ah), '|'):find('an accumulator of loops:build/2', 1, true), table.concat(reasons(ah), '|'))
    eq(1, S.stats.onepass, 'one pass')
    eq(1, S.stats.iterations, 'no iteration')
    -- the narrowing observes: without it the same term costs a fixpoint
    ET.OFF = { onepass = true, narrow = true }
    local a3, _, S4 = at('a/1')
    ET.OFF = {}
    ok(a3:find('^%(rec:disco_info "n" %(list%) %(list %?%S+%.%.%.%) %(list%)%)$'), 'the same shape by iteration: ' .. a3)
    ok(S4.stats.iterations >= 2, 'iterated: ' .. S4.stats.iterations)
    -- the carried classes, read off the clauses once
    local lm = P:module('loops')
    local C = ET.carried(lm, 'build/2', lm.fns['build/2'])
    eq({ 'dec', 'prepend' }, C.class)
    eq(true, C.tail)
    eq(false, ET.carried(lm, 'ids/1', lm.fns['ids/1']).tail, 'a list builder is body recursion')
    eq('(rec:disco_info "done" (list) (list) (list))', (at('b/0')))
    -- a list builder over an UNKNOWN list: a sequence of unknown length, and the claim about its elements
    local c, _, S3 = at('c/1')
    local h = c:match('^%(list %?(%S+)%.%.%.%)$')
    ok(h, 'a list of unknown length: ' .. c)
    local el = ET.elements(S3, h)
    ok(el and A.show(el):find('^%(rec:disco_info %?%S+ %(list%) %(list%) %(list%)%)$'), 'a list of #disco_info{node = ?}: ' .. (el and A.show(el) or 'nil'))
    eq(0, S3.stats.unconverged)
    -- a KNOWN spine folds exactly: the recursion is structural (the Tail of a known list)
    eq('(rec:disco_info "n" (list) (list "urn:a") (list))', (at('k/0')))
    eq('(list (rec:disco_info "x" (list) (list) (list)) (rec:disco_info "y" (list) (list) (list)))', (at('m/0')))
    ET.OFF = { spine = true }
    local m2 = at('m/0')
    ET.OFF = {}
    ok(m2:find('^%(list %?%S+%.%.%.%)$'), 'the spine fold observes: joined into the loop the length is lost: ' .. m2)
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
    eq('(rec:disco_info "a" (list) (list) (list))', s2, 'the guard observes (bound variable)')
    eq('(rec:disco_info "a" (list) (list) (list))', rep2, 'the guard observes (repeated variable)')
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
    eq('(list (rec:disco_info "urn:x" (list) (list "f1") (list)) (rec:disco_info "urn:x" (list) (list "f2") (list)))', (at('a/0')))
    eq('(list (rec:disco_info "n1" (list) (list) (list)))', (at('b/0')))
    eq('(list (rec:disco_info "n2" (list) (list) (list)))', (at('c/0')))
    eq('(list "q" "p")', (at('d/0')))
    eq('(rec:disco_info "ap" (list) (list) (list))', (at('e/0')))
    eq('(rec:disco_info "ap3" (list) (list) (list))', (at('g/0')))
    eq('"done"', (at('h/0')))
    local k, kh = at('k/0')
    ok(k:find('^%?'), k)
    ok(table.concat(reasons(kh), '|'):find('a BIF (its source is a nif_error stub)', 1, true), table.concat(reasons(kh), '|'))
    eq('(rec:disco_info "cap" (list) (list "x") (list))', (at('n/0')))
    local w, wh = at('w/0')
    ok(w:find('^%?') and table.concat(reasons(wh), '|'):find('no clause', 1, true), 'arity: ' .. w .. ' ' .. table.concat(reasons(wh), '|'))
    -- the guards observe
    local nf = at('a/0', { funs = true })
    ok(nf:find('^%(list %?%S+ %?%S+%)$'), 'without fun values the spine is known, the elements are not: ' .. nf)
    local ks = at('k/0', { stubs = true })
    local _, ksh = at('k/0', { stubs = true })
    ok(not table.concat(reasons(ksh), '|'):find('stub', 1, true), 'without the stub rule the body is evaluated: ' .. ks)
end)

test('erlterms: lists are FLAT on both sides of the wire — the server term and the client decode build the same list', function ()
    local ET = require 'cartograph.erlterms'
    local XM = require 'cartograph.xmppmerge'
    local A = require('cartograph.algebra').load()
    local x, y = A.lit('x'), A.lit('y')
    local S = ET.session()
    -- closed, a known tail spliced, an unknown rest as a hedge hole
    eq(A.show(XM._flat_list({ x, y })), A.show(ET.mklist({ x, y }, nil, S)))
    eq(A.show(XM._flat_list({ x }, A.node('list', y))), A.show(ET.mklist({ x }, A.node('list', y), S)))
    local cl, sv = XM._flat_list({ x }, A.hole('T')), ET.mklist({ x }, A.hole('T'), S)
    eq('(list "x" ?T...)', A.show(cl))
    ok(sv.kids[2].rep, 'the server side rest is a hedge hole too: ' .. A.show(sv))
    -- and the two unify: the client's rest against the server's
    ok(A.unify(A.template(cl), A.template(A.node('list', x, y))), 'a request list unifies with a longer known list')
    -- an improper tail stays cons, on both sides
    eq(A.show(XM._flat_list({ x }, A.lit('z'))), A.show(ET.mklist({ x }, A.lit('z'), S)))
end)

test('erlterms: a list pattern binds its tail as a SEQUENCE; two hedges in one list are a refusal, not a no', function ()
    need()
    local shown = last_term(table.concat({
        'f() ->',
        '    [H | T] = [<<"a">>, <<"b">>, <<"c">>],',
        '    #disco_info{node = H, features = T}.', '' }, '\n'))
    eq('(rec:disco_info "a" (list) (list "b" "c") (list))', shown)
    -- an ALIAS of a list pattern is the whole list: the tail's sequence splices back in, it is not one element
    eq('(rec:disco_info "e" (list) (list "a" "b") (list))', (last_term(
        'f() -> case [<<"a">>, <<"b">>] of [_H | _T] = L -> #disco_info{node = <<"e">>, features = L} end.\n')))
    -- unify refuses a list with a hedge on each side of fixed elements; that is not knowledge, so both arms join
    local ET = require 'cartograph.erlterms'
    local A = require('cartograph.algebra').load()
    local S = ET.session()
    local v = ET.match(A.node('list', A.hole('p1', true), A.lit('m'), A.hole('p2', true)),
        A.node('list', A.hole('s1', true), A.lit('m'), A.hole('s2', true)))
    eq('maybe', v, 'a refusal reads as maybe')
    local _ = S
end)

test('erlterms: the carried classes say WHY a loop iterates — an other position does, a closed form does not', function ()
    need()
    local ET = require 'cartograph.erlterms'
    local A = require('cartograph.algebra').load()
    local P = program {
        nf = table.concat({
            '-module(nf).',
            'inc(N) -> {s, N}.',
            -- Tag is invariant, the list is traversed, Acc is prepended to, St goes through a call ("other")
            'walk(_Tag, [], Acc, St) -> #disco_info{node = _Tag, features = Acc, xdata = [St]};',
            'walk(Tag, [H | T], Acc, St) -> walk(Tag, T, [H | Acc], inc(St)).',
            -- the last value seen: an element of the traversed list (xmpp's decode_*_attrs)
            'attrs([{n, V} | T], _N) -> attrs(T, V);',
            'attrs([], N) -> #disco_info{node = N}.', '' }, '\n'),
        user = '-module(user).\nr(L) -> nf:walk(<<"tag">>, L, [], zero).\nq(L) -> nf:attrs(L, undefined).\n',
    }
    local m = P:module('user')
    local function at(off)
        ET.OFF = off or {}
        local cl = m.fns['r/1'][1]
        local last
        for c in cl:field('body')[1]:iter_children() do if c:named() then last = c end end
        local t, _, S = ET.term(last, m.src, m.ctx)
        ET.OFF = {}
        return A.show(t), S
    end
    local C = ET.carried(P:module('nf'), 'walk/4', P:module('nf').fns['walk/4'])
    eq({ 'inv', 'dec', 'prepend', 'other' }, C.class)
    local t, S = at()
    -- the invariant Tag stays "tag", exactly; the accumulator is a sequence; the other position is unknown
    ok(t:find('^%(rec:disco_info "tag" %(list%) %(list %?%S+%.%.%.%) %(list %?%S+%)%)$'), t)
    -- an element of the traversed list is a closed form: one pass, and the hole says what it is
    local qm = m.fns['q/1'][1]
    local ql
    for c in qm:field('body')[1]:iter_children() do if c:named() then ql = c end end
    local qt, qh, QS = ET.term(ql, m.src, m.ctx)
    eq({ 'dec', 'elem' }, ET.carried(P:module('nf'), 'attrs/2', P:module('nf').fns['attrs/2']).class)
    eq(1, QS.stats.onepass)
    ok(table.concat(reasons(qh), '|'):find('an element of what it traverses', 1, true), A.show(qt) .. ' ' .. table.concat(reasons(qh), '|'))
    -- an 'other' position is why this loop still iterates, and the breakdown says so
    eq(1, S.stats.loop_kinds['tail, an other position'])
    ok(S.stats.iterations >= 2, 'iterated')
end)
