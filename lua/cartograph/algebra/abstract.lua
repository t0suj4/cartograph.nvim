-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 5 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local at, child, key, set_at, unpack =
    SHARED.at, SHARED.child, SHARED.key, SHARED.set_at, SHARED.unpack

--- the subterm of I at a site path, parsing each grammar boundary the path crosses;
--- returns the term reached and, for the last segment, its parent and index
local function at_through(I, path, through)
    local cur, consumed = I, 0
    for _, b in ipairs(through or {}) do
        local sub = at(cur, { unpack(path, consumed + 1, #b.path) })
        if sub == nil then return nil end
        if sub.k == 'embed' then cur = sub.kids[1] -- already a boundary node (abstract in progress)
        else
            if sub.k ~= 'lit' or type(sub.v) ~= 'string' then return nil end
            cur = M.grammars[b.g].parse(sub.v)
            if not cur then return nil end
        end
        consumed = #b.path + 1 -- past the embed node and its single kid index
    end
    local rest = { unpack(path, consumed + 1) }
    return at(cur, rest), cur, rest
end

--- read each hole's value off I at its sites (first site; the others must agree)
function M.values_at(I, H)
    local V, conflicts = {}, {}
    for h, e in pairs(H) do
        for _, s in ipairs(e.sites) do
            local v
            if e.ctx then
                -- cut the context out: the slice with the sub-slice at the cursor replaced by ◦ (CTXCUT.md)
                if not s.cursor then error('values_at: a context site (hole ' .. h .. ') needs a cursor record; H from sites(T) has none, H from match does') end
                local parent = at(I, { unpack(s.path, 1, #s.path - 1) })
                local start, n = s.path[#s.path], s.n or 0
                local slice = {}
                for j = start, start + n - 1 do slice[#slice + 1] = parent.kids[j] end
                v = M.with_cursor(slice, s.cursor.path, s.cursor.from, s.cursor.from + s.cursor.n - 1)
            elseif e.rep then
                local _, root, rest = at_through(I, s.path, s.through)
                local parent = at(root, { unpack(rest, 1, #rest - 1) })
                local start, n = rest[#rest], s.n or 0
                local kids = {}
                for j = start, start + n - 1 do kids[#kids + 1] = M.copy(parent.kids[j]) end
                v = M.seq(kids)
            else
                v = M.copy(at_through(I, s.path, s.through))
            end
            if V[h] == nil then V[h] = v
            elseif not M.eq(V[h], v) then conflicts[#conflicts + 1] = h end
        end
    end
    return V, conflicts
end

--- the template whose holes sit at H's sites in I
local function later_first(a, b)
    -- deeper / later sites first, so indices of untouched siblings stay valid; at one path,
    -- the later-bound site first (ids from match), else the positive-width one
    if #a.path ~= #b.path then return #a.path > #b.path end
    for i = 1, #a.path do
        if a.path[i] ~= b.path[i] then return a.path[i] > b.path[i] end
    end
    if a.id and b.id then return a.id > b.id end
    return (a.n or 1) > (b.n or 1)
end

function M.abstract(I, H)
    local entries = {}
    for h, e in pairs(H) do
        for _, s in ipairs(e.sites) do
            if e.ctx and not s.cursor then error('abstract: a context site (hole ' .. h .. ') needs a cursor record; H from sites(T) has none, H from match does') end
            entries[#entries + 1] = { h = h, path = s.path, n = s.n, rep = e.rep, ctx = e.ctx or nil, cursor = s.cursor,
                through = s.through, id = s.id, within = s.within }
        end
    end
    -- the sites matched inside a context site's applied hedge, transitively (nested contexts)
    local function inside(e, pool)
        if not e.id then return {} end -- a hand-built site: nothing was matched inside it
        local ids, out, grew = { [e.id] = true }, {}, true
        while grew do
            grew = false
            for _, x in ipairs(pool) do if x.within and ids[x.within] and not ids[x.id] then ids[x.id] = true; grew = true end end
        end
        for _, x in ipairs(pool) do if x.id ~= e.id and ids[x.id] then out[#out + 1] = x end end
        return out
    end
    -- CONTEXT SITES (CTXCUT.md): cut the sub-slice at the cursor out of the ORIGINAL level, rebase
    -- the sites inside it onto that hedge, abstract the hedge recursively, and put one context hole
    -- node holding the result where the slice was. Recursing on original coordinates means a
    -- repetition hole or a nested context inside the applied hedge never shifts the cut.
    local build
    local function cut(orig, e, pool)
        local P = { unpack(e.path, 1, #e.path - 1) }
        local ii, p, from, cn = e.path[#e.path], e.cursor.path, e.cursor.from, e.cursor.n
        -- the cursor list: at the top level it is the slice itself (cursor.from counts from the
        -- slice's first element), deeper it is the kids of the node reached by p inside the slice
        local Lparent, fstart = P, ii + from - 1
        if #p > 0 then
            Lparent = { unpack(P) }
            Lparent[#Lparent + 1] = ii + p[1] - 1
            for i = 2, #p do Lparent[#Lparent + 1] = p[i] end
            fstart = from
        end
        local L = at(orig, Lparent)
        local kids = {}
        for j = fstart, fstart + cn - 1 do kids[#kids + 1] = M.copy(L.kids[j]) end
        local sub = M.seq(kids)
        local rebased = {}
        for _, x in ipairs(inside(e, pool)) do
            local q = { unpack(x.path, #Lparent + 1) }
            q[1] = q[1] - fstart + 1
            local y = {}
            for k2, v in pairs(x) do y[k2] = v end
            y.path = q
            rebased[#rebased + 1] = y
        end
        local hedge = build(sub, e.id, rebased)
        return { k = 'hole', h = e.h, ctx = true, kids = hedge.kids }
    end
    build = function(orig, enc, pool)
        local body = M.copy(orig)
        local plan = {}
        for _, x in ipairs(pool) do if x.within == enc then plan[#plan + 1] = x end end
        table.sort(plan, later_first)
        for _, p in ipairs(plan) do
            if p.ctx then
                local node = cut(orig, p, pool)
                local parent = at(body, { unpack(p.path, 1, #p.path - 1) })
                local start, n = p.path[#p.path], p.n or 0
                local kids = {}
                for j = 1, start - 1 do kids[#kids + 1] = parent.kids[j] end
                kids[#kids + 1] = node
                for j = start + n, #parent.kids do kids[#kids + 1] = parent.kids[j] end
                parent.kids = kids
            elseif p.through then
                -- a site behind grammar boundaries: parse each string into an embed node first (once),
                -- then place the hole inside the parsed term
                local root, rest = body, p.path
                local consumed = 0
                for _, b in ipairs(p.through) do
                    local epath = { unpack(p.path, consumed + 1, #b.path) }
                    local sub = at(root, epath)
                    if sub.k ~= 'embed' then
                        local parsed = M.grammars[b.g].parse(sub.v)
                        local e = { k = 'embed', g = b.g, kids = { parsed } }
                        root = set_at(root, epath, e)
                        sub = e
                    end
                    root = sub.kids[1] -- descend into the parsed term; edits below mutate it in place
                    consumed = #b.path + 1
                    rest = { unpack(p.path, consumed + 1) }
                    if #rest == 0 then error('abstract: a hole cannot replace a whole boundary') end
                end
                if p.rep then
                    local parent = at(root, { unpack(rest, 1, #rest - 1) })
                    local start, n = rest[#rest], p.n or 0
                    local kids = {}
                    for j = 1, start - 1 do kids[#kids + 1] = parent.kids[j] end
                    kids[#kids + 1] = M.hole(p.h, true)
                    for j = start + n, #parent.kids do kids[#kids + 1] = parent.kids[j] end
                    parent.kids = kids
                else
                    set_at(root, rest, M.hole(p.h))
                end
            elseif p.rep then
                local parent = at(body, { unpack(p.path, 1, #p.path - 1) })
                local start, n = p.path[#p.path], p.n or 0
                local kids = {}
                for j = 1, start - 1 do kids[#kids + 1] = parent.kids[j] end
                kids[#kids + 1] = M.hole(p.h, true)
                for j = start + n, #parent.kids do kids[#kids + 1] = parent.kids[j] end
                parent.kids = kids
            else
                body = set_at(body, p.path, M.hole(p.h))
            end
        end
        return body
    end
    local body = build(I, nil, entries)
    local domains = {}
    for h, e in pairs(H) do domains[h] = { domain = e.domain, origin = e.origin or 'derived', was = e.was } end
    return M.template(body, domains)
end

--- where in I could V's values sit? The answer is a SET per hole — sites are not derivable
--- from (I, V) when a value occurs more than once or two holes carry equal values.
function M.locate(I, V)
    local cands, ambiguous = {}, false
    for h, v in pairs(V) do
        cands[h] = {}
        local function walk(t, path)
            if M.eq(t, v) then cands[h][#cands[h] + 1] = key(path) end
            for i, c in ipairs(t.kids or {}) do walk(c, child(path, i)) end
        end
        walk(I, {})
        if #cands[h] ~= 1 then ambiguous = true end
    end
    return cands, ambiguous
end
end
