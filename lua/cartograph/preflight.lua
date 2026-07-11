-- PREFLIGHT's pure core: what does this diff touch? Changed lines →
-- the functions containing them (range containment) → the reverse call
-- cone (who depends on what changed) → the SPECS whose import cones
-- reach any touched file (test selection by reverse cone). Pure over a
-- store + a {file -> {line,...}} map; the git parsing and orchestration
-- live in tools/preflight.lua.
--
-- Honesty: spec selection is IMPORT-cone based — a spec that exercises a
-- module without requiring it (fixtures, string dispatch) is not
-- selected, which is why --fast is a loop tool and the full suite still
-- guards the push.

local atr = require 'cartograph.at'

local M = {}

--- changed = { [rel-file] = { line1, line2, ... } } (1-based lines).
--- Returns { fns = {ids}, cone = {ids beyond fns}, files = {set of
--- touched files incl. cone fns' homes}, specs = {spec rel-paths} }.
function M.affected(store, changed)
    local fnset, files = {}, {}
    for file, lines in pairs(changed) do
        files[file] = true
        for _, n in ipairs(store.by_file[file] or {}) do
            if n.kind == 'function' or n.kind == 'method' then
                local s, e = atr.sl(n.range) + 1, atr.el(n.range) + 1
                for _, l in ipairs(lines) do
                    if l >= s and l <= e then fnset[n.id] = true break end
                end
            end
        end
    end
    -- reverse cone over the call graph (usedby): who can observe a change
    local cone, work = {}, {}
    for id in pairs(fnset) do work[#work + 1] = id end
    while #work > 0 do
        local id = table.remove(work)
        for _, from in ipairs(store.usedby[id] or {}) do
            if not fnset[from] and not cone[from] then
                cone[from] = true
                work[#work + 1] = from
                local n = store.node(from)
                if n and n.file then files[n.file] = true end
            end
        end
    end
    -- spec selection: a spec is affected when its transitive REQUIRE cone
    -- reaches any touched file
    local specs = {}
    for _, f in ipairs(store.files) do
        if f:match('^tests/.+_spec%.lua$') then
            local seen, w2 = {}, { f }
            local hit = false
            while #w2 > 0 and not hit do
                local cur = table.remove(w2)
                if not seen[cur] then
                    seen[cur] = true
                    if files[cur] then hit = true break end
                    for _, to in ipairs(store.imports_out[cur] or {}) do
                        w2[#w2 + 1] = to
                    end
                end
            end
            if hit then specs[#specs + 1] = f end
        end
    end
    table.sort(specs)
    local fns, conelist = {}, {}
    for id in pairs(fnset) do fns[#fns + 1] = id end
    for id in pairs(cone) do conelist[#conelist + 1] = id end
    table.sort(fns)
    table.sort(conelist)
    return { fns = fns, cone = conelist, files = files, specs = specs }
end

return M
