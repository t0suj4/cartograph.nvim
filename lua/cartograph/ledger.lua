-- Ledger reconstruction (pure). Given two graph snapshots, describe the
-- structural change between them as a delta: which named symbols were added,
-- removed, or renamed, and how the reference edges changed. A sequence of
-- snapshots (e.g. one graph per git commit) becomes a reconstructed ledger — the
-- inverse of the ImpactEngine: instead of predicting a move's edits, it recovers
-- what a series of edits actually did to the structure.
--
-- Identity across snapshots is (file, name, kind), NOT the node id — ids embed a
-- line number and shift as code moves, so they can't be matched across versions.

local M = {}

local function is_fn(n) return n.kind ~= 'module' end
local function key(n) return n.file .. '::' .. n.name .. '/' .. n.kind end

-- short display name from a key "file::name/kind"
function M.short(k) return (k:gsub('^.*::', ''):gsub('/[^/]*$', '')) end

-- index a snapshot: named nodes by key, ref edges keyed by endpoint *names*
-- (stable across id churn), and each node's neighbour-name set (for renames).
local function index(g)
    local id2n, nodes, nbr, edges = {}, {}, {}, {}
    for _, n in ipairs(g.nodes or {}) do
        id2n[n.id] = n
        if is_fn(n) then nodes[key(n)] = n end
    end
    for _, e in ipairs(g.edges or {}) do
        if e.kind == 'ref' then
            local f, t = id2n[e.from], id2n[e.to]
            if f and t then
                edges[f.name .. '\31' .. t.name] = true
                if is_fn(f) then nbr[key(f)] = nbr[key(f)] or {}; nbr[key(f)][t.name] = true end
                if is_fn(t) then nbr[key(t)] = nbr[key(t)] or {}; nbr[key(t)][f.name] = true end
            end
        end
    end
    return { nodes = nodes, nbr = nbr, edges = edges }
end

local function sorted(set)
    local o = {}
    for k in pairs(set) do o[#o + 1] = k end
    table.sort(o)
    return o
end

--- Structural delta from `before` to `after`.
function M.delta(before, after)
    local B, A = index(before), index(after)
    local added, removed = {}, {}
    for k in pairs(A.nodes) do if not B.nodes[k] then added[k] = true end end
    for k in pairs(B.nodes) do if not A.nodes[k] then removed[k] = true end end

    -- rename heuristic: within one (file,kind) bucket, a lone removed + lone
    -- added is treated as a rename. Deliberately conservative — small commits do
    -- one rename at a time; we don't guess multi-renames (they stay add+remove).
    local function bucket(set, idx)
        local b = {}
        for k in pairs(set) do
            local n = idx.nodes[k]
            local bk = n.file .. '/' .. n.kind
            b[bk] = b[bk] or {}
            b[bk][#b[bk] + 1] = k
        end
        return b
    end
    local ba, br = bucket(added, A), bucket(removed, B)
    local renamed = {}
    for bk, rlist in pairs(br) do
        local alist = ba[bk]
        if alist and #rlist == 1 and #alist == 1 then
            renamed[#renamed + 1] = { from = rlist[1], to = alist[1] }
            removed[rlist[1]] = nil
            added[alist[1]] = nil
        end
    end
    table.sort(renamed, function (a, b) return a.from < b.from end)

    local e_add, e_del = {}, 0
    for e in pairs(A.edges) do if not B.edges[e] then e_add[#e_add + 1] = e end end
    for e in pairs(B.edges) do if not A.edges[e] then e_del = e_del + 1 end end
    table.sort(e_add)

    return {
        added = sorted(added),
        removed = sorted(removed),
        renamed = renamed,
        edges_added = #e_add,
        edges_removed = e_del,
        edges_added_list = e_add,
    }
end

--- One-word operation guess for a delta.
function M.classify(d)
    local a, r, rn = #d.added, #d.removed, #d.renamed
    if a == 0 and r == 0 and rn == 0 then
        return (d.edges_added > 0 or d.edges_removed > 0) and 'rewire' or 'internal'
    end
    if rn > 0 and a == 0 and r == 0 then return 'rename' end
    if a > 0 and r == 0 then return 'extract' end
    if a == 0 and r > 0 then return 'inline' end
    return 'restructure'
end

--- Reconstruct a ledger from a sequence of snapshots (oldest → newest). `labels`
--- is a parallel list; labels[i] describes the change *into* snapshot i.
function M.reconstruct(graphs, labels)
    local steps = {}
    for i = 2, #graphs do
        local d = M.delta(graphs[i - 1], graphs[i])
        steps[#steps + 1] = { label = labels and labels[i] or ('#' .. i), delta = d, op = M.classify(d) }
    end
    return steps
end

--- Render a reconstructed ledger to display lines.
function M.render(steps)
    local lines = {}
    for _, s in ipairs(steps) do
        local d, bits = s.delta, {}
        if #d.added > 0 then bits[#bits + 1] = '+' .. #d.added end
        if #d.removed > 0 then bits[#bits + 1] = '-' .. #d.removed end
        if #d.renamed > 0 then bits[#bits + 1] = '~' .. #d.renamed end
        if d.edges_added > 0 or d.edges_removed > 0 then
            bits[#bits + 1] = ('e+%d/-%d'):format(d.edges_added, d.edges_removed)
        end
        lines[#lines + 1] = ('[%-11s] %-14s %s'):format(s.op, table.concat(bits, ' '), s.label)
        for _, k in ipairs(d.added)   do lines[#lines + 1] = '        + ' .. M.short(k) end
        for _, k in ipairs(d.removed) do lines[#lines + 1] = '        - ' .. M.short(k) end
        for _, rn in ipairs(d.renamed) do
            lines[#lines + 1] = '        ~ ' .. M.short(rn.from) .. ' -> ' .. M.short(rn.to)
        end
    end
    return lines
end

return M
