-- cartograph.parsecache — ONE PARSE PER TEXT PER PROCESS. The extractor, flowtype's walker and the lint rules each
-- parsed every file again: tree-sitter parsing was ~18% of an extract + flowtype + lint of lua/cartograph, most of it
-- re-parses of texts already parsed (the profiler, jit.p mode vl). Keyed by (language, the exact text): a different
-- text — a masked parse view, an edited file — is a different entry, so a cached tree is always the tree of that text.
-- Trees are immutable; each entry keeps its owner (the LanguageTree, or the raw parse's TSTree) alive with its root.
-- ★ BOUNDED BY SOURCE BYTES (CART-1664): nothing ever cleared it, so a LONG-LIVED process (the LSP, the MCP agent, the
-- cockpit) kept the tree of every text it had ever parsed — every edit a new entry, the old trees never freed. Past
-- MAX_BYTES of cached source the OLDEST entries are dropped (a dropped text is parsed again on its next use, which is
-- what every caller did before this cache). Trees cost ~25x their source in memory (the 428-file corpus: 9.5 MB of
-- source, 237 MB of trees), so the default 32 MB of source is ~800 MB of trees: a whole batch corpus of that size
-- stays cached, an editing session is capped. CARTOGRAPH_PARSECACHE_MB overrides it.
--   root(text, lang)        -> the root node (parsed on a miss) | nil
--   put(text, lang, owner, root)   a tree parsed elsewhere (the extractor's reused raw parser)
--   peek(text, lang)        -> the cached root | nil, never parsing (a caller with its own bounded cache)
--   size()                  -> cached source bytes, entries
--   clear()                 drop every tree (a caller that knows it is done with a world)
local M = {}

local CACHE, ORDER, HEAD, BYTES = {}, {}, 1, 0
M.stats = { hits = 0, misses = 0, evictions = 0 }
M.MAX_BYTES = (tonumber(vim.env.CARTOGRAPH_PARSECACHE_MB or '') or 32) * 1048576

-- (ORDER is a FIFO of { lang, text } in insertion order; HEAD its oldest live slot)
local function insert(lang, text, owner, root)
    local per = CACHE[lang]
    if not per then per = {}; CACHE[lang] = per end
    if per[text] then return end
    per[text] = { owner, root }
    ORDER[#ORDER + 1] = { lang, text }
    BYTES = BYTES + #text
    while BYTES > M.MAX_BYTES and HEAD < #ORDER do -- (the newest entry always stays, whatever its size)
        local o = ORDER[HEAD]
        ORDER[HEAD] = nil
        HEAD = HEAD + 1
        local p = CACHE[o[1]]
        if p and p[o[2]] then p[o[2]] = nil; BYTES = BYTES - #o[2]; M.stats.evictions = M.stats.evictions + 1 end
    end
end

function M.root(text, lang)
    local per = CACHE[lang]
    local e = per and per[text]
    if e then M.stats.hits = M.stats.hits + 1; return e[2] end
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok or not parser then return nil end
    local tree = parser:parse()[1]
    if not tree then return nil end
    M.stats.misses = M.stats.misses + 1
    local root = tree:root()
    insert(lang, text, parser, root)
    return root
end

function M.peek(text, lang)
    local per = CACHE[lang]
    local e = per and per[text]
    if e then M.stats.hits = M.stats.hits + 1; return e[2] end
end

function M.put(text, lang, owner, root) insert(lang, text, owner, root) end

--- the cached source bytes and entries (a long-lived process can report what it holds)
function M.size()
    local n = 0
    for _, per in pairs(CACHE) do for _ in pairs(per) do n = n + 1 end end
    return BYTES, n
end

function M.clear() CACHE, ORDER, HEAD, BYTES = {}, {}, 1, 0 end

return M
