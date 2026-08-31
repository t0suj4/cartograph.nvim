-- gramdiff — THE PORTING QUESTION, ASKED OF A GRAMMAR (CART-0666).
--
--   nvim --headless -u NONE -l tools/gramdiff.lua                      -- the GATE
--   nvim --headless -u NONE -l tools/gramdiff.lua <lang> [<corpus|path>] [--files N]
--
-- ★★ A TREE-SITTER GRAMMAR IS AN ENVIRONMENT WITH A VERSION, so the whole portability
-- surface applies to it unchanged:
--
--     PORTING                            HERE
--     an environment profile             the grammar
--     a version                          abi_version
--     provides(prof, name)               does this grammar have this node type
--     requires(store)                    node types a spec's QUERIES name
--     a version diff A -> B              a grammar update that renamed a node type
--     rank (requirement x call count)    node type x occurrences in a corpus
--
-- ★ AND EVERYTHING IS OFFLINE. `vim.treesitter.language.inspect` returns the installed
-- parser's symbols, fields and abi_version — the provides side that needed a whole
-- fetch-and-distil chain for Factorio is one call. No network decision to make.
--
-- ── DIRECTION 1 (no arguments): THE STALENESS GATE ──────────────────────────────
-- Does any spec name a node type its grammar does not have? Same question as an API name
-- a target version removed, and the same failure: a query naming a type the grammar
-- dropped matches NOTHING, silently — the class tools/langaudit.lua's header is about.
-- Exits 1 on any hit. Measured green across all 17 installed grammars when written; the
-- value is that it stays visibly green across nvim-treesitter updates.
--
-- ── DIRECTION 2 (a language): THE ADOPTION WORK LIST ────────────────────────────
-- What does the grammar have that the spec never names, ranked by how often a corpus
-- actually contains it? Ranking is what makes it a list rather than an inventory. For
-- bash on testssl.sh: 60 named node types, the spec's queries name 8, 49 appear in the
-- corpus, led by string / string_content / simple_expansion / number / expansion.
--
-- ★★ IT CROSS-CHECKS WITH tools/exprcensus.lua, WHICH IS THE POINT. The census reaches
-- the same gap from the CORPUS side (a row whose reads the expression IR cannot see) and
-- this reaches it from the SURFACE side. On bash they agree on list / if_statement /
-- test_command / case_item, and this side ADDS the expression LEAVES — string,
-- simple_expansion, binary_expression, concatenation, command_substitution — which is
-- what an expression IR is made of and which a census can only report as its enclosing
-- row. Two independent instruments agreeing on a work list is the strongest evidence
-- this project accepts.
--
-- ⚠ THE REQUIRES SIDE IS READ FROM QUERY BLOCKS AND NOWHERE ELSE. Taking every lowercase
-- string in a spec instead reported 11 names for bash and 7 for java, ALL NOISE: `name`,
-- `field`, `parameters`, `type` are tree-sitter FIELD names, and `alias`/`export`/`let`
-- are bash BUILTIN names the spec carries as data. Inside a query a node type is what
-- follows an open paren, and that is unambiguous.
--
-- ⚠ THE RANKING IS A FACT ABOUT ONE CORPUS. A different bash corpus ranks differently —
-- testssl.sh is one giant script and leans on string expansion. The MEMBERSHIP of the
-- unnamed set is a fact about the spec; only the order comes from the corpus.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/gramdiff%.lua$')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = here .. '/?.lua;' .. here .. '/../lua/?.lua;'
    .. here .. '/../lua/?/init.lua;' .. package.path

local want_lang, where, cap = nil, nil, 60
do
    local a = _G.arg or {}
    local i = 1
    while a[i] do
        if a[i] == '--files' then i = i + 1; cap = tonumber(a[i]) or cap
        elseif not a[i]:match('^%-%-') then
            if not want_lang then want_lang = a[i] else where = a[i] end
        end
        i = i + 1
    end
end

local ts = require 'cartograph.providers.treesitter'
local function say(s) io.write(s .. '\n') end

--- The grammar's PROVIDES set: its named node types. Anonymous tokens (punctuation and
--- keywords, spelled with quotes) are excluded — no spec matches on those.
local function provides(lang)
    if not pcall(vim.treesitter.language.add, lang) then return nil end
    local ok, info = pcall(vim.treesitter.language.inspect, lang)
    if not (ok and info and info.symbols) then return nil end
    local have = {}
    for s, named in pairs(info.symbols) do
        if named == true and not s:match('^"') then have[s] = true end
    end
    return have, info.abi_version
end

--- The spec's REQUIRES set, in TWO STRENGTHS because the two directions need different
--- ones.
---
--- CERTAIN — node types its QUERY BLOCKS name. Inside a query a node type is what follows
--- an open paren, so this is exact. `_` is tree-sitter's wildcard, a query construct and
--- not a node type, and is the one name that must be excluded or every spec reports a
--- false hit. THE GATE USES ONLY THIS: a query naming a type the grammar lacks is
--- definitely dead, and a looser set would let a real one hide.
---
--- PROBABLE — plus any bare string in the spec that IS a node type of THIS grammar. A
--- spec handles plenty of node types in Lua tables rather than queries (fn_types,
--- write_gate, the binder lists), and the work list must not send someone to model
--- something already handled.
--- ★ THE LUA CONTROL IS WHY THIS EXISTS: query-only reported lua as naming 12 of 50 and
--- listed `if_statement`, `block`, `for_statement` as unnamed — all of which spec/lua.lua
--- handles, in tables. Filtering bare strings by "is it a node type of this grammar"
--- keeps `name`/`field`/`parameters` out where they are only tree-sitter FIELD names,
--- without a hand-written exclusion list.
---
--- ⚠ EVEN THE PROBABLE SET CAN OVER-REPORT A GAP: a spec may handle a node type without
--- naming it anywhere, through a generic fallback. So the work list is a CANDIDATE list,
--- and the census is the instrument that says whether a candidate actually costs reads.
local function requires(lang, have)
    local fd = io.open(here .. '/../lua/cartograph/spec/' .. lang .. '.lua', 'r')
    if not fd then return {}, {} end
    local src = fd:read('*a'); fd:close()
    local certain, probable = {}, {}
    for block in src:gmatch('%[=*%[(.-)%]=*%]') do
        for s in block:gmatch('%(%s*([a-z_][a-z0-9_]*)') do
            if s ~= '_' then certain[s] = true; probable[s] = true end
        end
    end
    if have then
        for _, pat in ipairs({ "'([a-z][a-z0-9_]+)'", '"([a-z][a-z0-9_]+)"' }) do
            for s in src:gmatch(pat) do
                if have[s] then probable[s] = true end
            end
        end
    end
    return certain, probable
end

if not want_lang then
    -- ── THE GATE ────────────────────────────────────────────────────────────────
    local names = {}
    for lang in pairs(ts.spec) do names[#names + 1] = lang end
    table.sort(names)
    say('gramdiff — does any spec name a node type its grammar does not have?')
    local bad = 0
    for _, lang in ipairs(names) do
        local have, abi = provides(lang)
        if not have then
            say(('  %-12s parser NOT INSTALLED — not checked, and that is not a pass')
                :format(lang))
        else
            local miss, n = {}, 0
            -- THE GATE USES THE CERTAIN SET ONLY
            for s in pairs((requires(lang))) do
                if not have[s] then miss[#miss + 1] = s end
            end
            for _ in pairs(have) do n = n + 1 end
            table.sort(miss)
            if #miss > 0 then
                bad = bad + #miss
                say(('  %-12s abi %-3s %3d type(s)  ⚠ NAMES %d THE GRAMMAR LACKS: %s')
                    :format(lang, tostring(abi), n, #miss, table.concat(miss, ' ')))
            end
        end
    end
    if bad == 0 then
        say('  every spec names only node types its grammar has')
        say('  ⚠ a green gate is a claim about the INSTALLED parsers, not about the'
            .. ' grammars upstream — it is re-asked every time they move')
    end
    os.exit(bad > 0 and 1 or 0)
end

-- ── THE WORK LIST ───────────────────────────────────────────────────────────────
local have, abi = provides(want_lang)
if not have then say('gramdiff: no installed parser for ' .. want_lang); os.exit(2) end
local certain, want = requires(want_lang, have)

local root = where
if root and vim.fn.isdirectory(vim.fn.expand(root)) == 0 then
    local reg = dofile(here .. '/corpora.lua')
    local c = reg[root]
    if not c then say('gramdiff: no corpus or directory named ' .. root); os.exit(2) end
    root = c.root
end

local total, named = 0, 0
for s in pairs(have) do total = total + 1; if want[s] then named = named + 1 end end
local nq = 0; for _ in pairs(certain) do nq = nq + 1 end
say(('%s — abi %s: the grammar has %d named node type(s); the spec names %d (%d of them'
    .. ' in queries, the rest in tables)'):format(want_lang, tostring(abi), total, named, nq))

if not root then
    -- no corpus: the MEMBERSHIP is still a fact about the spec, only the order is not
    local rows = {}
    for s in pairs(have) do if not want[s] then rows[#rows + 1] = s end end
    table.sort(rows)
    say(('UNNAMED BY THE SPEC — %d type(s), unranked (give a corpus to rank them):')
        :format(#rows))
    say('   ' .. table.concat(rows, ' '))
    return
end

local seen, nfiles = {}, 0
for _, f in ipairs(vim.fn.systemlist({ 'find', vim.fn.expand(root), '-type', 'f' })) do
    if nfiles < cap and ts.lang_of(f) == want_lang then
        local rf = io.open(f, 'r')
        if rf then
            local src = rf:read('*a'); rf:close()
            nfiles = nfiles + 1
            local okp, parser = pcall(vim.treesitter.get_string_parser, src, want_lang)
            local tree = okp and parser and parser:parse()[1]
            if tree then
                local function walk(x)
                    if x:named() then seen[x:type()] = (seen[x:type()] or 0) + 1 end
                    for c in x:iter_children() do walk(c) end
                end
                walk(tree:root())
            end
        end
    end
end

local rows, unseen = {}, 0
for s in pairs(have) do
    if not want[s] then
        if seen[s] then rows[#rows + 1] = { t = s, c = seen[s] }
        else unseen = unseen + 1 end
    end
end
table.sort(rows, function (a, b)
    if a.c ~= b.c then return a.c > b.c end
    return a.t < b.t
end)
say(('%d file(s) read from %s'):format(nfiles, root))
say(('UNNAMED BY THE SPEC AND PRESENT IN THIS CORPUS — %d type(s), ranked:'):format(#rows))
for i = 1, math.min(20, #rows) do
    say(('   %7d  %s'):format(rows[i].c, rows[i].t))
end
if #rows > 20 then say(('   … and %d more'):format(#rows - 20)) end
-- ⚠ ABSENT FROM THE CORPUS IS NOT ABSENT FROM THE LANGUAGE, and the count says so rather
-- than letting a reader mistake this corpus for the grammar.
if unseen > 0 then
    say(('   (%d further unnamed type(s) do not occur in this corpus — a fact about the'
        .. ' corpus, not about the language)'):format(unseen))
end
