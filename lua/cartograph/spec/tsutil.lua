-- Shared tree-sitter helpers for the spec modules AND the engine — the L0
-- grammar-binding substrate ([[cartograph-spec-layering]]). A spec module
-- (spec/<lang>.lua) requires this for the common node primitives instead of
-- reaching into the engine, which would be a require cycle (the engine
-- requires the spec modules). The engine aliases these too, so there is ONE
-- definition. Pure: depends on nothing.

local M = {}

-- Node text, hot-path fast form. vim.treesitter.get_node_text allocates two
-- throwaway tables (opts, metadata) on EVERY call before doing this same
-- byte-slice; over a big corpus that is millions of dead tables feeding the
-- GC. We only ever pass a string source and never metadata, so the slice is
-- byte-for-byte identical (multiline included) without the allocation.
function M.node_text(n, src)
    return src:sub(select(3, n:start()) + 1, select(3, n:end_()))
end

-- indexed child iteration, replacing TSNode:iter_children() everywhere:
-- iter_children allocates a TSTreeCursor userdata + a closure PER CALL —
-- measured 2.7x slower and ~2x more transient garbage than indexed access.
-- STATELESS iterator (zero alloc), same sequence as iter_children (ALL
-- children, anonymous tokens included — existing named()/type() guards
-- filter):  for _, c in tsutil.inext, node, -1 do ... end
function M.inext(n, i)
    i = i + 1
    local c = n:child(i)
    if c then return i, c end
end

-- a REFUSAL is a place: when resolution declines to pick, the call keeps the
-- rule that refused and (capped, sorted — worker == inline) the candidate ids
-- it refused between, so the browser can descend into the fork, not a dead end.
function M.refusal(rule, list)
    if not list or #list == 0 then return { rule = rule } end
    local ids = {}
    for i = 1, math.min(#list, 8) do ids[i] = list[i].id end
    table.sort(ids)
    return { rule = rule, cands = ids, n = #list }
end

return M
