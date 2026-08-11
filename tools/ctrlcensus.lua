-- ctrlcensus — WHICH CONTROL FORMS DOES flow FAIL TO OPEN, per language (CART-0363).
--   nvim --headless -u NONE -l tools/ctrlcensus.lua <dir> [--lang cpp] [--files N]
--
-- ★ THE POINT IS THAT IT ENUMERATES FORMS BEFORE COUNTING ANYTHING. flow decides "this node
-- is a control statement" from a NAME SET, and a name set is only ever as complete as the
-- grammar knowledge of whoever last edited it. A missing spelling is INVISIBLE in every
-- aggregate: the body folds into one opaque row, the row count still looks plausible, and no
-- number anywhere says a whole construct went unseen. That is how ruby reached 100% opaque
-- while cfg.lua had held the right names all along.
--
-- So the test here is STRUCTURAL, not a name list: a node that CONTAINS a region (a
-- body/compound_statement/statement_block, or the language's own body spelling) and is NOT
-- classified by flow is a control form flow cannot see. That question cannot drift, because
-- it asks the tree rather than a second copy of the answer.
--
-- ★ AND IT READS flow.classes(), NEVER A COPY. This ticket exists because a second copy of
-- flow's CTRL had drifted — in the probe that was measuring the fix, which then reported the
-- fix had not worked. An audit tool holding its own idea of the answer audits itself.
--
-- ── THREE MODES, THREE DIFFERENT BLIND SPOTS ────────────────────────────────────────────
--   (default)   GAP: an unclassified node that CONTAINS A RECOGNISED REGION. Finds a control
--               form flow cannot see — as long as its body spelling IS recognised.
--   --coverage  WITNESS: which classified forms this corpus contains at all. A corpus with
--               zero instances of a form cannot gate it, however well calibrated.
--   --folded    CONTAINER: a node flow emits as ONE plain row while several statements hide
--               inside it. This is the case NEITHER of the others can see, and it has now
--               cost four real bugs — java's `switch_block`, ruby's `begin`, js's
--               `switch_body`, and the `rows` column's own "has a child" test (CART-0391).
--               The gap mode misses it because a container of UNRECOGNISED containers has no
--               recognised region child; the coverage mode misses it because an unclassified
--               form is not in the denominator.
--
-- ★ THE FOLDED TEST, AND WHY IT IS THIS ONE. The obvious candidate — "a control row with a
-- single leaf child" — is MEASURED DEAD: 38-56% of all control rows (jquery 47%, 7kaa 38%,
-- activesupport 56%), because `if (x) return;` and `x if c` legitimately have exactly one
-- child. What discriminates a CONTAINER is that its node has >= 2 named children OF THE SAME
-- control-ish TYPE — a list of arms looks like that and an expression does not. Measured:
-- jquery 0 (its switch_body was just fixed), 7kaa 108 across 5 types dominated by
-- preproc_ifdef/if/else/elif — which was ALREADY FILED as CART-0380, so the detector
-- rediscovers a known real gap without being told about it.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local root, want_lang, maxfiles, coverage, folded = nil, nil, 400, false, false
local i = 1
while arg and arg[i] do
    if arg[i] == '--lang' then i = i + 1; want_lang = arg[i]
    elseif arg[i] == '--files' then i = i + 1; maxfiles = tonumber(arg[i]) or maxfiles
    elseif arg[i] == '--coverage' then coverage = true
    elseif arg[i] == '--folded' then folded = true
    else root = vim.fn.expand(arg[i]) end
    i = i + 1
end
if not root then
    print('usage: ctrlcensus <dir> [--lang cpp] [--files N] [--coverage | --folded]')
    os.exit(2)
end

local ts = require 'cartograph.providers.treesitter'
local flow = require 'cartograph.flow'

-- every file under root the provider claims a language for
local files = {}
for _, p in ipairs(vim.fn.globpath(root, '**/*', false, true)) do
    if vim.fn.isdirectory(p) == 0 then
        local lang = ts.lang_of(p)
        if lang and (not want_lang or lang == want_lang) then
            files[#files + 1] = { path = p, lang = lang }
        end
    end
end
print(('%d file(s) with a language%s'):format(#files, want_lang and (' = ' .. want_lang) or ''))

-- per language: the merged classes flow itself would use
local classes = {}
local function classes_for(lang)
    if classes[lang] == nil then
        local spec = ts.spec and ts.spec[lang] or {}
        local c = flow.classes(spec)
        -- ★ A FUNCTION IS NOT A MISSING CONTROL FORM. Every function/lambda contains a
        -- region and is classified by NONE of the four sets, because flow deliberately
        -- STOPS at one — so a census that only asks "contains a region, unclassified"
        -- reports every function body in the corpus as a gap. Measured: that was the top
        -- row for both cpp and java (6481 and 16310), loud enough to bury for_range_loop's
        -- 317 underneath it. The nested-fn stop is the same seam, so ask it too.
        c.fn = ts.flow_stop and ts.flow_stop(lang) or {}
        classes[lang] = c
    end
    return classes[lang]
end

-- tally[lang][node_type] = { n = <occurrences>, regions = <how many contained a region> }
local tally, seen = {}, {}
local nparsed = 0
for _, f in ipairs(files) do
    if nparsed >= maxfiles then break end
    local fd = io.open(f.path, 'r')
    if fd then
        local src = fd:read('a'); fd:close()
        -- ★ NOT `local okp, parser = okl and pcall(...)`. Lua's `and` truncates a
        -- multi-value expression to ONE, so `parser` would be nil and this would report
        -- "parsed 0 files" — a clean, plausible, entirely wrong zero. Fourth instance of
        -- this trap in this project; it always looks like the corpus is the problem.
        local okp, parser = false, nil
        if pcall(vim.treesitter.language.add, f.lang) then
            okp, parser = pcall(vim.treesitter.get_string_parser, src, f.lang)
        end
        if okp and parser then
            nparsed = nparsed + 1
            local cls = classes_for(f.lang)
            tally[f.lang] = tally[f.lang] or {}
            local T = tally[f.lang]
            local function walk(n)
                local t = n:type()
                if n:named() then
                    T[t] = T[t] or { n = 0, regions = 0 }
                    T[t].n = T[t].n + 1
                    -- does it CONTAIN a region? (a body this language regions as statements)
                    for c in n:iter_children() do
                        if c:named() and cls.body[c:type()] then
                            T[t].regions = T[t].regions + 1
                            break
                        end
                    end
                    seen[f.lang] = seen[f.lang] or {}
                    seen[f.lang][t] = (seen[f.lang][t] or 0) + 1
                end
                for c in n:iter_children() do walk(c) end
            end
            walk(parser:parse()[1]:root())
        end
    end
end
print(('parsed %d file(s)'):format(nparsed))

-- ── FOLDED CONTAINERS ───────────────────────────────────────────────────────────────────
-- A node flow emits as ONE plain row while several statements hide inside it. See the header
-- for why the test is "≥ 2 named children of the same control-ish type" and not the obvious
-- lone-child heuristic (which is 38-56% of all control rows and therefore useless).
if folded then
    for lang, T in pairs(tally) do
        local cls = classes_for(lang)
        local rows, examples = {}, {}
        for _, f in ipairs(files) do
            if f.lang ~= lang then goto nextfile end
            do
                local fd = io.open(f.path, 'r')
                if not fd then goto nextfile end
                local src = fd:read('a'); fd:close()
                local okl = pcall(vim.treesitter.language.add, lang)
                if not okl then goto nextfile end
                local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
                if not (okp and parser) then goto nextfile end
                local function walk(nd)
                    local t = nd:type()
                    -- classified nodes are flow's business, not a folded container; and the
                    -- FUNCTION BODY is excluded because flow reaches it through the spec's
                    -- `body_field` rather than by folding (measured: it was 31 of ruby's 35
                    -- hits, a pure probe artifact).
                    if nd:named() and not (cls.ctrl[t] or cls.clause[t] or cls.body[t]
                        or cls.fn[t] or t == 'ERROR') then
                        local bytype = {}
                        for c in nd:iter_children() do
                            if c:named() then bytype[c:type()] = (bytype[c:type()] or 0) + 1 end
                        end
                        for ct, cnt in pairs(bytype) do
                            if cnt >= 2 and (cls.ctrl[ct] or cls.clause[ct]
                                or ct:find('case') or ct:find('statement')) then
                                rows[t] = (rows[t] or 0) + 1
                                if not examples[t] then
                                    examples[t] = ('%s:%d holds %d× %s'):format(
                                        vim.fn.fnamemodify(f.path, ':t'),
                                        (select(1, nd:range())) + 1, cnt, ct)
                                end
                                break
                            end
                        end
                    end
                    for c in nd:iter_children() do walk(c) end
                end
                -- walk from each FUNCTION BODY down, never the file root: a module-level
                -- statement run is not a folded container either.
                local fnset = cls.fn or {}
                local function seek(nd)
                    if fnset[nd:type()] then
                        -- start at the body's CHILDREN, not the body itself: the fn body is
                        -- reached through the spec's body_field, so flagging it would be a
                        -- pure artifact (measured: 31 of ruby's first 35 hits).
                        local b = nd:field('body')[1]
                        if b then
                            for c in b:iter_children() do if c:named() then walk(c) end end
                        else
                            for c in nd:iter_children() do if c:named() then walk(c) end end
                        end
                        return
                    end
                    for c in nd:iter_children() do if c:named() then seek(c) end end
                end
                seek(parser:parse()[1]:root())
            end
            ::nextfile::
        end
        local ord, tot = {}, 0
        for t, c in pairs(rows) do ord[#ord + 1] = { t = t, c = c }; tot = tot + c end
        table.sort(ord, function (a, b) return a.c > b.c end)
        print('')
        print(('── %s FOLDED ── %d candidate node(s), %d distinct type(s)')
            :format(lang, tot, #ord))
        if #ord == 0 then
            print('   none — no unclassified node in this corpus is holding a list of arms')
        end
        for k = 1, math.min(12, #ord) do
            print(('  %6d  %-32s e.g. %s'):format(ord[k].c, ord[k].t, examples[ord[k].t] or '?'))
        end
    end
    return
end

-- ★ THE OTHER DIRECTION: WHICH CLASSIFIED FORMS DOES THIS CORPUS CONTAIN AT ALL?
-- The gap census above asks what flow cannot see. This asks what the CORPUS cannot show —
-- and it is the question that matters for a GATE. A corpus with zero instances of a form
-- cannot fail on that form, ever, however carefully the gate is calibrated. Measured, that
-- was not hypothetical: `synjava`, the java GATE corpus, contains zero switch, zero
-- enhanced-for, zero synchronized and zero try-with-resources, so java's gate could not have
-- caught that java switches opened NOTHING (CART-0377). Two other corpora the same session
-- returned the same kind of clean, useless zero — luanti is pre-C++11, big-app.spring has no
-- enhanced-for. A zero here is a statement about the WITNESS, not about the code.
if coverage then
    for lang, T in pairs(tally) do
        local cls = classes_for(lang)
        local want = {}
        for t in pairs(cls.ctrl) do want[t] = 'ctrl' end
        for t in pairs(cls.clause) do want[t] = want[t] or 'clause' end
        -- ★ INTERSECT WITH THE GRAMMAR, or the ABSENT list is mostly noise. flow's sets are a
        -- cross-language UNION, so a java corpus is trivially "missing" rust's `match_block`
        -- and php's `foreach_statement` — reporting those as coverage gaps would bury the
        -- real ones. The grammar's own symbol table says which forms this language even HAS,
        -- so what remains is the honest question: the language has it, the corpus does not.
        local grammar
        do
            local okl = pcall(vim.treesitter.language.add, lang)
            local oki, info = false, nil
            if okl then oki, info = pcall(vim.treesitter.language.inspect, lang) end
            if oki and type(info) == 'table' and type(info.symbols) == 'table' then
                grammar = info.symbols
            end
        end
        local have, absent, offlang = {}, {}, 0
        for t, role in pairs(want) do
            if grammar and not grammar[t] then
                offlang = offlang + 1        -- another language's spelling; not this corpus's job
            else
                local n = T[t] and T[t].n or 0
                if n > 0 then have[#have + 1] = { t = t, n = n, role = role }
                else absent[#absent + 1] = t end
            end
        end
        table.sort(have, function (a, b) return a.n > b.n end)
        table.sort(absent)
        print('')
        print(('── %s COVERAGE ── %d of %d form(s) THIS GRAMMAR HAS are present, %d ABSENT%s')
            :format(lang, #have, #have + #absent, #absent,
                grammar and '' or '  [no grammar symbols — cross-language union, read loosely]'))
        for _, r in ipairs(have) do
            print(('  %8d  %-34s (%s)'):format(r.n, r.t, r.role))
        end
        if #absent > 0 then
            print('  ABSENT — this corpus CANNOT gate these, whatever the calibration says:')
            local line = '   '
            for _, t in ipairs(absent) do
                if #line + #t > 92 then print(line); line = '   ' end
                line = line .. ' ' .. t
            end
            if line ~= '   ' then print(line) end
        end
    end
    return
end

for lang, T in pairs(tally) do
    local cls = classes_for(lang)
    local rows = {}
    for t, v in pairs(T) do
        -- classified already? then flow sees it, whatever it is called
        local known = cls.ctrl[t] or cls.clause[t] or cls.body[t] or cls.preloop[t]
            or cls.fn[t] or t == 'ERROR' or t:match('^translation_unit$') or t:match('^program$')
        if not known and v.regions > 0 then
            rows[#rows + 1] = { t = t, n = v.n, r = v.regions }
        end
    end
    table.sort(rows, function (a, b) return a.r > b.r end)
    print('')
    print(('── %s ── %d unclassified node type(s) that CONTAIN a region'):format(lang, #rows))
    if #rows == 0 then
        print('   none — every region-containing node in this corpus is classified')
    end
    for k = 1, math.min(25, #rows) do
        local r = rows[k]
        print(('  %6d regions / %6d nodes   %s'):format(r.r, r.n, r.t))
    end
    if #rows > 25 then print(('  … and %d more'):format(#rows - 25)) end
end
