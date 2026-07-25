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
-- python literal containers: `[*a]` is PEP 448 (3.5), `f(*a)` is not
local LITERALS = { list = true, set = true, tuple = true, dictionary = true }

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
    python = {
        { id = 'yield-from', v = '3.3', desc = 'yield from',
            node = 'yield', test = function (n) return anon(n, 'from') end },
        { id = 'await', v = '3.5', desc = 'await expression', node = 'await' },
        -- PEP 448 unpacking in a LITERAL is 3.5; `f(*args)` is ancient, so the
        -- literal ancestor is what makes this a version fact rather than noise
        { id = 'literal-unpack', v = '3.5', desc = '[*a, *b] unpacking in a literal',
            node = 'list_splat',
            test = function (n)
                local p = n:parent()
                return p ~= nil and LITERALS[p:type()] == true
            end },
        { id = 'fstring', v = '3.6', desc = 'f-string interpolation',
            node = 'interpolation' },
        { id = 'var-annotation', v = '3.6', desc = 'x: int = 1 variable annotation',
            node = 'assignment',
            test = function (n)
                for c in n:iter_children() do
                    if c:named() and c:type() == 'type' then return true end
                end
                return false
            end },
        { id = 'walrus', v = '3.8', desc = ':= assignment expression',
            node = 'named_expression' },
        { id = 'positional-only', v = '3.8', desc = 'def f(a, /, b) positional-only',
            node = 'positional_separator' },
        { id = 'match-statement', v = '3.10', desc = 'match/case statement',
            node = 'match_statement' },
        { id = 'union-type', v = '3.10', desc = 'X | Y union in an annotation',
            node = 'type',
            test = function (n)
                for c in n:iter_children() do
                    if c:named() and c:type() == 'binary_operator' and anon(c, '|') then
                        return true
                    end
                end
                return false
            end },
        { id = 'except-star', v = '3.11', desc = 'except* exception group',
            node = 'except_group_clause' },
        { id = 'type-parameter', v = '3.12', desc = 'def f[T]() type parameter',
            node = 'type_parameter' },
    },
}

-- ── version-gated STDLIB calls (the second, WEAKER evidence tier) ──────────
-- Syntax is certain: `{x:}` in the tree IS 3.1 syntax. A stdlib call is not —
-- `x.tally` is 2.7 only if `x` is an Enumerable, and Ruby will not tell us. So
-- these facts are INFERRED (`~`) and reported apart from the certain floor.
--
-- The soundness gate is the graph's own disposition: a name here counts ONLY
-- when the call resolved to NOTHING in the project (census disposition
-- `external`). If the project defines `except`, that call resolves to the
-- project's method and is not a stdlib use at all. What remains uncertain is a
-- receiver from outside the corpus (a gem's class with a same-named method) —
-- which is exactly why the tier is hedged rather than asserted.
--
-- Keys with a dot match the WHOLE callee (`Data.define`); bare keys match the
-- last segment. `define` alone would collide with every project builder.
M.STDLIB = {
    ruby = {
        ['dig']              = { v = '2.3', desc = 'Hash/Array#dig' },
        ['sum']              = { v = '2.4', desc = 'Enumerable#sum' },
        ['digits']           = { v = '2.4', desc = 'Integer#digits' },
        ['transform_values'] = { v = '2.4', desc = 'Hash#transform_values' },
        ['match?']           = { v = '2.4', desc = 'Regexp/String#match?' },
        ['clamp']            = { v = '2.4', desc = 'Comparable#clamp' },
        ['transform_keys']   = { v = '2.5', desc = 'Hash#transform_keys' },
        ['delete_prefix']    = { v = '2.5', desc = 'String#delete_prefix' },
        ['delete_suffix']    = { v = '2.5', desc = 'String#delete_suffix' },
        ['yield_self']       = { v = '2.5', desc = 'Kernel#yield_self' },
        ['then']             = { v = '2.6', desc = 'Kernel#then' },
        ['tally']            = { v = '2.7', desc = 'Enumerable#tally' },
        ['filter_map']       = { v = '2.7', desc = 'Enumerable#filter_map' },
        ['intersection']     = { v = '2.7', desc = 'Array#intersection' },
        ['difference']       = { v = '2.7', desc = 'Array#difference' },
        ['except']           = { v = '3.0', desc = 'Hash#except' },
        ['intersect?']       = { v = '3.1', desc = 'Array#intersect?' },
        ['Data.define']      = { v = '3.2', desc = 'Data.define' },
    },
    python = {
        ['subprocess.run']   = { v = '3.5', desc = 'subprocess.run' },
        ['os.fspath']        = { v = '3.6', desc = 'os.fspath' },
        ['asyncio.run']      = { v = '3.7', desc = 'asyncio.run' },
        ['fromisoformat']    = { v = '3.7', desc = 'datetime.fromisoformat' },
        ['math.prod']        = { v = '3.8', desc = 'math.prod' },
        ['removeprefix']     = { v = '3.9', desc = 'str.removeprefix' },
        ['removesuffix']     = { v = '3.9', desc = 'str.removesuffix' },
        ['functools.cache']  = { v = '3.9', desc = 'functools.cache' },
        ['itertools.pairwise'] = { v = '3.10', desc = 'itertools.pairwise' },
    },
}

--- The gate a callee matches, if any: the WHOLE callee first (`math.prod`), then
--- its last segment (`tally`). Exposed as the lookup seam so the spec can assert
--- every table entry is reachable — a dotted key that the extractor never
--- produces in that form would otherwise sit there dead forever.
--- Returns (entry, key) or nil.
function M.gate_for(lang, callee)
    local tbl = M.STDLIB[lang]
    if not (tbl and callee) then return nil end
    if tbl[callee] then return tbl[callee], callee end
    local tail = callee:match('([%w_]+[!?]?)$')
    if tail and tbl[tail] then return tbl[tail], tail end
    return nil
end

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

--- Group facts by id → { v, desc, n, site }, plus the ids newest-version-first.
--- Shared by both tiers so they read identically in the report.
function M.group(facts)
    local by, ids = {}, {}
    for _, f in ipairs(facts or {}) do
        local g = by[f.id]
        if not g then
            g = { v = f.v, desc = f.desc, n = 0,
                site = ('%s:%d'):format(f.file or '?', (f.line or 0) + 1) }
            by[f.id] = g
            ids[#ids + 1] = f.id
        end
        g.n = g.n + 1
    end
    table.sort(ids, function (a, b)
        if by[a].v ~= by[b].v then return M.older(by[b].v, by[a].v) end
        return a < b
    end)
    return by, ids
end

--- Version-gated stdlib CALLS in the open graph, as hedged facts. Counted only
--- where the call resolved to nothing in the project, so a project method that
--- happens to share a stdlib name is never mistaken for one.
function M.call_facts(store)
    local census = require 'cartograph.census'
    local callrec = require 'cartograph.callrec'
    local ts = require 'cartograph.providers.treesitter'
    local ext2lang = {}
    for lang in pairs(M.STDLIB) do
        local s = ts.spec[lang]
        for _, e in ipairs((s and s.exts) or {}) do ext2lang[e] = lang end
    end
    local out = {}
    for _, c in callrec.each(store.data or {}) do
        local file = callrec.file(c)
        local ext = file and file:match('%.([%w]+)$')
        local lang = ext and ext2lang[ext:lower()]
        if lang then
            local callee = callrec.callee(c) or ''
            -- key by the TABLE ENTRY, not the callee: `a.match?` and `b.match?`
            -- are the same gated method and must group as one row
            local hit, key = M.gate_for(lang, callee)
            -- `external` = resolved to NOTHING here. resolved/refused/dynamic all
            -- mean the project (or an unseeable dispatch) owns the name.
            if hit and census.disp(c) == 'external' then
                out[#out + 1] = { id = 'stdlib:' .. key, v = hit.v,
                    desc = hit.desc .. ' (~ name-matched)', tier = 'inferred',
                    file = file, line = callrec.line(c) or 0 }
            end
        end
    end
    return out
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
    local by, ids = M.group(facts)
    local floor
    for _, id in ipairs(ids) do
        if not floor or M.older(floor, by[id].v) then floor = by[id].v end
    end
    -- the WEAKER tier, kept apart: name-matched stdlib calls (see M.STDLIB)
    local hby, hids = M.group(M.call_facts(store))
    local hfloor
    for _, id in ipairs(hids) do
        if not hfloor or M.older(hfloor, hby[id].v) then hfloor = hby[id].v end
    end
    L[#L + 1] = ('version floor — %s: %s'):format(table.concat(langs, '/'),
        floor or 'nothing version-gated found')
    L[#L + 1] = '  CERTAIN, from syntax: a LOWER bound, so it says "needs at least"'
    L[#L + 1] = '  — never "runs on". The ladder below is the definite worklist.'
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
    -- The hedged tier, deliberately NOT folded into the floor or the ladder: a
    -- stdlib name match cannot see its receiver's type, so it is evidence to
    -- CHECK, not work to do. Folding it in would launder a ~ into a fact.
    if #hids > 0 then
        L[#L + 1] = ''
        local raises = hfloor and (not floor or M.older(floor, hfloor))
        L[#L + 1] = ('  ~ %s stdlib name matches (unresolved here — receiver type unknown):')
            :format(raises and ('WOULD RAISE the floor to ' .. hfloor .. ' —') or 'consistent with the floor —')
        for _, id in ipairs(hids) do
            local g = hby[id]
            L[#L + 1] = ('    %-5s %-34s %3d  %s%s'):format(g.v, g.desc, g.n, g.site,
                g.n > 1 and (' (+%d more)'):format(g.n - 1) or '')
        end
        L[#L + 1] = '    verify these before trusting a target below ' .. hfloor
            .. '; a gem class with the same method name would look identical'
        L[#L + 1] = '    and this tier UNDER-reports: a stdlib name the project also'
        L[#L + 1] = '    defines resolves there instead, so it is absent from this list'
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
