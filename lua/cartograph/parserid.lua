-- THE PARSER IDENTITY: which nvim and which tree-sitter parser builds a graph was extracted with.
--
-- A cached graph (and a saved gate baseline) is a function of the source AND of the grammars that parsed it. nvim
-- BUNDLES some parsers (c and lua, in its runtime `parser/` dir, which precedes nvim-treesitter's on the runtimepath),
-- so an nvim upgrade swaps those grammars under every warm cache, and a grammar change moves the graph with no edit to
-- cartograph at all. Before this, the cache key was cartograph's own VERSION plus file stamps, profiles and ecosystem
-- specs: a graph built by the old grammars would have been served as valid after the upgrade, and a gate diff would
-- have mixed the grammar change with the code change under test.
--
-- The key is the nvim version plus a hash over the parser file each language would LOAD: the first `parser/<lang>.*`
-- on the runtimepath (the rule vim.treesitter.language.add follows), by size and mtime. It is recomputed when the
-- runtimepath changes. Registered as a validity contributor, so cache.lua folds it into every manifest's stamp: a
-- different parser set is a clean cache MISS, and an old manifest (no parser part) invalidates once.
local M = {}

local memo_rtp, memo_key

function M.key()
    local rtp = vim.o.runtimepath
    if rtp == memo_rtp and memo_key then return memo_key end
    local seen, parts = {}, {}
    for _, f in ipairs(vim.api.nvim_get_runtime_file('parser/*', true)) do
        local lang = f:match('([^/\\]+)%.[%w]+$')
        if lang and not seen[lang] then
            seen[lang] = true
            local st = vim.uv.fs_stat(f)
            parts[#parts + 1] = lang .. ':' .. (st and (st.size .. ':' .. st.mtime.sec) or '?')
        end
    end
    table.sort(parts)
    local v = vim.version()
    memo_key = ('nvim %d.%d.%d; %d parsers %s'):format(v.major, v.minor, v.patch, #parts,
        vim.fn.sha256(table.concat(parts, ',')):sub(1, 16))
    memo_rtp = rtp
    return memo_key
end

require('cartograph.validity').contribute('parsers', M.key)

return M
