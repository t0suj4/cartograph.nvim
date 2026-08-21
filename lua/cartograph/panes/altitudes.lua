-- THE ALTITUDE REGISTRY: what CONTAINS each altitude, declared once.
--
-- The browser has two ways out of a view. `h` is HISTORY -- the trail, one press
-- per descent. `H` is CONTAINMENT -- off the trail, up the structural tree. The
-- second one needs an answer per altitude, and until this file that answer lived
-- in an eleven-branch if/elseif inside the ascend keymap.
--
-- WHY THAT WAS A BUG FACTORY, in the words of the file next door: concerns.lua
-- exists because five relation altitudes each "open-coded the same five answers
-- in five different places [...] and every one of those lists was incomplete for
-- at least one altitude". The cure was scoped to RELATION altitudes only, so the
-- containment answer kept being written by hand -- and the predicted hole was
-- there: `syms` had NO branch at all (nobody noticed, because the trail always
-- answered first), and `live` had none either. navaudit already fences two
-- per-altitude dispositions at ratchet 0 (is it a concern? does it hover a
-- node?); this file gives it the third, so an altitude cannot ship without
-- saying what encloses it.
--
-- WHAT AN ENTRY DECLARES -- exactly one of:
--   up    = function (key, store, ctx) -> level, key, anchor
--           where `key` is M.view[<altitude>] (the field is the altitude's own
--           name, for every altitude) and `anchor` says where to put the cursor
--           in the view that opens. A CLOSED set of forms, so the pane's applier
--           stays one small function and this table stays data:
--             { row = N }     a fixed row number
--             { node = id }   the row that IS this node
--             { line = N }    a 1-based source line (lands via the containment
--                             chain, so a folded compound statement is opened)
--             { file = f }    the row that names this file
--             { lit = key }   the literal-tree row with this key
--             { state = k }   the state row with this key
--   root  = why nothing contains this altitude (a string, kept as the record)
--
-- The eight RELATION altitudes are NOT listed here: their inverse is already
-- declared as concerns.REGISTRY[lvl].ascend / .ascend_row, and copying it would
-- be a second source of truth for one fact. They are folded in below, from that
-- declaration.
--
-- GROUPING IS DELIBERATELY ABSENT. The altitude rethink
-- ([[cartograph-navigation-model]]) wants altitudes grouped by behaviour --
-- containment vs axis vs interpretation -- and the way to get there is to let
-- every altitude state its answers first and read the groups off the table.
-- Asserting the taxonomy before the members declare anything is how "4 of 21
-- rungs are interpretations wearing a rung" happened in the first place.

local vim = vim
local atr = require 'cartograph.at'
local concerns = require 'cartograph.panes.concerns'

local M = {}

--- The containment ladder for a NODE-shaped subject: the region that holds it,
--- else its file, else the file tree. Shared by every altitude that hangs off a
--- node rather than off another view (var, a literal/live tree at its root, the
--- FSM model via its spec var).
--- A MODULE is its file, so it surfaces to the file altitude with no row: a
--- module node has no row of its own inside its own file view.
function M.up_of_node(id, store)
    local n = id and store.node(id)
    if not n then return 'files' end
    if n.kind == 'module' then return 'file', n.file end
    for _, c in ipairs(store.by_file[n.file] or {}) do
        if c.kind == 'region' and atr.sl(c.range) <= atr.sl(n.range)
            and atr.el(c.range) >= atr.el(n.range) then
            return 'region', c.id, { node = id }
        end
    end
    return 'file', n.file, { node = id }
end

--- The REGION holding a line in a file, or nil. A site in module-level data (a
--- registration, a dispatch-table entry) belongs to the region that contains it,
--- which is where the browser can show it in context -- the file altitude only
--- lists defs, so landing there means landing on row 1.
function M.region_at(file, line0, store)
    for _, n in ipairs(store.by_file[file] or {}) do
        if n.kind == 'region' and atr.sl(n.range) <= line0
            and atr.el(n.range) >= line0 then
            return n.id
        end
    end
end

--- A DEF altitude (fn / region / tbl) is contained by its file, on its own row.
--- The nil-node case keeps the current file rather than guessing: `M.show('file',
--- nil)` leaves M.view.file alone, which is what the hand-written branch did.
local function up_of_def(key, store)
    local n = key and store.node(key)
    return 'file', n and n.file or nil, { node = key }
end

--- A key of the form `<owner>\31<sr>\31...` is contained by the owner's function,
--- on the statement that holds the range's first line. Shared by `block` and
--- `syms`, whose keys are spelled the same way on purpose.
local function up_of_ranged(key, store)
    local owner, sr = (key or ''):match('^(.-)\31(%-?%d+)')
    if not (owner and store.node(owner)) then return 'files' end
    return 'fn', owner, { line = tonumber(sr) + 1 }
end

--- A VALUE TREE (`lit`, `live`): one path segment up, or out onto the node whose
--- value it is. The child key rides along as the anchor so the row you came from
--- is where the cursor lands.
local function up_of_tree(level, anchor_kind)
    return function (key, store)
        local parts = vim.split(key or '', '\31')
        if #parts > 1 then
            local child = table.concat(parts, '\31')
            table.remove(parts)
            return level, table.concat(parts, '\31'), { [anchor_kind] = child }
        end
        return M.up_of_node(parts[1], store)
    end
end

M.REGISTRY = {
    -- ── roots: nothing structural above them ────────────────────────────────
    files  = { root = 'the structural root: the file tree contains everything' },
    protos = { root = 'a ROOT axis (the prototype roster): its rows hang from'
        .. ' nothing, and its door is :CartographPrototypes!' },
    ws     = { root = 'the working set is a USER set, not a place in the tree' },

    -- ── containment proper ──────────────────────────────────────────────────
    file   = { up = function (key) return 'files', nil, { file = key } end },
    fn     = { up = up_of_def },
    region = { up = up_of_def },
    tbl    = { up = up_of_def },
    block  = { up = up_of_ranged },
    syms   = { up = up_of_ranged },
    var    = { up = function (key, store) return M.up_of_node(key, store) end },

    -- ── data-borne altitudes ────────────────────────────────────────────────
    lit    = { up = up_of_tree('lit', 'lit') },
    live   = { up = up_of_tree('live', 'lit') }, -- live rows ARE lit rows
    state  = { up = function (key) return 'states', nil, { state = key } end },
    -- the FSM model hangs below the var that DECLARES it (the FSM-anchor law).
    -- The anchor is a model lookup, so the pane hands it in rather than this
    -- table reaching for the config.
    states = { up = function (_, store, ctx)
        return M.up_of_node(ctx and ctx.anchor and ctx.anchor.id, store)
    end },
}

-- THE RELATION ALTITUDES, folded in from their own declaration. concerns.ascend
-- IS the containment answer for a relation (the FSM-anchor law again: every
-- altitude hangs somewhere in the structural tree, and a concern hangs off its
-- subject), so it is reused rather than restated.
for lvl, e in pairs(concerns.REGISTRY) do
    M.REGISTRY[lvl] = M.REGISTRY[lvl] or {
        view_key = e.view_key, -- the concern's own declaration, not a guess
        up = function (key)
            local level, target = e.ascend(key)
            return level, target, e.ascend_row and { row = e.ascend_row } or nil
        end,
        from_concern = true,
    }
end

--- The declaration for `level`, or nil if it has none (which navaudit fails on).
function M.of(level) return M.REGISTRY[level] end

--- The KEY this altitude is currently showing, out of a view table. Every
--- altitude happens to keep its key in the field of its own name, and a
--- coincidence is not a contract: the field is declared (defaulting to the name),
--- so a future altitude that stores its key elsewhere cannot silently read nil.
function M.key_of(level, view)
    local e = M.REGISTRY[level]
    return view[(e and e.view_key) or level]
end

return M
