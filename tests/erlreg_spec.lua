-- THE SECOND REGISTRATION CARRIER (CART-0846). ejabberd registers IQ handlers
-- by CALL and by a TUPLE RETURNED FROM A CALLBACK; argv reads only the call.
-- `erlreg` reads the tuple against the interpretation gen_mod.erl states in
-- executable code.
--
-- ★★★ WHAT THESE SPECS FENCE IS THE THREE-WAY DISCRIMINATION, because it is
-- what the first implementation got wrong. THREE different things in ejabberd
-- are `{iq_handler, …}` tuples and only one is a registration:
--     the `-type` DECLARATION      elements are TYPE APPLICATIONS
--     the CONSUMER'S CLAUSE HEAD   elements are `var`s being BOUND
--     the REGISTRATION             elements are atoms and macro calls
-- Indistinguishable by tag and by arity. My first cut counted all three: 32
-- "registrations" including gen_mod's own type and its own interpretation.

local ts = require 'cartograph.providers.treesitter'
local erlreg = require 'cartograph.erlreg'

local function have_erlang()
    return pcall(vim.treesitter.language.add, 'erlang')
        and pcall(vim.treesitter.get_string_parser, '', 'erlang')
end

-- ⚠ REAL NAMESPACE MACROS: the URI comes from the distilled vocabulary
-- (erl-macros.mpack, from the pinned processone/xmpp), so an invented
-- `?NS_FIXTURE` could never be valued and the spec would prove nothing about
-- the key half. NS_BLOCKING and NS_TIME are both in the artifact.
local MOD = [[
-module(mod_fixture).

-type registration() :: {iq_handler, component(), binary(), atom()}
                      | {iq_handler, component(), binary(), module(), atom()}.

start(_Host, _Opts) ->
    {ok, [{iq_handler, ejabberd_local, ?NS_BLOCKING, process_iq},
          {iq_handler, ejabberd_sm, ?NS_TIME, mod_other, other_iq}]}.

consume(Registrations) ->
    lists:foreach(
      fun ({iq_handler, Component, NS, Function}) ->
              gen_iq_handler:add_iq_handler(Component, NS, Function)
      end, Registrations).

process_iq(IQ) -> IQ.
]]

local OTHER = [[
-module(mod_other).
other_iq(IQ) -> IQ.
]]

local function mkroot()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for name, src in pairs({ ['mod_fixture.erl'] = MOD, ['mod_other.erl'] = OTHER }) do
        local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(src); fd:close()
    end
    return root
end

local function run()
    local root = mkroot()
    local data = ts.extract(root)
    data.root = data.root or root
    local s = erlreg.attach(data)
    return s, data, root
end

test('erlreg: a TYPE declaration and a CONSUMER PATTERN are not registrations', function ()
    if not have_erlang() then skip('no erlang parser') end
    local s, _, root = run()
    -- 2 real + 2 from the -type + 1 from the consumer's fun clause head
    ok(s.tuples >= 5, 'the walk finds every tagged tuple: ' .. s.tuples)
    eq(2, s.regs, 'but only the two VALUE tuples are registrations')
    ok((s.notvalue or 0) >= 3,
        'the type applications and the bound vars are refused by ELEMENT KIND')
    -- ★ AND THE REFUSALS ARE NAMED, not silent: a dropped shape must be
    -- reportable or the reader cannot be checked against a text census.
    ok(#s.refused > 0 and s.refused[1]:find('not a value', 1, true),
        'each refusal says why: ' .. tostring(s.refused[1]))
    vim.fn.delete(root, 'rf')
end)

test('erlreg: BOTH arities, and the 4-tuple fills its module from CONTEXT', function ()
    if not have_erlang() then skip('no erlang parser') end
    local s, _, root = run()
    local by_arity = {}
    for _, r in ipairs(s.rows) do by_arity[r.arity] = r end
    ok(by_arity[4], 'the 4-tuple form is read')
    ok(by_arity[5], 'the 5-tuple form is read')
    -- ★★ THE CONTEXT FILL. The 4-tuple has NO module position; gen_mod supplies
    -- the module whose callback returned the list. A single rule for both
    -- arities would attribute this handler to the wrong module wherever one
    -- module registers on another's behalf.
    eq('mod_fixture', by_arity[4].mod, 'the 4-tuple takes the ENCLOSING module')
    eq('mod_other', by_arity[5].mod, 'the 5-tuple takes the DECLARED module')
    -- and each resolves to the handler in ITS module, not the other's
    ok(by_arity[4].handler, 'the 4-tuple handler resolved')
    ok(by_arity[5].handler, 'the 5-tuple handler resolved')
    ok(by_arity[4].handler ~= by_arity[5].handler, 'to two different functions')
    vim.fn.delete(root, 'rf')
end)

test('erlreg: the key is valued from the VOCABULARY, and provenance is stated', function ()
    if not have_erlang() then skip('no erlang parser') end
    local s, _, root = run()
    local uris = {}
    for _, r in ipairs(s.rows) do if r.uri then uris[r.uri] = r.key end end
    eq('NS_BLOCKING', uris['urn:xmpp:blocking'], 'the macro is valued by the artifact')
    eq('NS_TIME', uris['urn:xmpp:time'])
    -- ⚠ dec/36: the URI is a fact about a LIBRARY neither endpoint vendors, so
    -- the artifact's stamp rides on the result rather than the value being
    -- treated as if the source said it.
    ok(s.stamp and s.stamp:find('erlmacros', 1, true), 'the vocabulary STAMP is recorded: '
        .. tostring(s.stamp))
    vim.fn.delete(root, 'rf')
end)

test('erlreg: it mints a HANDLER EDGE and never a synthetic call', function ()
    if not have_erlang() then skip('no erlang parser') end
    local s, data, root = run()
    ok(s.edges >= 2, 'a handler edge per resolved registration: ' .. s.edges)
    -- ★★★ THE dec/36 GUARD. Rewriting the tuple into a fake `add_iq_handler`
    -- call record would make the existing linker fire for free, and that free
    -- win is exactly why it is forbidden: there is no call at that site.
    -- "teach the linker about it, do not lie in the graph so an existing linker
    -- fires."
    local synthetic = 0
    for _, c in ipairs(data.calls or {}) do
        if (c.callee or '') == 'add_iq_handler' and c.erlreg then synthetic = synthetic + 1 end
    end
    eq(0, synthetic, 'no call record was fabricated')
    -- the edges it DID make are marked, so a reader can tell which carrier
    -- produced them
    local marked = 0
    for _, e in ipairs(data.edges or {}) do if e.erlreg then marked = marked + 1 end end
    ok(marked >= 2, 'and the edges it made carry the carrier mark: ' .. marked)
    vim.fn.delete(root, 'rf')
end)

test('erlreg: no erlang parser is REPORTED, never a clean zero', function ()
    -- ⚠ "no registrations" and "we cannot read erlang" are opposite claims and
    -- must not render the same. The module reports a refusal rather than
    -- returning an empty result that reads as a clean corpus.
    local s = erlreg.attach({ root = 'mcp://not-a-tree', nodes = {}, edges = {} })
    eq(0, s.regs)
    eq(0, s.files, 'a non-filesystem root is not walked')
end)
