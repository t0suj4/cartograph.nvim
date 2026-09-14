-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 2 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local at, subst =
    SHARED.at, SHARED.subst

--- replay one recorded edit on the template it was recorded against
function M.replay_edit(T, op)
    if op.op == 'pin' then return M.pin(T, op.h, op.value)
    elseif op.op == 'open' then return M.open_hole(T, op.h)
    elseif op.op == 'dig' then return M.dig(T, op.path, op.h, op.domain)
    elseif op.op == 'merge' then return M.merge(T, op.h, op.into)
    elseif op.op == 'split' then return M.split(T, op.h, op.site, op.new)
    elseif op.op == 'rewrite' then return M.rewrite(T, op.path, op.sub)
    elseif op.op == 'join' then
        local r, why = M.join(T, op.with)
        return r and r.template, why
    end
    return nil, 'unknown edit ' .. tostring(op.op)
end

--- one member across one edit. T is the template BEFORE `op`, T2 the one after.
--- Returns V' or nil, why.
function M.migrate_one(T, T2, op, V, env)
    local W = {}
    for k, v in pairs(V) do W[k] = v end
    if op.op == 'pin' then
        if not M.eq(V[op.h], op.value) then return nil, 'pin ' .. op.h .. ': value differs' end
    elseif op.op == 'dig' then
        local unfilled = {}
        W[op.h] = subst(at(T.body, op.path), V, unfilled)
        if next(unfilled) then return nil, 'dig ' .. op.h .. ': member lacks a value under the dug subtree' end
    elseif op.op == 'merge' then
        if not M.eq(V[op.h], V[op.into]) then
            return nil, 'merge ' .. op.h .. '/' .. op.into .. ': values differ'
        end
        W[op.into] = nil
    elseif op.op == 'split' then
        W[op.new] = M.copy(V[op.h])
    elseif op.op == 'rewrite' then
        -- the fixed part changed and the hole set did not (rewrite refuses to discard):
        -- values are carried unchanged and every member's instance moves by the same
        -- fixed delta. This is the one edit whose purpose is to change the instances.
    elseif op.op == 'join' then
        -- the template moved up to admit a newcomer; this member's values follow by the
        -- join's own left map (kept by name, split copied, swallowed fragments rendered)
        local r, why = M.join(T, op.with)
        if not r then return nil, 'join: ' .. why end
        local W2, err = r.left(V)
        if not W2 then return nil, 'join: ' .. err end
        W = W2
    end
    local H = M.sites(T2)
    for h in pairs(W) do if not H[h] then W[h] = nil end end -- swallowed by a dig
    local r = M.instantiate(T2, W, env)
    if not r.ok then
        local why = {}
        if #r.rejected > 0 then why[#why + 1] = 'domain refuses ' .. table.concat(r.rejected, '; ') end
        if #r.unfilled > 0 then why[#why + 1] = 'no value for ' .. table.concat(r.unfilled, ', ') end
        if #r.extra > 0 then why[#why + 1] = 'value without a site ' .. table.concat(r.extra, ', ') end
        return nil, op.op .. ' ' .. op.h .. ': ' .. table.concat(why, '; ')
    end
    return W
end

--- the family follows T0 to T1 along the edits T1 recorded beyond T0's.
--- Returns { template, values = {[i]=V'}, kept = {i..}, dropped = {{i, edit, op, why}..} }.
function M.migrate(T0, T1, Vs, env, Ps)
    local T = T0
    local cur, alive, dropped, prov = {}, {}, {}, {}
    for i, V in ipairs(Vs) do cur[i], alive[i] = V, true end
    for k = #T0.edits + 1, #T1.edits do
        local op = T1.edits[k]
        local T2, err = M.replay_edit(T, op)
        if not T2 then return nil, 'edit ' .. k .. ': ' .. err end
        for i = 1, #Vs do
            if alive[i] then
                local W, why = M.migrate_one(T, T2, op, cur[i], env)
                if W then
                    if Ps and Ps[i] then prov[i] = M.migrate_provenance(op, cur[i], W, prov[i] or Ps[i]) end
                    cur[i] = W
                else
                    alive[i] = false
                    dropped[#dropped + 1] = { i = i, edit = k, op = op.op, why = why }
                end
            end
        end
        T = T2
    end
    if not M.eq(T.body, T1.body) then return nil, 'T1 is not T0 plus its recorded edits' end
    local kept, values, stamped, provenance = {}, {}, {}, {}
    for i = 1, #Vs do
        if alive[i] then
            kept[#kept + 1] = i; values[i] = cur[i]
            if Ps and Ps[i] then provenance[i] = prov[i] or Ps[i] end
        end
    end
    -- derived domains follow the column: a dig without a domain gets its summary here, and a
    -- pin-then-open returns to the column's sort rather than to the old record
    T = M.rederive_domains(M.copy(T), values)
    for i = 1, #Vs do if alive[i] then stamped[i] = M.stamp(T, cur[i]) end end -- valid for T1 at its edit position
    return { template = T, values = values, kept = kept, dropped = dropped, stamped = stamped, provenance = provenance }
end
end
