-- ImpactEngine (seam #2). Pure: given the graph store, a set of symbols staged
-- to move, and a destination file, compute the consequences of the move — what
-- references must be rewritten, what requires must be added, and what hazards
-- the move carries. No UI, no edits applied here; this only *describes* the move.
--
-- It computes what the current graph supports (symbol refs, imports, module
-- load-effects) AND file-local capture — a moved symbol (or a nested def that
-- travels inside its text) referencing a same-file `local` that stays behind.

local M = {}
local atr = require 'cartograph.at'

-- does `from` already `require` `to`?
local function imports_already(band, from, to)
    for _, f in ipairs(band:imports_in(to)) do
        if f == from then return true end
    end
    return false
end

local function sorted_keys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- @param store table   the graph store (node/uses/usedby/occurrences/imports_in)
--- @param moveset string[]   ids staged to move
--- @param dest string?   destination file
--- @return table plan
function M.compute(store, moveset, dest)
    local band = store.topo() -- topology through the resident Band, not raw indexes
    local in_move = {}
    for _, id in ipairs(moveset) do in_move[id] = true end

    -- staged moves, with their current home
    local moves, sources = {}, {}
    for _, id in ipairs(moveset) do
        local n = store.node(id)
        if n then
            moves[#moves + 1] = { id = id, name = n.name, from = n.file }
            sources[n.file] = true
        end
    end
    table.sort(moves, function (a, b)
        if a.from ~= b.from then return a.from < b.from end
        return a.name < b.name
    end)

    -- references to rewrite: callers of a moved symbol that aren't in `dest` and
    -- aren't themselves moving (a caller in dest becomes a local call; a caller
    -- that travels with the symbol stays together).
    local rw = {} -- file -> { name -> count }
    for _, id in ipairs(moveset) do
        local n = store.node(id)
        for _, caller in ipairs(band:callers(id)) do
            local cn = not in_move[caller] and store.node(caller)
            local cfile = cn and cn.file
            if n and cfile and cfile ~= dest then
                local sites = store.occurrences(caller, id)
                rw[cfile] = rw[cfile] or {}
                rw[cfile][n.name] = (rw[cfile][n.name] or 0) + (sites and #sites or 1)
            end
        end
    end
    local rewrites, rewrite_files = {}, {}
    for _, file in ipairs(sorted_keys(rw)) do
        local syms, total = {}, 0
        for _, name in ipairs(sorted_keys(rw[file])) do
            syms[#syms + 1] = { name = name, count = rw[file][name] }
            total = total + rw[file][name]
        end
        rewrites[#rewrites + 1] = { file = file, symbols = syms, total = total }
        rewrite_files[file] = true
    end

    -- requires to add: each rewrite-site file must be able to reach `dest`
    local add = {}
    if dest then
        for file in pairs(rewrite_files) do
            if not imports_already(band, file, dest) then add[file] = true end
        end
    end

    -- dest must require: modules holding deps of the moved symbols that stay put
    local dest_req = {}
    if dest then
        for _, id in ipairs(moveset) do
            for _, dep in ipairs(band:callees(id)) do
                local dn = not in_move[dep] and store.node(dep)
                local dfile = dn and dn.file
                if dfile and dfile ~= dest and not imports_already(band, dest, dfile) then
                    dest_req[dfile] = true
                end
            end
        end
    end
    local dest_requires = sorted_keys(dest_req)

    -- hazards
    local hazards = {}
    local function warn(kind, msg) hazards[#hazards + 1] = { level = 'warn', kind = kind, msg = msg } end
    local function info(kind, msg) hazards[#hazards + 1] = { level = 'info', kind = kind, msg = msg } end

    if dest and #moves > 0 then
        local all_home = true
        for _, m in ipairs(moves) do if m.from ~= dest then all_home = false end end
        if all_home then info('noop', 'all staged symbols already live in ' .. dest) end

        -- load-order: a side-effecting module on either end makes ordering matter
        local seen_lo = {}
        local function load_order(file)
            local mod = store.node(file)
            if mod and mod.effects and not seen_lo[file] then
                seen_lo[file] = true
                warn('load-order', file .. ' runs code at load time — moving across it may change ordering')
            end
        end
        load_order(dest)
        for file in pairs(sources) do load_order(file) end

        -- cycle risk: dest would need to require a module that already requires dest
        for _, dfile in ipairs(dest_requires) do
            if imports_already(band, dfile, dest) then
                warn('cycle', 'require cycle: ' .. dest .. ' <-> ' .. dfile)
            end
        end
    end
    -- FILE-LOCAL CAPTURE (was the blanket 'verify closures by hand'): a moved
    -- symbol — or a NESTED def that travels inside its text (e.g. a `local
    -- function walk` inside a moved helper) — references a same-file `local`
    -- (helper or module-level constant) that stays behind. A Lua file-local is
    -- invisible from the extracted module, so the move breaks unless that symbol
    -- travels too (or is wired in by hand). Both edge kinds count: call/ref deps
    -- (store.uses) AND variable reads (store.var_uses, e.g. a fn reading a const
    -- table). Cross-file deps are handled by dest_requires above (requirable).
    --
    -- `travels` = the move-set PLUS every node contained in a moved symbol's
    -- range (those move as text). A reference from any traveller to a same-file
    -- symbol NOT in `travels` is a capture; a reference TO a traveller is fine.
    local travels = {}
    for _, id in ipairs(moveset) do travels[id] = true end
    local ranges = {}
    for _, id in ipairs(moveset) do
        local mn = store.node(id)
        if mn and mn.range then
            ranges[#ranges + 1] = { file = mn.file,
                s = atr.sl(mn.range), e = atr.el(mn.range) }
        end
    end
    for _, n in ipairs(store.data.nodes or {}) do
        if not travels[n.id] and n.range then
            local ns, ne = atr.sl(n.range), atr.el(n.range)
            for _, r in ipairs(ranges) do
                if n.file == r.file and ns >= r.s and ne <= r.e then
                    travels[n.id] = true; break
                end
            end
        end
    end
    -- only MODULE-LEVEL file-locals are real captures: a nested local either
    -- travels inside its enclosing def or is out of scope entirely — flagging
    -- one is noise. Module-level = not contained in any fn/method range.
    local fnranges = {}
    for _, n in ipairs(store.data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.range then
            fnranges[n.file] = fnranges[n.file] or {}
            local t = fnranges[n.file]
            t[#t + 1] = { s = atr.sl(n.range), e = atr.el(n.range), id = n.id }
        end
    end
    local function module_level(dn)
        if not dn.range then return false end
        local s, e = atr.sl(dn.range), atr.el(dn.range)
        for _, r in ipairs(fnranges[dn.file] or {}) do
            if r.id ~= dn.id and s >= r.s and e <= r.e then return false end
        end
        return true
    end
    -- ★★★ THE FREE NAMES OF THE TRAVELLING SET, which is what a capture IS: a
    -- name the moved code reads and the moved code does not bind (CART-0912).
    --
    -- ⚠ I BUILT THIS TWICE WRONG FIRST, and each way failed in a different
    -- direction — over the SEED it suppressed real captures (`child`, `is_hole`
    -- read only by a private helper), over the CLOSURE without subtracting it
    -- reported names the set binds itself (a nested closure sees its PARENT's
    -- locals as free). Subtracting the set's own bindings is what makes it an
    -- answer. MEASURED on one section: the five real captures free, the two
    -- long-standing phantoms not read at all.
    --
    -- ⚠⚠ AND A PARTIAL ANSWER MAY NOT FILTER. If `expr.free` could not answer for
    -- some node, the free set is a LOWER BOUND and an absence is not evidence —
    -- so the filter is skipped entirely rather than applied to a short set. This
    -- verb has already suppressed a real capture once (CART-0919) and the cost
    -- was a module that loaded clean and died on first use.
    local travelling = {}
    for id in pairs(travels) do travelling[#travelling + 1] = id end
    local freeset, partial = require('cartograph.expr').free_set(store, travelling)

    local captured = {} -- dep id -> { name, file } (deduped)
    local function consider(depid)
        if depid and not travels[depid] and not captured[depid] then
            local dn = store.node(depid)
            if dn and sources[dn.file] and module_level(dn)
                and (partial or freeset[dn.name]) then -- true capture
                captured[depid] = { name = dn.name, file = dn.file }
            end
        end
    end
    for tid in pairs(travels) do
        for _, dep in ipairs(band:callees(tid)) do consider(dep) end
        for _, to in ipairs(band:var_uses(tid)) do consider(to) end
    end
    -- ★★★ A SECOND, CHEAPER RUNG, BECAUSE THE FIRST IS BOUNDED BY RESOLUTION
    -- (CART-0919). Everything above is built from `band:callees` / `band:var_uses`
    -- — RESOLVED edges — so a file-local whose call sites the linker could not
    -- resolve produces NO hazard at all. MEASURED on the vendored algebra:
    -- `slice` had 26 call sites in the moved text and all 26 were unresolved,
    -- while `vsym` (12) and `lcs_alignments` (4) resolved and were disclosed. The
    -- extracted module loaded clean and died on first use.
    --
    -- ⚠ THE ERROR DIRECTION IS WHAT MAKES THIS WORTH A SECOND MECHANISM: the list
    -- gets SHORTER where the graph knows LESS, so the plan reads as SAFER exactly
    -- where it is least understood.
    --
    -- The rung: the moved TEXT NAMES an identifier that is a module-level
    -- file-local of the source and is not travelling. NODES exist even when CALLS
    -- do not resolve, so the candidate set costs nothing extra, and a text match
    -- can only OVER-report — which for a disclosure is the safe direction, and is
    -- already how `module_scaffold`'s `M.x` residual works.
    local textual = {}
    do
        -- ★★★ THE SECOND RUNG READS THE IR, NOT THE TEXT (CART-0912). It began as
        -- `body:find(name)` over the moved lines, which works and over-reports:
        -- prose and string literals spell the same names, so three sections of the
        -- algebra split disclosed `template`, `values`, `instance` and `parse` as
        -- captures when the moved code reaches them as `M.template` or never at
        -- all. `expr.free` answers the same question over NAME NODES, where a
        -- comment is not a name and a string is not a name.
        -- ⚠ AND IT SEES EVERY SYNTACTIC ROLE. The resolved-edge rung above is
        -- blind where resolution fails; a CALL-shaped text scan is blind to values
        -- and indexes. Measured, one real defect each: `slice` (call), `key`
        -- (value), `RUNG_RANK` (index).
        -- ★ NO `skip`: a nested closure's statements are attributed to its parent,
        -- and a nested closure reading an enclosing file-local IS a capture of the
        -- function being moved.
        -- the files the move is leaving: a capture is a local of a SOURCE file,
        -- never of some unrelated file that happens to share a name
        local sourcefiles = {}
        for _, r in ipairs(ranges) do sourcefiles[r.file] = true end
        for _, n in ipairs(store.data.nodes or {}) do
            if not travels[n.id] and not captured[n.id]
                and n.name and not n.name:find('%.') and freeset[n.name]
                and (n.kind == 'function' or n.kind == 'var')
                and module_level(n) and sourcefiles[n.file] then
                captured[n.id] = { name = n.name, file = n.file }
                textual[n.id] = true
            end
        end
    end

    local capkeys, caps = {}, {}
    for depid in pairs(captured) do capkeys[#capkeys + 1] = depid end
    table.sort(capkeys, function (a, b) return captured[a].name < captured[b].name end)
    for _, depid in ipairs(capkeys) do
        local c = captured[depid]
        -- PRIVATE = every referrer travels with the move (all in `travels`) → it
        -- is cluster-private, safe to pull in. SHARED = referenced by staying
        -- code too → moving it would break the stayer; require or copy instead.
        -- (Referrers may be nested nodes, hence the `travels` test, not the set.)
        -- ⚠⚠ `private` IS NOT A MESSAGE, IT IS THE CLOSURE'S ELIGIBILITY TEST:
        -- `moveapply.close_moveset` PULLS every private capture INTO the move-set.
        -- So a TEXTUAL capture can never be private. Its whole premise is that the
        -- call sites did not resolve, and `band:callers` on an unresolved symbol
        -- returns an EMPTY list — which the loop below reads as "nobody else uses
        -- it" and would answer `private = true`.
        -- ★ MEASURED, AND IT WOULD HAVE BEEN WORSE THAN THE SILENCE IT FIXES: on
        -- the vendored algebra `slice` is a module-level local that the STAYING
        -- `VERTICAL DIFFERENCES` section calls ~20 times, and the first cut of this
        -- rung had the closure move it into the extracted file. I wrote the caveat
        -- into the MESSAGE and left the FLAG alone.
        local private = not textual[depid]
        if private then
            for _, r in ipairs(band:callers(depid)) do
                if not travels[r] then private = false; break end
            end
        end
        if private then
            for _, from in ipairs(band:var_used_by(depid)) do
                if not travels[from] then private = false; break end
            end
        end
        caps[#caps + 1] = { id = depid, name = c.name, file = c.file,
            private = private, textual = textual[depid] or nil }
        -- ⚠ A TEXTUAL HIT MUST NOT CLAIM `private`. That verdict is computed from
        -- `band:callers`, and this rung exists precisely because those edges are
        -- missing — an empty caller list would read as "nobody else uses it" when
        -- the truth is "nothing could be resolved". Say which it is.
        warn('capture', textual[depid]
            and ('%s (file-local in %s) is NAMED IN THE MOVED TEXT but its call'
                .. ' sites did not resolve, so whether staying code also uses it'
                .. ' is UNKNOWN — require it, copy it, or add it to the move-set')
                :format(c.name, c.file)
            or private
            and ('%s (file-local in %s, private to the move) is referenced but'
                .. ' stays behind — add it to the move-set'):format(c.name, c.file)
            or ('%s (file-local in %s, shared with staying code) is referenced'
                .. ' — require it, or copy it into the extracted module')
                :format(c.name, c.file))
    end

    return {
        moves = moves,
        rewrites = rewrites,
        requires_add = sorted_keys(add),
        dest_requires = dest_requires,
        hazards = hazards,
        captures = caps, -- structured {id,name,file} — the move-set-closure seed
    }
end

return M
