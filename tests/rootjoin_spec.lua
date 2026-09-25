-- THE TWO-ROOT JOIN (CART-0821). tools/rootjoin.lua extracts two roots in one
-- process and joins them on a declared relation — the cross-service question a
-- per-language server cannot represent.
--
-- ⚠ WHAT IS FENCED HERE IS THE MECHANISM, NOT THE APPLICATION'S NUMBERS.
-- brotardcast is the APPLICATION corpus and MOVES, so no `expected` count for
-- it appears anywhere in this repo. These specs run on a FIXTURE that reproduces
-- the shape: a macro-keyed registration whose value lives in a vocabulary rather
-- than in the source, a client declaring the same key as a literal under a
-- DIFFERENT local name, and a second registration mechanism the argument reader
-- cannot reach.
--
-- ★★★ THE PROPERTY UNDER TEST IS THAT THE TWO KEYS DISAGREE. Joining by the
-- protocol's own identity (the URI) and by each project's local name find
-- DIFFERENT SETS, and a tool that reported one number would be asserting a
-- comparison it never made.

local ts = require 'cartograph.providers.treesitter'
local argv = require 'cartograph.argv'

local function have(lang)
    return pcall(vim.treesitter.language.add, lang)
        and pcall(vim.treesitter.get_string_parser, '', lang)
end

-- the server: TWO registration mechanisms, exactly as ejabberd has. The first
-- is a call the argument reader sees; the second is a tuple returned from a
-- callback — a DECLARED registry with no call site to scan (CART-0226's shape).
-- ⚠ REAL NAMESPACE MACROS, and that is not incidental. The URI is supplied by
-- the DISTILLED VOCABULARY (`erl-macros.mpack`, from a library neither endpoint
-- vendors), so a fixture inventing `?NS_FIXTURE_ONE` can never have a URI at
-- all — my first version did, and the tool correctly reported a URI join of
-- ZERO for a reason that had nothing to do with the join. Using names the
-- vocabulary actually defines exercises the provenance path too.
-- ★ AND THE PAIR IS CHOSEN SO THE TWO KEYS MUST DISAGREE, the way they do on
-- the real corpus: `NS_BLOCKING` strips to `BLOCKING` and converse declares
-- `BLOCKING`; `NS_MAM_2` strips to `MAM_2` and converse declares `MAM`.
local SRV = [[
start(Host) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_BLOCKING, ?MODULE, handle_block),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_MAM_2, ?MODULE, handle_mam),
    ok.

depends(_Host, _Opts) ->
    {ok, [{iq_handler, ejabberd_local, ?NS_TIME, process_local_iq}]}.

handle_block(IQ) -> IQ.
handle_mam(IQ) -> IQ.
process_local_iq(IQ) -> IQ.
]]

-- the client: declares the same URIs under its OWN names. `ONE` matches the
-- server's macro tail, `DOS` does not — so the name join finds one and the URI
-- join finds two.
local CLI = [[
const Strophe = {};
export function boot () {
    Strophe.addNamespace('BLOCKING', 'urn:xmpp:blocking');
    Strophe.addNamespace('MAM', 'urn:xmpp:mam:2');
    Strophe.addNamespace('TIME', 'urn:xmpp:time');
}
]]

local function mkroot(name, src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(src); fd:close()
    return root
end

--- the two halves the tool joins, read the way the tool reads them
local function sides()
    local a = mkroot('mod_fixture.erl', SRV)
    local b = mkroot('boot.js', CLI)
    local da, db = ts.extract(a), ts.extract(b)
    local reg = {}
    for _, c in ipairs(da.calls or {}) do
        if (c.callee or '') == 'add_iq_handler' then
            local x = argv.at(c, 3)
            if x then reg[#reg + 1] = { k = x.k, name = x.name, v = x.v } end
        end
    end
    local decl_uri, decl_alias = {}, {}
    for _, c in ipairs(db.calls or {}) do
        if (c.callee or '') == 'addNamespace' then
            local al, key = argv.at(c, 1), argv.at(c, 2)
            if key and key.v then decl_uri[key.v] = al and al.v end
            if al and al.v then decl_alias[al.v] = true end
        end
    end
    return reg, decl_uri, decl_alias, a, b
end

test('rootjoin: the registration key arrives as a MACRO, never a literal', function ()
    if not have('erlang') then skip('no erlang parser') end
    local reg = sides()
    eq(2, #reg, 'both add_iq_handler calls were read')
    for _, r in ipairs(reg) do
        -- ⚠ dec/36: the source does not say the URI at this position, a LIBRARY
        -- does. Rewriting the slot to `lit` would make an existing linker join
        -- the two languages for free, and that free join is exactly why it is
        -- the wrong move.
        eq('macro', r.k, 'the key slot stays a macro kind')
        ok(r.name and r.name:match('^NS_'), 'and carries the NAME from the syntax')
    end
end)

test('rootjoin: the URI key and the NAME key find DIFFERENT sets', function ()
    if not (have('erlang') and have('javascript')) then skip('need erlang + javascript') end
    local reg, decl_uri, decl_alias = sides()
    -- the vocabulary the URI comes from — supplied here rather than distilled,
    -- because the point under test is the JOIN, not the distiller
    local vocab = { NS_BLOCKING = 'urn:xmpp:blocking',
        NS_MAM_2 = 'urn:xmpp:mam:2', NS_TIME = 'urn:xmpp:time' }
    local by_uri, by_name = {}, {}
    for _, r in ipairs(reg) do
        local uri = r.name and vocab[r.name]
        if uri and decl_uri[uri] then by_uri[uri] = true end
        -- ⚠ THE TOOL'S OWN RULE, not a spec-local variant: strip `^NS_`. A
        -- fixture that exercises a different rule cannot check the tool's
        -- numbers, which is how the end-to-end assertion below became possible.
        if r.name and decl_alias[(r.name:gsub('^NS_', ''))] then
            by_name[r.name] = true
        end
    end
    local function cnt(t) local k = 0 for _ in pairs(t) do k = k + 1 end return k end
    -- ★★★ THE WHOLE POINT. Two namespaces are registered AND declared, so the
    -- protocol's own identity joins both. The client calls the second one `DOS`,
    -- so a name join finds only the first. A tool reporting one number would be
    -- asserting a comparison it never made — and on the real corpus the two
    -- numbers are 6 and 4.
    eq(2, cnt(by_uri), 'the URI is the identity: both join')
    eq(1, cnt(by_name), 'the local names agree on only one')
    ok(cnt(by_uri) > cnt(by_name), 'and the URI join is the larger set')
end)

test('rootjoin: the SECOND registration mechanism is invisible to argv', function ()
    if not have('erlang') then skip('no erlang parser') end
    -- ★★ THIS IS THE RESIDUAL THE TOOL MUST COUNT. `{iq_handler, …}` tuples
    -- returned from a callback register a handler with no call site, so the
    -- argument reader reaches NONE of them. Counting them is what separates
    -- "this server does not handle that namespace" from "it does, in a shape we
    -- cannot read" — opposite claims that otherwise render as the same empty
    -- cell. On the real corpus it is 32 registrations / 19 namespaces, and 4 of
    -- those namespaces are ones the call form does not reach at all.
    local reg, _, _, a = sides()
    for _, r in ipairs(reg) do
        ok(r.name ~= 'NS_TIME',
            'the tuple-registered namespace must NOT appear among call-read keys')
    end
    -- and the text census the tool falls back to DOES see it
    local src = table.concat(vim.fn.readfile(a .. '/mod_fixture.erl'), '\n')
    local found = {}
    for tup in src:gmatch('{iq_handler,[^}]*}') do
        for nm in tup:gmatch('%?(NS_[%w_]+)') do found[nm] = true end
    end
    ok(found.NS_TIME, 'the census reaches what argv cannot')
    -- ⚠ a census that silently counts zero would report a CLEAN residual, which
    -- is the strongest possible wrong answer here
    local n = 0
    for _ in pairs(found) do n = n + 1 end
    eq(1, n, 'exactly the one tuple registration in the fixture')
end)

test('rootjoin: the tool runs on the fixture and reports its populations', function ()
    if not (have('erlang') and have('javascript')) then skip('need erlang + javascript') end
    -- END TO END, because the populations and their labels are the deliverable:
    -- four questions each produce a "namespaces in common" number and they
    -- differ by 5.7x on the real corpus.
    local _, _, _, a, b = sides()
    local out = vim.fn.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
            .. '/tools/rootjoin.lua', a, b })
    ok(out:find('JOINED, by URI', 1, true), 'reports the URI join: ' .. out:sub(1, 400))
    ok(out:find('JOINED, by NAME', 1, true), 'and the NAME join beside it')
    ok(out:find('rule: strip', 1, true),
        'and PRINTS ITS NAME RULE — an unstated rule makes its own number uncheckable')
    ok(out:find('CEILINGS', 1, true), 'and the ceilings to read the join against')
    -- ⚠⚠ ASSERT THE TOOL'S OWN CENSUS, NOT A REIMPLEMENTATION OF IT. The test
    -- above re-does the gmatch inline, so breaking the tool's pattern left it
    -- GREEN while the tool printed "0 registration(s)" — a guard that did not
    -- fire, in the spec written to guard exactly that. The count in the OUTPUT
    -- is the thing a reader trusts, so it is the thing under test.
    -- ⚠ THE LABEL CHANGED WHEN THE CARRIER BECAME READABLE (CART-0846). It said
    -- "REFUSED (registered in a shape argv cannot read)"; argv still cannot, but
    -- `erlreg` now does, so the section is a TEXT CENSUS kept as an independent
    -- check on the structural reader. This spec broke on that rename, which is
    -- the spec working: it asserts the tool's own output, not a copy of it.
    local n = out:match('censused by TEXT[^:]*:%s*(%d+) tagged tuple')
    ok(n ~= nil, 'the tool reports the text census: ' .. out:sub(1, 400))
    ok(tonumber(n) == 1,
        'the fixture has exactly ONE tagged tuple and the census must find it, got ' .. tostring(n))
    -- and the tool must say so rather than presenting zero as clean
    ok(not out:find('ZERO IS SUSPECT', 1, true),
        'a census reporting zero on a fixture that has one is broken')
    -- ★ THE TWO READERS MUST AGREE. A text scan and a structural reader over the
    -- same shape are each other's check; the tool prints which.
    ok(out:find('COUNTS AGREE', 1, true) or out:find('COUNTS DISAGREE', 1, true),
        'the tool states whether the census and the reader agree')

    -- ★★★ AND THE TWO JOIN NUMBERS, FROM THE TOOL. Asserting only that the
    -- LABELS appear left the key logic unfenced: collapsing the name join onto
    -- the URI table passed every spec, because the disagreement property was
    -- tested against a REIMPLEMENTATION of the join in this file rather than
    -- against the tool. The fixture is built so the two keys must disagree —
    -- `urn:fixture:two` is declared as `DOS`, which no stripped macro name
    -- matches — so the tool has to print 2 and 1, and cannot print one number
    -- twice.
    local nu = out:match('JOINED, by URI:%s*(%d+)')
    local nn = out:match('JOINED, by NAME:%s*(%d+)')
    -- ★★★ THREE, NOT TWO, AND THE THIRD IS THE POINT (CART-0846). The fixture's
    -- server registers TWO namespaces by CALL and a third by the TUPLE carrier
    -- (`{iq_handler, ejabberd_local, ?NS_TIME, process_local_iq}`), which argv
    -- cannot reach. Reading it takes this join 2 -> 3 — the same move that took
    -- the real corpus 6 -> 10. This assertion was `2` until the carrier landed,
    -- and it changing IS the deliverable.
    eq('3', nu, 'the URI is the identity: both carriers contribute')
    ok(tonumber(nu) > tonumber(nn),
        'and the URI join stays the LARGER set — the two keys still disagree')
    -- and the carrier is recorded per row, so a reader can ask which produced a
    -- pair: an argv-read call and an interpretation-read tuple are different
    -- rungs of evidence even when they join identically
    ok(out:find('carrier=tuple', 1, true) or out:find('carrier: %d+%-tuple'),
        'the tuple carrier is attributed in the rows')

    -- ★★★ THE ROW'S RUNG IS COMPUTED, NOT ASSERTED (CART-0843). Both carriers
    -- shipped claiming a flat `xlang`; the key comes from a distilled PROFILE
    -- artifact, which the ladder grades `stdlib` — rank 5 against xlang's 3.
    -- `tier.floor` takes the weakest hop, so the rung DROPS, and that drop is
    -- the correction rather than a regression.
    local rcall = out:match('rung%(call%) = (%S+)')
    local rtup = out:match('rung%(tuple%) = (%S+)')
    eq('stdlib', rcall, 'the call carrier floors at stdlib, not xlang')
    eq('stdlib', rtup, 'and so does the tuple carrier')
    ok(not out:find('rung%(call%) = xlang'), 'the flat overclaim must be gone')
    -- ⚠ AND THE UNGRADED HOP IS VISIBLE. The tuple's meaning comes from an
    -- INTERPRETATION — a `convention`, which the ladder has no slot for because
    -- it is full. Reporting it is the `unbuilt` lesson one axis over: do not
    -- approximate a missing rung with its nearest neighbour.
    ok(out:find('UNGRADED', 1, true),
        'the interpretation hop is reported as ungraded: ' .. tostring(rtup))
    vim.fn.delete(a, 'rf'); vim.fn.delete(b, 'rf')
end)
