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
    -- ⚠⚠ DECLARATIONS ARE POSITION SAMPLES TOO, AND LEAVING THEM OUT WAS A REAL BUG.
    -- My first cut sampled only REFERENCES, so the scope in effect was always the last
    -- one a reference had witnessed — and a binding with no use yet is invisible to that.
    -- MEASURED against `cloneextract`'s flat model over 40 files: 45.6% disagreement, all
    -- of the form "bound by the old model, free by mine", at and just after every
    -- `local function` declaration. The seam was systematically ONE BINDING BEHIND.
    -- ⇒ A declaration's `scope` IS the sequential let's successor scope — the one holding
    -- it — so a decl point says "from here on, this is in effect". With both kinds of
    -- point the interpolation has a sample at every place the scope actually changes.
    -- ⚠ IT TOOK A DIFFERENTIAL TO SEE: the module's own spec passed, because a 14-line
    -- fixture has a reference on nearly every line and the lag never shows.
    local want, from = {}, {}
    for id, r in pairs(G.refs or {}) do
        if r.site and (r.file == nil or r.file == (file or '?')) then
            local k = table.concat(r.site, ',')
            want[k] = id; from[k] = 'ref'
        end
    end
    for id, d in pairs(G.decls or {}) do
        if d.site and (d.file == nil or d.file == (file or '?')) then
            local k = table.concat(d.site, ',')
            -- a REF at the same path wins: it is the narrower statement about that spot
            if want[k] == nil then want[k] = id; from[k] = 'decl' end
        end
    end
    local off_of, pos = {}, 0
    local function walk(n, path)
        if type(n) ~= 'table' then return end
        local key = table.concat(path, ',')
        if want[key] then off_of[want[key]] = { off = pos, kind = from[key] } end
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

    local pts, decls = {}, {}
    for id, rec in pairs(off_of) do
        local e = (rec.kind == 'ref') and G.refs[id] or G.decls[id]
        if e and e.scope then
            -- ⚠ `name` AND `site` RIDE ALONG BECAUSE A SUBSTITUTION NEEDS THE OCCURRENCE,
            -- NOT THE SCOPE (CART-1005). Every consumer until `invert` asked "what is in
            -- effect HERE"; inlining asks the transposed question — "where does this name
            -- OCCUR" — and the walk that answers the first already visited every one of
            -- them. Dropping the name made the second question look like it needed a
            -- second walker, which is how this codebase grows its fourth half-predicate.
            pts[#pts + 1] = { line = line_of(rec.off), off = rec.off, scope = e.scope,
                kind = rec.kind, name = e.name, site = e.site }
        end
        -- ★ EVERY DECLARATION WITH A PATH, for the containment answer below.
        if rec.kind == 'decl' and G.decls[id] and G.decls[id].site then
            local d = G.decls[id]
            decls[#decls + 1] = { name = d.name, kind = d.kind, site = d.site,
                line = line_of(rec.off), off = rec.off, fn_scope = d.fn_scope }
        end
    end
    table.sort(decls, function (x, y) return x.off < y.off end)
    table.sort(pts, function (x, y) return x.off < y.off end)
    local chunk
    for _, c in ipairs(G.chunks or {}) do chunk = (type(c) == 'table' and c.scope) or c end
    return { G = G, A = A, chunk = chunk or G.root, points = pts, nrefs = #pts,
        decls = decls, ndecls = #decls }
end

--- ★★★ IS `name` BOUND ANYWHERE INSIDE THIS FUNCTION — BY TERM-PATH CONTAINMENT.
--- USER: "could be worth checking experiments." This is the construction
--- `experiments/resolve_census.lua` uses (`prefix(path, ref.site)`, :192): every
--- declaration and reference carries a `site`, a path of child indices into the CST, and
--- a binding is inside a function exactly when its site lies UNDER the function's path.
--- Path space, not line space — no interpolation, no ranges, nothing to lag.
---
--- ⚠ IT IS THE THIRD CONSTRUCTION AND THE FIRST CORRECT ONE, and the other two are kept
--- in the module because their failures are the argument for this one:
---   · LINE INTERPOLATION (`scope_at`) lags a binding with no site before the line —
---     318 of 7335 parameters read as unbound inside their own function.
---   · `fn_scope` is EXACT AND ANSWERS A DIFFERENT QUESTION: a function's ENTRY scope
---     holds its parameters and, because each `local` opens a successor scope, NONE of
---     its body locals — 20916 of 21369 missed.
---
--- ⚠ THE FUNCTION'S PATH IS ITS DECLARATION'S SITE MINUS THE LAST STEP, because the site
--- addresses the NAME inside the declaration node. That is a claim about the Lua mapping
--- and it is CHECKED rather than assumed: `M.fn_path` verifies the function's own
--- parameters lie under the path it returns, and refuses when they do not.
--- @return table|nil path, string|nil why
function M.fn_path(h, line0)
    if not h then return nil, 'no scope graph for this file' end
    local best
    for _, d in ipairs(h.decls) do
        if d.fn_scope and d.line <= line0 and (best == nil or d.line > best.line) then best = d end
    end
    if not best then return nil, ('no function declaration at or before line %d'):format(line0) end
    if #best.site < 2 then return nil, 'the function declaration has no enclosing node' end
    local path = { unpack and unpack(best.site, 1, #best.site - 1)
        or table.unpack(best.site, 1, #best.site - 1) }
    -- ⚠ THE CHECK: this function's own parameters must lie under it. If the mapping ever
    -- addresses a declaration differently, this refuses instead of silently answering
    -- "nothing is bound" — which is the direction that mints a colliding name.
    local nparam, under = 0, 0
    for _, d in ipairs(h.decls) do
        if d.kind == 'parameter' and d.off > best.off and d.off < best.off + 1e9 then
            if M.under(path, d.site) then under = under + 1; nparam = nparam + 1
            elseif d.line == best.line then nparam = nparam + 1 end
        end
    end
    if nparam > 0 and under == 0 then
        return nil, 'the function path does not contain its own parameters'
    end
    return path, nil
end

--- ★★★ EVERY *USE* OF `name` UNDER `path`, AS BYTE OFFSETS (CART-1005).
--- The inverse of an extraction substitutes an argument for a parameter, and a
--- substitution is about OCCURRENCES. `is_bound`/`binds_in` answer about DECLARATIONS;
--- this is the other side of the same index, and it is the reason `invert` does not
--- reach for a pattern.
---
--- ⚠ WHY NOT `gsub`, WHICH IS WHAT EVERY FIRST CUT OF AN INLINER DOES: `x` occurs inside
--- `max`, inside `"x"`, and inside `t.x`. Only the first of those three is a reference,
--- and only the scope graph knows which. The offsets here come from the CST walk whose
--- law is `cst_print(read(src)) == src` byte for byte, so each is an exact splice point.
---
--- ⚠ REFERENCES ONLY — a declaration of the same name is deliberately NOT returned.
--- ★ AND MEASURED, THIS FILTER CHANGES NOTHING TODAY, which is worth writing down rather
--- than leaving as an assumption: `invert` is the only caller, it discards offsets outside
--- the body (so a parameter's own declaration in the signature never reaches it) and it
--- refuses a parameter that is rebound inside one (so a shadowing declaration never reaches
--- it either). Dropping the filter leaves the suite green. It stays because `uses` is an
--- ACCESSOR, not that caller's private step: the next caller will not have both conditions,
--- and "every occurrence of this name" and "every reference to it" are different questions
--- that must not share an answer by accident.
--- @return table uses  { { off, line, site } } ascending by offset
function M.uses(h, path, name)
    local out = {}
    if not (h and h.points) then return out end
    local short = tostring(name):match('[%w_]+$') or name
    for _, p in ipairs(h.points) do
        if p.kind == 'ref' and p.name == short and p.site
            and (path == nil or M.under(path, p.site)) then
            out[#out + 1] = { off = p.off, line = p.line, site = p.site }
        end
    end
    table.sort(out, function (x, y) return x.off < y.off end)
    return out
end

--- is `site` under `path` (a strict-or-equal prefix)?
function M.under(path, site)
    if #site < #path then return false end
    for i = 1, #path do if site[i] ~= path[i] then return false end end
    return true
end

--- @return boolean bound, string how
function M.binds_in(h, line0, name)
    local path, why = M.fn_path(h, line0)
    if not path then return false, why or 'no function' end
    local short = tostring(name):match('[%w_]+$') or name
    for _, d in ipairs(h.decls) do
        if d.name == short and M.under(path, d.site) then return true, d.kind end
    end
    return false, 'unbound'
end

--- A name free everywhere inside the function containing `line0`.
function M.fresh_by_path(h, line0, base, taken)
    if not h then return nil, 'no scope graph for this file' end
    local path, why = M.fn_path(h, line0)
    if not path then return nil, why end
    taken = taken or {}
    for i = 1, 64 do
        local cand = (i == 1) and base or (base .. i)
        if not taken[cand] and not (M.binds_in(h, line0, cand)) then return cand end
    end
    return nil, ('no free name from `%s` within 64 tries'):format(base)
end

--- ★★★ THE SCOPE A FUNCTION'S BODY IS IN, EXACTLY — no interpolation (CART-1001).
--- A `function` declaration publishes `fn_scope`: the scope its body lives in. So the
--- question "is this name bound inside this function" has a DIRECT answer and never
--- needed a position lookup at all.
---
--- ⚠⚠ THIS IS THE PROTOTYPE'S OWN CONSTRUCTION AND I HAND-ROLLED A WORSE ONE FIRST.
--- `experiments/resolve_census.lua` takes exactly this route — `d.fn_scope` for a
--- function's scope (:231), and TERM-PATH CONTAINMENT (`prefix(path, ref.site)`, :192)
--- to select the references inside a subtree. It works in path space; I worked in line
--- space and interpolated "the scope of the last point at or before this line", which is
--- systematically ONE BINDING BEHIND wherever a binding has no reference yet. MEASURED:
--- 37.4% disagreement with `cloneextract`'s flat model, and 318 of 7335 PARAMETERS
--- reading as unbound inside their own function. USER: "could be worth checking
--- experiments" — the standing rule, and the construction was sitting there.
--- @return any|nil scope, string|nil why
function M.fn_scope(h, name)
    if not h then return nil, 'no scope graph for this file' end
    local short = tostring(name):match('[%w_]+$') or name
    for _, d in pairs(h.G.decls or {}) do
        if d.fn_scope and d.name == short then return d.fn_scope end
    end
    return nil, ('no function declaration named `%s` in this file'):format(tostring(short))
end

--- Is `name` bound inside the function `fn`? EXACT where `fn_scope` is known.
--- @return boolean bound, string class
function M.is_bound_in(h, fn, name)
    local S, why = M.fn_scope(h, fn)
    if not S then return false, why or 'no scope' end
    local ok, T = pcall(h.A.resolve_name, h.G, S, name)
    if not ok or not T then return false, 'unresolved' end
    local okc, cls = pcall(h.A.resolution_class, h.G, T)
    cls = okc and cls or 'unresolved'
    return cls ~= 'unresolved', cls
end

--- A name free inside the function `fn`: `base`, `base2`, … (see `M.fresh`).
function M.fresh_in(h, fn, base, taken)
    if not h then return nil, 'no scope graph for this file' end
    local S, why = M.fn_scope(h, fn)
    if not S then return nil, why end
    taken = taken or {}
    for i = 1, 64 do
        local cand = (i == 1) and base or (base .. i)
        local bound, cls = M.is_bound_in(h, fn, cand)
        if not taken[cand] and not (bound and cls ~= 'library') then return cand end
    end
    return nil, ('no free name from `%s` within 64 tries in `%s`'):format(base, tostring(fn))
end

--- ⚠ THE LINE FORM IS AN APPROXIMATION AND IS NOW LABELLED AS ONE. Scopes carry no
--- ranges, so this interpolates from the sites of references and declarations: the scope
--- of the last one at or before the line. Where a binding has no site before the line it
--- LAGS. Prefer `fn_scope`/`is_bound_in` whenever the question is about a named function,
--- which is every caller in this tree today.
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
