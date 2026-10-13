-- tsquery ORACLE (CART-1659): the compiled matcher against tree-sitter's own `query:iter_matches`, ROW FOR ROW, on
-- real trees — every file of every language a spec has a `calls` query for. A row is (pattern index, the @call node's
-- range, the @name node's range), in the order each side yields them.
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/tsquery_oracle.lua <dir> [<dir> …] [order=sorted]
-- Prints per language: files, rows, SAME | DIFFERS (the first differing row of the first differing file); exits
-- non-zero on any difference or on a query outside the compiled subset. order=sorted compares the rows as SETS
-- (which tells an ORDER difference from a content one).
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local TS = require 'cartograph.providers.treesitter'
local tsquery = require 'cartograph.tsquery'
local sorted = false
local dirs = {}
for _, a in ipairs(arg) do if a == 'order=sorted' then sorted = true else dirs[#dirs + 1] = a end end
local MATCH_OPTS = { match_limit = 65536 }
local function rng(n) if not n then return '-' end local a, b, c, d = n:range(); return ('%d:%d-%d:%d'):format(a, b, c, d) end
local per, bad = {}, 0
for _, dir in ipairs(dirs) do
    for _, f in ipairs(vim.fn.globpath(dir, '**/*', false, true)) do
        local lang = vim.fn.isdirectory(f) == 0 and TS.lang_of(f)
        local ok_s, spec = pcall(require, 'cartograph.spec.' .. tostring(lang))
        if lang and ok_s and type(spec) == 'table' and spec.calls then
            local grammar = TS.parse_lang(f) or lang
            local P = per[grammar] or { files = 0, rows = 0, same = true }; per[grammar] = P
            local okq, q = pcall(vim.treesitter.query.parse, grammar, spec.calls)
            local m, why = tsquery.compile(spec.calls)
            if not m then P.refused = why
            elseif okq then
                local fd = io.open(f); local src = fd and fd:read('a'); if fd then fd:close() end
                local root = src and require('cartograph.parsecache').root(src, grammar)
                if root then
                    local A, B = {}, {}
                    for pat, match in q:iter_matches(root, src, 0, -1, MATCH_OPTS) do
                        local cn, nn
                        for id, ns in pairs(match) do
                            local n = type(ns) == 'table' and ns[#ns] or ns
                            if q.captures[id] == 'call' then cn = n elseif q.captures[id] == 'name' then nn = n end
                        end
                        A[#A + 1] = pat .. ' ' .. rng(cn) .. ' ' .. rng(nn)
                    end
                    tsquery.all(m, root, function (pat, caps) B[#B + 1] = pat .. ' ' .. rng(caps.call) .. ' ' .. rng(caps.name) end)
                    if sorted then table.sort(A); table.sort(B) end
                    P.files, P.rows = P.files + 1, P.rows + #A
                    if P.same then
                        for k = 1, math.max(#A, #B) do
                            if A[k] ~= B[k] then
                                P.same = false
                                P.first = ('%s row %d: query %s | compiled %s (%d vs %d rows)'):format(f, k, tostring(A[k]), tostring(B[k]), #A, #B)
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end
local langs = vim.tbl_keys(per); table.sort(langs)
for _, l in ipairs(langs) do
    local P = per[l]
    if P.refused then bad = bad + 1; print(('%-11s REFUSED  %s'):format(l, P.refused))
    else
        if not P.same then bad = bad + 1 end
        print(('%-11s %s %5d files %7d rows%s'):format(l, P.same and 'SAME   ' or 'DIFFERS', P.files, P.rows, P.first and ('  ' .. P.first) or ''))
    end
end
os.exit(bad == 0 and 0 or 1)
