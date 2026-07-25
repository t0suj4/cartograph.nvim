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

-- ── the JS family: ONE table on the ECMAScript-year scale ──────────────────
-- Shared by javascript/typescript/tsx, which is why the private-field detector
-- keys on `private_property_identifier` (present in BOTH grammars) rather than
-- the field node — that is `field_definition` in javascript and
-- `public_field_definition` in typescript, so keying on it would silently cover
-- only half the family.
--
-- ECMAScript years ONLY. TypeScript's own versions (`satisfies` → TS 4.9) are a
-- DIFFERENT axis: max(ES2020, 4.9) is meaningless, so they are deliberately
-- absent rather than folded into a nonsense scale.
local ES = {
    { id = 'arrow-function', v = '2015', desc = 'arrow function', node = 'arrow_function' },
    { id = 'class', v = '2015', desc = 'class declaration', node = 'class_declaration' },
    { id = 'template-string', v = '2015', desc = 'template string', node = 'template_string' },
    { id = 'exponent', v = '2016', desc = '** exponentiation',
        node = 'binary_expression', test = function (n) return anon(n, '**') end },
    { id = 'await', v = '2017', desc = 'async/await', node = 'await_expression' },
    { id = 'object-spread', v = '2018', desc = '{...a} object spread',
        node = 'spread_element',
        test = function (n)
            local p = n:parent()
            return p ~= nil and p:type() == 'object'
        end },
    { id = 'optional-catch', v = '2019', desc = 'catch {} without a binding',
        node = 'catch_clause',
        test = function (n)
            for c in n:iter_children() do
                if c:named() and c:type() ~= 'statement_block' then return false end
            end
            return true
        end },
    { id = 'optional-chain', v = '2020', desc = '?. optional chaining',
        node = 'optional_chain' },
    { id = 'nullish', v = '2020', desc = '?? nullish coalescing',
        node = 'binary_expression', test = function (n) return anon(n, '??') end },
    { id = 'logical-assign', v = '2021', desc = '??= ||= &&= logical assignment',
        node = 'augmented_assignment_expression',
        test = function (n)
            return anon(n, '??=') or anon(n, '||=') or anon(n, '&&=')
        end },
    { id = 'numeric-separator', v = '2021', desc = '1_000 numeric separator',
        node = 'number',
        -- no distinctive node exists; the check is on the NUMBER token's own
        -- text, so it still cannot fire inside a string or a comment
        test = function (n, src)
            return (vim.treesitter.get_node_text(n, src) or ''):find('_', 1, true) ~= nil
        end },
    { id = 'private-field', v = '2022', desc = '#private class member',
        node = 'private_property_identifier' },
    { id = 'static-block', v = '2022', desc = 'static {} initialisation block',
        node = 'class_static_block' },
}
M.FEATURES.javascript, M.FEATURES.typescript, M.FEATURES.tsx = ES, ES, ES

--- Version-scale name per language, for the header: an ECMAScript year is not a
--- language version number and should not read as one.
M.SCALE = { javascript = 'ECMAScript', typescript = 'ECMAScript', tsx = 'ECMAScript' }

--- WHICH SCALE a language's versions are measured in. Facts may only be compared
--- inside one scale: ruby 3.1, python 3.8 and ECMAScript 2022 are three different
--- rulers, and a max() across them is a meaningless number. Found the hard way —
--- a mixed ruby+typescript project reported "floor 2022" because 2022 > 3.1.
function M.scale_key(lang)
    return M.SCALE[lang] or lang
end

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
    javascript = {
        ['Object.entries']     = { v = '2017', desc = 'Object.entries' },
        ['Object.fromEntries'] = { v = '2019', desc = 'Object.fromEntries' },
        ['flat']               = { v = '2019', desc = 'Array#flat' },
        ['flatMap']            = { v = '2019', desc = 'Array#flatMap' },
        ['replaceAll']         = { v = '2021', desc = 'String#replaceAll' },
        ['at']                 = { v = '2022', desc = 'Array/String#at' },
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
-- the same ECMAScript gates apply to the whole js family
M.STDLIB.typescript, M.STDLIB.tsx = M.STDLIB.javascript, M.STDLIB.javascript

-- ── the CEILING: what a NEWER version takes away ───────────────────────────
-- A floor answers "how old can I go"; the mirror is "how new breaks me". Tag a
-- feature with a `removed-in` as well as an introduced-in and the version
-- dimension becomes a supported RANGE [floor, ceiling) — cross-version support is
-- the whole interval, not one end of it.
--
-- Call- and constant-shaped rather than syntax, so these ride the same
-- disposition-gated machinery as M.STDLIB: a name counts only where it resolved
-- to NOTHING in the project. The hedge points the OTHER WAY from the floor's,
-- which is worth stating plainly: a wrong floor fact makes the floor too HIGH,
-- a wrong removal makes the ceiling too LOW. Both NARROW the range and neither
-- widens it, so the reported interval errs conservative at both ends.
--
-- Deprecated-but-present names are deliberately ABSENT (File.exists? still
-- works): a deprecation is not a removal, and listing one would invent a ceiling.
M.REMOVED = {
    ruby = {
        ['URI.escape']       = { v = '3.0', desc = 'URI.escape' },
        ['URI.unescape']     = { v = '3.0', desc = 'URI.unescape' },
        ['Thread.exclusive'] = { v = '3.0', desc = 'Thread.exclusive' },
        ['taint']            = { v = '3.2', desc = 'Object#taint' },
        ['untaint']          = { v = '3.2', desc = 'Object#untaint' },
        ['tainted?']         = { v = '3.2', desc = 'Object#tainted?' },
        ['trust']            = { v = '3.2', desc = 'Object#trust' },
        ['untrust']          = { v = '3.2', desc = 'Object#untrust' },
    },
    python = {
        ['time.clock']         = { v = '3.8', desc = 'time.clock' },
        ['fractions.gcd']      = { v = '3.9', desc = 'fractions.gcd' },
        ['asyncio.coroutine']  = { v = '3.11', desc = '@asyncio.coroutine' },
        ['inspect.getargspec'] = { v = '3.11', desc = 'inspect.getargspec' },
        ['assertEquals']       = { v = '3.12', desc = 'unittest assertEquals alias' },
        ['assertNotEquals']    = { v = '3.12', desc = 'unittest assertNotEquals alias' },
    },
    -- ECMAScript gets NO table on purpose: it does not remove things (backward
    -- compatibility is the language's whole strategy), so a ceiling table here
    -- would invent a bound. The absence is reported as an absence.
}

--- The gate a callee matches, if any: the WHOLE callee first (`math.prod`), then
--- its last segment (`tally`). Exposed as the lookup seam so the spec can assert
--- every table entry is reachable — a dotted key that the extractor never
--- produces in that form would otherwise sit there dead forever.
--- Returns (entry, key) or nil.
function M.gate_for(lang, callee, which)
    local tbl = (which or M.STDLIB)[lang]
    if not (tbl and callee and callee ~= '') then return nil end
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
                f.lang = lang   -- a fact belongs to a SCALE, via its language
                facts[#facts + 1] = f
            end
        else
            stats.unknown = stats.unknown + 1
            stats.why = stats.why or why or 'unreadable'
        end
    end
    return facts, stats
end

-- Paths a package usually does NOT ship. Used only to QUALIFY a finding, never
-- to drop one: the floor is computed over every scanned file, so evidence that
-- lives solely in a test fixture may not reach a user of the package. Found on
-- ruby-lsp, whose 3.1 syntax sits in test/fixtures/ deliberately.
local function unshipped(path)
    return path:match('^tests?/') ~= nil or path:match('^spec/') ~= nil
        or path:match('/fixtures?/') ~= nil or path:match('^features/') ~= nil
end

-- ── DECLARED vs COMPUTED: the checkable invariant ──────────────────────────
-- A project DECLARES a floor in a real artifact; this module COMPUTES one from
-- the code. Comparing them is a free bug-finder, because the declaration is a
-- ground-truth answer key — the same shape as `@param` vs inferred nilability.
--
-- The two directions are NOT symmetric, and that asymmetry is the whole point:
--   computed NEWER than declared  → a BROKEN PROMISE, and we hold positive
--     evidence for it (a feature, at a site). Sound to report as a defect: the
--     declaration says it runs somewhere it provably cannot.
--   computed OLDER than declared  → only a HINT. Our floor is a LOWER bound, so
--     an undetected feature may justify the declaration. Never asserted as
--     needless — reported as "no evidence for", which is what we actually know.
local ES_ALIAS = { es3 = '1999', es5 = '2009', es6 = '2015', es7 = '2016',
    es2015 = '2015', esnext = nil, latest = nil }

--- Every floor a project DECLARES, tagged with the SCALE it speaks for. A mixed
--- repo declares more than one (ruby-lsp has a gemspec AND a tsconfig), so this
--- returns a list — taking only the first would compare a ruby declaration
--- against an ECMAScript floor.
--- Each: { source, raw, v, scale } — v is nil for an open-ended declaration
--- (ESNext), which is known-but-unusable and distinct from absent.
function M.declarations(root)
    local out = {}
    local function read(rel)
        local fd = io.open(root .. '/' .. rel, 'r')
        if not fd then return nil end
        local s2 = fd:read('a'); fd:close()
        return s2
    end
    for _, g in ipairs(vim.fn.globpath(root, '*.gemspec', false, true)) do
        local body = read(vim.fn.fnamemodify(g, ':t'))
        local raw = body and body:match('required_ruby_version%s*=%s*["\']([^"\']+)["\']')
        if raw then
            out[#out + 1] = { source = vim.fn.fnamemodify(g, ':t'), raw = raw,
                v = raw:match('(%d[%d%.]*)'), scale = 'ruby' }
            break
        end
    end
    if #out == 0 then
        local gf = read('Gemfile')
        local grb = gf and gf:match('\nruby%s+["\']([^"\']+)["\']')
        if grb then
            out[#out + 1] = { source = 'Gemfile', raw = grb,
                v = grb:match('(%d[%d%.]*)'), scale = 'ruby' }
        end
    end
    local py = read('pyproject.toml')
    local pyr = py and py:match('requires%-python%s*=%s*["\']([^"\']+)["\']')
    if pyr then
        out[#out + 1] = { source = 'pyproject.toml', raw = pyr,
            v = pyr:match('(%d[%d%.]*)'), scale = 'python' }
    else
        local sp = read('setup.py')
        local spr = sp and sp:match('python_requires%s*=%s*["\']([^"\']+)["\']')
        if spr then
            out[#out + 1] = { source = 'setup.py', raw = spr,
                v = spr:match('(%d[%d%.]*)'), scale = 'python' }
        end
    end
    local tsc = read('tsconfig.json')
    local tgt = tsc and tsc:match('"target"%s*:%s*"([^"]+)"')
    if tgt then
        local low = tgt:lower()
        local v = ES_ALIAS[low]
        if v == nil and low:match('^es%d%d%d%d$') then v = low:sub(3) end
        out[#out + 1] = { source = 'tsconfig.json', raw = tgt, v = v,
            scale = 'ECMAScript' }
    end
    return out
end

--- The declaration for one scale, or nil.
function M.declared(root, scale)
    for _, d in ipairs(M.declarations(root)) do
        if not scale or d.scale == scale then return d end
    end
    return nil
end

--- Compare the declared floor with the computed one.
--- Returns { verdict, declared, computed, holders } where verdict is
--- 'broken' | 'no-evidence' | 'consistent' | 'undeclared' | 'open-ended'.
function M.invariant(store, computed, holders, scale)
    local root = (store.data or {}).root
    if not root or root:match('^%w+://') then return { verdict = 'undeclared' } end
    local d = M.declared(root, scale)
    if not d then return { verdict = 'undeclared' } end
    if not d.v then
        return { verdict = 'open-ended', declared = d }
    end
    if not computed then return { verdict = 'undeclared', declared = d } end
    if M.older(d.v, computed) then
        return { verdict = 'broken', declared = d, computed = computed, holders = holders }
    end
    if M.older(computed, d.v) then
        return { verdict = 'no-evidence', declared = d, computed = computed }
    end
    return { verdict = 'consistent', declared = d, computed = computed }
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

-- ── constant- and import-shaped removals (TREE-detected) ───────────────────
-- The call gate cannot see these: `Fixnum` is a constant, `$SAFE` a global,
-- `import distutils` a statement. Node type plus exact node TEXT, both read off
-- the real grammar. `mod` matches a module path at a dot boundary, so
-- `distutils.core` counts while a project's `distutils_helpers` does not.
M.REMOVED_SYNTAX = {
    ruby = {
        { id = 'Fixnum', v = '3.2', desc = 'Fixnum constant', node = 'constant', text = 'Fixnum' },
        { id = 'Bignum', v = '3.2', desc = 'Bignum constant', node = 'constant', text = 'Bignum' },
        { id = 'Random::DEFAULT', v = '3.2', desc = 'Random::DEFAULT',
            node = 'scope_resolution', text = 'Random::DEFAULT' },
        { id = '$SAFE', v = '3.0', desc = '$SAFE special global',
            node = 'global_variable', text = '$SAFE' },
    },
    python = {
        { id = 'distutils', v = '3.12', desc = 'the distutils module',
            node = 'dotted_name', mod = 'distutils' },
        { id = 'imp', v = '3.12', desc = 'the imp module', node = 'dotted_name', mod = 'imp' },
        { id = 'collections.Mapping', v = '3.10', desc = 'collections ABC aliases',
            node = 'attribute', text = 'collections.Mapping' },
        { id = 'collections.MutableMapping', v = '3.10', desc = 'collections ABC aliases',
            node = 'attribute', text = 'collections.MutableMapping' },
        { id = 'collections.Sequence', v = '3.10', desc = 'collections ABC aliases',
            node = 'attribute', text = 'collections.Sequence' },
        { id = 'collections.Iterable', v = '3.10', desc = 'collections ABC aliases',
            node = 'attribute', text = 'collections.Iterable' },
    },
}

--- Names the PROJECT itself defines, so its own `Fixnum` is never counted as the
--- removed one. A ruby class shows up in the graph as `Fixnum#method`, never as a
--- bare `Fixnum` node, so class heads are recovered from qualified names too.
function M.defined_names(store)
    local out = {}
    for nm in pairs((store or {}).by_name or {}) do
        out[nm] = true
        local head = nm:match('^([%w_:]+)[#%.]')
        if head then out[head] = true end
    end
    return out
end

--- Tree-detected removals across the graph's files. CERTAIN in the sense that the
--- token is really there, but still skipped when the project defines that name.
function M.removed_syntax_facts(store)
    local ts = require 'cartograph.providers.treesitter'
    local ext2lang = {}
    for lang in pairs(M.REMOVED_SYNTAX) do
        local sp = ts.spec[lang]
        for _, e in ipairs((sp and sp.exts) or {}) do ext2lang[e] = lang end
    end
    local defined = M.defined_names(store)
    local pernode, order = {}, {}
    for _, n in ipairs((store.data or {}).nodes or {}) do
        local f = n.file
        local ext = f and f:match('%.([%w]+)$')
        if f and not pernode[f] and ext and ext2lang[ext:lower()] then
            pernode[f] = n
            order[#order + 1] = f
        end
    end
    table.sort(order)
    local out = {}
    for _, file in ipairs(order) do
        local lang = ext2lang[file:match('%.([%w]+)$'):lower()]
        local lines = store.content(pernode[file])
        local src = lines and table.concat(lines, '\n')
        -- NOT `local ok, parser = src and pcall(...)`: an `and` expression is
        -- adjusted to ONE value, so parser would always be nil
        local ok, parser = false, nil
        if src then ok, parser = pcall(vim.treesitter.get_string_parser, src, lang) end
        local trees = ok and parser and parser:parse()
        local root = trees and trees[1] and trees[1]:root()
        if root then
            local bynode = {}
            for _, e in ipairs(M.REMOVED_SYNTAX[lang]) do
                bynode[e.node] = bynode[e.node] or {}
                table.insert(bynode[e.node], e)
            end
            local function walk(n)
                local cands = bynode[n:type()]
                if cands then
                    local txt = vim.treesitter.get_node_text(n, src) or ''
                    for _, e in ipairs(cands) do
                        local hit = (e.text and txt == e.text)
                            or (e.mod and (txt == e.mod or txt:sub(1, #e.mod + 1) == e.mod .. '.'))
                        if hit and not defined[e.id] and not defined[txt] then
                            local l = n:range()
                            out[#out + 1] = { id = 'gone:' .. e.id, v = e.v,
                                desc = e.desc, tier = 'certain', file = file,
                                lang = lang, line = l }
                        end
                    end
                end
                for c in n:iter_children() do walk(c) end
            end
            walk(root)
        end
    end
    return out
end

--- The gate a CALL matches. The qualified form comes first and it matters: the
--- extractor records `callee` as the TAIL (`escape`) and the receiver-qualified
--- name in `full` (`URI.escape`), so a dotted key can only ever match via `full`.
--- Every dotted key in these tables was silently dead until this was measured —
--- and the ordering is also what keeps `CGI.escape` from matching a table entry
--- written for `URI.escape`.
local function gate_of(lang, c, which)
    local callrec = require 'cartograph.callrec'
    local hit, key = M.gate_for(lang, callrec.full(c), which)
    if hit then return hit, key end
    return M.gate_for(lang, callrec.callee(c) or '', which)
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
            -- key by the TABLE ENTRY, not the callee: `a.match?` and `b.match?`
            -- are the same gated method and must group as one row
            local hit, key = gate_of(lang, c, M.STDLIB)
            -- `external` = resolved to NOTHING here. resolved/refused/dynamic all
            -- mean the project (or an unseeable dispatch) owns the name.
            if hit and census.disp(c) == 'external' then
                out[#out + 1] = { id = 'stdlib:' .. key, v = hit.v,
                    desc = hit.desc .. ' (~ name-matched)', tier = 'inferred',
                    file = file, lang = lang, line = callrec.line(c) or 0 }
            end
        end
    end
    return out
end

--- Names this code uses that a NEWER version REMOVES — the ceiling facts. Same
--- disposition gate as the stdlib tier (a project-defined name resolves there and
--- is not a removal), same hedge, opposite direction.
function M.removal_facts(store)
    local census = require 'cartograph.census'
    local callrec = require 'cartograph.callrec'
    local ts = require 'cartograph.providers.treesitter'
    local ext2lang = {}
    for lang in pairs(M.REMOVED) do
        local sp = ts.spec[lang]
        for _, e in ipairs((sp and sp.exts) or {}) do ext2lang[e] = lang end
    end
    local out = {}
    for _, c in callrec.each(store.data or {}) do
        local file = callrec.file(c)
        local ext = file and file:match('%.([%w]+)$')
        local lang = ext and ext2lang[ext:lower()]
        if lang then
            local hit, key = gate_of(lang, c, M.REMOVED)
            if hit and census.disp(c) == 'external' then
                out[#out + 1] = { id = 'removed:' .. key, v = hit.v,
                    desc = hit.desc .. ' (~ name-matched)', tier = 'inferred',
                    file = file, lang = lang, line = callrec.line(c) or 0 }
            end
        end
    end
    return out
end

--- The report: per SCALE, the floor, the attributed set holding it up, the
--- downgrade ladder, the declared-vs-computed invariant, then the hedged tier.
--- One section per scale, never one number across scales: ruby 3.1, python 3.8
--- and ECMAScript 2022 are three different rulers.
function M.report(store)
    local facts, stats = M.facts(store)
    local langs = {}
    for l in pairs(stats.langs) do langs[#langs + 1] = l end
    table.sort(langs)
    if #langs == 0 then
        return { 'version floor: no file here belongs to a language with a'
            .. ' feature table (covered: '
            .. table.concat(vim.tbl_keys(M.FEATURES), ' ') .. ')' }
    end
    -- partition every fact by the SCALE its language is measured in
    local byscale, order, scalelangs = {}, {}, {}
    for _, l in ipairs(langs) do
        local k = M.scale_key(l)
        if not byscale[k] then byscale[k] = {}; order[#order + 1] = k; scalelangs[k] = {} end
        table.insert(scalelangs[k], l)
    end
    for _, f in ipairs(facts) do
        local k = M.scale_key(f.lang or langs[1])
        byscale[k] = byscale[k] or {}
        table.insert(byscale[k], f)
    end
    local hedged, gone = {}, {}
    for _, f in ipairs(M.call_facts(store)) do
        local k = M.scale_key(f.lang or langs[1])
        hedged[k] = hedged[k] or {}
        table.insert(hedged[k], f)
    end
    for _, f in ipairs(M.removal_facts(store)) do
        local k = M.scale_key(f.lang or langs[1])
        gone[k] = gone[k] or {}
        table.insert(gone[k], f)
    end
    for _, f in ipairs(M.removed_syntax_facts(store)) do
        local k = M.scale_key(f.lang or langs[1])
        gone[k] = gone[k] or {}
        table.insert(gone[k], f)
    end
    table.sort(order)

    local L = {}
    if #order > 1 then
        L[#L + 1] = ('%d version scales here (%s) — reported SEPARATELY: a max()')
            :format(#order, table.concat(order, ', '))
        L[#L + 1] = 'across different rulers would be a meaningless number.'
        L[#L + 1] = ''
    end
    for _, k in ipairs(order) do
        local by, ids = M.group(byscale[k] or {})
        local floor
        for _, id in ipairs(ids) do
            if not floor or M.older(floor, by[id].v) then floor = by[id].v end
        end
        local named = (M.SCALE[scalelangs[k][1]] and (k .. ' ') or '')
        L[#L + 1] = ('version floor — %s: %s%s'):format(
            table.concat(scalelangs[k], '/'), named,
            floor or 'nothing version-gated found')
        L[#L + 1] = '  CERTAIN, from syntax: a LOWER bound, so it says "needs at least"'
        L[#L + 1] = '  — never "runs on". The ladder below is the definite worklist.'
        if #ids == 0 then
            L[#L + 1] = ('  no version-gated syntax found'):format()
        else
            local holders, hnames = 0, {}
            for _, id in ipairs(ids) do
                if by[id].v == floor then
                    holders = holders + by[id].n
                    hnames[#hnames + 1] = ('%s at %s'):format(by[id].desc, by[id].site)
                end
            end
            L[#L + 1] = ('  held up by %d site(s) at %s:'):format(holders, floor)
            for _, id in ipairs(ids) do
                local g = by[id]
                L[#L + 1] = ('    %-5s %-34s %3d  %s%s'):format(g.v, g.desc, g.n, g.site,
                    g.n > 1 and (' (+%d more)'):format(g.n - 1) or '')
            end
            local targets, seen = {}, {}
            for _, id in ipairs(ids) do
                local v = by[id].v
                if not seen[v] then seen[v] = true; targets[#targets + 1] = v end
            end
            L[#L + 1] = '  downgrade ladder — sites to fix per older target:'
            for _, t in ipairs(targets) do
                if t ~= floor then
                    local cost = 0
                    for _, id in ipairs(ids) do
                        if M.older(t, by[id].v) then cost = cost + by[id].n end
                    end
                    L[#L + 1] = ('    to %-6s fix %d site(s)'):format(t, cost)
                end
            end
            local all = 0
            for _, id in ipairs(ids) do all = all + by[id].n end
            L[#L + 1] = ('    below %-6s fix %d site(s) (all of them)')
                :format(targets[#targets], all)
            -- the project's own declaration, as an answer key for THIS scale
            local inv = M.invariant(store, floor, hnames, k)
            local d = inv.declared
            if inv.verdict == 'broken' then
                L[#L + 1] = ('  ⚠ BROKEN PROMISE — %s declares %s, but this needs %s')
                    :format(d.source, d.raw, inv.computed)
                for _, h in ipairs(inv.holders or {}) do
                    L[#L + 1] = '      because of ' .. h
                end
                local all_test = #(inv.holders or {}) > 0
                for _, h in ipairs(inv.holders or {}) do
                    if not unshipped(h:match('at ([^:]+)') or '') then all_test = false end
                end
                if all_test then
                    L[#L + 1] = '    But every site above is under a test/fixture path,'
                    L[#L + 1] = '    which a package often does not ship — the floor spans'
                    L[#L + 1] = '    EVERY scanned file. Check reachability before calling'
                    L[#L + 1] = '    this a defect.'
                else
                    L[#L + 1] = '    A user on the declared version cannot run those sites.'
                    L[#L + 1] = '    The evidence is positive, so it is a defect in the code'
                    L[#L + 1] = '    or in the declaration.'
                end
            elseif inv.verdict == 'no-evidence' then
                L[#L + 1] = ('  %s declares %s; no detected feature needs past %s')
                    :format(d.source, d.raw, inv.computed)
                L[#L + 1] = '    NOT a finding: this floor is a lower bound, so an'
                L[#L + 1] = '    undetected gate may well justify the declaration.'
            elseif inv.verdict == 'consistent' then
                L[#L + 1] = ('  ✓ %s declares %s, and the computed floor agrees')
                    :format(d.source, d.raw)
            elseif inv.verdict == 'open-ended' then
                L[#L + 1] = ('  %s declares %s — open-ended, nothing to check')
                    :format(d.source, d.raw)
            end
        end
        local hby, hids = M.group(hedged[k] or {})
        if #hids > 0 then
            local hfloor
            for _, id in ipairs(hids) do
                if not hfloor or M.older(hfloor, hby[id].v) then hfloor = hby[id].v end
            end
            local raises = hfloor and (not floor or M.older(floor, hfloor))
            L[#L + 1] = ('  ~ %s stdlib name matches (receiver type unknown):'):format(
                raises and ('WOULD RAISE the floor to ' .. hfloor .. ' —')
                    or 'consistent with the floor —')
            for _, id in ipairs(hids) do
                local g = hby[id]
                L[#L + 1] = ('    %-5s %-34s %3d  %s%s'):format(g.v, g.desc, g.n, g.site,
                    g.n > 1 and (' (+%d more)'):format(g.n - 1) or '')
            end
            L[#L + 1] = '    verify these before trusting an older target; and this tier'
            L[#L + 1] = '    UNDER-reports — a stdlib name the project also defines'
            L[#L + 1] = '    resolves there instead, so it is absent from this list'
        end
        -- the CEILING and therefore the supported RANGE
        local rby, rids = M.group(gone[k] or {})
        if #rids > 0 then
            local ceiling
            for _, id in ipairs(rids) do
                if not ceiling or M.older(rby[id].v, ceiling) then ceiling = rby[id].v end
            end
            L[#L + 1] = ('  ⚠ CEILING %s — the first version that REMOVES something used here:')
                :format(ceiling)
            for _, id in ipairs(rids) do
                local g = rby[id]
                L[#L + 1] = ('    %-5s %-34s %3d  %s%s'):format(g.v, g.desc, g.n, g.site,
                    g.n > 1 and (' (+%d more)'):format(g.n - 1) or '')
            end
            if floor and not M.older(floor, ceiling) then
                L[#L + 1] = ('    ✗ NO VERSION WORKS: the floor (%s) is not below the')
                    :format(floor)
                L[#L + 1] = '      ceiling, so no single version satisfies both ends.'
                L[#L + 1] = '      One of the two sites has to change.'
            else
                L[#L + 1] = ('    supported range: [%s, %s)'):format(floor or '?', ceiling)
            end
            L[#L + 1] = '    ~ name-matched like the tier above. A wrong removal makes the'
            L[#L + 1] = '    ceiling too LOW, never too high, so the range errs narrow.'
        elseif M.REMOVED[scalelangs[k][1]] == nil then
            L[#L + 1] = '  no ceiling table for this scale — ECMAScript does not remove'
            L[#L + 1] = '  features, so there is no upper bound to compute — which is'
            L[#L + 1] = '  not the same claim as "unbounded"'
        else
            -- silence would be ambiguous: "we looked and found nothing" reads the
            -- same as "we never looked". Say which.
            local n = 0
            for _, t in ipairs({ M.REMOVED, M.REMOVED_SYNTAX }) do
                for _ in pairs(t[scalelangs[k][1]] or {}) do n = n + 1 end
            end
            L[#L + 1] = ('  no ceiling in evidence — %d known removals were checked for'):format(n)
        end
        L[#L + 1] = ''
    end
    L[#L + 1] = ('scanned %d file(s)%s'):format(stats.files,
        stats.unknown > 0
            and (('; %d could not be read (%s) — counted as UNKNOWN, not clean')
                :format(stats.unknown, stats.why or '?'))
            or '')
    return L
end

return M
