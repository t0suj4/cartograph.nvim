-- CART-0815: profile SELECTION walks UP from the root and picks one; a monorepo PARENT (brotardcast: ejabberd/rebar.config,
-- converse.js/package.json side by side) selected NONE, and 14,735 OTP stdlib calls read as external while graph_info
-- said `index: full, 0 unparsed` — a clean-looking answer. An answer NAMES the profile in force, how it was chosen, and
-- the build-system shapes below the root whose profiles it does not apply. Since CART-2108 the parent applies them per
-- boundary (tests/profileboundaries_spec.lua); `below` keeps what NO boundary applies (upward wins for a language).

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local agent = require 'cartograph.agent'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function open(root)
    local data = ts.extract(root); data.root = root
    store.ingest(data)
end
local function note(a, kind) for _, n in ipairs(a.notes or {}) do if n.kind == kind then return n end end end
local MONO = {
    ['srv/rebar.config'] = '{deps, []}.\n', ['srv/src/srv.erl'] = '-module(srv).\n-export([go/0]).\ngo() -> lists:reverse([1]).\n',
    ['web/package.json'] = '{ "name": "web", "version": "1.0.0" }\n', ['web/src/app.js'] = 'function main() { return JSON.stringify({}); }\n',
    ['apps/core/rebar.config'] = '{deps, []}.\n', -- two levels down
}

test('profile: a monorepo PARENT applies each shape below through its boundary, and names them (CART-0815, CART-2108)', function ()
    local root = tree(MONO)
    open(root)
    local a = agent.answer(store, 'graph_info', {})
    eq('node+otp', a.graph.profile.name, 'the boundaries\' summary — it was NONE before the boundary model')
    eq(vim.NIL, a.graph.profile.selected, 'nothing at or above the parent selects one')
    eq({}, a.graph.profile.below, 'every shape below is applied by its boundary')
    local dirs = {}
    for _, b in ipairs(a.graph.profile.boundaries) do dirs[#dirs + 1] = b.dir end
    eq({ 'apps/core', 'srv', 'web' }, dirs, 'two levels down too')
    eq(nil, note(a, 'profiles-not-applied'))
    ok(note(a, 'profile-boundaries'), vim.inspect(a.notes))
    vim.fn.delete(root, 'rf')
end)

test('profile: a shape below whose profile UPWARD overrides for its language is still reported unapplied (CART-0815, CART-2108)', function ()
    -- an nvim plugin root (plugin/ + lua/) holding a factorio mod: both Lua — upward wins for the language
    local root = tree({ ['plugin/p.lua'] = 'local x = 1\n', ['lua/m.lua'] = 'return {}\n',
        ['mods/m/info.json'] = '{ "name": "m" }\n', ['mods/m/control.lua'] = 'script.on_init(function () end)\n',
        ['mods/m/data.lua'] = 'local d = 1\n' })
    open(root)
    local a = agent.answer(store, 'graph_info', {})
    eq('nvim', a.graph.profile.name)
    eq(nil, a.graph.profile.boundaries, 'a TRIVIAL root: the envelope gains no field')
    local below = {}
    for _, r in ipairs(a.graph.profile.below) do below[#below + 1] = r.dir .. '=' .. r.profile end
    eq({ 'mods/m=lua-factorio' }, below)
    local n = note(a, 'profiles-not-applied')
    ok(n and n.why:match('the profile nvim') and n.why:match('EXTERNAL'), vim.inspect(a.notes))
    vim.fn.delete(root, 'rf')
end)

test('profile: a child root names its own profile and how shapes selected it; nothing below, no note (CART-0815)', function ()
    local root = tree(MONO)
    open(root .. '/srv')
    local a = agent.answer(store, 'graph_info', {})
    eq('otp', a.graph.profile.name)
    eq('otp-app', a.graph.profile.selected.shape); eq(false, a.graph.profile.selected.inherited)
    eq({}, a.graph.profile.below)
    eq(nil, note(a, 'profiles-not-applied'))
    vim.fn.delete(root, 'rf')
end)

test('profile: a shape below with the SAME profile the root applies is not reported; an explicit override says so (CART-0815)', function ()
    local root = tree({ ['package.json'] = '{ "name": "top" }\n', ['index.js'] = 'module.exports = 1;\n',
        ['pkgs/ui/package.json'] = '{ "name": "ui" }\n', ['pkgs/ui/i.js'] = 'module.exports = 2;\n' })
    open(root)
    local a = agent.answer(store, 'node_find', { query = 'nothing' })
    eq('node', a.graph.profile.name)
    eq({}, a.graph.profile.below, 'pkgs/ui selects node too: nothing unapplied')
    store.data.profile = 'luajit'; store.generation = store.generation + 1 -- (the memo must follow the profile itself)
    eq('override', agent.answer(store, 'node_find', { query = 'nothing' }).graph.profile.selected)
    vim.fn.delete(root, 'rf')
end)
