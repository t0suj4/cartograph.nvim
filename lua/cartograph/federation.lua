-- cartograph.federation — WHAT A NAMESPACE DERIVES ACROSS ITS MOUNTS (CART-1160 step 9; the July band-federation
-- design, [[cartograph-band-federation]]).
--
-- A band is a MOUNTED GRAPH. The linkage between bands is not itself mounted: it is DERIVED from the namespace value
-- (`linkage(ns)`), cached by that value — a mounted linkage could go stale against bands that changed under it; a
-- derived one changes key when they do. The rules the July design fixed, kept here:
--   ADDITIVE ON THE FRONTIER — linkage consumes only what a band honestly LEFT unresolved (its ports), so it can
--     never override an edge resolved inside a band.
--   TWO RESOLVES, APART — ADDRESS resolve (which band owns a file) is the namespace's longest mount point; PORT resolve
--     (which export satisfies a frontier) searches every mount the SHARING options allow, with no mount-point
--     precedence (bands have no rank). Several candidates are not picked between: a tie stays a frontier (a miss,
--     never a mis-link).
--   SHARING = MOUNT OPTIONS — a project mount's `opts.share = { <profile runtime | band mount point>, ... }` names the
--     bands its ports may match; the default shares nothing, and nothing links.
--
-- FIRST CUT (9a): a stdlib PROFILE mounted read-only as its own band. Its exports are the profile's declared surface
-- (sigs, free functions, canonical owners); a project band extracted with `profile_mint = false` keeps the disposed
-- calls as ports; the port rule is the ONE the in-graph mint uses (treesitter.profile_port). ACCEPTANCE: the derived
-- linkage EQUALS the edges the in-graph mint writes, row by row.
local M = {}

--- a PROFILE as a read-only band: { root = 'profile://<runtime>', nodes = its exports, profile = runtime }
function M.profile_band(runtime)
    local prof = require('cartograph.spec.profile').load(runtime)
    if not prof then return nil, ('no profile `%s`'):format(tostring(runtime)), 'environment' end
    local seen, nodes = {}, {}
    local function add(path)
        if type(path) ~= 'string' or seen[path] then return end
        seen[path] = true
        nodes[#nodes + 1] = { id = prof.runtime .. '::' .. path, name = path, kind = 'external', file = prof.runtime,
            external = true, order = -1 }
    end
    for k in pairs(prof.sigs or {}) do add(k) end
    for k in pairs(prof.free or {}) do add(k) end
    for _, v in pairs(prof.canon or {}) do add(v) end
    table.sort(nodes, function (a, b) return a.id < b.id end)
    return { root = 'profile://' .. prof.runtime, nodes = nodes, edges = {}, calls = {}, readonly = true,
        band_kind = 'profile', profile = prof.runtime }
end

-- ── OVER THE WIRE (9b): a band whose mount target is ANOTHER CARTOGRAPH ─────────────────────────────────────────
-- ★ ONLY PORTS CROSS: the remote host answers its `ports` verb (the calls its band left unresolved with a profile
-- disposition, and the band identity); the linkage is still DERIVED HERE, over this namespace, by the same code.
-- ★ A HOST THAT CANNOT BE ASKED IS `UNAVAILABLE`, NEVER ABSENT: its band carries `unavailable = why`, and every
-- question through it is a frontier that says so — never an `external` (the confident negative a transient failure
-- would otherwise become, measured in the transport work: ABSENT vs UNAVAILABLE).

local function denull(v)
    if v == vim.NIL then return nil end
    if type(v) == 'table' then local o = {}; for k, x in pairs(v) do o[k] = denull(x) end; return o end
    return v
end

--- a remote band: `spec = { cmd = argv of a cartograph MCP host, timeout?, root? }`, or `{ client = <open MCP client> }`.
--- -> a graph { root, calls = its ports, band_kind = 'remote', remote = { stamp, profile } } — or, when the host cannot
--- be asked, { root, band_kind = 'remote', unavailable = why } (never nil: an unreachable band is still a mounted band)
function M.remote_band(spec)
    spec = spec or {}
    local function unavailable(why)
        return { root = spec.root or '?', nodes = {}, edges = {}, calls = {}, band_kind = 'remote', unavailable = tostring(why) }
    end
    local c, why = spec.client, nil
    if not c then
        c, why = require('cartograph.mcp').connect({ cmd = spec.cmd, timeout = spec.timeout })
        if not c then return unavailable('the host did not start: ' .. tostring(why)) end
    end
    local res, cwhy = c:call('ports', {}, spec.timeout)
    if not spec.client then c:close() end
    if type(res) ~= 'table' then return unavailable('the host did not answer `ports`: ' .. tostring(cwhy or res)) end
    res = denull(res)
    local subject = res.subject or {}
    local calls = {}
    for _, r in ipairs(res.result or {}) do calls[#calls + 1] = r end
    return { root = subject.root or spec.root or '?', nodes = {}, edges = {}, calls = calls, band_kind = 'remote',
        profile = subject.profile, remote = { stamp = subject.stamp, minted = subject.minted, absence = res.absence } }
end

--- the graphs mounted in `ns`, with their mount entries: { { point, graph, opts } }
local function mounted(ns)
    local out = {}
    for _, e in ipairs(require('cartograph.namespace').entries(ns)) do
        local g = type(e.target) == 'table' and (e.target.graph or e.target) or nil
        if type(g) == 'table' and g.nodes then out[#out + 1] = { point = e.point, graph = g, opts = e.opts or {} } end
    end
    return out
end

local cache = setmetatable({}, { __mode = 'k' })

--- ★ THE LINKAGE A NAMESPACE DERIVES: -> { rows = { { from, to, key, band, tier, at = { … } } }, misses = { … } }
--- `from` is a function id in its project band (with `band` = that band's mount point), `to` an export id in a
--- profile band. Cached by the namespace VALUE (weakly): the same namespace answers without re-deriving.
function M.linkage(ns)
    if cache[ns] then return cache[ns] end
    local ts = require 'cartograph.providers.treesitter'
    local bands = mounted(ns)
    -- ⚠ EVERY profile band, keyed by its MOUNT, not its runtime: two bands of one runtime (two versions, a twin) are two
    -- bands — keying by runtime dropped one silently and turned a real tie into a pick (measured by the tie test)
    local profiles = {}
    for _, b in ipairs(bands) do
        if b.graph.band_kind == 'profile' then
            local exports = {}
            for _, n in ipairs(b.graph.nodes) do exports[n.name] = n end
            profiles[#profiles + 1] = { band = b, runtime = b.graph.profile, exports = exports,
                port = ts.profile_port(require('cartograph.spec.profile').load(b.graph.profile)) }
        end
    end
    -- ★ PEER-PROJECT EXPORTS (9c): a band mounted with `bindings` EXPORTS the keys its registrations name (xlang's own
    -- export scan — luanti's `API_FCT(name)` -> the C++ handler `l_name`), computed on a COPY of its records so the
    -- mounted value is never mutated. Several handlers for one key inside ONE band are that band's own fan-out (as the
    -- merged graph links them); a tie is only ever ACROSS bands.
    local exporters = {}
    for _, b in ipairs(bands) do
        if b.opts.bindings and not b.graph.unavailable then
            local copy = { root = b.graph.root, nodes = b.graph.nodes, edges = {}, calls = {} }
            for i, c in ipairs(b.graph.calls or {}) do local r = {}; for k, v in pairs(c) do r[k] = v end; copy.calls[i] = r end
            local st = require('cartograph.xlang').link(copy, b.opts.bindings)
            local any_call = false
            for _, bd in ipairs(b.opts.bindings) do if bd.import and bd.import.any_call then any_call = true end end
            exporters[#exporters + 1] = { band = b, keys = st.keys or {}, any_call = any_call }
        end
    end
    local rows, byk, misses = {}, {}, {}
    for _, b in ipairs(bands) do
        if b.graph.unavailable then
            -- nothing is known about this band's ports: ONE frontier for the band, never an absence of links
            misses[#misses + 1] = { band = b.point, why = 'UNAVAILABLE: ' .. b.graph.unavailable, unavailable = true }
        elseif b.graph.band_kind ~= 'profile' then
            -- the SHARING model: only the profiles this mount names, and only one this band's calls were disposed by
            local want = {}
            for _, r in ipairs(b.opts.share or {}) do want[r] = true end
            local shares = {}
            for _, P in ipairs(profiles) do if want[P.runtime] or want[P.band.point] then shares[#shares + 1] = P end end
            -- the PEER exporters this band's mount names: an unresolved call whose callee is a registered key is a port
            -- they answer (any_call: the exported key IS the callable name, as xlang's own import rule reads it)
            local peers = {}
            for _, X in ipairs(exporters) do if X.band ~= b and want[X.band.point] and X.any_call then peers[#peers + 1] = X end end
            if #peers > 0 then
                local cv = require('cartograph.callview').of(b.graph)
                for i = 1, cv.n do
                    local callee, fn = cv.get(i, 'callee'), cv.get(i, 'fn')
                    if not cv.get(i, 'to') and callee and fn then
                        local hits = {}
                        for _, X in ipairs(peers) do if X.keys[callee] then hits[#hits + 1] = X end end
                        if #hits == 1 then
                            for _, h in ipairs(hits[1].keys[callee]) do
                                local k = b.point .. '\31' .. fn .. '\31' .. h
                                local row = byk[k]
                                if not row then
                                    row = { from = fn, to = h, key = callee, band = b.point, peer = hits[1].band.point, tier = 'xlang', at = {} }
                                    byk[k] = row; rows[#rows + 1] = row
                                end
                                row.at[#row.at + 1] = { line = cv.get(i, 'line') }
                            end
                        elseif #hits > 1 then
                            misses[#misses + 1] = { band = b.point, fn = fn, callee = callee, why = 'ambiguous', candidates = #hits }
                        end
                    end
                end
            end
            if #shares > 0 then
                local cv = require('cartograph.callview').of(b.graph)
                for i = 1, cv.n do
                    -- ADDITIVE ON THE FRONTIER: a call that resolved inside its band is never a port
                    if not cv.get(i, 'to') and type(cv.get(i, 'ext')) == 'table' then
                        local hits = {}
                        for _, P in ipairs(shares) do
                            local path = P.port(cv.get, i)
                            local target = path and P.exports[path]
                            if target then hits[#hits + 1] = { P = P, n = target, path = path } end
                        end
                        local fn = cv.get(i, 'fn')
                        if #hits == 1 and fn then
                            local h = hits[1]
                            local k = b.point .. '\31' .. fn .. '\31' .. h.n.id
                            local row = byk[k]
                            if not row then
                                row = { from = fn, to = h.n.id, key = h.path, band = b.point, profile = h.P.band.point,
                                    tier = 'stdlib', at = {} }
                                byk[k] = row
                                rows[#rows + 1] = row
                            end
                            local line = cv.get(i, 'line')
                            row.at[#row.at + 1] = cv.get(i, 'at') or { start = { line = line, char = 0 }, ['end'] = { line = line, char = 0 } }
                        elseif #hits > 1 then
                            misses[#misses + 1] = { band = b.point, fn = fn, callee = cv.get(i, 'callee'), why = 'ambiguous',
                                candidates = #hits }
                        elseif fn then
                            misses[#misses + 1] = { band = b.point, fn = fn, callee = cv.get(i, 'callee'),
                                why = 'no export of a shared band names it' }
                        end
                    end
                end
            end
        end
    end
    table.sort(rows, function (a, c) return (a.band .. a.from .. a.to) < (c.band .. c.from .. c.to) end)
    local out = { rows = rows, misses = misses }
    cache[ns] = out
    return out
end

return M
