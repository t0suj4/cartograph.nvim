-- cartograph.reshape — CHANGE A RECORD FAMILY'S REPRESENTATION at exactly the accesses flowtype says it reaches
-- (CART-1656, provenance reshape). The family and its roster come from renamefield.family (flowtype's access roster);
-- this module holds the transformations beyond a rename.
--
--   plan(store, { family = { 'file.lua:LINE', … }, positional = { '1=x', '2=y', … }, world = 'closed' | 'open' })
--     POSITIONAL -> NAMED: `{ a, b }` becomes `{ x = a, y = b }` in the family's constructors, `t[1]` becomes `t.x` at
--     every access the family reaches (a read or a write, under any spelling).
-- A position read or built that the mapping does not name stops on a DECISION (name it too). A use of the family AS AN
-- ARRAY — `#t`, ipairs, table.insert / concat / sort / remove / unpack, a computed numeric index — or of its keys
-- (pairs), or a computed key, cannot keep its meaning once the positions are names: a FRONTIER, refused with the
-- sites. So are saturated / partial accesses the family reaches and a family that escaped (renamefield.family). An
-- access shared with other tables stops on the widen-the-family decision; a target name already a field of the family
-- on the name-occupied one. A family whose metatable has an __index FUNCTION refuses (computed fields).
local M = {}

-- replace each { sr, sc, er, ec, text } range, bottom-up (an insertion is an empty range)
local function splice(text, edits)
    local lines = vim.split(text, '\n', { plain = true })
    local function offset(row, col) local o = 0; for i = 1, row do o = o + #lines[i] + 1 end; return o + col end
    local abs = {}
    for _, e in ipairs(edits) do abs[#abs + 1] = { offset(e[1], e[2]), offset(e[3], e[4]), e[5] } end
    table.sort(abs, function (a, b) return a[1] > b[1] end)
    for _, e in ipairs(abs) do text = text:sub(1, e[1]) .. e[3] .. text:sub(e[2] + 1) end
    return text
end

function M.plan(store, args)
    args = args or {}
    local txn = require 'cartograph.txn'
    local root = store.data and store.data.root
    if not root then return nil, 'no world is loaded', 'ill-posed' end
    if type(args.family) ~= 'table' or #args.family == 0 then return nil, '`family` names the table constructors (file:LINE, …)', 'ill-posed' end
    if type(args.positional) ~= 'table' or #args.positional == 0 then return nil, '`positional` maps positions to names (1=x, 2=y, …)', 'ill-posed' end
    local name_of, taken = {}, {}
    for _, kv in ipairs(args.positional) do
        local i, nm = tostring(kv):match('^(%d+)=([%a_][%w_]*)$')
        if not i then return nil, ('`%s` is not POSITION=name'):format(tostring(kv)), 'ill-posed' end
        if name_of[i] or taken[nm] then return nil, ('`%s` maps a position or a name twice'):format(tostring(kv)), 'ill-posed' end
        name_of[i], taken[nm] = nm, true
    end
    local F, why, class = require('cartograph.renamefield').family(store, args)
    if not F then return nil, why, class or 'ill-posed' end
    local fam, where = F.fam, F.where
    local edits, frontier, others, unmapped, occupied = {}, {}, {}, {}, {}
    local npos, nidx = 0, 0
    -- (an __index FUNCTION on the family computes what an index reads: no roster sees it)
    for site in pairs(fam) do
        local _, computed = F.R.proto_fields(site, '#')
        if computed then frontier[#frontier + 1] = site .. ' has an __index function (fields are computed)' end
    end
    for _, a in ipairs(F.R.accesses or {}) do
        local mine, foreign = false, {}
        for site in pairs(a.sites) do if fam[site] then mine = true else foreign[#foreign + 1] = site end end
        local positional = a.kind == 'pos' or a.kind == 'index'
        if mine and a.loaded then
            -- (in code loaded from a string LITERAL: followed, but no rewrite can edit a string — CART-1796)
            frontier[#frontier + 1] = where(a) .. ' in code loaded from a string literal (not rewritable)'
        elseif mine then
            if a.kind == 'array' then frontier[#frontier + 1] = where(a) .. ' uses it as an array'
            elseif a.kind == 'iterate' then frontier[#frontier + 1] = where(a) .. ' iterates its keys'
            elseif a.kind == 'dynamic' then frontier[#frontier + 1] = where(a) .. ' a computed key'
            elseif (a.top or a.partial) and (positional or taken[a.field]) then frontier[#frontier + 1] = where(a) .. (a.top and ' saturated' or ' partial')
            elseif positional then
                if #foreign > 0 then table.sort(foreign); others[#others + 1] = where(a) .. ' also ' .. table.concat(foreign, ', ')
                elseif not name_of[a.field] then unmapped[#unmapped + 1] = where(a) .. ' position ' .. a.field
                else
                    local l = edits[a.file] or {}; edits[a.file] = l
                    local r = a.range
                    if a.kind == 'pos' then l[#l + 1] = { r[1], r[2], r[1], r[2], name_of[a.field] .. ' = ' }; npos = npos + 1
                    else l[#l + 1] = { r[1], r[2], r[3], r[4], '.' .. name_of[a.field] }; nidx = nidx + 1 end
                end
            elseif taken[a.field] then occupied[#occupied + 1] = where(a) .. ' ' .. a.field
            end
        elseif a.top and a.kind == 'index' and name_of[a.field] then
            frontier[#frontier + 1] = where(a) .. ' saturated (it may hold the family)'
        end
    end
    local function list(t) table.sort(t); return table.concat(t, '; ', 1, math.min(#t, 12)) end
    if #frontier > 0 then return nil, ('%d use(s) cannot keep their meaning with named fields: %s'):format(#frontier, list(frontier)), 'frontier' end
    if #others > 0 then return nil, ('the family is not closed: %d access(es) are shared with other tables — add them to the family: %s'):format(#others, list(others)), 'decision' end
    if #unmapped > 0 then return nil, ('%d position(s) the mapping does not name are built or read: %s — name them too'):format(#unmapped, list(unmapped)), 'decision' end
    -- (nothing left to reshape is DONE — a re-run after the reshape finds the names it wrote, and that is no collision)
    if npos + nidx == 0 then return nil, 'no positional field or index of the family: nothing to reshape', 'empty' end
    if #occupied > 0 then return nil, ('a target name is already a field of the family: %s'):format(list(occupied)), 'decision' end
    local out, touched, stamps = {}, {}, {}
    for rel, l in pairs(edits) do
        local text = txn.read_file(root, rel)
        if not text then return nil, 'cannot read ' .. rel, 'ill-posed' end
        out[rel] = splice(text, l); touched[#touched + 1] = rel; stamps[rel] = txn.disk_stamp(root, rel)
    end
    table.sort(touched)
    local plan = {
        verb = 'reshape', guards = { 'parses' }, generation = store.generation,
        touched = touched, stamps = stamps, refspecs = {}, edits = out, hazards = {},
        preserves = 'unreviewed',
        preserves_why = 'by PROVENANCE: every positional field and constant index flowtype resolves to the family is named, every rewritten access is reached ONLY by the family, and any use as an array, of its keys, a computed key, a saturated or partial access refused the plan. Not covered: a metatable',
        desc = ('reshape (family of %d) positional -> named: %d constructor field(s), %d index access(es) in %d file(s)'):format(F.n, npos, nidx, #touched),
    }
    return txn.protocol(plan, function (p) return function (rel, before) return p.edits[rel] or before end end)
end

return M
