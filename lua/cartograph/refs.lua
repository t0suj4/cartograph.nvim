-- The reference layer (pure). Node IDS embed line numbers and never leave
-- the session; anything durable — pins, staged plans, journals — holds a
-- REF instead and resolves it at use time:
--
--   ref = { file, kind, name, ordinal?, witness? }
--
-- The WITNESS is the clone detector's insight reused as identity evidence:
-- df shape + param count + callee set — insensitive to renames and moves,
-- sensitive to what the function does. It disambiguates reordered
-- same-named siblings, detects probable renames (offered, never assumed),
-- and lets a transaction verify at commit time that what it staged still
-- looks like what it staged.
--
-- Resolution policy, edit by edit: edits elsewhere survive; body edits
-- survive with a drift note; renames break by name and recover by witness
-- WITH a note; true clones (identical witnesses) refuse loudly; deletion
-- is 'missing', which is the truth.

local M = {}

--- Behavior witness for a node: a small stable hash over df shape,
--- param count and callee names. nil when the node has no data flow
--- (blocks, vars — those fall back to name resolution).
---@param node table
---@param callees string[]?  callee names of this node's calls
function M.witness(node, callees)
    local dfa = require 'cartograph.df'
    if not dfa.present(node) then return nil end
    local sig = { tostring(#(node.params or {})) }
    for _, st in ipairs(dfa.stmts(node)) do
        local deps = {}
        for _, d in ipairs(st.dep or {}) do deps[#deps + 1] = d.from end
        table.sort(deps)
        sig[#sig + 1] = ('%d/%d/%s'):format(
            #(st.def or {}), #(st.use or {}), table.concat(deps, ','))
    end
    local cs = {}
    for _, x in ipairs(callees or {}) do cs[#cs + 1] = x end
    table.sort(cs)
    sig[#sig + 1] = table.concat(cs, ',')
    local s = table.concat(sig, ';')
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return ('%08x'):format(h)
end

--- Build the ref for a node. `siblings` = same-file nodes of the same
--- kind and name (including the node itself); an ordinal is only present
--- when there is more than one.
function M.of(node, siblings, callees)
    local ordinal
    if siblings and #siblings > 1 then
        local sorted = {}
        for _, s in ipairs(siblings) do sorted[#sorted + 1] = s end
        table.sort(sorted, function (a, b) return (a.order or 0) < (b.order or 0) end)
        for i, s in ipairs(sorted) do
            if s.id == node.id then ordinal = i break end
        end
    end
    return { file = node.file, kind = node.kind, name = node.name,
        ordinal = ordinal, witness = M.witness(node, callees) }
end

--- Resolve a ref against candidate nodes. `ctx.callees(node)` supplies
--- callee names; `ctx.all` (optional) enables rename recovery over the
--- ref's whole file. Returns (id, note?) or (nil, why).
--- note = nil is a clean resolve; 'witness drifted…' and 'renamed?…'
--- are for the caller to judge.
function M.resolve(ref, candidates, ctx)
    ctx = ctx or {}
    local callees = ctx.callees or function () return nil end
    local cands = {}
    for _, n in ipairs(candidates or {}) do
        if n.file == ref.file and n.kind == ref.kind and n.name == ref.name then
            cands[#cands + 1] = n
        end
    end
    if #cands == 0 then
        -- rename succession: same file and kind, any name, UNIQUE witness
        if ref.witness and ctx.all then
            local hit
            for _, n in ipairs(ctx.all) do
                if n.file == ref.file and n.kind == ref.kind
                    and M.witness(n, callees(n)) == ref.witness then
                    if hit then hit = false break end
                    hit = n
                end
            end
            if hit then
                return hit.id, ("renamed? now '%s'"):format(hit.name)
            end
        end
        return nil, 'missing'
    end
    if #cands == 1 then
        local w = ref.witness and M.witness(cands[1], callees(cands[1]))
        return cands[1].id,
            (ref.witness and w and w ~= ref.witness)
                and 'witness drifted (body changed)' or nil
    end
    -- several same-named siblings: the witness picks; identical witnesses
    -- (true clones) fall through to the ordinal; still tied -> refuse
    if ref.witness then
        local hit
        for _, n in ipairs(cands) do
            if M.witness(n, callees(n)) == ref.witness then
                if hit then hit = false break end
                hit = n
            end
        end
        if hit then return hit.id end
    end
    if ref.ordinal then
        table.sort(cands, function (a, b) return (a.order or 0) < (b.order or 0) end)
        if cands[ref.ordinal] then
            return cands[ref.ordinal].id, 'by ordinal (witnesses inconclusive)'
        end
    end
    return nil, ('ambiguous: %d same-named candidates'):format(#cands)
end

return M
