-- Refactor-neutrality checker (bench-banked tool): diff each function's BEHAVIOR
-- WITNESS (refs.witness — df shape + param count + callee names, a hash independent
-- of file and line) between two graph states. A pure MOVE / extract-module relocates a
-- function without touching its body → its witness is unchanged → CERTIFIED NEUTRAL. A
-- function whose witness DRIFTED had its body changed — a rewrite, not a move — and is
-- surfaced for review. Functions gone/appeared are reported; a gone↔appeared pair
-- sharing one witness is recovered as a RENAME (also body-neutral).
--
-- SCOPE (honest, from the banked note): this certifies MOVES, not REWRITES. An
-- accessor-migration or an extract-HELPER legitimately changes a body (A becomes a
-- tail-call wrapper) → it drifts, correctly. Use it to prove a relocation changed no
-- behavior; a drift on a refactor you intended as a pure move is a real red flag.
-- The witness is keyed by NAME (move-stable, unlike the file::name@line id); a
-- name shared by several functions compares as a witness MULTISET.

local M = {}
local refs = require 'cartograph.refs'
local callrec = require 'cartograph.callrec'

local function callees_of(store, id)
    local out = {}
    for _, c in ipairs(store.topo():sites(id) or {}) do
        local ce = callrec.callee(c)
        if ce then out[#out + 1] = ce end
    end
    return out
end

--- Witness-map of a live store: name → { ws = {sorted witness hashes}, files = {…} }.
--- Only functions/methods with a data-flow witness participate (blocks/vars have none).
function M.witnesses(store)
    local map = {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.name then
            local w = refs.witness(n, callees_of(store, n.id))
            if w then
                local e = map[n.name]
                if not e then e = { ws = {}, files = {}, seenf = {} }; map[n.name] = e end
                e.ws[#e.ws + 1] = w
                if n.file and not e.seenf[n.file] then
                    e.seenf[n.file] = true; e.files[#e.files + 1] = n.file
                end
            end
        end
    end
    for _, e in pairs(map) do table.sort(e.ws); table.sort(e.files); e.seenf = nil end
    return map
end

local function eq_multiset(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

--- Compare two witness-maps (before → after). Returns
--- { neutral = {name…}, drifted = {{name,before,after,files}…},
---   removed = {{name,ws,files}…}, added = {{name,ws,files}…},
---   renamed = {{from,to,witness}…} }.
function M.compare(before, after)
    local out = { neutral = {}, drifted = {}, removed = {}, added = {}, renamed = {} }
    for name, be in pairs(before) do
        local ae = after[name]
        if not ae then
            out.removed[#out.removed + 1] = { name = name, ws = be.ws, files = be.files }
        elseif eq_multiset(be.ws, ae.ws) then
            out.neutral[#out.neutral + 1] = name
        else
            out.drifted[#out.drifted + 1] = { name = name,
                before = be.ws, after = ae.ws, files = ae.files }
        end
    end
    for name, ae in pairs(after) do
        if not before[name] then
            out.added[#out.added + 1] = { name = name, ws = ae.ws, files = ae.files }
        end
    end
    -- RENAME recovery: a removed name and an added name that each have exactly ONE
    -- witness, and it's the same, is a body-neutral rename (the witness survived).
    local added_by_w = {}
    for i, a in ipairs(out.added) do
        if #a.ws == 1 then
            added_by_w[a.ws[1]] = added_by_w[a.ws[1]] or {}
            table.insert(added_by_w[a.ws[1]], i)
        end
    end
    local drop_removed, drop_added = {}, {}
    for ri, r in ipairs(out.removed) do
        if #r.ws == 1 then
            local cands = added_by_w[r.ws[1]]
            -- unambiguous only: exactly one removed and one added at this witness
            if cands and #cands == 1 and not drop_added[cands[1]] then
                out.renamed[#out.renamed + 1] = { from = r.name,
                    to = out.added[cands[1]].name, witness = r.ws[1] }
                drop_removed[ri] = true; drop_added[cands[1]] = true
            end
        end
    end
    local function compact(list, drop)
        local keep = {}
        for i, v in ipairs(list) do if not drop[i] then keep[#keep + 1] = v end end
        return keep
    end
    out.removed = compact(out.removed, drop_removed)
    out.added = compact(out.added, drop_added)
    table.sort(out.neutral)
    table.sort(out.drifted, function (a, b) return a.name < b.name end)
    return out
end

-- an in-memory snapshot per root — captured before a refactor, compared after.
-- (In-session: the txn re-splices the live graph, so the snapshot→refactor→check
-- loop needs no disk. Cross-commit persistence is the banked follow-on.)
M._snap = {}

--- Capture the current witnesses as the baseline for `store`'s root. Returns the count.
function M.snapshot(store)
    local m = M.witnesses(store)
    M._snap[store.data.root] = m
    local n = 0
    for _ in pairs(m) do n = n + 1 end
    return n
end

--- Compare the current graph against the snapshot. Returns (compare, nil) or (nil, why).
function M.check(store)
    local before = M._snap[store.data.root]
    if not before then
        return nil, 'no baseline — run :CartographNeutralitySnapshot before the refactor'
    end
    return M.compare(before, M.witnesses(store))
end

--- Human-readable report of a compare result.
function M.report(cmp)
    local L = {
        ('refactor-neutrality — %d neutral · %d DRIFTED · %d renamed · %d removed · %d added')
            :format(#cmp.neutral, #cmp.drifted, #cmp.renamed, #cmp.removed, #cmp.added),
        '(neutral = body-witness unchanged, i.e. a pure move; DRIFTED = the body changed'
            .. ' — a rewrite, review it)', '' }
    if #cmp.drifted == 0 and #cmp.removed == 0 then
        L[#L + 1] = '✓ every surviving function is behavior-neutral (certified move)'
    end
    for _, d in ipairs(cmp.drifted) do
        L[#L + 1] = ('⚠ DRIFTED  %s   (%s)'):format(d.name, table.concat(d.files, ', '))
    end
    for _, r in ipairs(cmp.renamed) do
        L[#L + 1] = ('~ renamed  %s → %s   (witness preserved)'):format(r.from, r.to)
    end
    for _, r in ipairs(cmp.removed) do
        L[#L + 1] = ('- removed  %s   (%s)'):format(r.name, table.concat(r.files, ', '))
    end
    for _, a in ipairs(cmp.added) do
        L[#L + 1] = ('+ added    %s   (%s)'):format(a.name, table.concat(a.files, ', '))
    end
    return L
end

return M
