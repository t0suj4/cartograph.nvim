-- cartograph.world — WORLDS AS VALUES (CART-1160 step 3). A world is a set of source texts at a version; its graph is
-- DERIVED from it. This module is the `edit` primitive: an OVERLAY world is a base world plus edits that exist only in
-- memory, and its graph is derived WITHOUT touching the base graph or the disk.
--
--   edit(base_data, { [rel] = text }) -> overlay data (virtual = true) | nil, why, class
--
-- HOW, and why it is cheap (MEASURED before building): refresh's splice already re-derives the edges INTO an edited
-- file from its unchanged callers (rename / shift / add all equal a rebuild), it re-extracts through the graph's
-- TRANSPORT, and it returns NEW nodes/edges/calls tables rather than editing the base's. So an overlay graph is a
-- SHALLOW COPY of the base graph whose transport serves the edits first (the `overlay` kind), spliced on the copy.
-- ⚠ THE SHALLOW COPY SHARES every field the splice does not replace; world_spec fingerprints the whole base graph
-- before and after, so a pass that writes into a shared table is caught there, by name.
-- Research: Glean's stacked databases leave facts derived from a replaced unit dangling ("not implemented yet");
-- here the splice re-derives them, and the acceptance test is CodeNib's — the overlay equals a rebuild.
-- An overlay graph is VIRTUAL: txn.apply refuses it (the Target rule), and planners read its texts through its
-- transport (txn.read_file).
local M = {}

local function copy(t) local o = {}; for k, v in pairs(t or {}) do o[k] = v end; return o end

function M.edit(base, edits)
    if type(base) ~= 'table' or not base.root then return nil, 'edit needs a base graph with a root', 'ill-posed' end
    local rels, files = {}, {}
    for rel, text in pairs(edits or {}) do
        if type(text) ~= 'string' then return nil, ('the edit for %s is not text'):format(tostring(rel)), 'ill-posed' end
        rels[#rels + 1] = rel
        files[base.root .. '/' .. rel] = text
    end
    if #rels == 0 then return nil, 'an edit with no files is the base world itself', 'empty' end
    table.sort(rels)
    local over = copy(base)
    -- the fields a splice may write into are COPIED, never shared with the base
    over.stamps = copy(base.stamps)
    -- ★ AND THE RECORDS: relink writes a newly resolved call's `to` INTO the existing record. MEASURED (world_spec,
    -- the add case): sharing them made the BASE graph's unresolved `B.h` call point at the overlay's new B.h — a
    -- dangling id in a graph that never saw the edit. Every node, edge and call record is copied (shallowly: interned
    -- refusal records are immutable — resolution clears the field, never edits the record). O(facts) per overlay,
    -- the cost Glean's stacked databases pay too.
    for _, key in ipairs { 'nodes', 'edges', 'calls' } do
        local list = base[key]
        if type(list) == 'table' and (list[1] == nil or type(list[1]) == 'table') and getmetatable(list) == nil then
            local out = {}
            for i, rec in ipairs(list) do out[i] = copy(rec) end
            over[key] = out
        end
    end
    over.virtual = true
    over.base_root = base.root
    -- the overlay layer first, then whatever the base read through (a lower overlay, an archive, the disk)
    local stack = { { kind = 'overlay', files = files } }
    for _, layer in ipairs(base.transport or { { kind = 'disk' } }) do
        if layer.kind == 'overlay' then
            -- a stacked edit: the LOWER overlay's texts stay visible under the new ones
            local merged = {}
            for k, v in pairs(layer.files or {}) do merged[k] = v end
            for k, v in pairs(files) do merged[k] = v end
            stack[1] = { kind = 'overlay', files = merged }
        else
            stack[#stack + 1] = layer
        end
    end
    over.transport = stack
    local refresh = require 'cartograph.refresh'
    local stats, why = refresh.splice(over, rels, nil)
    if not stats then return nil, 'the overlay could not be derived: ' .. tostring(why), 'unbuilt' end
    refresh.relink(over)
    return over
end

return M
