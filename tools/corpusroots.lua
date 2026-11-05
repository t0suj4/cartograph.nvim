-- CORPUS ROOTS (CART-0588): what a DESTINATION CORPUS (code that already runs where a port is going) READS
-- from its environment, as raw counts per root and per name, written to a JSON file the `objectives`
-- tactic takes as `corpus=`.
--
--   nvim --headless -u NONE -l tools/corpusroots.lua <out.json> <dir> [<dir> ...]
--
-- ★ RAW ON PURPOSE: the counts come from externals.references (the binder's locality filter: a local or a
-- parameter is not a read) and from NO environment profile. The objectives tactic pairs a lost name with its
-- new form from the PROFILES; this file is the second source. If its counts were profile-adjudicated, the
-- two would share a generator and their agreement would confirm nothing.
-- ⚠ One headless process per corpus: each <dir> is ingested into the singleton store in turn, which is why
-- this is a tool and not a tactic (a tactic run on the shared MCP host must not replace its graph).
local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local externals = require 'cartograph.externals'

local out = arg[1]
if not out or not arg[2] then
    print('usage: corpusroots.lua <out.json> <dir> [<dir> ...]'); os.exit(2)
end
local res = { sources = {}, roots = {}, names = {} }
for i = 2, #arg do
    local dir = vim.fn.fnamemodify(vim.fn.expand(arg[i]), ':p'):gsub('/$', '')
    if vim.fn.isdirectory(dir) == 0 then print('corpusroots: not a directory: ' .. dir); os.exit(2) end
    local data = ts.extract(dir)
    data.root = data.root or dir
    store.ingest(data)
    local refs = externals.references(store)
    local reads = 0
    for name, n in pairs(refs.names) do
        res.names[name] = (res.names[name] or 0) + n
        local root = name:match('^[%w_]+')
        if root then res.roots[root] = (res.roots[root] or 0) + n end
        reads = reads + n
    end
    res.sources[#res.sources + 1] = { dir = dir, reads = reads, analysed = refs.analysed or 0 }
    print(('%s: %d read(s) over %d function(s)'):format(dir, reads, refs.analysed or 0))
end
local fd = assert(io.open(out, 'w'))
fd:write(vim.json.encode(res)); fd:close()
print('wrote ' .. out)
