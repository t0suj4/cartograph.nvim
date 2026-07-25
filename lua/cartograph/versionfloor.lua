-- The VERSION FLOOR ([[cartograph-portability-lever]], the version axis — step
-- one of the porting lever). Which language version this code actually NEEDS,
-- surfaced as an ATTRIBUTED SET rather than a scalar: "3.1 BECAUSE hash
-- shorthand {x:} at user.rb:42". The floor is a CONSEQUENCE; the reason is the
-- useful part.
--
-- On top of the set rides the DOWNGRADE LADDER, which is the backwards-
-- compatibility payoff: a floor is usually held up by a FEW high-version sites,
-- so sorting the facts by version prices every older target — "on 3.1, held by
-- 1 site; fix it and 3.0 works (5 sites below that)". Each rung is the exact
-- edit cost to widen support, and choosing a target turns the set difference
-- into a rewrite worklist.
--
-- HONESTY, and it is the whole design constraint here:
--   · The floor is a LOWER BOUND drawn from SYNTAX ONLY. Version-gated stdlib
--     calls (Hash#except → 3.0, Enumerable#tally → 2.7) are NOT modelled, so a
--     reported 2.7 means "needs at LEAST 2.7" and never "runs on 2.7". The
--     report says that in the header rather than letting a bare number imply
--     the stronger claim.
--   · Detection is over the TREE, never over text. `&.` inside a string or a
--     comment is not a feature use; a regex would insist it was.
--   · A file whose grammar is missing or which fails to parse contributes
--     NOTHING and is counted as unknown, not as clean.
--   · A language with no table is reported as uncovered, not as floor-free.

local M = {}

-- ── detector helpers (over the tree) ───────────────────────────────────────
-- an anonymous child IS its token text (`&.`, `=`), per the grammar probe
local function anon(n, token)
    for c in n:iter_children() do
        if not c:named() and c:type() == token then return true end
    end
    return false
end

local function named_count(n)
    local k = 0
    for c in n:iter_children() do if c:named() then k = k + 1 end end
    return k
end

local function first_is_anon(n)
    local c = n:child(0)
    return c ~= nil and not c:named()
end

local function under(n, types)
    local p = n:parent()
    while p do
        if types[p:type()] then return true end
        p = p:parent()
    end
    return false
end

local BLOCKS = { block = true, do_block = true }

-- ── the per-language feature tables ────────────────────────────────────────
-- Each entry: { id, v (version introduced), desc, node (tree-sitter type),
-- test? (extra structural predicate) }. Node types were read off the real
-- grammar, not recalled — a wrong type silently detects nothing, so the spec
-- asserts every entry fires on its own snippet.
M.FEATURES = {
    ruby = {
        { id = 'safe-navigation', v = '2.3', desc = '&. safe navigation',
            node = 'call', test = function (n) return anon(n, '&.') end },
        { id = 'squiggly-heredoc', v = '2.3', desc = '<<~ squiggly heredoc',
            node = 'heredoc_beginning',
            test = function (n, src)
                return (vim.treesitter.get_node_text(n, src) or ''):sub(1, 3) == '<<~'
            end },
        { id = 'numbered-param', v = '2.7', desc = '_1 numbered block parameter',
            node = 'identifier',
            test = function (n, src)
                return (vim.treesitter.get_node_text(n, src) or ''):match('^_[1-9]$') ~= nil
                    and under(n, BLOCKS)
            end },
        { id = 'arg-forwarding', v = '2.7', desc = '... argument forwarding',
            node = 'forward_parameter' },
        { id = 'beginless-range', v = '2.7', desc = '..x beginless range',
            node = 'range', test = first_is_anon },
        { id = 'pattern-match', v = '3.0', desc = 'case/in pattern matching',
            node = 'case_match' },
        { id = 'endless-method', v = '3.0', desc = 'def f = expr endless method',
            node = 'method', test = function (n) return anon(n, '=') end },
        { id = 'rightward-assign', v = '3.0', desc = 'expr => x rightward assignment',
            node = 'match_pattern' },
        { id = 'hash-shorthand', v = '3.1', desc = '{x:} hash value shorthand',
            node = 'pair', test = function (n) return named_count(n) == 1 end },
        { id = 'anon-block-param', v = '3.1', desc = 'def f(&) anonymous block parameter',
            node = 'block_parameter', test = function (n) return named_count(n) == 0 end },
    },
}

--- Version compare over dotted numeric parts. Returns true when a < b.
function M.older(a, b)
    local pa, pb = vim.split(a, '.', { plain = true }), vim.split(b, '.', { plain = true })
    for i = 1, math.max(#pa, #pb) do
        local x, y = tonumber(pa[i]) or 0, tonumber(pb[i]) or 0
        if x ~= y then return x < y end
    end
    return false
end

--- Every version-gated feature use in `src`. Returns a list of
--- { id, v, desc, line } (line is 0-based), or nil + why when it cannot look.
function M.scan(lang, src)
    local feats = M.FEATURES[lang]
    if not feats then return nil, 'no version-floor table for ' .. lang end
    local bynode = {}
    for _, f in ipairs(feats) do
        bynode[f.node] = bynode[f.node] or {}
        table.insert(bynode[f.node], f)
    end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return nil, 'no ' .. lang .. ' parser' end
    local ok2, trees = pcall(function () return parser:parse() end)
    local root = ok2 and trees and trees[1] and trees[1]:root()
    if not root then return nil, 'unparsed' end
    local out = {}
    local function walk(n)
        local cands = bynode[n:type()]
        if cands then
            for _, f in ipairs(cands) do
                if not f.test or f.test(n, src) then
                    local l = n:range()
                    out[#out + 1] = { id = f.id, v = f.v, desc = f.desc, line = l }
                end
            end
        end
        for c in n:iter_children() do walk(c) end
    end
    walk(root)
    return out
end

--- Scan every file of a covered language in the open graph. Returns
--- (facts, stats) where a fact adds `file`, and stats records what could NOT be
--- looked at — unknown is never folded into clean.
function M.facts(store)
    local ts = require 'cartograph.providers.treesitter'
    local ext2lang = {}
    for lang in pairs(M.FEATURES) do
        local s = ts.spec[lang]
        for _, e in ipairs((s and s.exts) or {}) do ext2lang[e] = lang end
    end
    local pernode, order = {}, {}
    for _, n in ipairs((store.data or {}).nodes or {}) do
        local f = n.file
        if f and not pernode[f] then
            local ext = f:match('%.([%w]+)$')
            if ext and ext2lang[ext:lower()] then
                pernode[f] = n
                order[#order + 1] = f
            end
        end
    end
    table.sort(order)
    local facts, stats = {}, { files = 0, unknown = 0, langs = {} }
    for _, file in ipairs(order) do
        local lang = ext2lang[file:match('%.([%w]+)$'):lower()]
        stats.langs[lang] = true
        local lines = store.content(pernode[file])
        local got, why = nil, nil
        if lines then got, why = M.scan(lang, table.concat(lines, '\n')) end
        if got then
            stats.files = stats.files + 1
            for _, f in ipairs(got) do
                f.file = file
                facts[#facts + 1] = f
            end
        else
            stats.unknown = stats.unknown + 1
            stats.why = stats.why or why or 'unreadable'
        end
    end
    return facts, stats
end

--- The report: the floor, the attributed set that holds it up, and the
--- downgrade ladder priced per older target.
function M.report(store)
    local facts, stats = M.facts(store)
    local langs = {}
    for l in pairs(stats.langs) do langs[#langs + 1] = l end
    table.sort(langs)
    local L = {}
    if #langs == 0 then
        return { 'version floor: no file here belongs to a language with a'
            .. ' feature table (covered: ' .. table.concat(vim.tbl_keys(M.FEATURES), ' ') .. ')' }
    end
    -- group by feature id: count + the first site, so the set is readable
    local by, ids = {}, {}
    for _, f in ipairs(facts) do
        local g = by[f.id]
        if not g then
            g = { v = f.v, desc = f.desc, n = 0, site = ('%s:%d'):format(f.file, f.line + 1) }
            by[f.id] = g
            ids[#ids + 1] = f.id
        end
        g.n = g.n + 1
    end
    table.sort(ids, function (a, b)
        if by[a].v ~= by[b].v then return M.older(by[b].v, by[a].v) end
        return a < b
    end)
    local floor
    for _, id in ipairs(ids) do
        if not floor or M.older(floor, by[id].v) then floor = by[id].v end
    end
    L[#L + 1] = ('version floor — %s: %s'):format(table.concat(langs, '/'),
        floor or 'nothing version-gated found')
    L[#L + 1] = '  a LOWER bound, from SYNTAX only: version-gated stdlib calls are not'
    L[#L + 1] = '  modelled, so this says "needs at least" — never "runs on".'
    L[#L + 1] = ''
    if #ids == 0 then
        L[#L + 1] = ('  no version-gated syntax in %d file(s)'):format(stats.files)
    else
        local holders = 0
        for _, id in ipairs(ids) do
            if by[id].v == floor then holders = holders + by[id].n end
        end
        L[#L + 1] = ('  held up by %d site(s) at %s:'):format(holders, floor)
        for _, id in ipairs(ids) do
            local g = by[id]
            L[#L + 1] = ('    %-5s %-34s %3d  %s%s'):format(g.v, g.desc, g.n, g.site,
                g.n > 1 and (' (+%d more)'):format(g.n - 1) or '')
        end
        -- the ladder: to support target V, every fact NEWER than V must be fixed
        local targets, seen = {}, {}
        for _, id in ipairs(ids) do
            local v = by[id].v
            if not seen[v] then seen[v] = true; targets[#targets + 1] = v end
        end
        L[#L + 1] = ''
        L[#L + 1] = '  downgrade ladder — sites to fix per older target:'
        for _, t in ipairs(targets) do
            if t ~= floor then
                local cost = 0
                for _, id in ipairs(ids) do
                    if M.older(t, by[id].v) then cost = cost + by[id].n end
                end
                L[#L + 1] = ('    to %-5s fix %d site(s)'):format(t, cost)
            end
        end
        local all = 0
        for _, id in ipairs(ids) do all = all + by[id].n end
        L[#L + 1] = ('    below %-5s fix %d site(s) (all of them)')
            :format(targets[#targets], all)
    end
    L[#L + 1] = ''
    L[#L + 1] = ('  scanned %d file(s)%s'):format(stats.files,
        stats.unknown > 0
            and (('; %d could not be read (%s) — counted as UNKNOWN, not clean')
                :format(stats.unknown, stats.why or '?'))
            or '')
    return L
end

return M
