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

return M
