-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 2 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local is_hole, subst =
    SHARED.is_hole, SHARED.subst

-- ── composition ───────────────────────────────────────────────────────────────
--- fill hole h of T with template T2 (T2's holes are renamed h.<name> on clash)
function M.fill(T, h, T2)
    local rename = {}
    for _, g in ipairs(M.hole_names(T2)) do
        rename[g] = (T.holes[g] and g ~= h) and (h .. '.' .. g) or g
    end
    local function ren(t)
        if is_hole(t) then return M.hole(rename[t.h], t.rep) end
        if not t.kids then return M.copy(t) end
        local kids = {}
        for i, c in ipairs(t.kids) do kids[i] = ren(c) end
        return M.rebuild(t, kids)
    end
    local body = subst(T.body, { [h] = ren(T2.body) }, {})
    local domains = {}
    for g, e in pairs(T.holes) do if g ~= h then domains[g] = M.copy(e) end end
    for g, e in pairs(T2.holes) do domains[rename[g]] = M.copy(e) end
    return M.template(body, domains)
end

--- the generality order: T1 is an instance of T2 iff some substitution takes T2 to T1
function M.instance_of(T1, T2, env)
    return M.match(T2, T1.body, { defs = env and env.defs, hole_domains = T1.holes }).ok
end
end
