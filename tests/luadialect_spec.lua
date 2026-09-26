-- The Lua DIALECT decides how `global` parses (lua/cartograph/luadialect.lua). tree-sitter-lua follows Lua 5.5, where
-- `global` is a keyword; before 5.5 it is a name (Factorio 1.x's persistent-state table). The workaround is TIED to
-- the dialect: a pre-5.5 root is parsed from a view with `global` masked, a 5.5 root is parsed as written.

local ld = require 'cartograph.luadialect'

local function root_with(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, body in pairs(files) do
        local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(body); fd:close()
    end
    return root
end

test('luadialect: resolves from .luarc.json, .luarc.jsonc, .luacheckrc, and says when it is the default', function ()
    local cases = {
        { { ['.luarc.json'] = '{ "runtime.version": "Lua 5.5" }' }, '5.5', '.luarc.json' },
        { { ['.luarc.json'] = '{ "runtime": { "version": "LuaJIT" } }' }, 'jit', '.luarc.json' },
        { { ['.luarc.jsonc'] = '{\n  // the lua-ls setting\n  "Lua": { "runtime": { "version": "Lua 5.1" } }\n}' },
            '5.1', '.luarc.jsonc' },
        { { ['.luacheckrc'] = 'std = "lua54+busted"\n' }, '5.4', '.luacheckrc' },
        { { ['.luacheckrc'] = "std = 'luajit'\n" }, 'jit', '.luacheckrc' },
        { {}, nil, 'default (before 5.5)' },
    }
    for _, c in ipairs(cases) do
        local root = root_with(c[1])
        local v, src = ld.resolve(root)
        eq(c[2], v, vim.inspect(c[1]))
        eq(c[3], src)
        vim.fn.delete(root, 'rf')
    end
end)

test('luadialect: the view masks whole-word `global` for pre-5.5 only, keeps every byte offset, touches no other language', function ()
    local src = 'x = global.flag; global_x = myglobal; y = globals .. "global"\n'
    local v = ld.view(src, 'lua', '5.2')
    eq(#src, #v, 'length preserved: every range still addresses the file')
    eq('x = _lobal.flag; global_x = myglobal; y = globals .. "_lobal"\n', v)
    eq(src, ld.view(src, 'lua', '5.5'), 'a 5.5 root is parsed as written')
    eq(src, ld.view(src, 'python', '5.2'), 'another language is untouched')
    eq(true, ld.global_is_name(nil), 'the unset default is the pre-5.5 reading')
end)

-- end to end, through extraction and the reference surface the failing portability tests use
local function reads_of(root)
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local data = ts.extract(root)
    store.ingest(data)
    return require('cartograph.externals').references(store).names, data
end

test('luadialect: in a Lua 5.4 root `global.flag` is a READ of the name `global`; in a 5.5 root `global x` declares', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local body = 'local function a()\n  if global.flag then return 1 end\n  global.helper(1)\nend\nreturn { a = a }\n'
    local r54 = root_with({ ['.luarc.json'] = '{ "runtime.version": "Lua 5.4" }', ['control.lua'] = body })
    local names, data = reads_of(r54)
    ok(names['global.flag'] ~= nil, 'the pre-5.5 reading keeps the read')
    eq({ version = '5.4', source = '.luarc.json' }, data.lua_dialect, 'recorded on the graph, with its source')
    eq('5.4', ld.get(), 'and adopted for later re-parses')
    -- and EXTRACTION itself parsed the view: the function's dataflow USES the name `global` (the 5.5 reading has
    -- no identifier there at all, so the use vanishes; the call name survives either way, being whole-node text)
    local uses = {}
    for _, n in ipairs(data.nodes) do
        if n.id == 'control.lua::a@0' then
            for _, st in ipairs(require('cartograph.df').stmts(n) or {}) do
                for _, u in ipairs(st.use or {}) do uses[u] = true end
            end
        end
    end
    eq(true, uses['global'], 'extraction reads `global` as a used name')
    vim.fn.delete(r54, 'rf')

    local r55 = root_with({ ['.luarc.json'] = '{ "runtime.version": "Lua 5.5" }',
        ['m.lua'] = 'global counter = 0\nlocal function inc() counter = counter + 1 end\nreturn { inc = inc }\n' })
    local _, d55 = reads_of(r55)
    eq('5.5', d55.lua_dialect.version)
    local unparsed = false
    for _, n in ipairs(d55.nodes) do if n.kind == 'module' and n.unparsed then unparsed = true end end
    eq(false, unparsed, 'the 5.5 declaration parses as written, not masked into an error')
    vim.fn.delete(r55, 'rf')
end)

test('luadialect: store.ingest re-adopts the dialect a graph was built with', function ()
    local store = require 'cartograph.store'
    store.ingest({ schema = 1, root = '/nonexistent', nodes = {}, edges = {}, calls = {}, stamps = {},
        lua_dialect = { version = '5.5', source = '.luarc.json' } })
    eq('5.5', ld.get())
    store.ingest({ schema = 1, root = '/nonexistent', nodes = {}, edges = {}, calls = {}, stamps = {} })
    eq(nil, ld.get(), 'a graph predating the field: the pre-5.5 default it was built with')
end)

test('luadialect: a changed dialect declaration makes the warm cache a MISS', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local cache = require 'cartograph.cache'
    local ts = require 'cartograph.providers.treesitter'
    local root = root_with({ ['m.lua'] = 'local function f(x) return x end\nreturn { f = f }\n' })
    cache.wipe(root)
    cache.save(ts.extract(root))
    ok(cache.open(root) ~= nil, 'warm open works right after save')
    local fd = assert(io.open(root .. '/.luarc.json', 'w')); fd:write('{ "runtime.version": "Lua 5.5" }'); fd:close()
    eq(nil, cache.open(root), 'the dialect moved: the cache is stale')
    os.remove(root .. '/.luarc.json')
    ok(cache.open(root) ~= nil, 'and valid again once restored')
    cache.wipe(root); vim.fn.delete(root, 'rf')
end)
