-- mintcensus — WHICH SYNTACTIC POSITIONS DOES THE MINTING RULE NOT COVER?
--
--   nvim --headless -u NONE -l tools/mintcensus.lua <corpus|dir> [--lang L] [--top N]
--
-- ★★★ THE QUESTION EVERY OTHER INSTRUMENT IS ON THE WRONG SIDE OF (CART-0926).
-- `probe.lua` iterates `data.nodes` where kind is function/method — the MINTED
-- side. So does every census in tools/. A minting GAP is by construction absent
-- from all of them: the thing you are looking for is the thing they enumerate
-- over. This walks the PARSE TREE instead and subtracts.
--
-- A `functions` query is a POSITION ALLOWLIST, not a type test. lua's is four
-- clauses (spec/lua.lua) — declaration, assignment value, table-field value,
-- call argument — so `function_definition` is minted in four positions and in
-- NO OTHER. The type is CONDITIONALLY MINTED, which providers/treesitter.lua
-- already names as a soundness bug in the flow walk: a stop at a type the
-- extractor did not mint does not RELOCATE the interior rows, it DELETES them.
-- js paid 21420 deleted rows on ghost for the same class (the IIFE), and the
-- escape hatch built for it — `fn_unminted` — is declared by ruby, python,
-- rust, go and javascript. ⚠ NOT BY LUA, THE LANGUAGE WE DOGFOOD ON.
--
-- ★ SO THE OUTPUT IS A POSITION HISTOGRAM, not a count. A count says the gap
-- exists; only the positions say whether it is ENUMERABLE (add clauses) or
-- OPEN-ENDED (mint the type outright and name it by position). That is the
-- decision this is built to ease, and it is the whole reason to build it.
--
-- ⚠ IT OVER-REPORTS IN `torn` FILES. Extraction tears defs whose own subtree
-- holds a parse error and does not mint them; this subtracts minted ranges, so a
-- torn def reads as unminted. Not corrected here because the counts above are
-- dominated by clean files and the correction needs the tear reason to stay
-- honest — but a position that appears ONLY in a torn file is an artefact.
--
-- ⚠ IT CENSUSES THE SAME FILES EXTRACTION WALKS (`ts.list_files`), deliberately.
-- Deriving the file list from the extracted nodes would drop any file whose only
-- function sits in an unminted position — the exact population being measured.
-- A denominator taken from the thing under test is not a denominator (CART-0918).

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local here = repo .. '/tools/'
dofile(here .. 'bench.lua').bootstrap()

local ts = require 'cartograph.providers.treesitter'
local shortlist = require 'cartograph.shortlist'

local M = {}

--- Every function-typed node the MINTING RULE DID NOT REACH, by parent position.
--- Returns `rows` (sorted, `{key, n, example}`), plus the three denominators.
--- ⚠ SEPARATED FROM THE PRINTING SO IT CAN BE TESTED. The classifier is the part
--- that is cheap to get wrong in the flattering direction: a census that
--- under-reports reads as "the query covers more than it does", and a test that
--- only pins the POSITIVE cases (these shapes are unminted) passes just as well
--- for a census that reports everything. Both directions are pinned in
--- tests/mintcensus_spec.lua.
--- @param root string directory to walk
--- @param want_lang string|nil restrict to one language
--- @param packs table|nil extraction packs
--- @return table rows, number n_files, number n_defs, number n_unminted
function M.positions(root, want_lang, packs)
    local data = ts.extract(root, packs and { packs = packs } or nil)
    local minted = {}
    for _, n in ipairs(data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.range then
            minted[('%s:%d:%d'):format(n.file, n.range.start.line, n.range.start.char)] = n
        end
    end
    local counts, order, examples = {}, {}, {}
    local n_files, n_defs, n_unminted = 0, 0, 0
    for _, rel in ipairs(ts.list_files(root)) do
        local lang = ts.lang_of(rel)
        if lang and (not want_lang or lang == want_lang) then
            local fn_types = ts.fn_types(lang)
            local fh = io.open(root .. '/' .. rel, 'r')
            if fh then
                local src = fh:read('a'); fh:close()
                if pcall(vim.treesitter.language.add, lang) then
                    local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
                    local tree = okp and parser and parser:parse()[1]
                    if tree then
                        n_files = n_files + 1
                        local function walk(node)
                            if fn_types[node:type()] then
                                n_defs = n_defs + 1
                                local sr, sc = node:range()
                                if not minted[('%s:%d:%d'):format(rel, sr, sc)] then
                                    n_unminted = n_unminted + 1
                                    -- ★ THE PARENT CHAIN IS THE ANSWER, not the type.
                                    -- lua wraps a returned function in an `expression_list`
                                    -- under `return_statement`, so ONE level names the
                                    -- wrapper and says nothing.
                                    local p = node:parent()
                                    local gp = p and p:parent()
                                    local key = ('%s   %s < %s < %s'):format(lang,
                                        gp and gp:type() or '-', p and p:type() or '-',
                                        node:type())
                                    if not counts[key] then
                                        order[#order + 1] = key
                                        examples[key] = ('%s:%d'):format(rel, sr + 1)
                                    end
                                    counts[key] = (counts[key] or 0) + 1
                                end
                            end
                            for ch in node:iter_children() do
                                if ch:named() then walk(ch) end
                            end
                        end
                        walk(tree:root())
                    end
                end
            end
        end
    end
    table.sort(order, function (a, b)
        if counts[a] ~= counts[b] then return counts[a] > counts[b] end
        return a < b                   -- total order, or the rank is not a fact
    end)
    local rows = {}
    for i = 1, #order do
        rows[i] = { key = order[i], n = counts[order[i]], example = examples[order[i]] }
    end
    return rows, n_files, n_defs, n_unminted
end

if pcall(debug.getlocal, 4, 1) then return M end

local target, want_lang, top = arg[1], nil, nil
local i = 2
while arg[i] do
    if arg[i] == '--lang' then want_lang = arg[i + 1]; i = i + 2
    elseif arg[i] == '--top' then top = tonumber(arg[i + 1]); i = i + 2
    else print('unknown argument: ' .. arg[i]); os.exit(2) end
end
if not target then
    print('usage: mintcensus.lua <corpus|dir> [--lang L] [--top N]'); os.exit(2)
end

local reg = dofile(here .. 'corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then print('not a directory: ' .. root); os.exit(2) end

local all, n_files, n_defs, n_unminted =
    M.positions(root, want_lang, c and c.packs or nil)

local shown = top and math.min(top, #all) or #all
local rows = {}
for k = 1, shown do rows[#rows + 1] = all[k] end

print(('%s: %d files · %d function-typed nodes · %d MINTED · %d UNMINTED (%.1f%%)')
    :format(target, n_files, n_defs, n_defs - n_unminted, n_unminted,
        n_defs > 0 and (n_unminted / n_defs * 100) or 0))
print('')

local list, why = shortlist.new{
    subject = 'unminted function positions in ' .. target,
    scope = ('%d distinct position(s) over %d unminted node(s) in %d file(s)')
        :format(#all, n_unminted, n_files),
    complete = (shown == #all) and shortlist.EXHAUSTIVE or shortlist.RANKED_OPEN,
    rows = rows,
}
if not list then print('shortlist refused: ' .. tostring(why)); os.exit(2) end
print(table.concat(list:render(function (r)
    return ('%-7d %-58s %s'):format(r.n, r.key, r.example or '')
end), '\n'))
