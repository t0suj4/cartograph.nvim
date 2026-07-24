-- INDEX-ONLY warm symbol serving ([[cartograph-thin-index]] thread (b)): the thin
-- index (defs only, no call graph) now persists to the shard cache so a reopen of an
-- unchanged tree reuses the def shards instead of re-parsing (~15x). The honesty
-- contract must survive the round-trip and the two cache modes must not collide:
--   A. the index_only MARKER round-trips (else is_index_only() lapses on a warm reopen
--      → the LSP caps / whole-graph verb guards silently serve a call-less graph as full)
--   B. a warm index-only open serves ONLY from a thin cache with a CLEAN diff; any change,
--      or a full cache, or a corrupted shard → nil (the caller cold-re-indexes defs-only)
--   C. a FULL open REJECTS a thin cache (it has no calls) → cold full extract
-- Uses a real treesitter graph on a temp dir + synchronous cache.save (the production
-- open uses save_bg; the persisted shape is identical).

local cache = require 'cartograph.cache'
local config = require 'cartograph.config'
local ts = require 'cartograph.providers.treesitter'

-- a real thin index over a two-file temp lua project
local function proj()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local a = assert(io.open(root .. '/a.lua', 'w'))
    a:write('local M = {}\nfunction M.foo() return 1 end\n'
        .. 'function M.bar() return M.foo() end\nreturn M\n'); a:close()
    local b = assert(io.open(root .. '/b.lua', 'w'))
    b:write('local M = {}\nfunction M.baz() return 2 end\nreturn M\n'); b:close()
    return root
end

test('index-only cache: the marker round-trips (warm reopen still reports index-only)', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = proj()
    local data = ts.index_only(root)
    ok(data.index_only, 'a fresh index_only extract is marked')
    cache.save(data, nil)
    local loaded = cache.load(root)
    ok(loaded ~= nil, 'the thin cache loads')
    ok(loaded and loaded.index_only == true,
        'the index_only marker survives save→load (honesty preserved on warm reopen)')
    vim.fn.delete(root, 'rf')
end)

test('index-only cache: a clean diff serves warm, a change forces a cold re-index', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = proj()
    cache.save(ts.index_only(root), nil)
    local warm, note = cache.open_index_only(root)
    ok(warm and warm.index_only, 'unchanged tree → warm thin graph, still marked')
    ok(note and note:find 'unchanged', 'the note reports an unchanged warm open')
    -- edit a file: the clean-diff gate declines → nil so the caller cold-re-indexes
    local f = assert(io.open(root .. '/a.lua', 'a'))
    f:write('\nfunction M.qux() return 3 end\n'); f:close()
    local d2, note2 = cache.open_index_only(root)
    ok(d2 == nil, 'a changed file declines the warm index-only open')
    ok(note2 and note2:find 'changed', 'the decline note names the change → cold re-index')
    vim.fn.delete(root, 'rf')
end)

test('index-only cache: a FULL open rejects a thin cache (no call graph)', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = proj()
    cache.save(ts.index_only(root), nil) -- a thin cache on disk
    ok(cache.open(root) == nil,
        'a full open will not consume the call-less thin cache → cold full extract')
    ok(not cache.warm_streamable(root),
        'a thin cache never drives the full streamed open path')
    vim.fn.delete(root, 'rf')
end)

test('index-only cache: the index-only opener rejects a FULL cache (wants the thin index)', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = proj()
    local data = ts.index_only(root)
    data.index_only = nil -- persist it as a FULL cache (no marker)
    cache.save(data, nil)
    ok(cache.open_index_only(root) == nil,
        'a full cache is not served to an index-only open → cold defs-only re-index')
    vim.fn.delete(root, 'rf')
end)
