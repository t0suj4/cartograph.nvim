-- Corpus-scale-in-miniature refresh contracts (pre-CSR): the incremental
-- path must be (a) IDEMPOTENT — refreshing every file of an UNCHANGED tree
-- leaves the graph per-item identical to a fresh extract — and
-- (b) CONVERGENT — after a real edit, refresh.file() equals a fresh
-- extract of the mutated tree, per-item. CSR shard invalidation inherits
-- exactly this contract; proving it on the wide path first means CSR
-- bugs will be attributable to CSR.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local refresh = require 'cartograph.refresh'
local gd = require 'cartograph.graphdiff'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local FILES = {
    ['lib/util.lua'] = [[
local function util_alpha(x) return x + 1 end
local function util_beta(x) return util_alpha(x) * 2 end
return { util_alpha = util_alpha, util_beta = util_beta }
]],
    ['lib/deep.lua'] = [[
local u = require 'lib.util'
local function deep_probe(v) return u.util_beta(v) end
local function deep_scan(v) return deep_probe(v) + util_alpha(v) end
return { deep_probe = deep_probe, deep_scan = deep_scan }
]],
    ['app/main.lua'] = [[
local d = require 'lib.deep'
local function main_run() return d.deep_scan(1) end
local function main_helper() return main_run() end
return { main_run = main_run, main_helper = main_helper }
]],
    ['app/extra.lua'] = [[
local function extra_one() return util_beta(3) end
local function extra_two() return extra_one() end
return { extra_one = extra_one, extra_two = extra_two }
]],
    ['tables.lua'] = [[
local handlers = { on_run = function () return deep_probe(0) end }
local registry = { extra_two, main_helper }
return { handlers = handlers, registry = registry }
]],
}

local function build()
    local root = vim.fn.tempname()
    for rel, text in pairs(FILES) do
        local dir = rel:match('^(.*)/[^/]*$')
        vim.fn.mkdir(root .. (dir and '/' .. dir or ''), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    return root
end

test('refresh sweep: unchanged-tree refresh of EVERY file is idempotent', function ()
    if not ready() then skip 'no lua parser' end
    local root = build()
    store.ingest(ts.extract(root))
    for rel in pairs(FILES) do
        local _, why = refresh.file(rel)
        ok(why == nil or why ~= 'error', 'refresh ' .. rel .. ' ok')
    end
    local fresh = ts.extract(root)
    local d = gd.diff(store.data, fresh)
    ok(gd.empty(d), 'store after full sweep == fresh extract, per-item')
    vim.fn.delete(root, 'rf')
end)

test('refresh sweep: an edited file converges to the fresh extract', function ()
    if not ready() then skip 'no lua parser' end
    local root = build()
    store.ingest(ts.extract(root))
    -- real edit: a new fn with a cross-file call, one fn deleted
    local fd = assert(io.open(root .. '/app/extra.lua', 'w'))
    fd:write([[
local function extra_one() return util_beta(4) end
local function newcomer() return deep_scan(9) end
return { extra_one = extra_one, newcomer = newcomer }
]])
    fd:close()
    local _, why = refresh.file('app/extra.lua')
    ok(why == nil or why ~= 'error', 'refresh after edit ok')
    local fresh = ts.extract(root)
    local d = gd.diff(store.data, fresh)
    ok(gd.empty(d), 'store after edit-refresh == fresh extract of mutated tree')
    vim.fn.delete(root, 'rf')
end)
