-- REORDER: statement-level commutativity for ONE function — the refactor
-- cockpit's safe-reorder view, composed entirely from shipped facts:
-- df statements (direct reads/defs + local dataflow deps), the fn's use
-- edges (which names are module state), and per-call discharged effect
-- summaries ([[cartograph-write-axis]]). Verdicts per statement PAIR:
--   dep       local dataflow: i defines a local j uses — ordered
--   state     both touch the same module var/field, not both set-once
--   world     both write the world (io) — external order observable
-- Statements with unresolvable effects are OPAQUE: listed with the hedge
-- named, certified for nothing — reads through calls are not modeled
-- (the report says so), so 'free' means free w.r.t. what IS modeled.

local dfa = require 'cartograph.df'
local effects = require 'cartograph.effects'

local M = {}

--- The model for one fn: { stmts, deps, conflicts, free, opaque }.
function M.analyze(store, fn_id)
    local node = store.node(fn_id)
    if not node then return nil, 'no such node' end
    local sts = dfa.stmts(node)
    if #sts == 0 then return nil, 'no statement-level dataflow' end

    -- module-state vocabulary: name -> var id (~: name-matched, as the
    -- use edges themselves are)
    local varkey, edgeinfo = {}, {}
    for _, u in ipairs(store.var_uses[fn_id] or {}) do
        local vn = store.node(u.to)
        if vn and vn.name then
            varkey[vn.name] = u.to
            edgeinfo[u.to] = u
        end
    end

    local function stmt_of(line0)
        local li, best = line0 + 1, nil
        for i = 1, #sts do
            if sts[i].l <= li then best = i else break end
        end
        return best
    end

    -- per-statement effect rows
    local rows = {}
    for i, st in ipairs(sts) do
        rows[i] = { i = i, l = st.l, writes = {}, reads = {}, hedges = nil }
        for _, d in ipairs(st.def) do
            local v = varkey[d]
            if v then
                local u = edgeinfo[v]
                rows[i].writes[v .. '\31'] = (u and u.gw) or 1
            end
        end
        for _, uname in ipairs(st.use) do
            local v = varkey[uname]
            if v then rows[i].reads[v .. '\31'] = true end
        end
    end
    -- call effects land on the statement containing the call site
    for _, c in ipairs(store.topo():sites(fn_id)) do
        local si = c.line and stmt_of(c.line)
        if si then
            local fx = effects.call_effects(store, c, node.file)
            local row = rows[si]
            for key, tier in pairs(fx.w) do
                local cur = row.writes[key]
                if not cur or tier < cur then row.writes[key] = tier end
            end
            if fx.hedges then
                row.hedges = row.hedges or {}
                for _, h in ipairs(fx.hedges) do
                    if #row.hedges < 3 then row.hedges[#row.hedges + 1] = h end
                end
            end
        end
    end

    -- local dataflow dependencies (df.dep: from-stmt defines, this uses)
    local deps = {}
    for j, st in ipairs(sts) do
        for _, d in ipairs(st.dep or {}) do
            if d.from and d.from ~= j then
                deps[#deps + 1] = { d.from, j, ('local %s'):format(d.var or '?') }
            end
        end
    end

    -- pairwise state/world conflicts (n = statement count: small)
    local IOKEY = effects.IOKEY
    local conflicts = {}
    for i = 1, #rows do
        for j = i + 1, #rows do
            local a, b = rows[i], rows[j]
            local hit, kind
            for key, ta in pairs(a.writes) do
                local tb = b.writes[key]
                if tb and not (ta == 3 and tb == 3) then
                    hit, kind = key, key == IOKEY and 'world' or 'state'
                    break
                end
                if key ~= IOKEY and b.reads[key] then
                    hit, kind = key, 'state'
                    break
                end
            end
            if not hit then
                for key in pairs(a.reads) do
                    if b.writes[key] then hit, kind = key, 'state' break end
                end
            end
            if hit then
                conflicts[#conflicts + 1] = { i, j, kind,
                    kind == 'world' and '(world order)'
                        or (hit:gsub('\31', '.'):gsub('%.$', '')) }
            end
        end
    end

    -- free = constrained by nothing modeled; opaque = hedged
    local bound = {}
    for _, d in ipairs(deps) do bound[d[1]], bound[d[2]] = true, true end
    for _, c in ipairs(conflicts) do bound[c[1]], bound[c[2]] = true, true end
    local free, opaque = {}, {}
    for i, row in ipairs(rows) do
        if row.hedges then
            opaque[#opaque + 1] = i
        elseif not bound[i] then
            free[#free + 1] = i
        end
    end
    return { node = node, stmts = rows, deps = deps, conflicts = conflicts,
        free = free, opaque = opaque }
end

--- Render the model as report lines (the scratch-buffer surface).
function M.report(store, fn_id)
    local m, why = M.analyze(store, fn_id)
    if not m then return { 'reorder: ' .. why } end
    local L = {}
    L[#L + 1] = ('reorder: %s — %d statements (reads through calls not modeled)')
        :format(m.node.name or fn_id, #m.stmts)
    L[#L + 1] = ''
    local IOKEY = effects.IOKEY
    for _, row in ipairs(m.stmts) do
        local fx = {}
        for key, tier in pairs(row.writes) do
            if key == IOKEY then
                fx[#fx + 1] = 'world'
            else
                local name = key:gsub('\31', '.'):gsub('%.$', '')
                local vn = store.node(name) -- key head is the var id
                fx[#fx + 1] = ('w:%s%s'):format(
                    (vn and vn.name) or name, tier == 3 and ' (set-once)' or '')
            end
        end
        table.sort(fx)
        L[#L + 1] = ('  #%-3d L%-5d %s%s'):format(row.i, row.l,
            #fx > 0 and table.concat(fx, '  ') or '·',
            row.hedges and ('  ~ ' .. row.hedges[1]) or '')
    end
    if #m.deps + #m.conflicts > 0 then
        L[#L + 1] = ''
        L[#L + 1] = 'ordering constraints:'
        for _, d in ipairs(m.deps) do
            L[#L + 1] = ('  #%d → #%d   %s'):format(d[1], d[2], d[3])
        end
        for _, c in ipairs(m.conflicts) do
            local name = c[4]
            local vn = store.node(name)
            L[#L + 1] = ('  #%d ⚡ #%d  %s: %s'):format(c[1], c[2], c[3],
                (vn and vn.name) or name)
        end
    end
    if #m.free > 0 then
        L[#L + 1] = ''
        L[#L + 1] = 'freely movable (w.r.t. modeled effects): #'
            .. table.concat(m.free, ', #')
    end
    if #m.opaque > 0 then
        L[#L + 1] = 'opaque (unresolved effects — certify nothing): #'
            .. table.concat(m.opaque, ', #')
    end
    return L
end

return M
