-- ERLANG RECORDS AS TYPES, SCOPED PER MODULE (CART-1095).
--
-- ★★★ WHAT THESE SPECS FENCE are the four things a plausible-looking record table gets wrong:
--   1. SCOPE: `state` means a different field list in every module; a global table is right for the last file read.
--   2. INCLUDE SEARCH: a header's own -include resolves from THAT HEADER's directory (xmpp.hrl -> ns.hrl), not from
--      the .erl's directory or the tree's include/.
--   3. DEPENDENCY ROOTS: -include_lib("app/…") maps through an explicit app dir that WINS over an ERL_LIBS scan,
--      the scan picks the highest `app-<vsn>`, and a renamed package (`p1_dep`) never answers for `dep`.
--   4. `#r{_ = V}` is a WILDCARD, not a reference to a field named `_`.

local ER = require 'cartograph.erlrecords'

local function have_erlang() return parser_available('erlang') end

local function put(root, rel, src)
    vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
    local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    return root .. '/' .. rel
end

-- one analysed app (app/) and one dependency root (dep/), in separate dirs
local function fixture()
    local base = vim.fn.tempname()
    local P = { base = base, app = base .. '/app', dep = base .. '/dep', libs = base .. '/libs' }
    P.m1 = put(base, 'app/src/m1.erl', [[
-module(m1).
-include("local.hrl").
-include_lib("dep/include/dep.hrl").
-record(state, {a, b = 1 :: integer()}).
-spec f(#state{}) -> ok.
f(#state{a = A} = S, X) ->
    Y = S#state.b, I = #state.a, S2 = S#state{a = 2},
    Z = #state{_ = 0},
    D = #dep_rec{f = <<"x">>, g = 1}, In = #inner{i = 1}, L = #local{x = 3},
    is_record(X, local), record_info(fields, state),
    ok.
]])
    P.m2 = put(base, 'app/src/m2.erl', [[
-module(m2).
-record(state, {c}).
g(S) -> S#state{c = 1}, #state{a = 1}.
]])
    put(base, 'app/include/local.hrl', [[
-record(local, {x = 1 :: integer(), y}).
]])
    put(base, 'dep/include/dep.hrl', [[
-ifndef(DEP_HRL).
-define(DEP_HRL, true).
-include("inner.hrl").
-record(dep_rec, {f = <<>> :: binary(),
                  g}).
-endif.
]])
    put(base, 'dep/include/inner.hrl', [[
-record(inner, {i}).
]])
    return P
end

local function engine(P, extra)
    local o = { include_dirs = { P.app .. '/include' }, apps = { dep = P.dep } }
    for k, v in pairs(extra or {}) do o[k] = v end
    return ER.new(o)
end

local function status_of(E, path)
    local by = {}
    for _, r in ipairs(E:check(path)) do
        local k = (r.use.name or r.use.macro or '?') .. (r.field and ('.' .. r.field) or '')
        by[k] = by[k] or {}
        by[k][r.status] = (by[k][r.status] or 0) + 1
    end
    return by
end

test('erlrecords: the SHAPE — ordered fields, positional index, default and type TEXT, declaring file:line', function ()
    if not have_erlang() then skip('no erlang parser') end
    local P = fixture()
    local E = engine(P)
    local d = E:scope(P.m1).records.dep_rec
    ok(d, 'dep_rec is visible in m1 through -include_lib')
    eq(P.dep .. '/include/dep.hrl', d.file, 'the DECLARING file, absolute')
    eq(4, d.line)
    eq({ 'f', 'g' }, { d.fields[1].name, d.fields[2].name }, 'declaration order')
    eq({ 1, 2 }, { d.fields[1].index, d.fields[2].index }, 'index is the position (tuple element = index + 1)')
    eq('<<>>', d.fields[1].default)
    eq('binary()', d.fields[1].type)
    eq(nil, d.fields[2].default, 'no default declared -> nil, not an empty string')
    eq(nil, d.fields[2].type)
    ok(d.by.g == d.fields[2], 'by-name view is the same field record')
    eq(nil, d.cond, 'an INCLUDE GUARD is not a condition')
    local st = E:scope(P.m1).records.state
    eq('1', st.by.b.default)
    eq('integer()', st.by.b.type)
    vim.fn.delete(P.base, 'rf')
end)

test('erlrecords: records are SCOPED PER MODULE, never a global table', function ()
    if not have_erlang() then skip('no erlang parser') end
    local P = fixture()
    local E = engine(P)
    eq('a,b', ER.signature(E:scope(P.m1).records.state))
    eq('c', ER.signature(E:scope(P.m2).records.state))
    local s1, s2 = status_of(E, P.m1), status_of(E, P.m2)
    ok(s1.state and s1.state.ok and not s1.state.unknown_field, 'm1 reads its OWN state: ' .. vim.inspect(s1.state))
    eq(1, (s2['state.a'] or {}).unknown_field, 'm2 has no field `a`: #state{a = 1} is rejected THERE')
    eq(1, (s2.state or {}).ok, "and m2's own S#state{c = 1} resolves")
    ok(not E:scope(P.m2).records.dep_rec, 'm2 includes nothing, so it sees no dependency record')
    vim.fn.delete(P.base, 'rf')
end)

test("erlrecords: a header's -include searches THAT HEADER's directory first", function ()
    if not have_erlang() then skip('no erlang parser') end
    local P = fixture()
    local E = engine(P)
    local sc = E:scope(P.m1)
    ok(sc.records.inner, 'dep.hrl -> -include("inner.hrl") found next to dep.hrl in the dependency root')
    eq(P.dep .. '/include/inner.hrl', sc.records.inner.file)
    eq(0, #sc.missing, 'nothing missing: ' .. vim.inspect(sc.missing))
    eq(1, (status_of(E, P.m1).inner or {}).ok)
    vim.fn.delete(P.base, 'rf')
end)

test('erlrecords: without the dependency root, the residue NAMES the missing application', function ()
    if not have_erlang() then skip('no erlang parser') end
    local P = fixture()
    local E = ER.new { include_dirs = { P.app .. '/include' } }
    local sc = E:scope(P.m1)
    eq(1, #sc.missing)
    eq('dep/include/dep.hrl', sc.missing[1].spec)
    eq('include_lib', sc.missing[1].kind)
    ok(sc.missing[1].reason:find('no root for application dep', 1, true), sc.missing[1].reason)
    local s = status_of(E, P.m1)
    eq(1, (s.dep_rec or {}).unknown_record)
    eq(1, (s.inner or {}).unknown_record, 'and what dep.hrl would have included is unknown too')
    eq(2, (s['local'] or {}).ok, 'the tree-local include still resolves through include_dirs (#local and is_record)')
    vim.fn.delete(P.base, 'rf')
end)

test('erlrecords: USE KINDS, the type context, and `_ = V` as a wildcard', function ()
    if not have_erlang() then skip('no erlang parser') end
    local P = fixture()
    local E = engine(P)
    local kinds, wild, typed = {}, nil, 0
    for _, u in ipairs(E:uses(P.m1)) do
        kinds[u.kind] = (kinds[u.kind] or 0) + 1
        if u.name == 'state' and u.kind == 'construct' and u.line == 8 then wild = u end
        if u.ctx == 'type' then typed = typed + 1 end
    end
    -- construct: spec #state{}, head #state{a=A}, #state{_=0}, #dep_rec, #inner, #local
    eq({ construct = 6, field = 1, index = 1, update = 1, is_record = 1, record_info = 1 }, kinds)
    eq(1, typed, 'the -spec argument is a TYPE-context use')
    ok(wild, 'the #state{_ = 0} use is read')
    eq(0, #wild.fields, '`_` is a wildcard, not a field reference')
    local s = status_of(E, P.m1)
    for k, v in pairs(s) do ok(v.ok and not v.unknown_field and not v.unknown_record, k .. ' ' .. vim.inspect(v)) end
    vim.fn.delete(P.base, 'rf')
end)

test('erlrecords: conditions are TAGGED, macros and -define bodies are REPORTED, not resolved', function ()
    if not have_erlang() then skip('no erlang parser') end
    local src = [[
-module(c).
-ifndef(SIP).
-record(z, {x}).
-else.
-include_lib("esip/include/esip.hrl").
-record(z, {y}).
-endif.
-define(MK, #z{x = 1}).
h(A) -> ?MK, #?REC{a = 1}, A#z.y.
]]
    local f = ER.parse_source(src, '/virtual/c.erl')
    eq(2, #f.records)
    eq('not defined(SIP)', f.records[1].cond)
    eq('defined(SIP)', f.records[2].cond)
    eq('defined(SIP)', f.includes[1].cond, 'the include inherits its branch')
    local mac, indef
    for _, u in ipairs(f.uses) do
        if u.macro then mac = u end
        if u.in_define then indef = u end
    end
    ok(mac and mac.name == nil and mac.macro == '?REC', 'a macro record name is kept as text, name = nil')
    ok(indef and indef.name == 'z', 'a use inside a -define body is flagged in_define')
    -- through a scope: both z declarations are visible as VARIANTS, and a field of either resolves
    local base = vim.fn.tempname()
    local p = put(base, 'c.erl', src)
    local E = ER.new {}
    local sc = E:scope(p)
    eq(2, #sc.variants.z, 'two exclusive branches -> two variants')
    local s = status_of(E, p)
    eq(1, (s['?REC'] or {}).macro_name)
    ok((s.z or {}).ok == 2, 'the -define body use and A#z.y both resolve against a variant: ' .. vim.inspect(s))
    eq('defined(SIP)', sc.missing[1].cond, 'the missing root is reported WITH its condition')
    -- a header included UNDER a condition: its records carry that condition AS PLAIN DATA
    put(base, 'cond.hrl', '-record(hdr, {h = 1}).\n')
    local p2 = put(base, 'c2.erl', '-module(c2).\n-ifdef(X).\n-include("cond.hrl").\n-endif.\n')
    local h = ER.new {}:scope(p2).records.hdr
    eq('defined(X)', h.cond, 'the include chain condition is inherited')
    ok(rawget(h, 'fields') and rawget(h, 'by') and rawget(h, 'name') == 'hdr',
        'a plain table, not a metatable proxy: it must survive pairs / mpack to a worker')
    eq(nil, getmetatable(h))
    vim.fn.delete(base, 'rf')
end)

test('erlrecords: ERL_LIBS scan picks the highest version, an explicit app WINS, no aliasing', function ()
    if not have_erlang() then skip('no erlang parser') end
    local P = fixture()
    put(P.base, 'libs/dep-1.9/include/dep.hrl', '-record(dep_rec, {old}).\n')
    put(P.base, 'libs/dep-1.10/include/dep.hrl', '-record(dep_rec, {new}).\n-include("inner.hrl").\n')
    put(P.base, 'libs/dep-1.10/include/inner.hrl', '-record(inner, {i}).\n')
    put(P.base, 'libs/p1_other-2.0/include/other.hrl', '-record(other, {o}).\n')
    -- lib scan only
    local E = ER.new { include_dirs = { P.app .. '/include' }, libs = { P.libs } }
    eq('new', ER.signature(E:scope(P.m1).records.dep_rec), '1.10 beats 1.9 (numeric, not lexical)')
    local hit, why = E:resolve('include_lib', 'other/include/other.hrl', P.m1)
    eq(nil, hit, 'p1_other-2.0 never answers for `other`')
    ok(why:find('no root for application other', 1, true), why)
    -- an explicit app dir shadows the scan
    local E2 = ER.new { include_dirs = { P.app .. '/include' }, libs = { P.libs }, apps = { dep = P.dep } }
    eq('f,g', ER.signature(E2:scope(P.m1).records.dep_rec), 'the explicit app root wins over the lib scan')
    vim.fn.delete(P.base, 'rf')
end)

-- ⚠ NOT the real ~/git/xmpp: the suite reads only the running tree (isolation_spec). The census reads the real
-- library (278 records); this is its LAYOUT, with iq and disco_info declared verbatim from xmpp_codec.hrl.
test('erlrecords: the xmpp layout, xmpp.hrl -> jid.hrl + xmpp_codec.hrl, reached by -include_lib', function ()
    if not have_erlang() then skip('no erlang parser') end
    local base = vim.fn.tempname()
    put(base, 'xmpp/include/xmpp.hrl', '-include("jid.hrl").\n-include("xmpp_codec.hrl").\n'
        .. '-include_lib("fast_xml/include/fxml.hrl").\n')
    put(base, 'xmpp/include/jid.hrl', '-record(jid, {user = <<"">> :: binary(), server = <<"">> :: binary()}).\n')
    put(base, 'xmpp/include/xmpp_codec.hrl', [[
-record(disco_info, {node = <<>> :: binary(),
                     identities = [] :: [#identity{}],
                     features = [] :: [binary()],
                     xdata = [] :: [#xdata{}]}).
-record(iq, {id = <<>> :: binary(),
             type :: iq_type(),
             lang = <<>> :: binary(),
             from :: undefined | jid:jid(),
             to :: undefined | jid:jid(),
             sub_els = [] :: [xmpp_element() | fxml:xmlel()],
	     meta = #{} :: map()}).
]])
    local p = put(base, 'app/src/h.erl', [[
-module(h).
-include_lib("xmpp/include/xmpp.hrl").
process_local_iq(#iq{type = get, sub_els = [#disco_info{node = Node}]} = IQ) -> {IQ, Node}.
]])
    local E = ER.new { apps = { xmpp = base .. '/xmpp' } }
    local sc = E:scope(p)
    local di = sc.records.disco_info
    eq('node,identities,features,xdata', ER.signature(di))
    eq('<<>>', di.by.node.default)
    eq('[#identity{}]', di.by.identities.type, 'a type naming another record is kept as text')
    eq(6, sc.records.iq.by.sub_els.index, 'sub_els is the 6th field: tuple element 7')
    eq(nil, sc.records.iq.by.type.default)
    eq('iq_type()', sc.records.iq.by.type.type)
    ok(sc.records.jid, 'jid.hrl reached through xmpp.hrl')
    eq(1, #sc.missing, 'fast_xml is not attached, and says so')
    eq('fast_xml/include/fxml.hrl', sc.missing[1].spec)
    local s = status_of(E, p)
    eq(1, (s.iq or {}).ok); eq(1, (s.disco_info or {}).ok)
    vim.fn.delete(base, 'rf')
end)
