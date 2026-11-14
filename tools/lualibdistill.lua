-- lualibdistill — distil a Factorio install's DATA-STAGE LUALIB into a per-version
-- artifact: every global the base game's data stage defines, and the members of each
-- (CART-0651 (b)).
--
-- WHY: the runtime class table models the runtime api and nothing else, so a
-- data-stage global such as `circuit_connector_definitions` was decided against an
-- artifact that could never hold it. 2.0 replaced its `.create` with `.create_vector`
-- / `.create_single`; a 1.1 mod calling `.create` calls nil at load. This artifact is
-- the missing surface: what core's and base's data stage actually leave in the
-- global table, per version.
--
-- AN OPTIONAL INPUT, EXTRACTED ON DEMAND (decision 2026-11-05, CART-1938): the game's
-- data directory is the user's own install and is never packaged. The artifact is
-- written to the ON-DEMAND profile directory (spec.profile.ONDEMAND, outside the
-- repo), never beside the shipped artifacts.
--
--   nvim --headless -u NONE -l tools/lualibdistill.lua <factorio>/data [--out <dir>] [--show]
--
-- HOW, AND WHY IT IS NOT A TEXT SCAN: the data stage is followed as Factorio loads it
-- — core/lualib/dataloader.lua, core/data.lua, then base's data*.lua — through every
-- `require`, resolved as the engine resolves it (the requiring file's directory, the
-- mod root, core/lualib, `__mod__/` paths). Each file is parsed with tree-sitter and
-- names are RESOLVED through a scope stack: `x = …` defines a global only where no
-- local `x` is in scope.
--
-- WHAT A GLOBAL'S MEMBER SET MEANS, and the one direction it is sound in: it is the
-- UNION of every key ever written — constructor fields, `G.k = …`, `G["k"] = …`,
-- `function G.k()`, writes inside function bodies, every reassignment. A union is a
-- superset of what is there at any moment, so "the member is NOT in the set" is a
-- sound absence. That is the only claim a consumer may build on it.
-- A global is OPEN — its member set may not be complete — when anything could add a
-- key the pass cannot name: a write at a computed key, an assignment from a value
-- that is not a constructor or a resolved `require`, or the table escaping as a whole
-- value (aliased, passed to a function other than a read-only iterator, returned).
-- A consumer decides nothing about an open global's members.
-- COMPLETENESS: a literal require that resolves to no file makes the artifact
-- `incomplete` (no absence is decidable). A require at a COMPUTED path (2.0.77's
-- util.sprite_load) could load any file, so every non-runtime core/base file is walked
-- as well; a global or key only that walk adds is `maybe` — kept for absences (a
-- superset), never offered as a presence.
--
-- No network, no graph mutation.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/lualibdistill%.lua$')
package.path = here .. '/../lua/?.lua;' .. here .. '/../lua/?/init.lua;' .. package.path

local M = require 'cartograph.lualib'

-- ── CLI ──────────────────────────────────────────────────────────────────────
if type(_G.arg) == 'table' and type(_G.arg[0]) == 'string'
    and _G.arg[0]:match('lualibdistill%.lua$') then
    local args = _G.arg or {}
    local dir, out, show = nil, nil, false
    local i = 1
    while args[i] do
        if args[i] == '--out' then i = i + 1; out = args[i]
        elseif args[i] == '--show' then show = true
        else dir = args[i] end
        i = i + 1
    end
    if not dir then
        io.write('usage: lualibdistill.lua <factorio>/data [--out <dir>] [--show]\n'); os.exit(2)
    end
    local art, why = M.distill(dir)
    if not art then io.write('refused: ' .. tostring(why) .. '\n'); os.exit(1) end
    local names = vim.tbl_keys(art.globals); table.sort(names)
    local nopen = 0
    for _, n in ipairs(names) do if art.globals[n].open then nopen = nopen + 1 end end
    io.write(('%s %s: %d globals (%d open) from %d files\n'):format(art.runtime,
        art.version, #names, nopen, art.stamp.files))
    if art.incomplete then
        io.write(('INCOMPLETE: %d unresolved require(s): %s\n'):format(#art.incomplete,
            table.concat(art.incomplete, '; ')))
    end
    if art.computed then
        io.write(('computed require at %s: %d more core/base file(s) walked, +%d globals, +%d members\n')
            :format(table.concat(art.computed.sites, ', '), art.computed.files,
                art.computed.added_globals, art.computed.added_members))
    end
    if show then
        for _, n in ipairs(names) do
            local g = art.globals[n]
            local ms = g.members and vim.tbl_keys(g.members) or {}
            table.sort(ms)
            io.write(('  %-44s %-8s %s%s\n'):format(n, g.kind, g.open and ('OPEN (' .. g.open .. ') ') or '',
                #ms > 0 and ('{' .. table.concat(ms, ' ', 1, math.min(#ms, 12)) .. (#ms > 12 and (' …+' .. (#ms - 12)) or '') .. '}') or ''))
        end
    else
        out = out or require('cartograph.spec.profile').ONDEMAND
        vim.fn.mkdir(out, 'p')
        local path = out .. '/' .. art.runtime .. '.mpack'
        local fd = assert(io.open(path, 'wb')); fd:write(vim.mpack.encode(art)); fd:close()
        io.write('wrote ' .. path .. '\n')
    end
end

return M
