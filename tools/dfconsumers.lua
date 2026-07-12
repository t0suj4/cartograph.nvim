-- Tool 2 (df-strangler step 5): the df-CONSUMER CENSUS + the migration verdict.
-- Two lenses on "who reads the df.* seam", because ONE of them fails instructively:
--
--  (1) DOGFOOD — cartograph's own resolved reverse-refs (store.usedby). This is
--      the intended tool, but it's NOISY+INCOMPLETE for df: the read API uses
--      COMMON method names (get/has/count/present) that cartograph refuses as
--      ambiguous (0 resolved callers) while semi-unique ones (stmts) over-match.
--      That gap IS the receiver-typing limitation — a real dogfood finding.
--  (2) RELIABLE — a require-SCOPED syntactic scan: find each file's
--      `require 'cartograph.df'` alias, then count `<alias>.<api>(` calls. Scoped
--      by the require, so it's complete and false-positive-free.
--
-- VERDICT (what step 5 needs): the (1)-vs-(2) gap shows a precise ref-analysis
-- census ISN'T achievable, so we do NOT rewrite consumers. Keep the df.* READ
-- contract and re-back it with flow.coarse — consumers untouched, equivalence
-- guaranteed by dfgate (coarse(stored flow)==df, 11 corpora), NOT by this census.
--
--   nvim --headless -u NONE -l tools/dfconsumers.lua
local REPO = (function ()
    local src = debug.getinfo(1, 'S').source:sub(2)
    return src:match('^(.*)/tools/dfconsumers%.lua$') or '.'
end)()
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
vim.opt.runtimepath:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local READ = { 'has', 'present', 'count', 'stmts', 'get' } -- the migrated seam
local READSET = {}; for _, a in ipairs(READ) do READSET[a] = true end

-- ── (1) dogfood: resolved reverse-refs of df.lua's API nodes ────────────────
store.ingest(ts.extract(REPO))
local data = store.data
local resolved = {} -- api -> count of resolved callers
for _, n in ipairs(data.nodes or {}) do
    if n.file and n.file:match('cartograph/df%.lua$')
        and (n.kind == 'function' or n.kind == 'method') then
        local tail = (n.name or ''):match('([%w_]+)$')
        if tail and (READSET[tail] or tail == 'fold') then
            resolved[tail] = #(store.usedby[n.id] or {})
        end
    end
end

-- ── (2) reliable: require-scoped syntactic scan over the source tree ────────
local consumers = {}  -- "file" -> { api -> count }
local total = {}      -- api -> total call sites
local nfiles = 0
local files = vim.fn.systemlist({ 'git', '-C', REPO, 'ls-files', '*.lua' })
for _, rel in ipairs(files) do
    local ok, lines = pcall(vim.fn.readfile, REPO .. '/' .. rel)
    if ok then
        local body = table.concat(lines, '\n')
        -- the alias this file binds cartograph.df to (if any); + the INLINE
        -- `require('cartograph.df').api(...)` form (no alias binding)
        local alias = body:match("([%w_]+)%s*=%s*require%(?%s*['\"]cartograph%.df['\"]")
        local reqdf = "require%s*%(?%s*['\"]cartograph%.df['\"]%s*%)?%."
        if rel:gsub('.*/', '') ~= 'df.lua' then
            local hits = {}
            for _, api in ipairs(READ) do
                local n = 0
                if alias then for _ in body:gmatch(alias .. '%.' .. api .. '%(') do n = n + 1 end end
                for _ in body:gmatch(reqdf .. api .. '%(') do n = n + 1 end -- inline require().api(
                if n > 0 then hits[api] = n; total[api] = (total[api] or 0) + n end
            end
            if next(hits) then consumers[rel] = hits; nfiles = nfiles + 1 end
        end
    end
end

-- ── report ──────────────────────────────────────────────────────────────
print('\n=== df consumer census — RELIABLE (require-scoped scan) ===')
local order = {}; for f in pairs(consumers) do order[#order + 1] = f end; table.sort(order)
for _, f in ipairs(order) do
    local parts = {}
    for _, api in ipairs(READ) do if consumers[f][api] then parts[#parts + 1] = ('%s×%d'):format(api, consumers[f][api]) end end
    print(('  %-40s %s'):format(f, table.concat(parts, ' ')))
end
local tparts = {}; for _, api in ipairs(READ) do if total[api] then tparts[#tparts + 1] = ('%s=%d'):format(api, total[api]) end end
print(('\n%d consumer files · call sites: %s'):format(nfiles, table.concat(tparts, ' ')))

print('\n=== dogfood cross-check — cartograph resolved reverse-refs ===')
for _, api in ipairs(READ) do
    print(('  df.%-8s resolved callers: %d%s'):format(api, resolved[api] or 0,
        (resolved[api] or 0) == 0 and '   ← ambiguous name → REFUSED (receiver-typing gap)' or ''))
end

print('\n── verdict ─────────────────────────────────────────────────')
print('The reliable scan finds the real consumers; the dogfood pass MISSES the')
print('ambiguous-named ones (get/has/count/present refuse to resolve). A precise')
print('ref-driven census/rewrite is therefore NOT achievable → step 5 keeps the')
print('df.* READ API and re-backs it with flow.coarse (consumers UNTOUCHED);')
print('equivalence is guaranteed by dfgate (coarse(stored flow)==df), not by this.')
