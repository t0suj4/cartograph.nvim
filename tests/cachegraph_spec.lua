-- cache.graph and the two guards that make a warm graph safe to use in the development loop (CART-1449):
--   * a FOLDED graph (store.ingest ran) is never persisted — its argv and ranges are indices into in-memory stores;
--     saved anyway, every call wrote the WHOLE argv store into its shard (18 GB for lua/, a 9-minute save)
--   * the loaded ENGINE's content stamp is part of every key, so an extractor edit never serves an old extraction
local cache = require 'cartograph.cache'
local config = require 'cartograph.config'

local function proj()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local a = assert(io.open(root .. '/a.lua', 'w'))
    a:write('local M = {}\nfunction M.foo(x) return x + 1 end\nfunction M.bar() return M.foo(2) end\nreturn M\n'); a:close()
    return root
end

test('cache.graph: a cold run extracts and saves RAW; the next run opens WARM, the same graph', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = proj()
    local d1, how1 = cache.graph(root)
    eq('cold', how1)
    ok(not d1._argvcol and not d1._atcol, 'returned un-ingested')
    local d2, how2, note = cache.graph(root)
    eq('warm', how2, tostring(note))
    eq(#d1.nodes, #d2.nodes); eq(#d1.calls, #d2.calls)
    vim.fn.delete(root, 'rf')
end)

test('cache.save REFUSES a folded (ingested) graph by name, and writes nothing', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = proj()
    local data = require('cartograph.providers.treesitter').extract(root)
    local store = require 'cartograph.store'
    store.scoped(data, function ()
        ok(data._argvcol or data._atcol, 'the premise: ingest folded it')
        local r, why = cache.save(data)
        eq(nil, r)
        ok(tostring(why):find('FOLDED', 1, true), tostring(why))
        local r2, why2 = cache.save_bg(data)
        eq(nil, r2); ok(tostring(why2):find('FOLDED', 1, true), tostring(why2))
    end)
    eq(nil, (cache.open(root)), 'nothing was written: a fresh open misses')
    vim.fn.delete(root, 'rf')
end)

test('the ENGINE contributes to every cache key — the loaded lua/cartograph tree\'s content stamp', function ()
    local validity = require 'cartograph.validity'
    local names = {}
    for _, n in ipairs(validity.contributors()) do names[n] = true end
    ok(names.engine, 'engine registered')
    local dir = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file('lua/cartograph/cache.lua', false)[1], ':p:h')
    ok(validity.artifact_key():find('engine=' .. require('cartograph.stampcache').loaded_tree(dir), 1, true), validity.artifact_key())
end)