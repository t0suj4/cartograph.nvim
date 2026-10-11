-- cartograph.parsecache — ONE PARSE PER TEXT PER PROCESS. The extractor, flowtype's walker and the lint rules each
-- parsed every file again: tree-sitter parsing was ~18% of an extract + flowtype + lint of lua/cartograph, most of it
-- re-parses of texts already parsed (the profiler, jit.p mode vl). Keyed by (language, the exact text): a different
-- text — a masked parse view, an edited file — is a different entry, so a cached tree is always the tree of that text.
-- Trees are immutable; each entry keeps its owner (the LanguageTree, or the raw parse's TSTree) alive with its root.
--   root(text, lang)        -> the root node (parsed on a miss) | nil
--   put(text, lang, owner, root)   a tree parsed elsewhere (the extractor's reused raw parser)
--   peek(text, lang)        -> the cached root | nil, never parsing (a caller with its own bounded cache)
--   clear()                 drop every tree (a caller that knows it is done with a world)
local M = {}

local CACHE = {}
M.stats = { hits = 0, misses = 0 }

function M.root(text, lang)
    local per = CACHE[lang]
    if not per then per = {}; CACHE[lang] = per end
    local e = per[text]
    if e then M.stats.hits = M.stats.hits + 1; return e[2] end
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or not parser then return nil end
    local tree = parser:parse()[1]
    if not tree then return nil end
    M.stats.misses = M.stats.misses + 1
    local root = tree:root()
    per[text] = { parser, root }
    return root
end

function M.peek(text, lang)
    local per = CACHE[lang]
    local e = per and per[text]
    if e then M.stats.hits = M.stats.hits + 1; return e[2] end
end

function M.put(text, lang, owner, root)
    local per = CACHE[lang]
    if not per then per = {}; CACHE[lang] = per end
    if not per[text] then per[text] = { owner, root } end
end

function M.clear() CACHE = {} end

return M
