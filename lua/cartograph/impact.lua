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
local function imports_already(store, from, to)
    for _, imp in ipairs(store.imports_in[to] or {}) do
        if imp.from == from then return true end
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
        for _, caller in ipairs(store.usedby[id] or {}) do
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
            if not imports_already(store, file, dest) then add[file] = true end
        end
    end

    -- dest must require: modules holding deps of the moved symbols that stay put
    local dest_req = {}
    if dest then
        for _, id in ipairs(moveset) do
            for _, dep in ipairs(store.uses[id] or {}) do
                local dn = not in_move[dep] and store.node(dep)
                local dfile = dn and dn.file
                if dfile and dfile ~= dest and not imports_already(store, dest, dfile) then
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
            if imports_already(store, dfile, dest) then
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
    local captured = {} -- dep id -> { name, file } (deduped)
    local function consider(depid)
        if depid and not travels[depid] and not captured[depid] then
            local dn = store.node(depid)
            if dn and sources[dn.file] and module_level(dn) then -- true capture
                captured[depid] = { name = dn.name, file = dn.file }
            end
        end
    end
    for tid in pairs(travels) do
        for _, dep in ipairs(store.uses[tid] or {}) do consider(dep) end
        for _, vu in ipairs(store.var_uses and store.var_uses[tid] or {}) do
            consider(vu.to)
        end
    end
    local capkeys = {}
    for depid in pairs(captured) do capkeys[#capkeys + 1] = depid end
    table.sort(capkeys, function (a, b) return captured[a].name < captured[b].name end)
    for _, depid in ipairs(capkeys) do
        local c = captured[depid]
        warn('capture', ('%s (file-local in %s) is referenced by the move-set'
            .. ' but stays behind — move it too, or wire it into the extracted'
            .. ' module'):format(c.name, c.file))
    end

    return {
        moves = moves,
        rewrites = rewrites,
        requires_add = sorted_keys(add),
        dest_requires = dest_requires,
        hazards = hazards,
    }
end

return M
