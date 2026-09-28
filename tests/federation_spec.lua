-- FEDERATION, FIRST CUT (CART-1160 step 9a): a stdlib PROFILE mounted read-only as its own band, and the linkage
-- DERIVED from the namespace — never mounted, cached by the namespace value. ★ ACCEPTANCE: the derived linkage EQUALS
-- the edges the in-graph mint writes, row by row (tools/fedgate.lua runs the same comparison on a real tree: ghost's
-- services 1132/1132 under node, discourse's controllers 3438/3438 under ruby-rails). ⚠ The two sides share ONE port
-- rule (treesitter.profile_port) by design — what this compares is the WIRING: exports, the namespace, sharing,
-- additivity, ties.
local ts = require 'cartograph.providers.treesitter'
local F = require 'cartograph.federation'
local NS = require 'cartograph.namespace'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'javascript') end

local SRC = [[
const path = require('path');
const fs = require('fs');
const assert = require('assert');
function load(p) { const t = fs.readFileSync(path.join(p, 'x'), 'utf8'); assert.equal(typeof t, 'string'); return JSON.parse(t); }
function tick() { setTimeout(tick, 10); return path.resolve('.'); }
function join(a, b) { return a + b; }
function mine() { return join('a', 'b'); }
module.exports = { load, tick, mine };
]]

local function tree()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/package.json', 'w')); fd:write('{"name":"p","version":"1.0.0"}'); fd:close()
    fd = assert(io.open(root .. '/a.js', 'w')); fd:write(SRC); fd:close()
    return root
end
local function edge_rows(data)
    local out = {}
    for _, e in ipairs(data.edges) do if e.stdlib then out[#out + 1] = ('%s -> %s x%d'):format(e.from, e.to, #e.at) end end
    table.sort(out); return out
end
local function link_rows(L)
    local out = {}
    for _, r in ipairs(L.rows) do out[#out + 1] = ('%s -> %s x%d'):format(r.from, r.to, #r.at) end
    table.sort(out); return out
end

test('federation: a profile mounted as its OWN band links exactly what the in-graph mint writes, row by row', function ()
    if not ready() then skip 'no javascript parser' end
    local root = tree()
    local mint = ts.extract(root, { profile = 'node' })
    local fed = ts.extract(root, { profile = 'node', profile_mint = false })
    eq({}, edge_rows(fed), 'the federated extraction mints nothing: its disposed calls stay PORTS')
    local want = edge_rows(mint)
    ok(#want >= 5, 'a non-vacuous oracle: ' .. vim.inspect(want))
    local band = assert(F.profile_band('node'))
    eq(true, band.readonly)
    local ns = NS.mount(NS.mount(NS.empty(), root, fed, { share = { 'node' } }), band.root, band, { ro = true })
    local L = F.linkage(ns)
    eq(want, link_rows(L))
    ok(F.linkage(ns) == L, 'cached by the namespace VALUE')
    local ns2 = NS.mount(ns, '/elsewhere', { root = '/elsewhere', nodes = {}, edges = {}, calls = {} })
    ok(F.linkage(ns2) ~= L, 'a different namespace value derives afresh')
end)

test('federation: sharing is a MOUNT OPTION (default: nothing links), linkage is ADDITIVE on the frontier, and a TIE is a miss', function ()
    if not ready() then skip 'no javascript parser' end
    local root = tree()
    local fed = ts.extract(root, { profile = 'node', profile_mint = false })
    local band = assert(F.profile_band('node'))
    -- no `share`: the project's ports may match nothing
    local closed = NS.mount(NS.mount(NS.empty(), root, fed), band.root, band, { ro = true })
    eq(0, #F.linkage(closed).rows, 'no sharing model, no linkage')
    -- ADDITIVE: mine() -> join() resolved INSIDE the band; it is never a port, so no row starts a link to node's join
    local open = NS.mount(NS.mount(NS.empty(), root, fed, { share = { 'node' } }), band.root, band, { ro = true })
    for _, r in ipairs(F.linkage(open).rows) do
        ok(not r.from:find('mine', 1, true), 'an in-band resolution was overridden: ' .. r.from .. ' -> ' .. r.to)
    end
    -- a TIE: two shared bands export the same path -> neither is picked, the call stays a frontier (a miss)
    local twin = vim.deepcopy(band); twin.root = 'profile://node-twin'
    local tie = NS.mount(open, twin.root, twin, { ro = true })
    local L = F.linkage(tie)
    eq(0, #L.rows, 'every linked call now has two candidates: none is picked')
    local amb = 0
    for _, m in ipairs(L.misses) do if m.why == 'ambiguous' then amb = amb + 1 end end
    ok(amb >= 5, 'the ties are reported as ambiguous misses: ' .. amb)
end)

test('federation: a call resolved IN its band is never a port, and a port links only to what the band EXPORTS', function ()
    local band = assert(F.profile_band('node'))
    -- a synthetic project band: one disposed call to path.join, and the same call ALSO resolved in-band
    local function project(to)
        return { root = '/p', nodes = { { id = 'x.js::f@1', name = 'f', kind = 'function', file = 'x.js' } }, edges = {},
            calls = { { fn = 'x.js::f@1', callee = 'join', full = 'path.join', ext = { why = 'stdlib' }, line = 1, file = 'x.js', to = to } } }
    end
    local function link(p, b)
        return F.linkage(NS.mount(NS.mount(NS.empty(), '/p', p, { share = { 'node' } }), b.root, b, { ro = true }))
    end
    local open = link(project(nil), band)
    eq(1, #open.rows, 'the disposed call is a port and links: ' .. vim.inspect(open.misses))
    eq('node::path.join', open.rows[1].to)
    eq(0, #link(project('x.js::join@9'), band).rows, 'resolved inside its band: ADDITIVE, never overridden')
    -- the same port against a band that does NOT export path.join: a miss, never a minted guess
    local thin = vim.deepcopy(band)
    for i = #thin.nodes, 1, -1 do if thin.nodes[i].name == 'path.join' then table.remove(thin.nodes, i) end end
    local L = link(project(nil), thin)
    eq(0, #L.rows); eq(1, #L.misses); ok(L.misses[1].why:find('no export', 1, true), L.misses[1].why)
end)

-- ── 9b: LOOPBACK OVER THE WIRE ─────────────────────────────────────────────────────────────────────────────────────
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local function host(root)
    return { vim.v.progpath, '--headless', '-u', 'NONE', '-l', REPO .. '/tools/mcpserve.lua', root,
        '--profile', 'node', '--no-profile-mint' }
end

test('federation over the WIRE: a band served by ANOTHER cartograph links exactly as the same band mounted locally', function ()
    if not ready() then skip 'no javascript parser' end
    local root = tree()
    local band = assert(F.profile_band('node'))
    local local_fed = ts.extract(root, { profile = 'node', profile_mint = false })
    local want = link_rows(F.linkage(NS.mount(NS.mount(NS.empty(), root, local_fed, { share = { 'node' } }), band.root, band, { ro = true })))
    ok(#want >= 5, 'a non-vacuous local oracle')
    local remote = F.remote_band { cmd = host(root), timeout = 60000 }
    eq(nil, remote.unavailable, tostring(remote.unavailable))
    eq('node', remote.profile); eq(false, remote.remote.minted, 'the host served PORTS, not a minted graph')
    ok(#remote.calls > 0 and #remote.nodes == 0, 'only ports crossed — no nodes, no bodies')
    local got = link_rows(F.linkage(NS.mount(NS.mount(NS.empty(), remote.root, remote, { share = { 'node' } }), band.root, band, { ro = true })))
    eq(want, got, 'the linkage over the wire equals the local one, row by row')
end)

test('federation over the WIRE: a host that dies is UNAVAILABLE — a band-level frontier, never an absence of links', function ()
    if not ready() then skip 'no javascript parser' end
    local root = tree()
    local band = assert(F.profile_band('node'))
    local mcp = require 'cartograph.mcp'
    local c = assert(mcp.connect { cmd = host(root), timeout = 60000 })
    -- the host dies after the handshake, before the question
    c.handle:kill('sigkill')
    vim.wait(2000, function () return not c.alive end, 20)
    local remote = F.remote_band { client = c, timeout = 5000 }
    pcall(function () c:close() end)
    ok(remote.unavailable, 'the band says it could not be asked')
    local L = F.linkage(NS.mount(NS.mount(NS.empty(), root, remote, { share = { 'node' } }), band.root, band, { ro = true }))
    eq(0, #L.rows)
    eq(1, #L.misses); eq(true, L.misses[1].unavailable); ok(L.misses[1].why:find('UNAVAILABLE', 1, true), L.misses[1].why)
    for _, m in ipairs(L.misses) do ok(not m.why:find('no export', 1, true), 'never read as "nothing to link": ' .. m.why) end
    -- and a host that never starts is the same kind of answer
    local never = F.remote_band { cmd = { '/nonexistent/cartograph-host' }, timeout = 2000 }
    ok(never.unavailable and never.unavailable:find('did not start', 1, true), tostring(never.unavailable))
end)
