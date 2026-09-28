-- POLICY OVER VIEWS (CART-1120, CART-1160 step 6): config.at(subject, key) — a scoped value is looked up by the
-- SUBJECT, the most specific scope that contains it wins (a subset beats its superset), a QUERY scope's containment is
-- EXTENSIONAL over the loaded graph's files, two most-specific scopes that disagree are AMBIGUOUS (both reported, none
-- picked), and every answer carries its provenance. Then the first two per-tree globals moved onto it: `exclude`
-- (the directory walk) and `entrypoints` (the file classifier).
local config = require 'cartograph.config'
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, t in pairs(files) do
        local d = (root .. '/' .. rel):match('^(.*)/[^/]*$'); vim.fn.mkdir(d, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    return root
end

--- run fn with `scoped` (and any other config keys) set, restoring them afterwards, raise or not
local function with(settings, fn)
    local saved = {}
    for k, v in pairs(settings) do saved[k] = { v = config[k] }; config[k] = v end
    local ok, err = pcall(fn)
    for k, s in pairs(saved) do config[k] = s.v end
    if not ok then error(err, 0) end
end

test('config.at: the most specific DIR wins, a FILE beats its dir, and every answer says which entry decided it', function ()
    local root = tree { ['a/b/f.lua'] = 'return 1\n', ['a/g.lua'] = 'return 2\n' }
    with({ scoped = { [root] = { k = 'root' }, [root .. '/a/b'] = { k = 'inner' }, [root .. '/a/b/f.lua'] = { k = 'file' } }, k = 'global' }, function ()
        local v, prov = config.at(root .. '/a/b/f.lua', 'k')
        eq('file', v); eq('scoped', prov.source); ok(prov.scope:find('file:', 1, true), prov.scope)
        eq('inner', (config.at(root .. '/a/b/other.lua', 'k')))
        eq('root', (config.at(root .. '/a/g.lua', 'k')))
        local g, gp = config.at('/elsewhere/x.lua', 'k')
        eq('global', g); eq('global', gp.source)
        eq('root', config.for_root(root, 'k'), 'for_root is the dir-anchor case')
        eq('inner', config.explain(root .. '/a/b/x.lua').k.value, 'the effective-configuration view')
    end)
    -- the SAME scope twice (the map form and the list form): equal scopes neither dominates the other
    with({ scoped = { [root .. '/a'] = { k = 'one' }, { dir = root .. '/a', values = { k = 'two' } } } }, function ()
        local v, prov = config.at(root .. '/a/g.lua', 'k')
        eq(nil, v); eq('ambiguous', prov.source, 'one scope, two different values: ambiguous')
    end)
    with({ scoped = { [root .. '/a'] = { k = 'one' }, { dir = root .. '/a', values = { k = 'one' } } } }, function ()
        eq('one', (config.at(root .. '/a/g.lua', 'k')), 'one scope, the same value twice: an answer')
    end)
end)

test('config.at: a QUERY scope is contained EXTENSIONALLY — inside a dir it wins; straddling it is AMBIGUOUS', function ()
    if not ready() then skip 'no lua parser' end
    local root = tree { ['src/x_gen.lua'] = 'return 1\n', ['src/y.lua'] = 'return 2\n', ['lib/z_gen.lua'] = 'return 3\n' }
    store.ingest(ts.extract(root))
    local gen_in_src = function (p) return p:find('/src/', 1, true) ~= nil and p:match('_gen%.lua$') ~= nil end
    local gen_anywhere = function (p) return p:match('_gen%.lua$') ~= nil end
    with({ scoped = { [root .. '/src'] = { k = 'src' }, { query = gen_in_src, name = 'gen-in-src', values = { k = 'gen' } } } }, function ()
        local v, prov = config.at(root .. '/src/x_gen.lua', 'k')
        eq('gen', v, 'every file the query selects lies in src/: the query is the subset, and it wins'); ok(prov.scope:find('gen-in-src', 1, true))
        eq('src', (config.at(root .. '/src/y.lua', 'k')), 'the query does not hold y.lua')
    end)
    with({ scoped = { [root .. '/src'] = { k = 'src' }, { query = gen_anywhere, name = 'gen', values = { k = 'gen' } } } }, function ()
        local v, prov = config.at(root .. '/src/x_gen.lua', 'k')
        eq(nil, v, 'the query also selects lib/z_gen.lua: neither contains the other, and they disagree')
        eq('ambiguous', prov.source); eq(2, #prov.entries)
    end)
    with({ scoped = { [root .. '/src'] = { k = 'same' }, { query = gen_anywhere, name = 'gen', values = { k = 'same' } } } }, function ()
        local v, prov = config.at(root .. '/src/x_gen.lua', 'k')
        eq('same', v, 'overlapping scopes that AGREE are an answer'); ok(prov.scope:find(' + ', 1, true), 'citing both: ' .. prov.scope)
    end)
    -- no graph: a query's containment is UNKNOWN, so a disagreement is ambiguous rather than guessed
    local saved = store.data
    store.data = nil
    local ok_run, err = pcall(function ()
        with({ scoped = { [root .. '/src'] = { k = 'src' }, { query = gen_in_src, name = 'gen-in-src', values = { k = 'gen' } } } }, function ()
            local v, prov = config.at(root .. '/src/x_gen.lua', 'k')
            eq(nil, v); eq('ambiguous', prov.source)
        end)
    end)
    store.data = saved
    if not ok_run then error(err, 0) end
end)

test('exclude, scoped: a subtree excludes its own directory names; the rest of the tree does not', function ()
    if not ready() then skip 'no lua parser' end
    -- ⚠ NOT `vendor/`: that name is a BUILT-IN exclusion, so a fixture under it is never walked and the test passes
    -- with the scoped lookup deleted (measured: the mutation survived)
    local root = tree { ['pkg/gen/a.lua'] = 'return 1\n', ['app/gen/b.lua'] = 'return 2\n', ['app/c.lua'] = 'return 3\n' }
    with({ scoped = { [root .. '/pkg'] = { exclude = { 'gen' } } } }, function ()
        store.ingest(ts.extract(root))
        local files = {}
        for _, f in ipairs(store.files or {}) do files[f] = true end
        ok(next(files), 'the roster is non-empty (the accessor is live)')
        eq(nil, files['pkg/gen/a.lua'], 'excluded inside pkg/')
        ok(files['app/gen/b.lua'] and files['app/c.lua'], 'but not under app/: ' .. vim.inspect(store.files))
    end)
end)

test('entrypoints, scoped: a subtree declares its own; lists that disagree but AGREE about a file answer; a real disagreement is `ambiguous`', function ()
    if not ready() then skip 'no lua parser' end
    local root = tree { ['mod/control.lua'] = 'local x = 1\n', ['mod/main.lua'] = 'local y = 2\n', ['lone.lua'] = 'local z = 3\n' }
    store.ingest(ts.extract(root))
    with({ entrypoints = {}, scoped = { [root .. '/mod'] = { entrypoints = { 'control%.lua$' } } } }, function ()
        eq('entry', store.classify('mod/control.lua'))
        eq('orphan', store.classify('mod/main.lua'))
        eq('orphan', store.classify('lone.lua'), 'outside the scope: the (empty) global list')
    end)
    -- ⚠ a query that held ALL of mod/ plus lone.lua would CONTAIN the dir extensionally, and the dir would simply win:
    -- the straddle has to be real — this query holds main.lua and lone.lua, the dir holds control.lua and main.lua
    local straddle = function (p) return p:match('/mod/main%.lua$') ~= nil or p:match('lone%.lua$') ~= nil end
    with({ entrypoints = {}, scoped = { [root .. '/mod'] = { entrypoints = { 'control%.lua$' } },
            { query = straddle, name = 'main+lone', values = { entrypoints = { 'main%.lua$', 'lone%.lua$' } } } } }, function ()
        eq('entry', store.classify('mod/control.lua'), 'only the dir holds control.lua: its answer')
        eq('ambiguous', store.classify('mod/main.lua'), 'both hold main.lua and disagree about it: never an orphan claim')
        eq('entry', store.classify('lone.lua'), 'only the query holds lone.lua')
    end)
    local both = function (p) return p:match('/mod/control%.lua$') ~= nil or p:match('lone%.lua$') ~= nil end
    with({ entrypoints = {}, scoped = { [root .. '/mod'] = { entrypoints = { 'control%.lua$' } },
            { query = both, name = 'control+lone', values = { entrypoints = { 'control%.lua$', 'lone%.lua$' } } } } }, function ()
        eq('entry', store.classify('mod/control.lua'), 'the LISTS differ, but both say entry about control.lua: an answer')
    end)
end)
