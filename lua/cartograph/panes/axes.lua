-- THE AXIS REGISTRY: a RELATION you can descend from its subject.
--
-- `callers` is the shape being copied here, and the user named why it works:
-- "it is attached to the function and it names the axis it's descending". A row
-- on the subject's own altitude, carrying the relation's NAME and its COUNT,
-- that opens the members. What made it good is that it is DECLARED
-- (concerns.REGISTRY): the count, the inverse, the hover class and the
-- two-halved empty note all come from one place. What was NOT declared drifted
-- immediately -- a var's writers are a hand-rolled SUBSECTION of render_var
-- with no door and no count.
--
-- FOUR KINDS, chosen to differ (CART-0482), because a view designed against
-- `callers` alone would be a grouping rather than a lens:
--   callees / reaches / reached_by   rows are NODES        (cone: TRANSITIVE)
--   imports / imported_by           rows are FILES         (no node row at all)
--   writes                          rows are SITES         (positions, not symbols)
-- Cardinality spans three orders of magnitude on mantis: writes in the units,
-- imports in the tens, a cone in the thousands.
--
-- WHAT AN ENTRY DECLARES
--   glyph, label   what the door says
--   on             which subject it hangs off: 'fn' | 'module' | 'var'
--   rows           (store, id) -> { {node=|file=|site=}, ... }
--   walk           true if the count needs a TRAVERSAL, not a slice. This is
--                  not decoration: a door must show its count at every render,
--                  so a transitive axis makes the doors arm pay a BFS per
--                  cursor move while the one-door arm pays nothing. Declared so
--                  the presentation can memoize it and the A/B can measure it.
--   note           (store, id) -> string|nil, an honest sentence for the EMPTY
--                  case. A zero on an inbound axis is the dangerous kind: the
--                  cone walks CALL edges only, so a function kept alive by a
--                  REGISTRATION (a dispatch table, load-time data) has no
--                  callers and an empty cone while being perfectly live. The
--                  note names the other half of the alibi rather than leaving
--                  the reader with a zero that reads as dead.
--   inverse        the axis you land on if you follow this one and come back
--                  (a declaration, not a copy -- `imports` and `imported_by`
--                  are two entries, and the cone's inverse is the other cone)

local atr = require 'cartograph.at'
local cone = require 'cartograph.cone'
local concerns = require 'cartograph.panes.concerns'

local M = {}

--- WHY AN AXIS MIGHT HAVE NO ANSWER, not just no members. Every axis here is
--- built from edges the thin index does not carry (imports are the exception,
--- but a module roster without calls still cannot answer a cone), so a count of
--- 0 on such a graph would be a fabricated "none" -- the exact defect the
--- concern registry's two-halved empty exists to prevent. Both arms of the A/B
--- ask this BEFORE showing a number, so neither can lie more cheaply than the
--- other. Returns nil when the axis IS computable.
function M.unavailable(store) return concerns.needs_edges(store) end

--- HOW A MODULE READS IN A LIST OF FUNCTIONS. A file-scope use edge's `from` is
--- the MODULE node (CART-0479), and a module's name IS its path -- so the row
--- would sit unlabelled among function names looking exactly like a file row.
--- That confusion was reported twice this week from two other surfaces, so the
--- marker LEADS: the row says what kind of writer this is before it says which.
function M.scope_label(file) return '(file scope) ' .. file end

local STAGEABLE = { ['function'] = true, method = true }

--- Which subject kind an axis hangs off, from the node.
function M.subject_kind(node)
    if not node then return nil end
    if node.kind == 'module' then return 'module' end
    if node.kind == 'var' then return 'var' end
    if STAGEABLE[node.kind] then return 'fn' end
    return nil
end

-- ── the cone memo ───────────────────────────────────────────────────────────
-- A transitive count is a BFS over the reachable subgraph, and a door renders
-- on every cursor move. Memoized per GRAPH IDENTITY (store.data's own table):
-- a re-ingest hands out a new table, so the memo cannot outlive its graph. This
-- is the cheap end of the validity rule -- no stamp needed, because the key IS
-- the thing that would have to change.
local memo = setmetatable({}, { __mode = 'k' })
local function cone_of(store, id, dir)
    local g = store.data
    if not g or M.unavailable(store) then return {} end
    local per = memo[g]
    if not per then per = {}; memo[g] = per end
    local k = dir .. '\31' .. id
    if per[k] == nil then
        per[k] = cone.reachable(id, dir == 'out' and store.uses or store.usedby)
    end
    return per[k]
end

local function node_rows(store, ids)
    local out = {}
    for _, id in ipairs(ids or {}) do
        local n = store.node(id)
        if n then out[#out + 1] = { node = id, name = n.name or id, file = n.file } end
    end
    table.sort(out, function (a, b) return (a.name or '') < (b.name or '') end)
    return out
end

local function cone_rows(store, id, dir)
    local ids = {}
    for cid in pairs(cone_of(store, id, dir)) do ids[#ids + 1] = cid end
    return node_rows(store, ids)
end

local function file_rows(_, recs, key)
    local out, seen = {}, {}
    for _, r in ipairs(recs or {}) do
        local f = type(r) == 'table' and r[key] or r
        if f and not seen[f] then
            seen[f] = true
            out[#out + 1] = { file = f, name = f,
                sideeffect = type(r) == 'table' and r.sideeffect or nil,
                -- ONCE-NESS (CART-0510) rides the row because a reader deciding
                -- whether a var in this file is set-once needs to know whether
                -- the file itself runs once. `false` is the interesting value:
                -- nil means the language does not discriminate, and marking that
                -- would claim a fact nobody asked for.
                rerun = type(r) == 'table' and r.once == false or nil }
        end
    end
    table.sort(out, function (a, b) return a.file < b.file end)
    return out
end

M.ORDER = { 'callees', 'reaches', 'reached_by', 'imports', 'imported_by', 'writes' }

M.AXES = {
    callees = {
        glyph = '↗', label = 'callees', on = 'fn', inverse = 'callers',
        rows = function (store, id) return node_rows(store, store.topo():callees(id)) end,
    },
    reaches = {
        glyph = '∴', label = 'reaches', on = 'fn', inverse = 'reached_by',
        walk = true,
        rows = function (store, id) return cone_rows(store, id, 'out') end,
    },
    reached_by = {
        glyph = '∵', label = 'reached by', on = 'fn', inverse = 'reaches',
        walk = true,
        rows = function (store, id) return cone_rows(store, id, 'in') end,
        -- an empty INBOUND cone on a registered function is not deadness
        note = function (store, id)
            local regs = store.topo():registrants_detail(id)
            if #regs == 0 then return nil end
            local who = {}
            for _, r in ipairs(regs) do who[#who + 1] = r.from end
            return ('nothing CALLS it — it is registered by %s (the ◆ door), and'
                .. ' this cone walks calls only'):format(table.concat(who, ', '))
        end,
    },
    imports = {
        glyph = '⇥', label = 'imports', on = 'module', inverse = 'imported_by',
        rows = function (store, id) return file_rows(store, store.topo():imports_out(id)) end,
    },
    imported_by = {
        glyph = '⇤', label = 'imported by', on = 'module', inverse = 'imports',
        rows = function (store, id)
            -- the DETAIL accessor: the bare imports_in flattens each record to
            -- its `from` id, so every per-site fact (sideeffect, once, soft,
            -- site) was being read off a string and silently coming back nil
            return file_rows(store, store.topo():imports_in_detail(id), 'from')
        end,
    },
    -- THE WRITE AXIS. atlas.classify already counts these to label the var at
    -- all (const / set-once / single-writer / multi-writer), so the rows were
    -- always one filter away from existing -- they were rendered as a
    -- subsection instead, which is the un-declared half this registry fixes.
    writes = {
        glyph = '✎', label = 'writes', on = 'var', inverse = nil,
        rows = function (store, id)
            local out = {}
            -- ★ THE DEFINITION IS A WRITE, and leaving it out made the door say
            -- "writes (0)" about a var whose own source line is an assignment
            -- (reported on mantis: `$g_core_path = $g_absolute_path . 'core' .
            -- DIRECTORY_SEPARATOR;` -> writes (0)). The edge records deliberately
            -- SKIP the mention on the def line -- that is what makes `const`
            -- mean "never assigned again" rather than "never assigned" -- so the
            -- axis has to put it back, marked, or the count is a lie by omission.
            -- MEASURED, and it is why this is sound rather than a guess: a var
            -- node's range SPANS ITS INITIALIZER, so a var born with a value was
            -- written where it was born.
            -- ★ AND SINCE CART-0537 THAT IS NO LONGER EVERY VAR. A declaration with
            -- no initializer used to produce no node at all; java now mints one
            -- (`private final byte[] idPage;` — 42.5% of its field declarators),
            -- marked `decl`, the same field a C prototype uses for "declared, not
            -- defined". Such a row must NOT claim a write: nothing is assigned
            -- there, and the assignment is in a constructor somewhere below. It is
            -- still worth a row — it is where the var IS — so the row says what it
            -- is instead of being dropped, which would leave the axis silent about
            -- the declaration entirely.
            local n = store.node(id)
            if n then
                out[#out + 1] = { site = true, def = not n.decl or nil, var = id,
                    decl = n.decl,
                    name = (n.name or '?') .. (n.decl
                        and '  (declared — assigned elsewhere)' or '  (definition)'),
                    file = n.file, line = atr.sl(n.range), range = n.range }
            end
            -- ★ ONE ROW PER WRITING FUNCTION, not per occurrence. `rw` is a
            -- property of the EDGE -- the union over its occurrence ranges --
            -- so a function that both reads and writes a var has rw=3 on ALL of
            -- them, and emitting a row per range claimed four writes where the
            -- source has one (measured on a php lazy-init getter: nw=1, rows=4).
            -- The graph knows WHO writes, not WHERE within them: atlas counts
            -- exactly these edges to classify the var, so the axis counts what
            -- the label counts. Every occurrence still rides along for the
            -- hover, which highlights them together the way a group row does.
            for _, u in ipairs(store.topo():var_used_by_detail(id)) do
                if (u.rw or 0) >= 2 then
                    local fn = store.node(u.from)
                    local first = u.at and u.at[1]
                    out[#out + 1] = { site = true, fn = u.from,
                        name = fn and fn.kind == 'module'
                            and M.scope_label(fn.file or u.from)
                            or (fn and fn.name or u.from),
                        file = fn and fn.file,
                        line = first and atr.sl(first) or 0,
                        range = first, ranges = u.at,
                        guarded = (u.gw or 1) >= 3 }
                end
            end
            -- the definition first, then the re-assignments in source order
            table.sort(out, function (a, b)
                if (a.def or false) ~= (b.def or false) then return a.def or false end
                return (a.line or 0) < (b.line or 0)
            end)
            return out
        end,
    },
}

--- The axes that hang off this node, in door order.
--- @param all boolean|nil  include the ones a DEFAULT band leaves out
function M.of(node, all)
    local kind = M.subject_kind(node)
    if not kind then return {} end
    local out = {}
    for _, name in ipairs(M.ORDER) do
        local e = M.AXES[name]
        if e.on == kind and (all or not e.walk) then out[#out + 1] = name end
    end
    return out
end

--- WHAT THE DEFAULT BAND LEAVES OUT, and why the line is `walk` rather than
--- taste: a door renders on EVERY cursor move and shows its count, so the
--- expensive axes are the ones whose count is a traversal. Measured on mantis,
--- the fn altitude renders in 6.08 ms with the two cones and 4.49 ms without —
--- so "default" is not a curated favourite list, it is the cheap half, and the
--- band says how many it is holding back rather than hiding the fact.
function M.held_back(node)
    local all, def = M.of(node, true), M.of(node)
    if #all == #def then return nil end
    local out = {}
    for _, name in ipairs(all) do
        local shown = false
        for _, d in ipairs(def) do if d == name then shown = true end end
        if not shown then out[#out + 1] = name end
    end
    return out
end

--- The key an axis altitude is entered with, and its two halves back.
function M.key(name, subject) return name .. '\31' .. subject end
function M.split(key)
    local name, subject = (key or ''):match('^(.-)\31(.*)$')
    return name, subject
end

--- The rows of one axis, or nil if the key names no axis we have.
function M.rows(key, store)
    local name, subject = M.split(key)
    local e = name and M.AXES[name]
    if not (e and subject and store.node(subject)) then return nil end
    return e.rows(store, subject), e
end

--- The COUNT for a door. Separate from rows() only because a door renders on
--- every cursor move: a cheap axis counts its slice, a `walk` axis answers from
--- the memo (built once per graph).
--- @return integer|nil count  nil when the axis cannot be answered at all
function M.count(name, subject, store)
    local e = M.AXES[name]
    if not (e and store.node(subject)) then return 0 end
    if M.unavailable(store) then return nil end
    return #e.rows(store, subject)
end

return M
