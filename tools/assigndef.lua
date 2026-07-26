-- assigndef — WOULD MINTING A DEF FOR AN ASSIGNMENT-BOUND CALLABLE EARN ITS KEEP?
-- The ceiling probe for the gap found while shipping the roster report: a function
-- defined by ASSIGNMENT from a call gets no def node at all, so every call to it is
-- unresolved. `M.load = validity.memo{…}` in spec/ecosystem/init.lua and
-- spec/profile/init.lua are two module entry points in exactly that state.
--
-- MEASURE BEFORE BUILDING (the levers.lua / ifaceceil.lua discipline): minting defs
-- is an EXTRACTION change — cache VERSION bump plus a gate re-save on every corpus —
-- so the question is how many defs it would add, how many unresolved calls that
-- actually explains, and where it would be WRONG.
--
-- THE SHAPES ARE NOT ONE GAP, which is the first thing this measures. A probe over
-- the four languages where assignment-bound callables are idiomatic:
--   lua   `M.f = function() end`  MINTS ALREADY      `M.f = memo(…)`  no def
--   js    `const f = () => {}`   MINTS ALREADY      `const f = memo(…)`  no def
--   py    `f = lambda: 2`        NO DEF             `f = memo(…)`  no def
--   rb    `f = lambda { 2 }`     NO DEF             `f = memo(…)`  no def
-- so lua/js are missing only the wrapper and alias forms, while python and ruby are
-- missing the literal too. A single "assignment defs" feature would be four
-- different-sized changes.
--
-- THREE RHS CLASSES, because they do not deserve the same answer:
--   LITERAL   a function/lambda expression      -> a def belongs here; the body is here
--   WRAPPED   a call returning a callable       -> the callable IDENTITY is here, the
--                                                  body is elsewhere (often an inner
--                                                  literal that already has its own
--                                                  def, which is why the body is not
--                                                  missing from the graph — the NAME is)
--   ALIAS     another name / field              -> minting would be WRONG: the target
--                                                  is the aliased def, so this wants
--                                                  resolution, not a new def
--
-- MEASURED 2026-07-26, unique (unambiguous) recoveries as % of a corpus's UNRESOLVED
-- calls — the verdict INVERTED the case that prompted the tool:
--
--   corpus  lang   LITERAL   WRAPPED   ALIAS
--   self    lua      0.00%     0.18%    1.12%
--   ruby    ruby     0.01%     0.26%    0.01%
--   python  py       0.13%     2.13%    0.58%
--   ghost   js       1.85%     4.07%    2.21%
--   jquery  js       6.38%     1.38%    6.85%
--
-- So: Lua's WRAPPED case — the `M.load = memo{…}` bug that prompted this — is the
-- WEAKEST bucket. The buy is the JS LITERAL form, and it is a plain missing def form:
-- `const f = function(){}` mints, `Thing.prototype.f = …` mints, but
-- `X.y = function(){}` (a plain member target) mints NOTHING, which is jquery's
-- jQuery.extend / jQuery.Callbacks / opt.complete. Lua already handles that shape, so
-- it is a js/ts spec query rather than a new mechanism.
--
--   nvim --headless -u NONE -l tools/assigndef.lua <corpus> [--top=N] [--sites]
--     --class=literal|wrapped|alias   isolate one form's evidence

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;'
    .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
bench.bootstrap()

local name = arg[1]
local top, show_sites, only_class = 12, false, nil
for i = 2, #arg do
    local n = arg[i]:match('^%-%-top=(%d+)$')
    if n then top = tonumber(n) end
    if arg[i] == '--sites' then show_sites = true end
    -- so the tool can show its own evidence: `--class=literal` isolates the form
    -- whose absence is a plain bug rather than a design question
    only_class = arg[i]:match('^%-%-class=(%a+)$') or only_class
end
if not name then
    print('usage: assigndef <corpus> [--top=N] [--sites] [--class=literal|wrapped|alias]')
    os.exit(2)
end

-- ── per-language grammar facts, declared ─────────────────────────────────────
-- Assignment is spelled differently in every grammar and the RHS classes live under
-- different node types; this is the only language knowledge in the tool.
local GRAMMAR = {
    lua = {
        assign = { assignment_statement = true },
        lhs = { variable_list = true },
        rhs = { expression_list = true },
        literal = { function_definition = true },
        wrapped = { function_call = true },
        alias = { identifier = true, dot_index_expression = true,
            method_index_expression = true },
    },
    javascript = {
        assign = { variable_declarator = true, assignment_expression = true },
        -- a declarator is (name, value) by POSITION for lhs and field for value;
        -- an assignment_expression uses left/right
        lhs_field = { 'name', 'left' }, rhs_field = { 'value', 'right' },
        literal = { function_expression = true, arrow_function = true,
            ['function'] = true },
        wrapped = { call_expression = true },
        alias = { identifier = true, member_expression = true },
    },
    python = {
        assign = { assignment = true },
        lhs_field = { 'left' }, rhs_field = { 'right' },
        literal = { lambda = true },
        wrapped = { call = true },
        alias = { identifier = true, attribute = true },
    },
    ruby = {
        assign = { assignment = true },
        lhs_field = { 'left' }, rhs_field = { 'right' },
        -- ruby has no lambda NODE: `lambda { }` / `proc { }` / `->() {}` are calls
        -- with a block, so the literal case is detected on the call's shape below
        literal = { lambda = true },
        wrapped = { call = true, method_call = true },
        alias = { identifier = true, constant = true, call = true },
    },
}
GRAMMAR.typescript = GRAMMAR.javascript
GRAMMAR.tsx = GRAMMAR.javascript

local EXT_LANG = { lua = 'lua', js = 'javascript', jsx = 'javascript',
    mjs = 'javascript', cjs = 'javascript', ts = 'typescript', tsx = 'tsx',
    py = 'python', rb = 'ruby' }

--- Ruby spells a lambda as a CALL with a block, so the literal case has to be read
--- off the call rather than a node type. `lambda { }` / `proc { }` / `->() { }`.
local RUBY_LAMBDA = { lambda = true, proc = true }
local function ruby_is_literal(node, src)
    if node:type() == 'lambda' then return true end
    local first = node:named_child(0)
    if not first then return false end
    local head = vim.treesitter.get_node_text(first, src)
    if not RUBY_LAMBDA[head] then return false end
    for c in node:iter_children() do
        local t = c:type()
        if t == 'block' or t == 'do_block' then return true end
    end
    return false
end

--- The bound NAME of an lhs node, or nil when the target is not a plain name (an
--- index expression, a destructuring pattern — a def has nowhere to attach).
local function bound_name(node, src)
    local t = node:type()
    if t == 'identifier' or t == 'dot_index_expression' or t == 'member_expression'
        or t == 'attribute' or t == 'constant' then
        local txt = vim.treesitter.get_node_text(node, src)
        -- one line, no call, no subscript: `M.x` yes, `t[k]` and `f().x` no
        if txt:match('^[%w_%.:]+$') then return txt end
    end
    return nil
end

local function child_by_types(node, set)
    for c in node:iter_children() do
        if c:named() and set[c:type()] then return c end
    end
    return nil
end

--- Every assignment-bound callable candidate in one file, classified.
--- Returns a list of { name, tail, class, line }.
local function sites_in(src, lang)
    local G = GRAMMAR[lang]
    if not G then return {} end
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not okp then return {} end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    if not okt or not tree then return {} end
    local out = {}

    local function classify(rhs)
        local t = rhs:type()
        if lang == 'ruby' and (t == 'call' or t == 'method_call') then
            if ruby_is_literal(rhs, src) then return 'literal' end
            -- a bare `stmt` with no arguments parses as a call in ruby, which would
            -- otherwise be counted as a wrapper; treat an argument-less call with no
            -- receiver as an ALIAS, the conservative reading
            local has_args, has_recv = false, false
            for c in rhs:iter_children() do
                local ct = c:type()
                if ct == 'argument_list' then has_args = true end
                if ct == '.' or ct == '&.' then has_recv = true end
            end
            if not has_args and not has_recv then return 'alias' end
            return 'wrapped'
        end
        if G.literal[t] then return 'literal' end
        if G.wrapped[t] then return 'wrapped' end
        if G.alias[t] then return 'alias' end
        return nil
    end

    local function record(lhs, rhs)
        local nm = lhs and bound_name(lhs, src)
        local class = rhs and classify(rhs)
        if nm and class then
            local row, _ = rhs:start()
            out[#out + 1] = { name = nm, tail = nm:match('([%w_]+)$') or nm,
                class = class, line = row + 1 }
        end
    end

    local function visit(node)
        if G.assign[node:type()] then
            if G.lhs then
                -- lua: parallel lists, matched by position
                local lhs_list = child_by_types(node, G.lhs)
                local rhs_list = child_by_types(node, G.rhs)
                if lhs_list and rhs_list then
                    local i = 0
                    for l in lhs_list:iter_children() do
                        if l:named() then
                            local r = rhs_list:named_child(i)
                            if r then record(l, r) end
                            i = i + 1
                        end
                    end
                end
            else
                local lhs, rhs
                for _, f in ipairs(G.lhs_field) do lhs = lhs or node:field(f)[1] end
                for _, f in ipairs(G.rhs_field) do rhs = rhs or node:field(f)[1] end
                record(lhs, rhs)
            end
        end
        for c in node:iter_children() do if c:named() then visit(c) end end
    end
    visit(tree:root())
    return out
end

-- ── run ──────────────────────────────────────────────────────────────────────
local data, stats = bench.extract(name)
local root = data.root

print(('== assigndef — %s  (%s)'):format(name, bench.fmt and bench.fmt(stats) or ''))

-- what the graph ALREADY defines, by name and by last segment
local defined, defined_tail = {}, {}
for _, n in ipairs(data.nodes or {}) do
    if n.kind == 'function' or n.kind == 'method' then
        defined[(n.file or '') .. '#' .. (n.name or '')] = true
        defined_tail[n.name] = (defined_tail[n.name] or 0) + 1
        local tail = (n.name or ''):match('([%w_]+)$')
        if tail then defined_tail[tail] = (defined_tail[tail] or 0) + 1 end
    end
end

-- WHICH NAMES ARE ACTUALLY CALLED. Without this the candidate count is meaningless:
-- syntax cannot tell `local n = tonumber(x)` (a value) from `local f = memo(g)` (a
-- callable), and counting every assignment-from-call gave 7700 "callables" on self
-- where the real figure is two orders smaller. A name is a callable candidate only if
-- something calls it.
--
-- AND THE SCOPE MATTERS AS MUCH AS THE COUNT. Matching a tail corpus-wide credited
-- `local ok, err = pcall(…)` (96 sites) with the 2000 calls to the test harness's
-- `ok()` — unrelated names that happen to share a tail. A BARE bound name is a local,
-- so only a call in the SAME FILE can be to it; a DOTTED one (`M.x`) is a module
-- field and is reachable corpus-wide. That is also how resolution itself is confined.
local called_tail, called_full, called_in_file = {}, {}, {}
for _, c in ipairs(data.calls or {}) do
    local nm = c.callee or c.full
    if nm then
        local tail = nm:match('([%w_]+)$')
        if tail then
            called_tail[tail] = (called_tail[tail] or 0) + 1
            local f = c.file
            if f then
                local per = called_in_file[f]
                if not per then per = {}; called_in_file[f] = per end
                per[tail] = (per[tail] or 0) + 1
            end
        end
    end
    if c.full then called_full[c.full] = (called_full[c.full] or 0) + 1 end
end

--- Is this bound name called anywhere it could be seen from? Dotted = module field
--- (corpus-wide); bare = local (this file only).
local function is_called(site, file)
    if site.name:find('[%.:]') then
        return (called_full[site.name] or 0) > 0 or (called_tail[site.tail] or 0) > 0
    end
    return ((called_in_file[file] or {})[site.tail] or 0) > 0
end

-- every candidate site, per file, through the language's own grammar
local by_class = { literal = 0, wrapped = 0, alias = 0 }
local gap_by_class = { literal = 0, wrapped = 0, alias = 0 }
local seen_class = { literal = 0, wrapped = 0, alias = 0 } -- before the called filter
local gap_names, gap_sites = {}, {}
local files_read, files_skipped = 0, 0
for file in pairs(data.names or {}) do
    local ext = file:match('%.([%w]+)$')
    local lang = ext and EXT_LANG[ext:lower()]
    if lang and GRAMMAR[lang] then
        local fd = io.open(root .. '/' .. file, 'rb')
        if fd then
            files_read = files_read + 1
            local src = fd:read('a'); fd:close()
            for _, s in ipairs(sites_in(src, lang)) do
                seen_class[s.class] = seen_class[s.class] + 1
                -- the CALLED filter: a bound name nothing ever calls is not a
                -- callable, whatever its right-hand side looks like
                if not is_called(s, file) then goto next end
                s.file, s.exported = file, s.name:find('[%.:]') ~= nil
                by_class[s.class] = by_class[s.class] + 1
                -- IS IT A GAP? only if the graph holds no def of that name in this
                -- file. A literal that already mints is not a gap, which is exactly
                -- what separates lua/js from python/ruby here.
                if not defined[file .. '#' .. s.name]
                    and not defined[file .. '#' .. s.tail] then
                    gap_by_class[s.class] = gap_by_class[s.class] + 1
                    -- GROUPED BY WHAT A CALL COULD SEE: a module field competes
                    -- corpus-wide, a local only inside its own file
                    local key = s.exported and ('*|' .. s.tail)
                        or (file .. '|' .. s.tail)
                    local g = gap_names[key]
                    if not g then g = { n = 0, class = {}, sites = {},
                        tail = s.tail, file = file, exported = s.exported }
                        gap_names[key] = g end
                    g.n = g.n + 1
                    g.class[s.class] = (g.class[s.class] or 0) + 1
                    if #g.sites < 3 then
                        g.sites[#g.sites + 1] = ('%s:%d'):format(file, s.line)
                    end
                    gap_sites[#gap_sites + 1] = s
                end
                ::next::
            end
        else
            files_skipped = files_skipped + 1
        end
    end
end

print(('  files read %d (skipped %d)  ·  assignment sites %d, of which %d bind a'
    .. ' name something CALLS'):format(files_read, files_skipped,
    seen_class.literal + seen_class.wrapped + seen_class.alias,
    by_class.literal + by_class.wrapped + by_class.alias))
print(('    LITERAL %5d  (%d have no def = gap)'):format(by_class.literal,
    gap_by_class.literal))
print(('    WRAPPED %5d  (%d have no def = gap)'):format(by_class.wrapped,
    gap_by_class.wrapped))
print(('    ALIAS   %5d  (%d have no def; minting one would be WRONG — the target'
    .. ' is the aliased def)'):format(by_class.alias, gap_by_class.alias))

-- ── THE CEILING: how many unresolved calls could a minted def actually explain? ──
-- Scoped the same way the candidates are: an unresolved call can only be explained by
-- a def a call at THAT site could see.
local unresolved, dyn = 0, 0
local miss_by_tail, miss_in_file = {}, {}
for _, c in ipairs(data.calls or {}) do
    if not c.to then
        if c.dynamic then dyn = dyn + 1 else
            unresolved = unresolved + 1
            local tail = (c.callee or c.full or ''):match('([%w_]+)$')
            if tail then
                miss_by_tail[tail] = (miss_by_tail[tail] or 0) + 1
                if c.file then
                    local per = miss_in_file[c.file]
                    if not per then per = {}; miss_in_file[c.file] = per end
                    per[tail] = (per[tail] or 0) + 1
                end
            end
        end
    end
end

-- how many GAP sites compete for one name, in the scope a call would search
local competitors = {}
for _, g in pairs(gap_names) do
    local key = g.exported and ('*|' .. g.tail) or (g.file .. '|' .. g.tail)
    competitors[key] = (competitors[key] or 0) + g.n
end

-- SPLIT THE CEILING BY WHAT WOULD ACTUALLY FIX IT. A group whose only sites are
-- ALIASES does not want a minted def — it wants the alias FOLLOWED to its target
-- (`local floor = math.floor` resolves to math.floor; minting a local def there would
-- invent a definition that does not exist). Reporting one number over both would
-- credit minting with recoveries only alias-following can make.
-- THREE buckets, because they are three different pieces of work:
--   LITERAL  the body is right there and no def exists — a missing def FORM, the
--            actionable one (measured: js member-target assignment)
--   WRAPPED  the callable identity is here but the body is elsewhere — a design
--            question (what does the def mean?), not a bug
--   ALIAS    wants the alias FOLLOWED, not a def minted
local rec = {
    literal = { unique = 0, amb = 0, groups = 0 },
    wrapped = { unique = 0, amb = 0, groups = 0 },
    alias = { unique = 0, amb = 0, groups = 0 },
}
local recoverable, rec_ambiguous, ranked = 0, 0, {}
for key, g in pairs(gap_names) do
    local hits = g.exported and (miss_by_tail[g.tail] or 0)
        or ((miss_in_file[g.file] or {})[g.tail] or 0)
    g.kind = g.class.literal and 'literal'
        or (g.class.wrapped and 'wrapped' or 'alias')
    if hits > 0 then
        -- AMBIGUOUS when more than one gap site competes for the name, or when a def
        -- of it already exists: a minted def is then one candidate among several, so
        -- recovery needs a HEDGE, not a fact. (And where a def already exists yet the
        -- call is still unresolved, name-matching has already refused for a reason —
        -- minting another candidate elsewhere would not change that.)
        local amb = (competitors[key] or 0) > 1 or (defined_tail[g.tail] or 0) > 0
        if amb then rec_ambiguous = rec_ambiguous + hits
        else recoverable = recoverable + hits end
        local b = rec[g.kind]
        b.groups = b.groups + 1
        b[amb and 'amb' or 'unique'] = b[amb and 'amb' or 'unique'] + hits
        if not only_class or (g.class[only_class] or 0) > 0 then
            ranked[#ranked + 1] = { tail = g.tail, hits = hits, g = g, amb = amb }
        end
    end
end
table.sort(ranked, function (a, b)
    if a.hits ~= b.hits then return a.hits > b.hits end
    return a.tail < b.tail
end)

local total_calls = #(data.calls or {})
local function pct(x, of) return of > 0 and (100 * x / of) or 0 end
print(('  unresolved non-dynamic calls %d of %d (%.1f%%)  ·  dynamic %d'):format(
    unresolved, total_calls, pct(unresolved, total_calls), dyn))
for _, k in ipairs({ 'literal', 'wrapped', 'alias' }) do
    local b = rec[k]
    io.write(('  %-8s %5d unique + %6d ambiguous  ->  %.2f%% of all calls, %.2f%%'
        .. ' of the unresolved  [%d group(s)]\n'):format(k:upper(), b.unique, b.amb,
        pct(b.unique, total_calls), pct(b.unique, unresolved), b.groups))
end
io.write(('  (AMBIGUOUS = a competitor in the same scope, or a def of the name'
    .. ' already exists: a hedge, not a fact)\n'))

if #ranked > 0 then
    -- io.write, not print: nvim's message layer COALESCES short print() lines in
    -- headless mode, which ran four table rows together on one line
    io.write(('  top gap names by unresolved calls they would explain (%d of %d):\n')
        :format(math.min(top, #ranked), #ranked))
    for i = 1, math.min(top, #ranked) do
        local r = ranked[i]
        local cls = {}
        for c, n in pairs(r.g.class) do cls[#cls + 1] = ('%s×%d'):format(c, n) end
        table.sort(cls)
        io.write(('    %-26s %4d call(s)  %-20s %-10s %s\n'):format(r.tail, r.hits,
            table.concat(cls, ','), r.amb and 'AMBIGUOUS' or 'unique',
            show_sites and table.concat(r.g.sites, ' ') or ''))
    end
end
