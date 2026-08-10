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

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local root, want_lang, maxfiles = nil, nil, 400
local i = 1
while arg and arg[i] do
    if arg[i] == '--lang' then i = i + 1; want_lang = arg[i]
    elseif arg[i] == '--files' then i = i + 1; maxfiles = tonumber(arg[i]) or maxfiles
    else root = vim.fn.expand(arg[i]) end
    i = i + 1
end
if not root then print('usage: ctrlcensus <dir> [--lang cpp] [--files N]'); os.exit(2) end

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
