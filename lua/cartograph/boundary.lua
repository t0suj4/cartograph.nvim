-- cartograph.boundary — BOUNDARIES of one polyglot root (CART-2108, phase 1 of kb polyglot-root-boundaries-design).
--
-- One tree is one root; a BOUNDARY is the unit its environment attaches to. Each file has exactly ONE shard boundary
-- (the deepest one containing it); each boundary carries { language -> profile } and records its SOURCE — user-defined,
-- computed (build markers) or default — so every assignment is explainable and overridable.
--
-- DETECTION is automatic, silent and bounded (design §3): the existing UPWARD probe (shapes.profile_for, nearest
-- ancestor) gives the root boundary its profile; a DOWNWARD probe (shapes.profiles_below, depth 2, sorted, skipping
-- .git / node_modules / deps / _build) finds build markers below. UPWARD WINS for a language it finds; downward fills
-- in the languages it lacks. A monorepo parent (brotardcast: ejabberd/rebar.config, converse.js/package.json) had no
-- profile at all — selection was nearest-up and single-valued (CART-0815) — so 24k stdlib calls read as external.
--
-- ★ TRIVIAL vs POLYGLOT. A root where no boundary below adds a profile is TRIVIAL: its per-file assignment is
-- exactly today's (one profile, by language, from the upward probe), and identity() returns TODAY'S (name, stamp) with
-- no key — the cache key stays byte-identical. Census 2026-11-16 over 75 roots (registry + cached): 73 trivial; hugo
-- (docs/package.json -> node) and the brotardcast parent change, once.
-- ⚠ Without markers the design wants one boundary per language: that split carries no profile and changes no graph,
-- so in phase 1 it is DISPLAY ONLY (graph_info) and never enters the key (it would flush nearly every repo).
-- User-defined boundaries: the PRECEDENCE SLOT exists (detect's opts.user); the manifest format is an open question
-- and none is read — a slot, not a format.

local M = {}

M.DEPTH = 2

local function pm() return require 'cartograph.spec.profile' end
local function lang_of_runtime(rt)
    local p = rt and pm().load(rt)
    return p and p.lang or nil
end

--- detect the boundaries of `root` -> B = { depth, root_profile, list = { { dir, source, markers, langs } }, trivial }
--- `dir` is root-relative ('' = the root boundary). opts.user = user-defined boundaries ({ dir, langs }), which take
--- precedence over computed ones for the same dir (the slot; no format reads into it yet).
function M.detect(root, opts)
    local shapes = require 'cartograph.shapes'
    local B = { depth = M.DEPTH, list = {}, by = {} }
    local function get(dir, source)
        local b = B.by[dir]
        if not b then
            b = { dir = dir, source = source, markers = {}, langs = {} }
            B.by[dir] = b; B.list[#B.list + 1] = b
        end
        return b
    end
    local up = type(root) == 'string' and shapes.profile_for(root) or nil
    local uplang = up and lang_of_runtime(up.profile)
    local rb = get('', up and 'computed' or 'default')
    if up then
        rb.markers[#rb.markers + 1] = up.name
        if uplang then rb.langs[uplang] = up.profile end
        B.root_profile = up.profile
    end
    for _, row in ipairs((type(root) == 'string' and shapes.profiles_below(root, M.DEPTH)) or {}) do
        local b = get(row.dir, 'computed')
        b.markers[#b.markers + 1] = row.name
        local lang = lang_of_runtime(row.profile)
        -- (UPWARD WINS for its language: a marker below of the upward profile's language adds nothing)
        if lang and lang ~= uplang and not b.langs[lang] then b.langs[lang] = row.profile end
    end
    for _, u in ipairs((opts and opts.user) or {}) do
        local b = get(u.dir or '', 'user')
        b.source = 'user'
        for l, rt in pairs(u.langs or {}) do b.langs[l] = rt end
    end
    table.sort(B.list, function (a, b) return a.dir < b.dir end)
    B.trivial = true
    for _, b in ipairs(B.list) do
        if b.dir ~= '' and next(b.langs) then B.trivial = false end
        if b.source == 'user' then B.trivial = false end
    end
    return B
end

--- the shard boundary of a root-relative file: the deepest boundary dir containing it, else the root boundary
function M.boundary_of(B, file)
    local best = B.by['']
    for _, b in ipairs(B.list) do
        if b.dir ~= '' and (file == b.dir or file:sub(1, #b.dir + 1) == b.dir .. '/') then
            if not best or #b.dir > #best.dir then best = b end
        end
    end
    return best
end

--- the profile runtime for a file of `lang` -> runtime | nil: the nearest boundary from the file's own up to the root
--- that declares the language (upward's language is the root boundary's alone, so it always wins)
function M.resolve(B, file, lang)
    if not (B and lang) then return nil end
    local best, bestlen
    for _, b in ipairs(B.list) do
        if b.langs[lang] and (b.dir == '' or file == b.dir or (file or ''):sub(1, #b.dir + 1) == b.dir .. '/') then
            if not bestlen or #b.dir > bestlen then best, bestlen = b.langs[lang], #b.dir end
        end
    end
    return best
end

--- every distinct runtime the boundaries attach, sorted
function M.runtimes(B)
    local set, out = {}, {}
    for _, b in ipairs((B and B.list) or {}) do for _, rt in pairs(b.langs) do set[rt] = true end end
    for rt in pairs(set) do out[#out + 1] = rt end
    table.sort(out)
    return out
end

--- the DISPLAY SUMMARY (data.profile): the one runtime when there is one, else the distinct runtimes joined by '+'
function M.summary(B)
    local rts = M.runtimes(B)
    if #rts == 0 then return nil end
    return table.concat(rts, '+')
end

--- the CANONICAL serialisation: boundaries (dir, source, sorted lang=runtime@stamp) + probe depth. nil for a TRIVIAL
--- root — its cache key is today's, byte for byte
function M.key(B)
    if not B or B.trivial then return nil end
    local parts = { 'boundary/1', 'depth=' .. tostring(B.depth) }
    for _, b in ipairs(B.list) do
        local ls = {}
        for l, rt in pairs(b.langs) do ls[#ls + 1] = ('%s=%s@%s'):format(l, rt, tostring(pm().stamp_of(rt))) end
        table.sort(ls)
        if #ls > 0 or b.source == 'user' then parts[#parts + 1] = ('[%s|%s|%s]'):format(b.dir, b.source, table.concat(ls, ',')) end
    end
    return table.concat(parts, ';')
end

--- the root's PROFILE IDENTITY for the cache gate -> name, stamp, key. TRIVIAL: today's (upward name, its stamp),
--- no key. POLYGLOT: the summary, the runtimes' joined stamps, the canonical key
function M.identity(root)
    return M.identity_of(M.detect(root))
end
function M.identity_of(B)
    if B.trivial then
        local rt = B.root_profile
        return rt, rt and pm().stamp_of(rt) or nil, nil
    end
    local st = {}
    for _, rt in ipairs(M.runtimes(B)) do st[#st + 1] = rt .. ':' .. tostring(pm().stamp_of(rt)) end
    return M.summary(B), table.concat(st, '|'), M.key(B)
end

--- a portable, JSON-safe copy for data.profiles (relink, workers, the cache): { depth, list = { { dir, source, markers,
--- langs } } }; from_data rebuilds the lookup index
function M.to_data(B)
    local out = { depth = B.depth, list = {} }
    for _, b in ipairs(B.list) do
        out.list[#out.list + 1] = { dir = b.dir, source = b.source, markers = vim.deepcopy(b.markers), langs = vim.deepcopy(b.langs) }
    end
    return out
end
function M.from_data(d)
    if type(d) ~= 'table' or type(d.list) ~= 'table' then return nil end
    local B = { depth = d.depth or M.DEPTH, list = {}, by = {}, trivial = false }
    for _, b in ipairs(d.list) do
        local c = { dir = b.dir or '', source = b.source, markers = b.markers or {}, langs = b.langs or {} }
        B.list[#B.list + 1] = c; B.by[c.dir] = c
    end
    table.sort(B.list, function (a, b) return a.dir < b.dir end)
    return B
end

--- the runtime a LANGUAGE-SCOPED reader applies (flowtype's Lua, effects' Lua methods, prototypes): a TRIVIAL graph
--- answers data.profile exactly as before; a POLYGLOT one the single runtime its boundaries attach to `lang` — nil when
--- none, or when two boundaries give the language two different runtimes (a per-file reader then uses profile_for)
function M.runtime_for_lang(data, lang)
    if not data then return nil end
    if not data.profiles then return data.profile end
    local B, one = M.from_data(data.profiles), nil
    for _, b in ipairs((B and B.list) or {}) do
        local rt = b.langs[lang]
        if rt then
            if one and one ~= rt then return nil end
            one = rt
        end
    end
    return one
end

--- every runtime a graph applies: { data.profile } on a trivial graph, the boundaries' runtimes on a polyglot one
function M.runtimes_of(data)
    if not data then return {} end
    if data.profiles then return M.runtimes(M.from_data(data.profiles)) end
    return data.profile and { data.profile } or {}
end

--- the profile RUNTIME a graph applies to `file` (any reader holding data): data.profiles when the root is polyglot,
--- else data.profile when the file's language is that profile's (today's rule)
function M.profile_for(data, file)
    if not data then return nil end
    local lang = file and require('cartograph.providers.treesitter').lang_of(file)
    if data.profiles then return M.resolve(M.from_data(data.profiles), file, lang) end
    local rt = data.profile
    if rt and lang and lang_of_runtime(rt) == lang then return rt end
    return nil
end

return M
