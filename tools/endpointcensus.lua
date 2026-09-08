-- endpointcensus — COULD WE EMIT A CLIENT FOR THIS ENDPOINT, AND IF NOT, WHO
-- OWNS THE GAP? (CART-0841, under CART-0840.)
--
--   nvim --headless -u NONE -l tools/endpointcensus.lua <corpus|dir> [--rows]
--
-- ★★★ THE FIRST DELIVERABLE OF "GENERATE A CLIENT FROM SERVER CODE" IS NOT A
-- GENERATOR. A generator built now would emit for the handful of endpoints whose
-- payload happens to be readable and READ AS A CAPABILITY. This is CART-0258's
-- shape one axis over: that census asked "how many functions could we emit a
-- TEST for, and which holes are OUR gap"; this asks it of ENDPOINTS.
--
-- ★★ A CLIENT NEEDS THREE THINGS PER ENDPOINT AND THEY HAVE DIFFERENT ANSWERS:
--   ADDRESS   what the runtime dispatches on (a wire path, a URI, a route)
--   HANDLER   the code that serves it — needed to read the payload FROM
--   PAYLOAD   what to send: the request's SHAPE, not its type NAME
-- Counting only the first would say "we can generate clients". Counting all
-- three is the answer.
--
-- ⚠⚠ AND `emittable` MUST NOT BE ONE NUMBER. CART-0284's lesson, paid for once:
-- `emittable` was THREE different numbers because the census's hole set had
-- diverged from the emitter's. There is no emitter yet, so this publishes the
-- DECOMPOSITION and refuses to headline a single figure.
--
-- ★★★ THE OUTPUT THAT DECIDES SOMETHING is the GAP OWNERS table: which single
-- analysis, if built, would unlock the most endpoints. That is the question
-- CART-0840 exists to answer, and a per-family total cannot answer it.
--
-- ⚠ THE GAPS CARRY tier.ABSENCE KINDS, because the remedies differ and the
-- three render identically as "no payload":
--   unavailable  the DATA CLASS is not extracted — proto.lua reads a message
--                body for nested NAMES and deliberately skips its FIELDS
--   frontier     no analysis exists for this language — holes.lua and
--                consumers.lua are both declared `@langs lua`, so an erlang or
--                go handler has no shape mechanism AT ALL
--   absent       we looked with a mechanism that applies and found nothing
-- "the analysis failed" and "no analysis is declared" are different answers with
-- different costs, and only the second is cheap to fix.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local argv = require 'cartograph.argv'
local proto = require 'cartograph.proto'
local xlang = require 'cartograph.xlang'
local tiers = require 'cartograph.tier'
local prof = require 'cartograph.spec.profile'

-- ── THE FAMILIES, DECLARED ──────────────────────────────────────────────────
-- ★ Each family says how to FIND its endpoints and what it can say about the
-- three questions. Declared as data so a fourth family is a table entry — and
-- deliberately NOT a generic "endpoint provider" interface, which would be an
-- engine with three instances to check it.
--
-- `payload` is a FUNCTION returning (known, absence_kind, owner) — never a
-- boolean, because the reason is the deliverable.
local FAMILIES = {}

--- Does any analysis in this tree claim to read value shapes for `lang`?
-- ⚠ MEASURED FROM THE DECLARATIONS, NOT ASSUMED. `holes.lua` and
-- `consumers.lua` both carry `-- @langs lua`, which the language fence audits.
-- So the answer for anything else is a FRONTIER with a named owner, and that is
-- a fact about our coverage rather than about the corpus.
local SHAPE_LANGS = { lua = true }
local function shape_owner(lang)
    if SHAPE_LANGS[lang] then return 'holes.lua (constraint / synth.summary)' end
    return ('holes.lua is @langs lua — nothing reads value shapes for %s')
        :format(tostring(lang))
end

FAMILIES[#FAMILIES + 1] = {
    name = 'grpc rpc',
    what = 'a declared .proto contract: the strongest possible starting point',
    find = function (data)
        local out = {}
        for _, n in ipairs(data.nodes) do
            if n.pb == 'rpc' then
                out[#out + 1] = { id = n.id, address = n.wire, name = n.name,
                    file = n.file, line = n.line, req = n.req, resp = n.resp }
            end
        end
        return out
    end,
    -- the address is a LITERAL both generated stubs write; nothing to infer
    address = function (e) return e.address ~= nil, 'the wire path, declared' end,
    handler = function (e, ctx)
        -- ⚠ EXPECTED TO BE ZERO, AND THAT IS CART-0833 RATHER THAN A BUG HERE:
        -- `contract -> source` is the biggest missing edge class. A client
        -- generator does not strictly need the handler when the CONTRACT states
        -- the payload — which is exactly why this family is the control case.
        return ctx.reg_in[e.id] ~= nil
    end,
    payload = function (e)
        if not e.req then return false, 'absent', 'proto.lua (no request type on the rpc)' end
        -- ★★★ THE FINDING THAT MOTIVATED CART-0840. We have the request type
        -- NAME and know nothing about its FIELDS: proto.lua reads a message body
        -- "recursed only to collect QUALIFIED nested names — fields are
        -- deliberately not read (descendable-data is a separate arc)". So even a
        -- fully declared IDL yields no payload.
        return false, 'unavailable',
            'proto.lua message FIELDS (deliberately unread) -> CART-0467 / descendable-data'
    end,
}

FAMILIES[#FAMILIES + 1] = {
    name = 'xmpp iq handler',
    what = 'no IDL at all: the server code IS the contract (the interesting case)',
    find = function (data, ctx)
        local out = {}
        for _, c in ipairs(data.calls or {}) do
            if (c.callee or '') == 'add_iq_handler' then
                local a = argv.at(c, 3)
                local nm = a and a.name
                out[#out + 1] = { id = ('iq::%s:%s'):format(c.file or '?', tostring(c.line)),
                    address = nm and ctx.vocab[nm] or (a and a.v), via = nm,
                    file = c.file, line = c.line, call = c }
            end
        end
        return out
    end,
    address = function (e)
        -- ⚠ THE URI COMES FROM A LIBRARY, NOT FROM THE SOURCE (dec/36). Without
        -- the distilled vocabulary the address is a macro NAME, which no client
        -- can dispatch on.
        return e.address ~= nil, 'the namespace URI, from the distilled vocabulary'
    end,
    handler = function (e, ctx)
        -- xlang resolves the handler from the module+function atom PAIR — the
        -- function atom alone is hopeless (`process_iq` is defined by a dozen
        -- modules) — and stamps the registration SITE on the edge it makes.
        return ctx.handler_at[('%s:%d'):format(tostring(e.file), e.line or -1)] ~= nil
    end,
    payload = function (e, ctx)
        -- the payload is whatever the handler does with its IQ record — a shape
        -- question about a parameter, in erlang
        return false, 'frontier', shape_owner(ctx.lang_of(e.file))
    end,
}

FAMILIES[#FAMILIES + 1] = {
    name = 'http route',
    what = 'a framework route: the address is declared, the payload is read off the request object',
    find = function (data)
        local out = {}
        for _, n in ipairs(data.nodes) do
            -- ⚠⚠ THE MARKER MEANS "THIS ADAPTER MINTED IT", NOT "THIS IS A
            -- ROUTE", AND THE KIND IS WHAT SEPARATES THEM. django.lua marks
            -- BOTH a route (`kind = 'var'`) and every TEMPLATE FILE that
            -- references one (`kind = 'module'`). Reading the marker alone gave
            -- 314 "endpoints" on django-oscar of which 149 were .html
            -- templates — a 47% overcount in the population the census
            -- publishes, which is the worst thing a census can get wrong. The
            -- tell was a `nil` language bucket in the gap-owners table: an
            -- unlabelled bucket is a population you have not looked at.
            if (n.dj or n.sf) and n.kind == 'var' then
                out[#out + 1] = { id = n.id, address = n.name, file = n.file,
                    line = n.order, kind = n.dj and 'django' or 'symfony' }
            end
        end
        return out
    end,
    address = function (e)
        -- ⚠ A ROUTE NAME IS NOT A URL. django's adapter mints the `reverse()`
        -- name, which addresses the route INSIDE the app and is not what an
        -- external client puts in a request line. So this is a HALF address, and
        -- calling it whole would be the flattering reading.
        return false, 'the reverse() NAME is minted, not the URL PATTERN'
    end,
    handler = function (e, ctx) return ctx.reg_in[e.id] ~= nil end,
    payload = function (e, ctx)
        return false, 'frontier', shape_owner(ctx.lang_of(e.file))
    end,
}

-- ── run ─────────────────────────────────────────────────────────────────────
local target, want_rows
for i = 1, #arg do
    if arg[i] == '--rows' then want_rows = true elseif not target then target = arg[i] end
end
if not target then print('usage: endpointcensus.lua <corpus|dir> [--rows]'); os.exit(2) end
local reg = dofile(repo .. '/tools/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then print('not a directory: ' .. root); os.exit(2) end

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)
data.root = data.root or root
-- ⚠ ADAPTERS DO NOT RUN HEADLESSLY (CART-0679): ts.extract runs no post-pass, so
-- the contract front end and the linker are called here. A census over a graph
-- with no contract in it would report zero endpoints, and zero reads as a
-- finding rather than as a fault.
local ps = proto.attach(data)
pcall(function () require('cartograph.django').attach(data) end)
pcall(function () require('cartograph.symfony').attach(data) end)
xlang.link(data)
store.ingest(data)

print(('endpointcensus %s'):format(root:gsub('.*/', '')))
print(('  %d nodes · %d calls · %s'):format(#(data.nodes or {}), #(data.calls or {}),
    proto.summary(ps) or 'no .proto'))

-- context every family reads: the handler index, the macro vocabulary, lang_of
-- ⚠⚠ INDEXED BY SITE, AND THREE WRONG ACCESSORS GOT ME HERE. The handler link
-- for a registration is NOT reliably a `reg` edge:
--   · xlang emits `ref` FROM THE ENCLOSING FUNCTION when the registration sits
--     inside one (ejabberd's add_iq_handler lives in `start/2`, so all 53 take
--     that branch) and only falls back to `reg` from the FILE for a TOP-LEVEL
--     registration.
--   · a `reg` edge's `from` is a FILE id, not a node id, so `store.node(e.from)`
--     answers nil — which reads as "no handler" rather than as "wrong lookup".
--   · and those reg edges are not `xlang`-marked when the resolver's callback
--     mirror made them first, so filtering on `e.xlang` hides them too.
-- Each of the three renders as a clean ZERO. ★ A falsy answer from a structure
-- is a claim about MY ACCESSOR first ([[ask-the-accessor-not-the-container]]) —
-- and `xlang.link` reporting `registered = 53` beside the zero was the tell that
-- the data existed and the reader was wrong. (That stat counts RESOLUTIONS
-- across both branches, not reg edges; the name flatters it.)
-- So: index the SITE RANGES the linker stamped on its edges. A site with a
-- handler-bearing edge at this call's line resolved; nothing else is claimed.
local at = require 'cartograph.at'
local ctx = { reg_in = {}, handler_at = {}, vocab = {} }
for _, e in ipairs(data.edges or {}) do
    if e.kind == 'reg' then ctx.reg_in[e.to] = true end
    if (e.kind == 'ref' or e.kind == 'reg') and e.xlang then
        local n = store.node(e.from)
        local file = (n and n.file) or e.from
        for _, r in ipairs(e.at or {}) do
            local ok, l = pcall(at.sl, r)
            if ok and l then ctx.handler_at[('%s:%d'):format(tostring(file), l)] = true end
        end
    end
end
do
    local a = prof.load('erl-macros')
    ctx.vocab = (a and a.values) or {}
end
function ctx.lang_of(file)
    local ext = file and file:match('%.([%w]+)$')
    if not ext then return nil end
    for lang, sp in pairs(ts.spec or {}) do
        for _, e in ipairs(sp.exts or {}) do
            if e:lower() == ext:lower() then return lang end
        end
    end
    return nil
end

local owners, total, rows = {}, { n = 0, addr = 0, handler = 0, payload = 0 }, {}
print('')
-- ★★ SITES AND DISTINCT ENDPOINTS ARE DIFFERENT NUMBERS, and a client is
-- generated per ENDPOINT. microservices-demo declares 66 rpc SITES at 16
-- distinct wire paths, because the .proto is vendored into several services —
-- so a per-site headline overstates the generable surface 4x. A COUNT IS NOT A
-- CLASS: the distinct column is the one a generator would size itself against.
print('  FAMILY              sites  distinct   address   handler   payload   EMITTABLE')
for _, fam in ipairs(FAMILIES) do
    local eps = fam.find(data, ctx)
    local na, nh, np, ne = 0, 0, 0, 0
    local distinct = {}
    for _, e in ipairs(eps) do
        if e.address then distinct[e.address] = true end
        local has_a = fam.address(e, ctx)
        local has_h = fam.handler(e, ctx)
        local has_p, kind, owner = fam.payload(e, ctx)
        if has_a then na = na + 1 end
        if has_h then nh = nh + 1 end
        if has_p then np = np + 1 end
        -- ★ EMITTABLE IS THE CONJUNCTION, and it is the only cell that answers
        -- "could we emit a client call". Every other column is a component.
        if has_a and has_p then ne = ne + 1 end
        if not has_p then
            -- ⚠ MEMBERSHIP IS CHECKED, the way agent.lua's envelope checks its
            -- own absence kind: a family inventing a kind the taxonomy does not
            -- declare is a FAULT in this tool, not a finding about the corpus.
            if not tiers.is_absence(kind) then
                print(('  ⚠ FAULT: family %q named absence %q, not a declared kind')
                    :format(fam.name, tostring(kind)))
                os.exit(2)
            end
            local key = ('%s [%s]'):format(owner, kind)
            owners[key] = (owners[key] or 0) + 1
        end
        if want_rows then
            rows[#rows + 1] = { fam = fam.name, address = e.address, via = e.via,
                file = e.file, line = e.line, a = has_a, h = has_h, p = has_p,
                kind = kind, owner = owner }
        end
    end
    local nd = 0
    for _ in pairs(distinct) do nd = nd + 1 end
    total.n = total.n + #eps; total.addr = total.addr + na
    total.handler = total.handler + nh; total.payload = total.payload + np
    total.distinct = (total.distinct or 0) + nd
    print(('    %-18s %5d  %8d   %7d   %7d   %7d   %7d')
        :format(fam.name, #eps, nd, na, nh, np, ne))
end
print(('    %-18s %5d  %8d   %7d   %7d   %7d   %7d')
    :format('TOTAL', total.n, total.distinct or 0, total.addr, total.handler,
        total.payload, 0))
if total.n == 0 then
    print('  ⚠ ZERO ENDPOINTS IS A FAULT HERE, NOT A CLEAN RESULT: this root has')
    print('    no family this census can read, so it says nothing about client')
    print('    generability. Point it at a root with a contract or routes.')
    os.exit(2)
end

-- ── ★★★ THE TABLE THAT DECIDES SOMETHING ───────────────────────────────────
print('')
print('  GAP OWNERS — which ONE analysis unlocks the most endpoints')
local ord = {}
for k, n in pairs(owners) do ord[#ord + 1] = { k = k, n = n } end
table.sort(ord, function (a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.k < b.k  -- ★ a total order, or the ranking is not a fact
end)
for _, o in ipairs(ord) do
    print(('    %4d  %s'):format(o.n, o.k))
end

print('')
print(('  READ IT THIS WAY: %d of %d endpoint site(s) have an ADDRESS (%d distinct')
    :format(total.addr, total.n, total.distinct or 0))
print(('  endpoints), and %d have a PAYLOAD. A client generator built today would')
    :format(total.payload))
print('  emit for the second number and be read as speaking for the first.')
print('  ⚠ AND THE TWO GAP KINDS HAVE DIFFERENT COSTS: `unavailable` is a data')
print('    class we chose not to extract (a decision to revisit); `frontier` is')
print('    a language nothing covers (a declaration to widen). Neither is a')
print('    failed analysis, and reporting them as one number would hide both.')

if want_rows then
    print('')
    print('  ROWS')
    table.sort(rows, function (a, b)
        if a.fam ~= b.fam then return a.fam < b.fam end
        return tostring(a.address) < tostring(b.address)
    end)
    for _, r in ipairs(rows) do
        print(('    [%s] %s%s'):format(r.fam, tostring(r.address),
            r.via and (' via ?' .. r.via) or ''))
        print(('      %s:%s · address=%s handler=%s payload=%s')
            :format(tostring(r.file), tostring(r.line), tostring(r.a),
                tostring(r.h), r.p and 'yes' or ('no [' .. tostring(r.kind) .. ']')))
        if not r.p then print(('      owner: %s'):format(r.owner)) end
    end
end
