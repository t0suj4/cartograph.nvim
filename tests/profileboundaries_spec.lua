-- CART-2108 (boundary model, phase 1 of kb polyglot-root-boundaries-design): one tree is one root; a BOUNDARY is the
-- unit its environment attaches to. Each file has one shard boundary; each boundary carries { language -> profile }
-- and its source (user / computed / default). Detection: the upward probe gives the root boundary, a downward probe
-- (depth 2, sorted, skipping .git / node_modules / deps / _build) adds a boundary per build marker; UPWARD WINS for its
-- language. A TRIVIAL root (no boundary below adds a profile) keeps today's profile, graph and cache key byte for
-- byte. Measured: the brotardcast parent opened as ONE root resolved 39,576 -> 64,757 calls (+25,181, all `stdlib`:
-- OTP on the ejabberd side, node on converse.js), and of 51 cached roots only hugo (docs/package.json) changes key.

local ts    = require 'cartograph.providers.treesitter'
local Bd    = require 'cartograph.boundary'
local cache = require 'cartograph.cache'
local store = require 'cartograph.store'
local agent = require 'cartograph.agent'
local pm    = require 'cartograph.spec.profile'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function call(data, file, full)
    for _, c in ipairs(data.calls) do if c.file == file and c.full == full then return c end end
end
local MONO = {
    ['srv/rebar.config'] = '{deps, []}.\n', ['srv/src/srv.erl'] = '-module(srv).\n-export([go/0]).\ngo() -> lists:reverse([1]).\n',
    ['web/package.json'] = '{ "name": "web", "version": "1.0.0" }\n', ['web/src/app.js'] = 'function main() { return JSON.stringify({}); }\n',
    ['apps/core/rebar.config'] = '{deps, []}.\n', -- two levels down
}

test('profile boundaries: a monorepo parent gets one boundary per build marker below — sorted, depth 2, the skip dirs skipped (CART-2108)', function ()
    local files = vim.deepcopy(MONO)
    files['node_modules/x/package.json'] = '{ "name": "x" }\n'
    files['deps/y/rebar.config'] = '{deps, []}.\n'
    files['a/b/c/package.json'] = '{ "name": "deep" }\n' -- depth 3: out of the probe
    local root = tree(files)
    local B = Bd.detect(root)
    eq(false, B.trivial)
    local rows = {}
    for _, b in ipairs(B.list) do
        local ls = {}
        for l, rt in pairs(b.langs) do ls[#ls + 1] = l .. '=' .. rt end
        table.sort(ls)
        rows[#rows + 1] = ('%s|%s|%s'):format(b.dir, b.source, table.concat(ls, ','))
    end
    eq({ '|default|', 'apps/core|computed|erlang=otp', 'srv|computed|erlang=otp', 'web|computed|javascript=node' }, rows)
    eq('node+otp', Bd.summary(B))
    eq('srv', Bd.boundary_of(B, 'srv/src/srv.erl').dir, 'the deepest containing boundary')
    eq('', Bd.boundary_of(B, 'README.md').dir)
    eq('otp', Bd.resolve(B, 'srv/src/srv.erl', 'erlang'))
    eq(nil, Bd.resolve(B, 'srv/src/srv.erl', 'javascript'), 'no boundary up the chain declares javascript')
    vim.fn.delete(root, 'rf')
end)

test('profile boundaries: UPWARD WINS for its language; a root whose markers below add nothing is TRIVIAL (CART-2108)', function ()
    local root = tree({ ['package.json'] = '{ "name": "top" }\n', ['pkgs/ui/package.json'] = '{ "name": "ui" }\n',
        ['srv/rebar.config'] = '{deps, []}.\n' })
    local B = Bd.detect(root)
    eq('node', B.by[''].langs.javascript); eq('computed', B.by[''].source)
    eq(nil, B.by['pkgs/ui'].langs.javascript, 'a node marker below a node root adds nothing')
    eq('otp', B.by.srv.langs.erlang, 'downward fills in the language upward lacks')
    eq(false, B.trivial)
    vim.fn.delete(root .. '/srv', 'rf')
    eq(true, Bd.detect(root).trivial)
    vim.fn.delete(root, 'rf')
end)

test('profile boundaries: the polyglot parent applies each side\'s profile as its child root does; relink keeps it (CART-2108)', function ()
    if not (parser_available('erlang') and parser_available('javascript')) then skip 'no erlang / javascript parser' end
    local root = tree(MONO)
    local data = ts.extract(root); data.root = root
    eq('node+otp', data.profile, 'data.profile is the display summary')
    ok(data.profiles and #data.profiles.list == 4, 'data.profiles carries the structure')
    local c = call(data, 'srv/src/srv.erl', 'lists.reverse/1')
    ok(c and c.to and c.prov == 'stdlib', 'OTP stdlib on the erlang side: ' .. vim.inspect(c))
    local child = ts.extract(root .. '/srv')
    eq(call(child, 'src/srv.erl', 'lists.reverse/1').to, c.to, 'the same target the child root resolves')
    -- RELINK reads the boundaries off the graph (data.profile 'node+otp' loads nothing)
    local function resolved() local n = 0; for _, x in ipairs(data.calls) do if x.to then n = n + 1 end end; return n end
    local before = resolved()
    ts.relink(data)
    eq(before, resolved(), 'relink keeps every resolution')
    ok(call(data, 'srv/src/srv.erl', 'lists.reverse/1').to)
    vim.fn.delete(root, 'rf')
end)

test('profile boundaries: TWO boundaries of ONE language carry two profiles — the user slot; each file takes its own (CART-2108)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local src = 'local M = {}\nfunction M.f()\n  game.print("x")\nend\nreturn M\n'
    local root = tree({ ['a/control.lua'] = src, ['b/plugin.lua'] = src })
    local B = Bd.detect(root, { user = { { dir = 'a', langs = { lua = 'lua-factorio' } }, { dir = 'b', langs = { lua = 'nvim' } } } })
    eq('user', B.by.a.source); eq(false, B.trivial)
    local data = ts.extract(root, { profiles = Bd.to_data(B) })
    local a, b = call(data, 'a/control.lua', 'game.print'), call(data, 'b/plugin.lua', 'game.print')
    ok(a.to and a.to:match('^lua%-factorio::'), 'the factorio boundary mints it: ' .. vim.inspect(a))
    eq(nil, b.to, 'the nvim boundary does not')
    eq('lua-factorio', Bd.profile_for(data, 'a/control.lua')); eq('nvim', Bd.profile_for(data, 'b/plugin.lua'))
    eq(nil, Bd.runtime_for_lang(data, 'lua'), 'a language-scoped reader gets no single answer for two')
    vim.fn.delete(root, 'rf')
end)

test('profile boundaries: a TRIVIAL root\'s identity is today\'s (name, stamp) and no key; a polyglot one is keyed (CART-2108)', function ()
    local root = tree({ ['rebar.config'] = '{deps, []}.\n', ['src/m.erl'] = '-module(m).\n' })
    local name, stamp, key = Bd.identity(root)
    local pf = require('cartograph.shapes').profile_for(root)
    eq({ pf.profile, pm.stamp_of(pf.profile) }, { name, stamp })
    eq(nil, key)
    local mono = tree(MONO)
    local n2, s2, k2 = Bd.identity(mono)
    eq('node+otp', n2)
    ok(s2:match('^node:') and s2:match('|otp:'), s2)
    ok(k2:match('^boundary/1;depth=2;'), k2)
    eq(k2, Bd.key(Bd.from_data(Bd.to_data(Bd.detect(mono)))), 'the key survives the data round trip')
    vim.fn.delete(root, 'rf'); vim.fn.delete(mono, 'rf')
end)

test('profile boundaries: a polyglot cache opens warm, and a marker added below is a clean miss (CART-2108)', function ()
    if not (parser_available('erlang') and parser_available('javascript')) then skip 'no erlang / javascript parser' end
    local root = tree(MONO)
    local data = ts.extract(root); data.root = root
    cache.save(data)
    local warm = cache.load(root)
    ok(warm, 'warm')
    eq('node+otp', warm.profile)
    eq(Bd.key(Bd.from_data(data.profiles)), Bd.key(Bd.from_data(warm.profiles)), 'the structure rides the manifest')
    vim.fn.mkdir(root .. '/tools', 'p')
    local fd = assert(io.open(root .. '/tools/package.json', 'w')); fd:write('{ "name": "tools" }\n'); fd:close()
    eq(nil, cache.load(root), 'a new boundary changes the key')
    vim.fn.delete(root, 'rf')
end)

test('profile boundaries: graph_info names the boundaries in force; nothing below is reported unapplied (CART-2108)', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = tree(MONO)
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local a = agent.answer(store, 'graph_info', {})
    eq('node+otp', a.graph.profile.name)
    eq({}, a.graph.profile.below, 'every shape below is applied by its boundary')
    eq(3, #a.graph.profile.boundaries)
    local kinds = {}
    for _, n in ipairs(a.notes or {}) do kinds[n.kind] = n end
    ok(kinds['profile-boundaries'] and kinds['profile-boundaries'].why:match('srv erlang=otp'), vim.inspect(a.notes))
    eq(nil, kinds['profiles-not-applied'])
    vim.fn.delete(root, 'rf')
end)
