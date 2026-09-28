-- cartograph.renamefield — RENAME A RECORD FIELD at the sites that read or define THAT record's field (CART-1175),
-- never a syntactic rename of a name. The step-7 case it replays: `spec.scopes` -> `spec.lexical_scopes`, while
-- `L.scopes` (another record) and `store.scopes()` stay, and the first target (`binders`) was already a slot.
--
--   plan(store, { base, field, to, define = { rel… }?, files = { rel… }?, accept placeholder? })
--     base    the spelling of the record's base (`spec`): a READ site is `<base>.<field>` — rooted by SPELLING, the
--             rule consumers.lua's rooted producers use; a record passed around under another name is a frontier
--     field / to   the old and the new field name
--     define  the files whose TABLE CONSTRUCTORS define the record (`{ field = … }` keys there are renamed too).
--             Omitted: a DECISION listing every file with such a key — which literals ARE this record is the caller's.
-- ★ AN OCCUPIED TARGET IS A DECISION, NOT A REFUSAL (CART-1009): when `<base>.<to>` or a `to = …` key in the define
--   files already exists, the plan stops on `name-occupied`, listing the occupants. Accepting it renames the OCCUPANT
--   to a fresh PLACEHOLDER (`<to>__1`, free at every site by construction) in the same plan, and leaves a deferred
--   decision: choose its real name. Never an auto-mint that overrides a chosen name silently — the placeholder SAYS
--   what it is.
-- ★ TEXT MENTIONS are reported, never rewritten: comments and strings naming `<base>.<field>` (or the field in a
--   string key) are a counted FRONTIER hazard with sites — they cannot be proven, and a rename that silently edits
--   prose is the syntactic rename this is not.
local M = {}

local QUERY = [[
(dot_index_expression table: (identifier) @base field: (identifier) @field)
(field name: (identifier) @key)
]]

local function files_of(store, root, args)
    if args.files then return args.files end
    local out = {}
    for _, f in ipairs(store.files or {}) do if f:match('%.lua$') then out[#out + 1] = f end end
    if #out == 0 then
        for name, ty in vim.fs.dir(root, { depth = 12 }) do
            if ty == 'file' and name:match('%.lua$') and not name:match('^%.') then out[#out + 1] = name end
        end
    end
    table.sort(out)
    return out
end

--- every site in one file's text: reads `<base>.<name>`, constructor keys `<name> =`, text mentions
local function scan(text, base, names)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, 'lua')
    if not ok or not parser then return nil end
    local tree = parser:parse()[1]
    if tree:root():has_error() then return nil end
    local q = vim.treesitter.query.parse('lua', QUERY)
    -- buckets keyed by ROLE (old / new / ph), matched through the name -> role map
    local out, role_of = { reads = {}, keys = {}, mentions = {} }, {}
    for role, n in pairs(names) do out.reads[role], out.keys[role], out.mentions[role] = {}, {}, {}; role_of[n] = role end
    for id, node in q:iter_captures(tree:root(), text) do
        local cap = q.captures[id]
        if cap == 'field' then
            local b = node:parent():field('table')[1]
            local bt = b and vim.treesitter.get_node_text(b, text)
            local role = role_of[vim.treesitter.get_node_text(node, text)]
            if bt == base and role then table.insert(out.reads[role], { node:range() }) end
        elseif cap == 'key' then
            local role = role_of[vim.treesitter.get_node_text(node, text)]
            if role then table.insert(out.keys[role], { node:range() }) end
        end
    end
    -- mentions: comments and strings holding `base.name` or a quoted 'name' / "name"
    local mq = vim.treesitter.query.parse('lua', '(comment) @c (string) @s')
    for _, node in mq:iter_captures(tree:root(), text) do
        local t = vim.treesitter.get_node_text(node, text)
        for role, n in pairs(names) do
            if t:find(base .. '.' .. n, 1, true) or t:find("'" .. n .. "'", 1, true) or t:find('"' .. n .. '"', 1, true) then
                table.insert(out.mentions[role], (node:range()) + 1)
            end
        end
    end
    return out
end

local function offset(lines, row, col) local o = 0; for i = 1, row do o = o + #lines[i] + 1 end; return o + col end

--- replace each range with `to`, bottom-up
local function splice(text, ranges, to)
    local lines = vim.split(text, '\n', { plain = true })
    table.sort(ranges, function (a, b) return a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) end)
    for _, r in ipairs(ranges) do
        local s, e = offset(lines, r[1], r[2]), offset(lines, r[3], r[4])
        text = text:sub(1, s) .. to .. text:sub(e + 1)
        lines = vim.split(text, '\n', { plain = true })
    end
    return text
end

function M.plan(store, args)
    args = args or {}
    local txn, hazard = require 'cartograph.txn', require 'cartograph.hazard'
    local root = store.data and store.data.root
    if not root then return nil, 'no world is loaded', 'ill-posed' end
    for _, k in ipairs { 'base', 'field', 'to' } do
        if type(args[k]) ~= 'string' or not args[k]:match('^[%a_][%w_]*$') then
            return nil, ('`%s` must be a Lua identifier'):format(k), 'ill-posed'
        end
    end
    if args.field == args.to then return nil, 'the field already has that name', 'ill-posed' end
    local placeholder = args.to .. '__1'
    local names = { old = args.field, new = args.to, ph = placeholder }
    local define = {}
    for _, f in ipairs(args.define or {}) do define[f] = true end
    local per, keyfiles, unread = {}, {}, {}
    local nreads, nkeys, occupied, mentions = 0, 0, {}, {}
    for _, rel in ipairs(files_of(store, root, args)) do
        local text = txn.read_file(root, rel)
        local s = text and scan(text, args.base, names)
        if not s then unread[#unread + 1] = rel
        else
            per[rel] = { text = text, s = s }
            nreads = nreads + #s.reads.old
            if #s.keys.old > 0 then keyfiles[#keyfiles + 1] = rel; if define[rel] then nkeys = nkeys + #s.keys.old end end
            if #s.reads.new > 0 then occupied[#occupied + 1] = ('%s: %d read(s) of %s.%s'):format(rel, #s.reads.new, args.base, args.to) end
            if define[rel] and #s.keys.new > 0 then occupied[#occupied + 1] = ('%s: %d `%s =` key(s)'):format(rel, #s.keys.new, args.to) end
            if #s.reads.ph > 0 or (define[rel] and #s.keys.ph > 0) then
                return nil, ('the placeholder name `%s` is itself taken in %s — rename it first'):format(placeholder, rel), 'ill-posed'
            end
            for _, line in ipairs(s.mentions.old) do mentions[#mentions + 1] = ('%s:%d'):format(rel, line) end
        end
    end
    if args.define == nil then
        if nreads == 0 and #keyfiles == 0 then
            return nil, ('no `%s.%s` read and no `%s =` key anywhere'):format(args.base, args.field, args.field), 'empty'
        end
        return nil, ('which table constructors DEFINE this record is your decision: `%s =` keys occur in %s — pass define = { … }')
            :format(args.field, #keyfiles > 0 and table.concat(keyfiles, ', ') or 'no file (pass define = {} for reads only)'), 'decision'
    end
    if nreads == 0 and nkeys == 0 then
        -- the rename is DONE when the new name holds the sites and the old one is gone: re-running is empty
        return nil, ('no `%s.%s` read and no `%s =` key in the define files: nothing to rename'):format(args.base, args.field, args.field), 'empty'
    end
    -- the plan ALWAYS carries the occupant's placeholder rename when the target is taken; the `name-occupied` DECISION
    -- gates it (a tactic stops on it until the caller accepts — CART-1009's "ask, don't refuse")
    local hazards = {}
    if #occupied > 0 then
        hazards[#hazards + 1] = hazard.new('name-occupied', ('`%s` is already taken: %s — accepting renames the occupant to the PLACEHOLDER `%s` in this plan, and leaves choosing its real name as a deferred decision')
            :format(args.to, table.concat(occupied, '; '), placeholder), nil, { occupants = occupied, placeholder = placeholder }, 'decision')
    end
    if #mentions > 0 then
        hazards[#hazards + 1] = hazard.new('text-mentions', ('%d comment/string mention(s) of the old name were NOT rewritten (prose cannot be proven): %s')
            :format(#mentions, table.concat(mentions, ', ', 1, math.min(#mentions, 12))), nil, { sites = mentions }, 'frontier')
    end
    if #unread > 0 then
        hazards[#hazards + 1] = hazard.new('unread', ('%d file(s) did not parse and were not looked at: %s'):format(#unread,
            table.concat(unread, ', ', 1, math.min(#unread, 6))), nil, { files = unread }, 'frontier')
    end
    local edits, touched, stamps = {}, {}, {}
    for rel, p in pairs(per) do
        local s = p.s
        local ranges_old = {}
        for _, r in ipairs(s.reads.old) do ranges_old[#ranges_old + 1] = r end
        if define[rel] then for _, r in ipairs(s.keys.old) do ranges_old[#ranges_old + 1] = r end end
        local ranges_new = {}
        if #occupied > 0 then
            for _, r in ipairs(s.reads.new) do ranges_new[#ranges_new + 1] = r end
            if define[rel] then for _, r in ipairs(s.keys.new) do ranges_new[#ranges_new + 1] = r end end
        end
        if #ranges_old > 0 or #ranges_new > 0 then
            -- occupant -> placeholder and old -> new are disjoint ranges of one text: one bottom-up pass, tagged
            local all = {}
            for _, r in ipairs(ranges_old) do all[#all + 1] = { r[1], r[2], r[3], r[4], to = args.to } end
            for _, r in ipairs(ranges_new) do all[#all + 1] = { r[1], r[2], r[3], r[4], to = placeholder } end
            table.sort(all, function (a, b) return a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) end)
            local t = p.text
            for _, r in ipairs(all) do t = splice(t, { { r[1], r[2], r[3], r[4] } }, r.to) end
            edits[rel] = t; touched[#touched + 1] = rel; stamps[rel] = txn.disk_stamp(root, rel)
        end
    end
    table.sort(touched)
    if #occupied > 0 then
        hazards[#hazards + 1] = hazard.new('placeholder', ('the occupant is renamed to `%s` — a PLACEHOLDER: choose its real name (rename-field %s.%s -> …)')
            :format(placeholder, args.base, placeholder), nil, { placeholder = placeholder }, 'informational')
    end
    local plan = {
        verb = 'rename-field', guards = { 'parses' }, generation = store.generation,
        touched = touched, stamps = stamps, refspecs = {}, edits = edits, hazards = hazards,
        preserves = 'unreviewed',
        preserves_why = 'reads are found by the base SPELLING and keys only in the define files; a record read under another name is not seen (the frontier), so the claim is left for review',
        desc = ('rename-field %s.%s -> %s: %d read(s), %d key(s) in %d file(s)%s'):format(args.base, args.field, args.to, nreads, nkeys,
            #touched, #occupied > 0 and (', occupant -> ' .. placeholder) or ''),
    }
    return txn.protocol(plan, function (p) return function (rel, before) return p.edits[rel] or before end end)
end

return M