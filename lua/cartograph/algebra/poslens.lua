-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 3 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local at, child, is_hole =
    SHARED.at, SHARED.child, SHARED.is_hole

-- ── the position lens: the basis operators the re-derivation pass (REDERIVE.md) builds on ──
--- read the subterm at a path (nil when the path leaves the term)
function M.locate_at(t, path) return at(t, path) end

--- a PURE put: the term with `sub` at `path`, rebuilt along the way (set_at mutates)
function M.put(t, path, sub, i)
    i = i or 1
    if i > #path then return sub end
    local kids = {}
    for j, c in ipairs(t.kids or {}) do kids[j] = (j == path[i]) and M.put(c, path, sub, i + 1) or c end
    return M.rebuild(t, kids)
end

--- every position of a term in preorder, with its subterm: { {path, node}, .. }
function M.positions(t)
    local out = {}
    local function walk(x, path)
        out[#out + 1] = { path = path, node = x }
        for i, c in ipairs(x.kids or {}) do walk(c, child(path, i)) end
    end
    walk(t, {})
    return out
end

--- H: every hole's sites and domain, read off the body
function M.sites(T)
    local H = {}
    local through = {} -- grammar boundaries on the way down: { {path, g}, .. }
    local function walk(t, path)
        if is_hole(t) then
            local e = H[t.h]
            if not e then
                e = { sites = {}, domain = (T.holes and T.holes[t.h] and T.holes[t.h].domain) or M.open(),
                    origin = (T.holes and T.holes[t.h] and T.holes[t.h].origin) or 'derived',
                    was = T.holes and T.holes[t.h] and T.holes[t.h].was or nil,
                    rep = t.rep or false }
                H[t.h] = e
            end
            local site = { path = path }
            if #through > 0 then site.through = M.copy(through) end -- H carries the boundaries, so the third leg can cross them
            e.sites[#e.sites + 1] = site
            e.ctx = t.ctx or false
            if t.ctx then for i, c in ipairs(t.kids or {}) do walk(c, child(path, i)) end end
            return
        end
        if t.k == 'embed' then
            through[#through + 1] = { path = path, g = t.g }
            walk(t.kids[1], child(path, 1))
            through[#through] = nil
            return
        end
        for i, c in ipairs(t.kids or {}) do walk(c, child(path, i)) end
    end
    walk(T.body, {})
    return H
end

function M.hole_names(T)
    local names = {}
    for h in pairs(M.sites(T)) do names[#names + 1] = h end
    table.sort(names)
    return names
end
end
