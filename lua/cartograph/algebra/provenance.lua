-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 2 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local derived, key =
    SHARED.derived, SHARED.key

-- ── provenance beside values: observed | derived | supplied (CHARTER.md) ─────────────
--- P[h] = { src, via = {..}, journal = record | nil }. Kept BESIDE V, keyed by hole, never
--- inside the term (the side-channel decision). `observed` is read from an instance by
--- match; `derived` is computed by a total function (migrate, join, dig); `supplied` is a
--- premise a person or rule chose and needs a journal entry. A supplied value that passes
--- through migrate or join STAYS supplied: laundering it into observed is the charter's
--- fabrication failure.
function M.observed(V, sites)
    local P = {}
    for h in pairs(V) do P[h] = { src = 'observed', via = { sites and sites[h] and sites[h].sites and sites[h].sites[1] and key(sites[h].sites[1].path) or 'match' } } end
    return P
end

function M.supplied(h, journal, P)
    P = P or {}
    P[h] = { src = 'supplied', via = { 'operator' }, journal = journal }
    return P
end

function M.carry(p, via)
    if not p then return nil end
    local q = { src = p.src, via = {}, journal = p.journal }
    for _, v in ipairs(p.via or {}) do q.via[#q.via + 1] = v end
    q.via[#q.via + 1] = via
    return q
end

--- provenance for migrated values: a value equal to what the member had under the same
--- hole is carried; split's copy carries the source hole's; anything else was computed.
function M.migrate_provenance(op, V, W, P)
    local Q = {}
    for h, w in pairs(W) do
        if P and P[h] and V[h] ~= nil and M.eq(V[h], w) then Q[h] = M.carry(P[h], 'migrate:' .. op.op)
        elseif op.op == 'split' and h == op.new and P and P[op.h] then Q[h] = M.carry(P[op.h], 'migrate:split')
        else Q[h] = derived('migrate:' .. op.op) end
    end
    return Q
end

--- Emission is the line between verified span surgery and authoring: every value must
--- carry a provenance, a supplied value must carry its journal entry, and the reader
--- verifies the writer (match reads the emitted instance back).
function M.emit(T, V, P, env)
    for h in pairs(V) do
        local p = P and P[h]
        if not p then return { ok = false, absence = 'refused', why = 'hole ' .. h .. ': a value with no provenance is authoring' } end
        if p.src == 'supplied' and not p.journal then return { ok = false, absence = 'refused', why = 'hole ' .. h .. ': a supplied value without a journal entry' } end
        if p.src ~= 'observed' and p.src ~= 'derived' and p.src ~= 'supplied' then return { ok = false, absence = 'refused', why = 'hole ' .. h .. ': unknown provenance ' .. tostring(p.src) } end
    end
    local r = M.instantiate(T, V, env)
    if not r.ok then return { ok = false, absence = M.absence_of(r).absence, why = 'does not instantiate' } end
    local m = M.match(T, r.term, env)
    if not m.ok then return { ok = false, absence = 'refused', why = 'the reader does not verify the writer: ' .. m.refusal.why } end
    return { ok = true, term = r.term, verified = true }
end
end
