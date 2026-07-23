-- thinindex — measure the COST of the tiny index vs the bulky pipeline that produces it
-- (the wall-leap, user "the way on to the tiny index is so bulky"). The symbol table is tiny
-- (~20% of node bytes, all resolution/LSP needs), but the only route today is FULL extraction
-- (parse + all queries + dataflow flow/df + merge). This measures a DEFS-ONLY pass (parse +
-- the functions query → def stubs, NO dataflow/calls/resolution) against full extract, in
-- TIME and MEMORY — is the tiny index cheaply buildable DIRECTLY, so the bulk defers to
-- on-demand? A big gap = the wall is leapable (index-first, detail-on-demand).
--
--   nvim --headless -u NONE -l tools/thinindex.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ts = require 'cartograph.providers.treesitter'

local name = arg[1]
if not name then print('usage: thinindex <corpus>'); os.exit(2) end
local hr = vim.loop.hrtime
local function ms(ns) return ns / 1e6 end
local function mbnow() collectgarbage('collect'); collectgarbage('collect'); return collectgarbage('count') / 1024 end

-- === FULL extraction (the bulky pipeline) ===
local base = mbnow()
local t0 = hr()
local data = bench.extract(name)
local t_full = ms(hr() - t0)
local m_full = mbnow() - base
local root = data.root
local files = ts.list_files(root)
local nfiles = #files
data = nil

-- === THIN defs-only pass (parse + functions query → def stubs; NO dataflow/calls) ===
local b2 = mbnow()
local t1 = hr()
local index = { exact = {}, tail = {} }
local ndefs, parsed = 0, 0
for _, f in ipairs(files) do
    local path = f:match('^/') and f or (root .. '/' .. f)
    local fd = io.open(path, 'r')
    if fd then
        local src = fd:read('*a'); fd:close()
        local lang = ts.lang_of(f)
        local spec = lang and ts.spec[lang]
        local q = spec and spec.functions
        if q then
            pcall(vim.treesitter.language.add, lang) -- ensure the lang parser is registered
            local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
            if okp and parser then
                local tree = (parser:parse() or {})[1]
                if tree then
                    parsed = parsed + 1
                    local okq, query = pcall(vim.treesitter.query.parse, lang, q)
                    if okq and query then
                        for id, node in query:iter_captures(tree:root(), src, 0, -1) do
                            local cap = query.captures[id]
                            if cap == 'name' or cap == 'fn' then
                                local nm = vim.treesitter.get_node_text(node, src)
                                if nm then
                                    local stub = { name = nm, file = f, kind = 'function' }
                                    index.exact[nm] = index.exact[nm] or {}
                                    index.exact[nm][#index.exact[nm] + 1] = stub
                                    ndefs = ndefs + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
local t_thin = ms(hr() - t1)
local m_thin = mbnow() - b2

print(('thinindex %s — %d files'):format(name, nfiles))
print(('  FULL extraction:  %8.0f ms   %7.1f MB resident'):format(t_full, m_full))
print(('  THIN defs index:  %8.0f ms   %7.1f MB resident  (%d defs, %d parsed)')
    :format(t_thin, m_thin, ndefs, parsed))
print(('  ==> the tiny index costs %.1fx LESS TIME and %.1fx LESS MEMORY than the pipeline that produces it')
    :format(t_thin > 0 and t_full / t_thin or 0, m_thin > 0 and m_full / m_thin or 0))
print('  (thin = parse + functions-query only — no dataflow/calls/resolution; the bulk defers to on-demand)')
vim.cmd('qall!')
