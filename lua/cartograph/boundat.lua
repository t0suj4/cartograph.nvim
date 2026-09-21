-- boundat.lua — WHAT IS BOUND AT THIS LINE (CART-1001, the scope seam).
--
-- USER (2026-09-21): "Maybe the algebra's scope could help."
--
-- ── WHY A FLAT SET IS THE WRONG SHAPE, WHICH IS THE WHOLE REASON THIS EXISTS ──
-- Every naming decision in the write path asks a variant of "is this name taken?",
-- and every one of them answers it with a LIST: `va.params`, a file's `file_locals`,
-- a function's `locals` set. A list cannot express BOUND HERE AND NOT THREE LINES UP —
-- and Lua's `local` is precisely that: the algebra's Lua mapping builds it as the
-- SEQUENTIAL LET of Fig. 14, the right-hand side in the scope BEFORE the binding and a
-- NEW SCOPE AFTER it. So the chunk scope of a 600-line file declares NOTHING (measured,
-- and correct); what is bound is a property OF A POSITION.
--
-- ⚠ THE CODEBASE ALREADY KNOWS THIS AND KEEPS RE-DERIVING IT. `hoistclosure` learned it
-- as CART-0979 ("a local bound AFTER this closure is not in its scope") and answers it
-- with its own `def_line` comparison; `clones.bound_by_enclosing` (CART-0975) walks out
-- one definition at a time; `cloneextract` checks `va.params` and misses body locals
-- entirely. Three hand-rolled halves of one question — the two-lists defect at three
-- sites, which is why this is a SEAM and not a fourth.
--
-- ── HOW IT ANSWERS, AND WHAT IT IS ALLOWED TO ASSUME ─────────────────────────
-- `A.lua_scope_graph` publishes a scope graph whose REFERENCES carry a `site`: a path of
-- child indices into the lossless CST `algebraread.read` produces. `A.cst_print(read(s))
-- == s` BYTE FOR BYTE — the module's own law — so a path has an EXACT byte offset,
-- obtained by summing the leaves printed before it. That gives (line -> scope) samples
-- across the file, and `A.resolve_name(G, S, name)` answers the actual question:
-- "a fresh reference of `name` placed in scope S, resolved — what would this name mean
-- here". A class of `unresolved` means free.
--
-- ⚠ THE SCOPE FOR A LINE IS THE LAST REFERENCE'S SCOPE AT OR BEFORE IT, and that is an
-- interpolation, not a lookup: scopes carry no ranges, only references do. Under
-- sequential lets the scope in effect just after a reference is the one holding every
-- binding made before it, which is exactly what "may I introduce a name here" needs. A
-- line before any reference gets the chunk scope.
-- ⚠ AND IT IS LUA-ONLY, because `lua_scope_graph` is Lua's mapping. Every other language
-- gets `nil` and a reason — an honest absence, not a default that would silently answer
-- "nothing is bound" and hand back a name that collides.

local M = {}

--- @return table|nil handle { G, chunk, lines = sorted {offset-line, scope} }, string|nil why
--- @param src string  the file's text
--- @param file string|nil  for the graph's own records
function M.of(src, file)
    if type(src) ~= 'string' then return nil, 'not source text' end
    local alg = require 'cartograph.algebra'
    local A, why = alg.load()
    if not A then return nil, ('the algebra is unavailable: %s'):format(tostring(why)) end
    local R = require 'cartograph.algebraread'
    local t, rwhy = R.read(src)
    if not t then return nil, ('cannot read the source: %s'):format(tostring(rwhy)) end
    local G = A.scope_graph()
    local okg, gwhy = pcall(A.lua_scope_graph, t, G, { file = file or '?' })
    if not okg then return nil, ('scope graph: %s'):format(tostring(gwhy)) end
    pcall(A.sg_link, G)

    -- ── path -> byte offset, in ONE walk over the leaves ────────────────────
    -- ⚠ NOT `#cst_print(subtree)` PER REFERENCE: that reprints the whole file once per
    -- reference and is quadratic on exactly the files worth asking about (2151 refs in
    -- cloneextract.lua). Summing leaf widths costs one pass.
    local want = {}
    for id, r in pairs(G.refs or {}) do
        if r.site and (r.file == nil or r.file == (file or '?')) then
            want[table.concat(r.site, ',')] = id
        end
    end
    local off_of, pos = {}, 0
    local function walk(n, path)
        if type(n) ~= 'table' then return end
        local key = table.concat(path, ',')
        if want[key] then off_of[want[key]] = pos end
        if n.k == 'lit' then
            pos = pos + #tostring(n.v == nil and '' or n.v)
            return
        end
        for i, c in ipairs(n.kids or {}) do
            path[#path + 1] = i
            walk(c, path)
            path[#path] = nil
        end
    end
    walk(t, {})

    -- byte offset -> 0-based line, by the newline prefix count
    local nl = { 0 }
    for i = 1, #src do if src:sub(i, i) == '\n' then nl[#nl + 1] = i end end
    local function line_of(o)
        local lo, hi = 1, #nl
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if nl[mid] <= o then lo = mid else hi = mid - 1 end
        end
        return lo - 1
    end

    local pts = {}
    for id, o in pairs(off_of) do
        local r = G.refs[id]
        if r and r.scope then pts[#pts + 1] = { line = line_of(o), off = o, scope = r.scope } end
    end
    table.sort(pts, function (x, y) return x.off < y.off end)
    local chunk
    for _, c in ipairs(G.chunks or {}) do chunk = (type(c) == 'table' and c.scope) or c end
    return { G = G, A = A, chunk = chunk or G.root, points = pts, nrefs = #pts }
end

--- The scope in effect at a 0-based line.
--- @return any scope id
function M.scope_at(h, line0)
    if not (h and h.points) then return nil end
    local best = h.chunk
    for _, p in ipairs(h.points) do
        if p.line <= line0 then best = p.scope else break end
    end
    return best
end

--- Is `name` bound at this line, and as what?
--- ⚠ THE ANSWER IS THE RESOLUTION CLASS, NOT A BOOLEAN, because the callers differ on
--- what counts: a `library` binding does not stop you naming a local `table`, while a
--- `lexical` one does. Returning the class lets each decide and keeps this from being a
--- policy the seam has no business holding.
--- ⚠ `line1` MAKES IT A RANGE, AND A PARAMETER NAME NEEDS ONE. A helper's parameter is
--- in scope for its WHOLE body, so a local of the same name anywhere inside SHADOWS it
--- and the body's references stop meaning the parameter. Asking at one line would admit
--- exactly that. The range answer is the union: bound if bound at any line in it.
--- @return boolean bound, string class
function M.is_bound(h, line0, name, line1)
    if not h then return false, 'no graph' end
    if line1 and line1 > line0 then
        local worst = 'unresolved'
        for l = line0, line1 do
            local b, c = M.is_bound(h, l, name)
            if b then
                -- a lexical binding is the one that shadows; report it in preference to
                -- a library one, which does not.
                if c ~= 'library' then return true, c end
                worst = c
            end
        end
        return worst ~= 'unresolved', worst
    end
    local S = M.scope_at(h, line0)
    local ok, T = pcall(h.A.resolve_name, h.G, S, name)
    if not ok or not T then return false, 'unresolved' end
    local okc, cls = pcall(h.A.resolution_class, h.G, T)
    cls = okc and cls or 'unresolved'
    return cls ~= 'unresolved', cls
end

--- A name built from `base` that is free at this line: `base`, `base2`, `base3`, …
--- ⚠ `taken` IS A SECOND SOURCE AND IT IS NOT OPTIONAL POLITENESS. Names this caller is
--- ABOUT TO introduce are not in the graph yet — a helper minting `hp1..hpN` must not
--- hand out `hp2` twice because neither exists on disk.
--- ⚠ AND A LIBRARY BINDING DOES NOT BLOCK: shadowing `table` inside a helper is legal
--- Lua and refusing it would make this stricter than the language.
--- @param line1 number|nil  the end of the range the name must be free across
--- @return string|nil name, string|nil why
function M.fresh(h, line0, base, taken, line1)
    if not h then return nil, 'no scope graph for this file' end
    taken = taken or {}
    for i = 1, 64 do
        local cand = (i == 1) and base or (base .. i)
        local bound, cls = M.is_bound(h, line0, cand, line1)
        if not taken[cand] and not (bound and cls ~= 'library') then return cand end
    end
    -- ⚠ A REFUSAL, NOT A 65th GUESS. Sixty-four collisions on one base means the caller's
    -- naming scheme is wrong, and inventing `base65` would hide that.
    return nil, ('no free name from `%s` within 64 tries at line %d'):format(base, line0)
end

return M
