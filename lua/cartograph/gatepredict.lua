-- GATE PREDICTION's pure core: given a diff, which corpora CANNOT move?
--
-- The claim is a PROMISE — "these corpora cannot move" speaks about behaviour
-- that has not happened yet, so it is REFUTABLE ONLY and never confirmable
-- ([[cartograph-witness-and-promise]]). A real gate run can kill a prediction;
-- no number of agreeing runs can establish one. That asymmetry IS the design:
-- the interesting output is a REFUTATION.
--
-- SUBTRACTIVE ONLY. `predict` returns what it can rule OUT and what it cannot.
-- It never says a gate will pass — predicting the CONTENT of a gate delta is
-- just running the gate.
--
-- TWO AXES, and the second one is easy to miss. A corpus is reachable by a
-- change only if BOTH hold:
--   LANGUAGE  the corpus contains files of a language the change can affect
--   PROVIDER  the corpus is extracted by a provider the change can affect
-- bench.lua:223 dispatches ONE provider per corpus (`c.provider or
-- 'treesitter'`), exclusively. So bwipp carries 2 .rb files and is still
-- immovable by a ruby SPEC change: `M.spec` lives on the treesitter provider
-- and bwipp is extracted by the token provider, which never consults it.
-- Dropping the provider axis makes the predictor merely conservative; dropping
-- the language axis makes it useless.
--
-- ★ ABSENCE AND NEGATION MUST NOT RENDER THE SAME. Three situations arrive
-- here and two look alike if you are careless:
--   scope='langs'  a scoped diff — subtraction is possible
--   scope='all'    shared machinery changed — every corpus stays in play; this
--                  is a REFUSAL to subtract, not an empty subtraction
--   scope='none'   nothing that can affect extraction changed at all
-- `all` and `none` yield opposite verdicts from a similarly-empty language set.

local M = {}

-- Shared spec substrate: a change here can reach any language.
local SHARED_SPEC = { contract = true, tsutil = true }

--- Languages a spec module governs beyond its own name. `spec/javascript.lua`
--- is COPIED into typescript and tsx by the registry (treesitter.lua ~702), so
--- editing it reaches all three. Declared, not derived — a copy loses table
--- identity, so there is nothing to follow. `M.registry_gaps` is the fence that
--- keeps this from going stale: a language nothing maps to is a REPORTED gap.
--- ★ REGISTERED IS NOT CORRECT — the fence checks reach, not mere presence.
M.DERIVED = { javascript = { 'typescript', 'tsx' } }

--- ext -> {lang, ...}. SET-VALUED on purpose: `.h` resolves to c or cpp by
--- REPO SHAPE at extraction time (treesitter.lua H_LANG), so statically it is
--- both, and a subtractive claim must keep both alive.
function M.ext_langs(spec, dialect)
    local out = {}
    local function add(ext, lang)
        out[ext] = out[ext] or {}
        for _, l in ipairs(out[ext]) do if l == lang then return end end
        out[ext][#out[ext] + 1] = lang
    end
    for lang, s in pairs(spec or {}) do
        for _, ext in ipairs((type(s) == 'table' and s.exts) or {}) do add(ext, lang) end
    end
    for ext, dname in pairs(dialect or {}) do add(ext, dname) end
    -- @langs-ok `.h` is the one extension NO spec can claim alone — it is C and
    -- C++ both, and mapping it to either would make the prediction wrong for the
    -- other. Everything else in this table comes from the spec roster
    -- @langs-ok `.h` is C and C++ both; no spec can claim it alone
    if out.h then add('h', 'c') add('h', 'cpp') end
    for _, v in pairs(out) do table.sort(v) end
    return out
end

--- The extension a path counts as, LONGEST CLAIMED SUFFIX FIRST.
--- ★ COMPOUND EXTENSIONS ARE REAL AND TAKING THE LAST DOT-SEGMENT LOSES THEM.
--- The token provider declares postscript as { ps, ['ps.src'] }, and
--- postscriptbarcode holds 125 files named `*.ps.src`. Matching only `src`
--- files them as unclaimed, which UNDERCOUNTS postscript — and an undercounted
--- language is the unsound direction for a subtractive claim: a corpus holding
--- nothing but `.ps.src` would be ruled out of a postscript change entirely.
--- Falls back to the final segment so the unclaimed bucket still gets a name.
--- @return string? ext, boolean claimed
function M.ext_of(path, ext_langs)
    local base = path:match('([^/]+)$') or path
    local best
    -- every suffix starting at a dot, longest first
    for i = 1, #base do
        if base:sub(i, i) == '.' then
            local cand = base:sub(i + 1)
            if ext_langs[cand] then best = best or cand end
        end
    end
    if best then return best, true end
    local last = base:match('%.([%w_]+)$')
    return last, false
end

--- Which languages does this corpus contain? Counts are per FILE.
--- @return table langs, table unclaimed   (unclaimed: exts no language claims —
---   a large bucket there is a coverage finding, not noise)
function M.corpus_langs(ext_counts, ext_langs)
    local langs, unclaimed = {}, {}
    for ext, n in pairs(ext_counts or {}) do
        local ls = ext_langs[ext]
        if ls then
            for _, l in ipairs(ls) do langs[l] = (langs[l] or 0) + n end
        else
            unclaimed[ext] = n
        end
    end
    return langs, unclaimed
end

-- ── OUTPUT-NEUTRAL EDITS (CART-0622) ────────────────────────────────────────
-- Every extraction change ships with a cache.lua VERSION bump, and cache.lua is an engine file, so one bump forced
-- scope=all and the predictor was disarmed on exactly the commits it exists for: replayed, 76 of 84 scored commits read
-- scope=all, cache.lua among the files of 66. The rule is by CONSTRUCT, never by file:
--   · comment text is output-neutral in any Lua file — it cannot change what runs;
--   · the NUMBER assigned to cache.lua's `M.VERSION` is output-neutral — it keys caches and stamps an advisory epoch
--     (snapshot.tool_verdict), and extraction never reads it. In any other module a VERSION may be read, so it is not.
-- Decided on the PARSE, not the text: a `--` line inside a long string is code, and a side that does not parse is
-- never neutral. A wrong subtraction is the harmful direction for a promise, so every doubt answers "not neutral".
local NEUTRAL_VERSION_IN = { ['lua/cartograph/cache.lua'] = true }
local tsutil = require 'cartograph.spec.tsutil'

-- the leaves of a Lua source minus comments: { { type, text, node } }, or nil when it does not parse
local function leaves(src)
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not okp or not parser then return nil end
    local tree = parser:parse()[1]
    local root = tree and tree:root()
    if not root or root:has_error() then return nil end
    local out = {}
    local function walk(n)
        if n:type() == 'comment' then return end
        if n:child_count() == 0 then
            out[#out + 1] = { n:type(), vim.treesitter.get_node_text(n, src), n }
            return
        end
        for _, c in tsutil.inext, n, -1 do walk(c) end
    end
    walk(root)
    return out
end

-- is this leaf the number literal of an assignment `M.VERSION = <number>`?
local function version_number(leaf, src)
    if leaf[1] ~= 'number' then return false end
    local p = leaf[3]:parent()
    while p and p:type() ~= 'assignment_statement' do
        if p:type() ~= 'expression_list' then return false end
        p = p:parent()
    end
    if not p then return false end
    local vars = p:named_child(0)
    return vars ~= nil and vim.treesitter.get_node_text(vars, src):gsub('%s', '') == 'M.VERSION'
end

--- is the edit of `path` from `before` to `after` OUTPUT-NEUTRAL? -> a reason, or nil (= treat it as a real change)
function M.neutral(path, before, after)
    if type(before) ~= 'string' or type(after) ~= 'string' or not path:match('%.lua$') then return nil end
    local a, b = leaves(before), leaves(after)
    if not a or not b or #a ~= #b then return nil end
    local bumped = false
    for i = 1, #a do
        if a[i][1] ~= b[i][1] then return nil end
        if a[i][2] ~= b[i][2] then
            if NEUTRAL_VERSION_IN[path] and version_number(a[i], before) and version_number(b[i], after) then
                bumped = true
            else
                return nil
            end
        end
    end
    return bumped and 'a cache VERSION bump (and comments)' or 'comments only'
end

--- Which languages/providers can a set of changed repo files affect?
--- @param changed string[]  repo-relative paths
--- @param known table  every language the registry knows (lang -> true)
--- @param provider_langs table  provider -> { lang -> true }, the languages a
---   given provider can produce at all. Used to bound a providers/<p>.lua edit.
--- @param neutral table?  path -> reason, from M.neutral: an output-neutral edit reaches nothing (CART-0622)
--- @return table { scope, langs, providers (nil = every provider), why }
function M.touched(changed, known, provider_langs, neutral)
    local langs, why, all = {}, {}, false
    local providers, n = {}, 0
    local function reach_all(f, reason)
        all = true
        why[f] = reason
    end
    for _, f in ipairs(changed or {}) do
        local lang = f:match('^lua/cartograph/spec/([%w_]+)%.lua$')
        local eco = f:match('^lua/cartograph/spec/ecosystem/([%w_%-]+)')
        local prof = f:match('^lua/cartograph/spec/profile/([%w_%-]+)')
        local prov = f:match('^lua/cartograph/providers/([%w_]+)%.lua$')
        if neutral and neutral[f] then
            why[f] = ('output-neutral (%s) — ignored'):format(neutral[f])
        elseif prov then
            -- a provider edit is bounded to THAT provider; within it, every
            -- language it serves is in play.
            local pl = provider_langs and provider_langs[prov]
            providers[prov] = true
            if pl then
                n = n + 1
                for l in pairs(pl) do langs[l] = true end
                why[f] = ('provider %s — %s'):format(prov, 'its languages only')
            else
                reach_all(f, ('provider %s — languages unknown'):format(prov))
            end
        elseif lang and SHARED_SPEC[lang] then
            reach_all(f, 'shared spec substrate — reaches every language')
        elseif lang and known[lang] then
            n = n + 1
            langs[lang] = true
            -- M.spec is a treesitter-provider concept; the token provider
            -- never reads it. THIS is what makes bwipp immovable by a ruby fix.
            providers.treesitter = true
            why[f] = 'spec for ' .. lang .. ' (treesitter provider only)'
            for _, d in ipairs(M.DERIVED[lang] or {}) do langs[d] = true end
        elseif eco or prof then
            -- `lua-factorio.lua`, `cruby.mpack`, `zig-std.mpack`: try the whole
            -- name first so `cruby` never silently means `c`, then the head.
            local base = eco or prof
            local pick = known[base] and base or nil
            if not pick then
                local head = base:match('^([%w]+)%-')
                if head and known[head] then pick = head end
            end
            if pick then
                n = n + 1
                langs[pick] = true
                providers.treesitter = true
                why[f] = (eco and 'ecosystem pack for ' or 'env profile for ') .. pick
            else
                reach_all(f, 'pack/profile whose language is not readable from its name')
            end
        elseif f:match('^lua/cartograph/') or f:match('^queries/') then
            reach_all(f, 'engine or query file — reach unbounded')
        else
            why[f] = 'outside the extraction path — ignored'
        end
    end
    if all then return { scope = 'all', langs = langs, providers = nil, why = why } end
    if n == 0 then return { scope = 'none', langs = {}, providers = {}, why = why } end
    return { scope = 'langs', langs = langs, providers = providers, why = why }
end

--- The prediction. SUBTRACTIVE: `immovable` is the claim; `movable` is merely
--- everything not ruled out and is NOT a claim that those will move.
--- @param inventories table  name -> { langs = {lang->count}, provider = string }
function M.predict(inventories, touched)
    local immovable, movable = {}, {}
    for name, inv in pairs(inventories or {}) do
        local langs = inv.langs or {}
        local prov = inv.provider or 'treesitter'
        local hit
        if touched.scope == 'all' then
            hit = 'engine change — reach unbounded'
        elseif touched.scope == 'none' then
            hit = nil
        elseif touched.providers and next(touched.providers) and not touched.providers[prov] then
            hit = nil -- extracted by a provider this change cannot reach
        else
            for l in pairs(touched.langs) do
                if (langs[l] or 0) > 0 then
                    hit = ('%s: %d file(s)'):format(l, langs[l])
                    break
                end
            end
        end
        if hit then
            movable[#movable + 1] = { corpus = name, why = hit }
        else
            immovable[#immovable + 1] = { corpus = name,
                why = (touched.scope ~= 'none' and touched.providers
                       and not touched.providers[prov])
                    and ('provider %s is out of reach'):format(prov) or nil }
        end
    end
    local function bycorpus(a, b) return a.corpus < b.corpus end
    table.sort(immovable, bycorpus)
    table.sort(movable, bycorpus)
    return { scope = touched.scope, immovable = immovable, movable = movable }
end

--- THE FENCE. Every language the registry knows must be reachable by
--- `M.touched` from some real file, or a change affecting it would be silently
--- unmapped and the predictor would rule corpora out on no evidence.
function M.registry_gaps(known, files_present, provider_langs)
    local reachable = {}
    for _, f in ipairs(files_present or {}) do
        local t = M.touched({ f }, known, provider_langs)
        if t.scope == 'langs' then
            for l in pairs(t.langs) do reachable[l] = true end
        end
    end
    local gaps = {}
    for l in pairs(known) do
        if not reachable[l] then gaps[#gaps + 1] = l end
    end
    table.sort(gaps)
    return gaps
end

return M
