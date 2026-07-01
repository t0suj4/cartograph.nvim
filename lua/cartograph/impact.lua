-- ImpactEngine (seam #2). Pure: given the graph store, a set of symbols staged
-- to move, and a destination file, compute the consequences of the move — what
-- references must be rewritten, what requires must be added, and what hazards
-- the move carries. No UI, no edits applied here; this only *describes* the move.
--
-- Deliberately honest about its limits: it computes what the current graph
-- supports (symbol refs, imports, module load-effects) and explicitly flags what
-- it does NOT yet analyze (local/upvalue capture) rather than pretending.

local M = {}

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
    if #moves > 0 then
        info('scope', 'local/upvalue capture not yet analyzed — verify closures by hand')
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
