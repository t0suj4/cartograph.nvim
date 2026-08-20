-- navcensus — WHAT CAN THE BROWSER NOT DESCEND INTO, per language (CART-0456).
--   nvim --headless -u NONE -l tools/navcensus.lua <dir> [--lang php] [--files N]
--                                                  [--ratio 0.5] [--examples 3] [--vocab]
--
-- ★ THE POINT IS THAT NOBODY HAS TO PRESS THE KEY. Every navigation hole fixed so far was
-- found the same way: a user descended and nothing happened (a switch unenterable in six
-- languages, a region with no statements). The failure mode of a missing descent is SILENCE
-- — a row with no children reads exactly like a row that has none — so it trips no gate and
-- no aggregate says a whole construct went unvisitable. But `child_forms` is a pure function
-- of (node, lang), so descent REACHABILITY over a file is computable, and the question "is
-- there structure in this file no descent can reach" needs no answer key at all.
--
-- Sibling of tools/ctrlcensus.lua (which control forms can FLOW not open) and
-- tools/navaudit.lua (the navigation GATE). This one is EVIDENCE, not a gate: the first run
-- surfaces a backlog, and a backlog ratcheted to 0 on day one is a number, not a fix.
--
-- ── THE DETECTOR, AND WHY EACH HALF IS SELF-CALIBRATING ─────────────────────────────────
--   reach(file)  the closure from the root's statements through ts.child_forms — every node
--                a descent can arrive at, by any path.
--   V[lang]      the node types that DO appear as a reached form, corpus-wide. Not a name
--                list: the walk that finds the holes is the walk that builds the vocabulary.
--   TRAP         a node whose type is in V that reach never touched. Its PARENT is the
--                suspect: something holds statements and no descent opens it.
--
-- ★ AND WHY THERE IS A SECOND CALIBRATION. "Type appears as a form somewhere" is far too
-- loose in a language where statements ARE expressions: ruby's `call` is a statement (`puts
-- x`) and also every link of `a.b.c`, and a bare `identifier` is a statement too (`private`),
-- so `foo(a, b)` would report two trapped statements inside its own argument list. So a type
-- is STATEMENT-TYPED only when a MAJORITY of its occurrences in this corpus are reached as
-- forms (--ratio, default 0.5). The ratio is printed with every finding: it is the reader's
-- evidence that the type was calibrated rather than assumed.
--
-- ★ THE PARENT TEST IS ctrlcensus's MEASURED ONE, not the obvious one. "An unreached
-- statement under an unreached parent" is dominated by ordinary expression nesting; what
-- discriminates a CONTAINER from an expression is >= 2 statement-typed children — a list of
-- arms looks like that and a nested call does not. ctrlcensus measured the lone-child version
-- at 38-56% of all control rows (useless), so single-child traps are counted here as WEAK and
-- reported as a total only. Counted, because a cap nobody prints reads as coverage.
--
-- ── BLIND SPOT ─────────────────────────────────────────────────────────────────────────
-- A type that occurs ONLY inside unenterable constructs never enters V, so a construct whose
-- entire content is unique to it is invisible here. Corpus-wide V mitigates that (one
-- reachable instance anywhere in the corpus is enough); nothing closes it. The honest reading
-- of a clean run is "no trapped statement of a KIND seen elsewhere", not "nothing trapped".
--
-- Container files (vue/svelte SFC) are excluded: parse_lang answers `javascript` for a .vue,
-- and a whole-file re-parse of an SFC invents structure (CART-0410).

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local root, want_lang, maxfiles, ratio, nex, vocab, chain = nil, nil, 400, 0.5, 3, false, false
local i = 1
while arg and arg[i] do
    if arg[i] == '--lang' then i = i + 1; want_lang = arg[i]
    elseif arg[i] == '--files' then i = i + 1; maxfiles = tonumber(arg[i]) or maxfiles
    elseif arg[i] == '--ratio' then i = i + 1; ratio = tonumber(arg[i]) or ratio
    elseif arg[i] == '--examples' then i = i + 1; nex = tonumber(arg[i]) or nex
    elseif arg[i] == '--vocab' then vocab = true
    elseif arg[i] == '--chain' then chain = true
    else root = vim.fn.expand(arg[i]) end
    i = i + 1
end
if not root then
    print('usage: navcensus <dir> [--lang php] [--files N] [--ratio F] [--examples N]'
        .. ' [--vocab] [--chain]')
    os.exit(2)
end

local ts = require 'cartograph.providers.treesitter'

-- every file under root the provider claims a language AND a spec for. No spec means the
-- browser's forms() returns {} for the whole file — a known, different fact (the file has no
-- descent at all), not a trapped statement.
local files = {}
for _, p in ipairs(vim.fn.globpath(root, '**/*', false, true)) do
    if vim.fn.isdirectory(p) == 0 and not ts.is_container(p) then
        local lang = ts.lang_of(p)
        if lang and ts.spec[lang] and (not want_lang or lang == want_lang) then
            files[#files + 1] = { path = p, lang = lang, plang = ts.parse_lang(p) or lang }
        end
    end
end
print(('%d file(s) with a language + spec%s'):format(#files, want_lang and (' = ' .. want_lang) or ''))

local function parse(f)
    local fd = io.open(f.path, 'r')
    if not fd then return nil end
    local src = fd:read('a'); fd:close()
    -- NOT `local ok, parser = okl and pcall(...)`: lua's `and` truncates a multi-value
    -- expression to one, and the loud symptom is a plausible "parsed 0 files".
    local okp, parser = false, nil
    if pcall(vim.treesitter.language.add, f.plang) then
        okp, parser = pcall(vim.treesitter.get_string_parser, src, f.plang)
    end
    if not (okp and parser) then return nil end
    local tree = parser:parse()[1]
    return tree and tree:root() or nil, src
end

local function key(n)
    local sr, sc, er, ec = n:range()
    return ('%d,%d,%d,%d,%s'):format(sr, sc, er, ec, n:type())
end

--- THE SEED IS NOT JUST THE ROOT, and getting that wrong reads as a clean corpus.
--- The browser does not enter a file at its root: it lists the file's FUNCTIONS (from the
--- graph) and its regions, and a descent starts at one of those rows. Seeded from the root
--- alone, jquery reported 0 trapped statements across 115 files -- because every jquery file
--- is one IIFE, so the root has one statement, the walk stops there, and the vocabulary V
--- ends up EMPTY. An empty V traps nothing. That is the self-calibration defeated by a hole
--- big enough to be the majority, and the fix is to model the real entry points: every node
--- whose type the SPEC calls a function is also a seed.
local function seeds(rootnode, lang, plang)
    local out = { rootnode }
    local fnty = ts.fn_types(lang) or {}
    local function walk(n)
        if n:named() and fnty[n:type()] then out[#out + 1] = n end
        for c in n:iter_children() do walk(c) end
    end
    walk(rootnode)
    return out
end

--- Every node a descent can arrive at, by any path, plus the types it arrived as.
local function reach(rootnode, plang, ontype, lang)
    local seen, stack = {}, seeds(rootnode, lang, plang)
    for _, n in ipairs(stack) do
        if n:parent() then
            seen[key(n)] = true
            if ontype then ontype(n:type()) end
        end
    end
    while #stack > 0 do
        local n = table.remove(stack)
        for _, c in ipairs(ts.child_forms(n, plang)) do
            local k = key(c)
            if not seen[k] then
                seen[k] = true
                if ontype then ontype(c:type()) end
                stack[#stack + 1] = c
            end
        end
    end
    return seen
end

-- ── PASS 1: the reachable VOCABULARY, and every type's total occurrences ────────────────
local total, asform, nparsed = {}, {}, 0
for _, f in ipairs(files) do
    if nparsed >= maxfiles then break end
    local rootnode = parse(f)
    if rootnode then
        nparsed = nparsed + 1
        total[f.lang] = total[f.lang] or {}
        asform[f.lang] = asform[f.lang] or {}
        local T, A = total[f.lang], asform[f.lang]
        reach(rootnode, f.plang, function(t) A[t] = (A[t] or 0) + 1 end, f.lang)
        local function walk(n)
            if n:named() then T[n:type()] = (T[n:type()] or 0) + 1 end
            for c in n:iter_children() do walk(c) end
        end
        walk(rootnode)
    end
end
print(('parsed %d file(s)'):format(nparsed))

-- STATEMENT-TYPED: a majority of this type's occurrences are reached as forms. See the
-- header — without this, every nested call in an expression language is a finding.
local stmtty = {}
for lang, A in pairs(asform) do
    stmtty[lang] = {}
    for t, n in pairs(A) do
        local tot = total[lang][t] or n
        if n / tot >= ratio then stmtty[lang][t] = n / tot end
    end
end

if vocab then
    for lang, S in pairs(stmtty) do
        local rows = {}
        for t, r in pairs(S) do rows[#rows + 1] = { t = t, r = r, n = asform[lang][t] } end
        table.sort(rows, function(a, b) return a.n > b.n end)
        print(('\n── %s: %d statement-typed of %d reached type(s), ratio >= %.2f'):format(
            lang, #rows, vim.tbl_count(asform[lang]), ratio))
        for _, r in ipairs(rows) do
            print(('   %7d  %.2f  %s'):format(r.n, r.r, r.t))
        end
    end
end

-- ── PASS 2: statement-typed nodes no descent reaches ────────────────────────────────────
-- rows[lang][parent_type .. ' > ' .. trapped_type] = count; weak = single-child traps.
local rows, ex, weak, nfiles, cause, cex = {}, {}, {}, {}, {}, {}
nparsed = 0
for _, f in ipairs(files) do
    if nparsed >= maxfiles then break end
    local rootnode = parse(f)
    if rootnode then
        nparsed = nparsed + 1
        local S = stmtty[f.lang] or {}
        local seen = reach(rootnode, f.plang, nil, f.lang)
        rows[f.lang] = rows[f.lang] or {}
        weak[f.lang] = weak[f.lang] or {}
        cause[f.lang] = cause[f.lang] or {}
        --- THE BREAK: the DEEPEST link on the path where the route actually dies. The shape
        --- name is the symptom (php reported `compound_statement > expression_statement` 21
        --- times); the break is the cause (`else_clause ! if_statement`, one rule).
        ---
        --- ★ AND IT IS NOT "THE FIRST UNREACHED NODE", which is what this computed first and
        --- got wrong. child_forms SEES THROUGH clause and transparent wrappers, so a wrapper
        --- is never in the reached set even when the route runs straight past it -- and php's
        --- else-if then read as `if_statement ! else_clause`, blaming the if for a rule the
        --- clause owns. So each node on the path is ASKED: do your sub-forms contain anything
        --- deeper on this path? The deepest NO is the break, and a wrapper the route passes
        --- through answers yes.
        local fcache = {}
        local function emits(n)
            local k = key(n)
            if not fcache[k] then
                local set = {}
                for _, c in ipairs(ts.child_forms(n, f.plang)) do set[key(c)] = true end
                fcache[k] = set
            end
            return fcache[k]
        end
        local function break_of(n)
            local path, a = { n }, n
            while a:parent() do
                a = a:parent()
                table.insert(path, 1, a)
                if seen[key(a)] then break end
            end
            local pair
            for i = 1, #path - 1 do
                local e, jumped = emits(path[i]), false
                for j = #path, i + 1, -1 do
                    if e[key(path[j])] then jumped = true break end
                end
                if not jumped then
                    -- THE SHALLOWEST break, not the deepest. A trap can be blocked at several
                    -- links at once (php's else-if is blocked at the else, and again at the
                    -- `{` inside it, which is a second bug), and fixing a deeper one changes
                    -- nothing while the top one holds. So the census names the link to fix
                    -- FIRST, and must be RE-RUN after each fix: a cause leaving the report can
                    -- uncover the next one below it rather than emptying the count.
                    --
                    -- ★★ AND THE TOTAL IS NOT MONOTONE UNDER A FIX, so read the CAUSE LIST,
                    -- never the total. Measured on CART-0457: opening blocks took zig from
                    -- 9491 traps to 16778 while REMOVING its largest cause outright
                    -- (`block ! variable_declaration`, 7579) — because every newly reachable
                    -- statement enriches V, more types cross the ratio gate, and the census
                    -- can suddenly SEE traps it had no vocabulary for. A count that goes up is
                    -- the detector getting better eyes, not the browser getting worse. The
                    -- progress signal is a cause LEAVING the list; ruby 180->76, rust 528->38
                    -- and cpp 49->14 in the same run say it plainly.
                    pair = path[i]:type() .. ' ! ' .. path[i + 1]:type()
                    break
                end
            end
            return pair
        end
        local R, hit = rows[f.lang], false
        local function walk(n)
            if n:named() and S[n:type()] and not seen[key(n)] then
                local p = n:parent()
                if p then
                    -- THE CONTAINER TEST: >= 2 statement-typed children STARTING ON
                    -- DIFFERENT LINES. The sibling count alone is ctrlcensus's measured
                    -- discriminator and it is necessary but not sufficient here: `f(x) or
                    -- g(y)` has two statement-typed children (lua's function_call is a
                    -- statement 71% of the time, so it passes the ratio gate) and is an
                    -- expression, not a container. Measured on 300 wow addon files: 366
                    -- "container" traps, every one a call nested in a condition, a return or
                    -- another call's arguments. A body puts its statements on separate LINES;
                    -- an expression's operands share one. Our own lua/ scored 0 either way,
                    -- which is how a corpus of one style hides this.
                    local sibs, lines = 0, {}
                    for c in p:iter_children() do
                        if c:named() and S[c:type()] then
                            sibs = sibs + 1
                            lines[(select(1, c:range()))] = true
                        end
                    end
                    if sibs >= 2 and vim.tbl_count(lines) >= 2 then
                        local k = p:type() .. ' > ' .. n:type()
                        R[k] = (R[k] or 0) + 1
                        hit = true
                        local b = break_of(n)
                        if b then
                            cause[f.lang][b] = (cause[f.lang][b] or 0) + 1
                            if not cex[f.lang .. b] then
                                cex[f.lang .. b] = ('%s:%d'):format(
                                    f.path:gsub('^' .. vim.pesc(root) .. '/?', ''),
                                    (select(1, n:range())) + 1)
                            end
                        end
                        ex[f.lang] = ex[f.lang] or {}
                        ex[f.lang][k] = ex[f.lang][k] or {}
                        local e = ex[f.lang][k]
                        if #e < nex then
                            local where = ('%s:%d'):format(
                                f.path:gsub('^' .. vim.pesc(root) .. '/?', ''),
                                (select(1, n:range())) + 1)
                            if chain then
                                -- WHERE THE ROUTE BREAKS, which the shape name cannot say:
                                -- climb to the nearest node a descent DOES reach and print
                                -- the path down. php's `compound_statement >
                                -- expression_statement` turned out to be `if_statement !
                                -- else_clause > if_statement > compound_statement` -- the
                                -- else-if, three levels up from the symptom.
                                local path, a = {}, n
                                while a do
                                    local reached = seen[key(a)] or not a:parent()
                                    table.insert(path, 1, (reached and '[' or '')
                                        .. a:type() .. (reached and ']' or ''))
                                    if reached then break end
                                    a = a:parent()
                                end
                                where = where .. '  ' .. table.concat(path, ' > ')
                            end
                            e[#e + 1] = where
                        end
                    else
                        local k = p:type() .. ' > ' .. n:type()
                        local W = weak[f.lang]
                        W[k] = (W[k] or 0) + 1
                    end
                end
            end
            for c in n:iter_children() do walk(c) end
        end
        walk(rootnode)
        if hit then nfiles[f.lang] = (nfiles[f.lang] or 0) + 1 end
    end
end

-- ── REPORT ──────────────────────────────────────────────────────────────────────────────
-- Two tiers, and the WEAK one is itemized rather than summed. ctrlcensus measured the
-- lone-child shape as 38-56% noise, which is why it is not a finding — but mantis's first run
-- put the ROOT CAUSE of its 25 strong hits in here (`else_clause > if_statement`: php's
-- two-word `else if`, whose nested if is dropped, so the statements one level DOWN are what
-- shows up strong). A tier collapsed to one number cannot say that.
local WEAK_SHOW = 8
local grand = 0
local function tier(label, tally, lang, withex)
    local list = {}
    for k, n in pairs(tally) do list[#list + 1] = { k = k, n = n } end
    table.sort(list, function(a, b) return a.n > b.n or (a.n == b.n and a.k < b.k) end)
    local sum = 0
    for _, r in ipairs(list) do sum = sum + r.n end
    if #list == 0 then return 0 end
    print(('   %s: %d in %d shape(s)'):format(label, sum, #list))
    local shown = withex and #list or math.min(#list, WEAK_SHOW)
    for i = 1, shown do
        local r = list[i]
        local trapped = r.k:match('> (.+)$')
        print(('   %6d  %-52s ratio %.2f'):format(r.n, r.k, (stmtty[lang] or {})[trapped] or 0))
        if withex then
            for _, e in ipairs((ex[lang] or {})[r.k] or {}) do print('             ' .. e) end
        end
    end
    if shown < #list then
        print(('          ... %d more shape(s) not shown'):format(#list - shown))
    end
    return sum
end
for lang, R in pairs(rows) do
    print('')
    print(('── %s: %d file(s) with a trapped statement'):format(lang, nfiles[lang] or 0))
    local cl = {}
    for k, n in pairs(cause[lang] or {}) do cl[#cl + 1] = { k = k, n = n } end
    table.sort(cl, function(a, b) return a.n > b.n or (a.n == b.n and a.k < b.k) end)
    if #cl > 0 then
        print(('   CAUSES (reached ! first unreached), %d distinct:'):format(#cl))
        for i = 1, math.min(#cl, 10) do
            print(('   %6d  %-46s %s'):format(cl[i].n, cl[i].k, cex[lang .. cl[i].k] or ''))
        end
        if #cl > 10 then print(('          ... %d more cause(s) not shown'):format(#cl - 10)) end
    end
    grand = grand + tier('CONTAINER (parent holds >= 2 statements)', R, lang, true)
    tier('WEAK (single-child parent; mostly expression nesting)', weak[lang] or {}, lang, false)
end
print('')
print(('TRAPPED TOTAL (container tier): %d'):format(grand))
