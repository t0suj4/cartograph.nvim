-- Shared tree-sitter helpers for the spec modules AND the engine — the L0
-- grammar-binding substrate ([[cartograph-spec-layering]]). A spec module
-- (spec/<lang>.lua) requires this for the common node primitives instead of
-- reaching into the engine, which would be a require cycle (the engine
-- requires the spec modules). The engine aliases these too, so there is ONE
-- definition. Pure: depends on nothing.

-- @langs any — a SHARED helper over every spec: the node types it names
-- belong to whichever grammar the caller passed, not to one of its own.

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

-- ── guard substrate ──────────────────────────────────────────────────────
-- Shared by the language `guards` specs (lua, php, …) AND the engine's generic
-- guard machinery. Grammar-agnostic node predicates; each language's GUARDS
-- table wires them into its own set-once/presence/absence tests. Lives here
-- (not the engine) so a spec module can require them without a require cycle.

-- whitespace-stripped node text, for the rare longer-span comparison fallback
local function ntext(x, src) return (M.node_text(x, src):gsub('%s', '')) end

-- text-equality of a node's source span against a target `chain` string,
-- span-length-gated (most comparisons reject on a cheap byte-length check).
-- A longer span falls back to whitespace-insensitive compare (format variance).
function M.chain_eq(x, src, chain)
    local d = select(3, x:end_()) - select(3, x:start())
    if d < #chain then return false end
    if d == #chain then return M.node_text(x, src) == chain end
    return ntext(x, src) == chain -- longer: whitespace variance, rare
end

-- anonymous nodes' type() IS their literal text: no string extraction
function M.optext_is(n, _, want)
    for i = 0, n:child_count() - 1 do
        local ch = n:child(i)
        if not ch:named() and want[ch:type()] then return true end
    end
    return false
end

-- descend through parenthesized wrappers to the inner expression
function M.unparen(n)
    while n and n:type() == 'parenthesized_expression' do n = n:named_child(0) end
    return n
end

return M
