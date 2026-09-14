-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ This part reaches back for NOTHING: a section boundary that is also a
-- dependency boundary.
return function (M, SHARED)
local _ = SHARED

-- ── validity key: values are valid for a template at a position in its edit log ────────
--- A stored V is a derivation from T as it was; the edit log index is the key the charter
--- demands ("nothing persists across a boundary without a validity key"). Scoped to the
--- template's own history; the source generation key is cartograph's validity.lua.
function M.edit_key(T)
    local parts = {}
    for i, op in ipairs(T.edits or {}) do
        local ks = {}
        for k in pairs(op) do ks[#ks + 1] = k end
        table.sort(ks)
        local fs = {}
        for _, k in ipairs(ks) do
            local v = op[k]
            if type(v) == 'table' and v.k then fs[#fs + 1] = k .. '=' .. M.show(v)
            elseif type(v) == 'table' and v.body then fs[#fs + 1] = k .. '=' .. M.show(v.body)
            elseif type(v) == 'table' then fs[#fs + 1] = k .. '=' .. table.concat(v, '.')
            else fs[#fs + 1] = k .. '=' .. tostring(v) end
        end
        parts[i] = table.concat(fs, ',')
    end
    return #parts .. ':' .. table.concat(parts, ';')
end

function M.stamp(T, V) return { values = V, at = #(T.edits or {}), key = M.edit_key(T) } end

function M.valid(T, S)
    if type(S) ~= 'table' or S.key == nil then return false, 'unstamped values are a guess wearing a cache\'s clothes' end
    if S.key ~= M.edit_key(T) then return false, ('stale: stamped at edit %d, template is at edit %d'):format(S.at or -1, #(T.edits or {})) end
    return true
end

--- instantiate from stamped values: a stale stamp is `unavailable` (the value class for
--- this generation was never extracted), never a silent fill.
function M.instantiate_stamped(T, S, env)
    local ok, why = M.valid(T, S)
    if not ok then return { ok = false, absence = 'unavailable', why = why } end
    return M.instantiate(T, S.values, env)
end
end
