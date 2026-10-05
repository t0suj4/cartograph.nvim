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

-- ★ REPEATED SAVES CONVERGE (CART-1439): every relink re-ran module ownership (own_module_calls walks every call) and
-- appended each module-level call's site AGAIN — the occurrence counts grew with every save of ANY file (our tree:
-- ~280 sites a save, ~1,700 more from xlang.link). Saving one file four times must leave the graph a fresh extract
-- gives, occurrence counts included.
test('refresh sweep: saving the same file FOUR times leaves every edge\'s sites where one save left them', function ()
    if not ready() then skip 'no lua parser' end
    local root = build()
    -- (module-level calls: their region edges are what every relink re-owned)
    local fd = assert(io.open(root .. '/boot.lua', 'w'))
    fd:write("local d = require 'lib.deep'\nd.deep_probe(1)\nd.deep_scan(2)\nlocal m = require 'app.main'\nm.main_run()\n")
    fd:close()
    store.ingest(ts.extract(root))
    local function sites()
        local n = 0
        for _, e in ipairs(store.data.edges) do n = n + #(e.at or {}) end
        return n
    end
    local _, why = refresh.file('lib/util.lua')
    ok(why == nil or why ~= 'error', 'first save ok')
    local once = sites()
    for _ = 1, 3 do refresh.file('lib/util.lua') end
    eq(once, sites(), 'the at-sites after four saves equal those after one')
    local d = gd.diff(store.data, ts.extract(root))
    ok(gd.empty(d), 'and the store equals a fresh extract, per-item')
    vim.fn.delete(root, 'rf')
end)

test('refresh sweep: a string-keyed REGISTRY\'s cross-language links keep one site each, however many saves relink them', function ()
    if not ready() then skip 'no lua parser' end
    local root = build()
    local fd = assert(io.open(root .. '/reg.lua', 'w'))
    fd:write(table.concat({
        'local R = {}', 'local function on(name, fn) R[name] = fn end', 'local function emit(name, ...) return R[name](...) end',
        'local function alpha_handler() return 1 end', 'local function beta_handler() return 2 end', 'local function gamma_handler() return 3 end',
        "on('alpha', alpha_handler)", "on('beta', beta_handler)", "on('gamma', gamma_handler)",
        "local function run() emit('alpha'); emit('beta'); emit('gamma') end", 'return { run = run }', '' }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local function xsites()
        local e, n = 0, 0
        for _, x in ipairs(store.data.edges) do if x.xlang then e = e + 1; n = n + #(x.at or {}) end end
        return e, n
    end
    refresh.file('lib/util.lua')
    local e1, n1 = xsites()
    ok(e1 >= 3, 'the registry is linked (' .. e1 .. ' xlang edges)')
    for _ = 1, 3 do refresh.file('lib/util.lua') end
    local e4, n4 = xsites()
    eq(e1, e4); eq(n1, n4, 'xlang.link appended its sites again on every save')
    vim.fn.delete(root, 'rf')
end)

-- ★ THE MENTION INDEX IS PART OF THE CONTRACT (CART-1393). graphdiff compares nodes and edges, not `data.names`, so a
-- refreshed file whose name set never came back passed every test above while `mentions` answered a false `absent`.
-- The file that lost it was a NEW one with NO FUNCTIONS: the splice handed the id pass only files with fn ranges,
-- though the id pass itself (and the cold extract) reads a var-only file too.
test('refresh sweep: a NEW file with no functions gets its mention names, like a fresh extract', function ()
    if not ready() then skip 'no lua parser' end
    local root = build()
    store.ingest(ts.extract(root))
    local fd = assert(io.open(root .. '/lib/consts.lua', 'w'))
    fd:write('local freshname = 1\nreturn freshname\n')
    fd:close()
    local _, why = refresh.file('lib/consts.lua')
    ok(why == nil or why ~= 'error', 'refresh of the new file ok')
    local fresh = ts.extract(root)
    ok(fresh.names and fresh.names['lib/consts.lua'], 'the fresh extract indexes the new file (the control)')
    eq(fresh.names['lib/consts.lua'], (store.data.names or {})['lib/consts.lua'], 'and so does the refreshed store')
    for f, s in pairs(fresh.names) do
        eq(s, (store.data.names or {})[f], 'every file\'s name set agrees: ' .. f)
    end
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
