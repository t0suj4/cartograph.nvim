-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ `child`, `is_hole` and `key` are the file-locals this section reaches back
-- for; the plan's capture hazards named two of them and the free-identifier
-- scan (zero on every part already adapted) found the third.
return function (M, S)
local child, is_hole, key = S.child, S.is_hole, S.key

function M.is_absence(name) return M.ABSENCE[name] ~= nil end

local function absence(name, at, why, extra)
    assert(M.ABSENCE[name], 'undeclared absence: ' .. tostring(name)) -- CART-0831: the set is a table
    local a = { absence = name, at = at, why = why, licenses = M.ABSENCE[name].licenses }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end

function M.worst_tier(tiers)
    local worst
    for _, t in ipairs(tiers) do
        local r = RUNG_RANK[t] or #M.RUNGS + 1 -- an unknown tier is weaker than any known one
        if not worst or r > RUNG_RANK[worst] then worst = (RUNG_RANK[t] and t) or 'frontier' end
    end
    return worst
end

local KIND_OF = { mod = 'module', def = 'function', ['local'] = 'var', block = 'region' }

local SITE_OF = { call = 'ref', use = 'use' }

local DEF_FOR = { ref = 'function', use = 'var' }

local function prefix_of(p, q) -- p ancestor-or-equal of q
    if #p > #q then return false end
    for i = 1, #p do if p[i] ~= q[i] then return false end end
    return true
end

local function under_any(paths, q) for _, p in ipairs(paths) do if prefix_of(p, q) then return p end end end

-- walk a body: nodes at their positions, sites (call/use) with their scope, hole places
local function mat_walk(body)
    local nodes, sites, places, order = {}, {}, {}, {}
    local function name_of(x)
        if type(x) ~= 'table' then return nil end
        if is_hole(x) then return nil, x.h end
        return x.n or x.v
    end
    local function walk(t, path, scope)
        if is_hole(t) then -- a hole at a node position is still a PLACE: a region with a hole field
            local id = key(path)
            nodes[id] = { id = id, kind = 'region', hole = t.h, range = path }
            order[#order + 1] = id
            places[#places + 1] = { h = t.h, path = path, id = id }
            return
        end
        if type(t) ~= 'table' or not t.kids then return end
        if KIND_OF[t.k] then
            local id = key(path)
            local n = { id = id, kind = KIND_OF[t.k], range = path }
            local from = 1
            if t.k == 'def' or t.k == 'local' then
                local nm, h = name_of(t.kids[1])
                n.name, n.hole = nm, h
                from = 2
            end
            nodes[id] = n
            order[#order + 1] = id
            for i = from, #t.kids do walk(t.kids[i], child(path, i), id) end
            return
        end
        if SITE_OF[t.k] then
            local nm, h = name_of(t.kids[1])
            sites[#sites + 1] = { from = scope, kind = SITE_OF[t.k], at = path, name = nm, hole = h }
            for i = 2, #t.kids do walk(t.kids[i], child(path, i), scope) end
            return
        end
        for i, c in ipairs(t.kids) do walk(c, child(path, i), scope) end
    end
    walk(body, {}, nil)
    return nodes, sites, places, order
end

local function resolve_ground(nodes, sites)
    local edges, absences = {}, {}
    local defs = {}
    for id, n in pairs(nodes) do
        if n.name then
            defs[n.kind] = defs[n.kind] or {}
            defs[n.kind][n.name] = defs[n.kind][n.name] or {}
            table.insert(defs[n.kind][n.name], id)
        end
    end
    for _, s in ipairs(sites) do
        local cands = defs[DEF_FOR[s.kind]] and defs[DEF_FOR[s.kind]][s.name] or {}
        table.sort(cands)
        if #cands == 1 then
            edges[#edges + 1] = { from = s.from, to = cands[1], kind = s.kind, at = key(s.at), tier = 'linked' }
        elseif #cands > 1 then
            absences[#absences + 1] = absence('refused', key(s.at), 'ambiguous ' .. s.kind .. ' ' .. tostring(s.name), { cands = cands, kind = s.kind, from = s.from })
        else
            absences[#absences + 1] = absence('frontier', key(s.at), 'no definition of ' .. tostring(s.name) .. ' in the term', { kind = s.kind, from = s.from })
        end
    end
    return edges, absences
end

local function edge_key(e) return e.from .. '>' .. e.to .. ':' .. e.kind .. '@' .. e.at end

local function subgraph_key(G, path)
    local ns, es = {}, {}
    for id, n in pairs(G.nodes) do if prefix_of(path, n.range) then ns[#ns + 1] = id .. ':' .. n.kind .. ':' .. tostring(n.name) end end
    for _, e in ipairs(G.edges) do if prefix_of(path, e.atp) then es[#es + 1] = edge_key(e) end end
    for _, a in ipairs(G.absences) do if prefix_of(path, a.atp) then es[#es + 1] = a.absence .. '@' .. a.at end end
    table.sort(ns); table.sort(es)
    return table.concat(ns, ' ') .. ' | ' .. table.concat(es, ' ')
end

local function split_key(k) local p = {}; if k == 'root' then return p end; for s in k:gmatch('[^/]+') do p[#p + 1] = tonumber(s) end; return p end

--- Materialize a term, or a template with its family, onto the closed schema.
--- Returns { nodes = {id -> node}, order, edges, absences }. For a template, every fact
--- that depends on a hole's value is either STATED because every member of the family
--- agrees on it (tier = the worst member's, prov = 'derived', via = 'family'), or a typed
--- absence: `refused` with the distinct member answers as candidates when they disagree,
--- `unavailable` when there is no family to read (the value class was never extracted).
--- ⚠ Once the body has ANY hole, every site is read through the family, including sites
--- whose fixed name has a fixed definition: in this toy a statement hole may hold a
--- competing definition and a name-hole def may take that very name, so no resolution is
--- provably hole-independent. Sound-first, and the price is over-hedging: a fully fixed
--- edge in a template with no family reads `unavailable`. Only a ground term is read off
--- the body directly.
function M.materialize(t, opts)
    opts = opts or {}
    local T = t.body and t or nil
    local body = T and T.body or t
    if not T and M.hole_names(M.template(body))[1] then T = M.template(body) end -- a bare term with holes: open domains
    local nodes, sites, places, order = mat_walk(body)
    local G = { nodes = nodes, order = order, edges = {}, absences = {} }
    local function finish()
        for _, e in ipairs(G.edges) do e.atp = split_key(e.at) end
        for _, a in ipairs(G.absences) do a.atp = split_key(a.at) end
        return G
    end
    local hedged = #places > 0
    for id, n in pairs(nodes) do if n.hole then hedged = true end end
    for _, s in ipairs(sites) do if s.hole then hedged = true end end
    if not hedged then
        G.edges, G.absences = resolve_ground(nodes, sites)
        return finish()
    end
    -- the hedged case: read the family
    local members = {}
    for i, V in ipairs(opts.family or {}) do
        local r = M.instantiate(T, V, opts.env)
        if r.ok then members[#members + 1] = M.materialize(r.term) end
    end
    local hole_paths = {}
    for _, p in ipairs(places) do hole_paths[#hole_paths + 1] = p.path end
    -- 1. sites at fixed positions: the fact is the family's answer at that path
    for _, s in ipairs(sites) do
        local at = key(s.at)
        if #members == 0 then
            G.absences[#G.absences + 1] = absence('unavailable', at, 'no family to read the ' .. s.kind .. ' at this site', { kind = s.kind, from = s.from, hole = s.hole })
        else
            local targets, seen, absent_in, tiers = {}, {}, 0, {}
            for _, m in ipairs(members) do
                local hit
                for _, e in ipairs(m.edges) do if e.at == at then hit = e end end
                if hit then
                    if not seen[hit.to] then seen[hit.to] = true; targets[#targets + 1] = hit.to end
                    tiers[#tiers + 1] = hit.tier
                else absent_in = absent_in + 1 end
            end
            table.sort(targets)
            local to = targets[1]
            if #targets == 1 and absent_in == 0 and not under_any(hole_paths, split_key(to)) then
                -- stated with the WEAKEST member tier: a family never knows more than its members
                G.edges[#G.edges + 1] = { from = s.from, to = to, kind = s.kind, at = at, tier = M.worst_tier(tiers), prov = 'derived', via = 'family' }
            elseif #targets >= 1 then
                G.absences[#G.absences + 1] = absence('refused', at, 'the family answers differently at this site', { cands = targets, kind = s.kind, from = s.from, missing_in = absent_in })
            else
                -- every member is silent here too: the members' own absence, the least
                -- licensing one wins, and refused keeps the union of the members' candidates
                local rank = { absent = 1, refused = 2, frontier = 3, unavailable = 4, unbuilt = 5 }
                local worst, cands, seenc = 'absent', {}, {}
                for _, m in ipairs(members) do
                    for _, a in ipairs(m.absences) do
                        if a.at == at then
                            if rank[a.absence] > rank[worst] then worst = a.absence end
                            for _, c in ipairs(a.cands or {}) do if not seenc[c] then seenc[c] = true; cands[#cands + 1] = c end end
                        end
                    end
                end
                table.sort(cands)
                G.absences[#G.absences + 1] = absence(worst, at, 'every member is silent at this site', { kind = s.kind, from = s.from, cands = #cands > 0 and cands or nil })
            end
        end
    end
    -- 2. hole places: the inner subgraph is stated only when every member agrees on it
    for _, p in ipairs(places) do
        local at = key(p.path)
        if #members == 0 then
            G.absences[#G.absences + 1] = absence('unavailable', at, 'no family to read hole ' .. p.h, { hole = p.h })
        else
            local keys, distinct = {}, {}
            for _, m in ipairs(members) do
                local k = subgraph_key(m, p.path)
                if not keys[k] then keys[k] = true; distinct[#distinct + 1] = k end
            end
            if #distinct == 1 then
                local m = members[1]
                for _, id in ipairs(m.order) do
                    local n = m.nodes[id]
                    if prefix_of(p.path, n.range) and not nodes[id] then
                        local c = M.copy(n); c.prov, c.via = 'derived', 'family'
                        nodes[id] = c; order[#order + 1] = id
                    end
                end
                for _, e in ipairs(m.edges) do
                    if prefix_of(p.path, e.atp) then
                        local c = { from = e.from, to = e.to, kind = e.kind, at = e.at, tier = e.tier, prov = 'derived', via = 'family' }
                        G.edges[#G.edges + 1] = c
                    end
                end
                for _, a in ipairs(m.absences) do
                    if prefix_of(p.path, a.atp) then local c = M.copy(a); c.atp = nil; G.absences[#G.absences + 1] = c end
                end
            else
                table.sort(distinct)
                G.absences[#G.absences + 1] = absence('refused', at, 'the members disagree inside hole ' .. p.h, { cands = distinct, hole = p.h })
            end
        end
    end
    return finish()
end

--- the schema check the charter carries as an executable claim: kinds by name only
function M.on_schema(G)
    for _, n in pairs(G.nodes) do if not M.NODE_KINDS[n.kind] then return false, 'node kind ' .. tostring(n.kind) end end
    for _, e in ipairs(G.edges) do
        if not M.EDGE_KINDS[e.kind] then return false, 'edge kind ' .. tostring(e.kind) end
        if not (G.nodes[e.from] and G.nodes[e.to]) then return false, 'dangling edge ' .. e.from .. '>' .. e.to end
    end
    for _, a in ipairs(G.absences) do if not M.ABSENCE[a.absence] then return false, 'absence ' .. tostring(a.absence) end end
    return true
end
end
