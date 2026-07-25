-- The LUA-FACTORIO L2 profile minting face ([[cartograph-stdlib-profile]]): a
-- factorio-mod root (info.json + control.lua) activates the lua-factorio profile,
-- and a namespace-rooted `<global>.<method>` call (game.print) mints an OWNER-
-- PRECISE `lua-factorio::Class::method` node from runtime-api.json (via the
-- profile's receiver-namespace mint_path). Receiver-typed methods (player.insert)
-- and non-global dotted calls stay a frontier (no receiver typing for dynamic
-- langs). Gate-protects the distill artifact + the mint_path wiring + hover sigs.

local ts = require 'cartograph.providers.treesitter'
local profmod = require 'cartograph.spec.profile'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end
local function call_to(data, callee)
    for _, c in ipairs(data.calls or {}) do if c.callee == callee then return c end end
end

test('lua-factorio profile: runtime-api enrichment (mint + owner-precise sigs)', function ()
    local p = profmod.load('lua-factorio')
    ok(p and p.schema == 1, 'profile loads')
    if not p.mint then skip 'no lua-factorio-api.mpack (runtime-api.json not distilled)' end
    eq('factorio', p.sig_kind) -- the hover provenance label (NOT "RBS")
    ok(type(p.mint_path) == 'function', 'carries the receiver-namespace mint mapper')
    ok(p.sigs and p.sigs['LuaGameScript::print'] and p.sigs['LuaGameScript::print'].sig,
        'sigs carries the owner-precise LuaGameScript::print signature')
    ok(p.sigs['LuaGameScript::print'].sig:find('LocalisedString', 1, true),
        'the signature shows the real parameter type from runtime-api.json')
end)

test('lua-factorio profile: a factorio root mints global calls owner-precise', function ()
    if not ready() then skip 'no lua parser' end
    local p = profmod.load('lua-factorio')
    if not p.mint then skip 'no lua-factorio-api.mpack' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'info.json', { '{"name":"m"}' })       -- the factorio-mod shape marker
    write(root, 'control.lua', {
        'game.print("hi")',                            -- global.method  → LuaGameScript::print
        'rendering.draw_text{text="x"}',               -- global.method  → LuaRendering::draw_text
        'log("msg")',                                  -- free fn        → lua-factorio::log
        'local pl = game.get_player(1)',               -- global.method  → LuaGameScript::get_player
        'pl.insert{name="iron-plate"}',                -- receiver-typed → FRONTIER (unminted)
        'foo.bar()',                                   -- non-global dot → FRONTIER (unminted)
    })
    local data = ts.extract(root)
    eq('lua-factorio', data.profile) -- the profile activated via the factorio-mod shape

    eq('lua-factorio::LuaGameScript::print', call_to(data, 'print').to)
    eq('lua-factorio::LuaRendering::draw_text', call_to(data, 'draw_text').to)
    eq('lua-factorio::LuaGameScript::get_player', call_to(data, 'get_player').to)
    eq('lua-factorio::log', call_to(data, 'log').to) -- bare free fn
    -- SOUNDNESS: receiver-typed + non-global dotted calls are NOT minted (frontier)
    ok(not call_to(data, 'insert').to, 'receiver-typed pl.insert stays a frontier (not minted)')
    ok(not call_to(data, 'bar').to, 'non-global dotted foo.bar stays a frontier (not minted)')
    -- the minted node is external, at the runtime's synthetic file, stdlib-tier edge
    local byid = {}; for _, n in ipairs(data.nodes) do byid[n.id] = n end
    local nd = byid['lua-factorio::LuaGameScript::print']
    ok(nd and nd.kind == 'external' and nd.file == 'lua-factorio', 'minted node external @ lua-factorio')
    vim.fn.delete(root, 'rf')
end)

test('lua-factorio profile: hover shows the runtime-api signature of a minted node', function ()
    if not ready() then skip 'no lua parser' end
    local p = profmod.load('lua-factorio')
    if not p.mint then skip 'no lua-factorio-api.mpack' end
    local store = require 'cartograph.store'
    local lsp = require 'cartograph.lsp'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'info.json', { '{"name":"m"}' })
    write(root, 'control.lua', { 'game.print("hi")' }) -- `game.` cols 0-4, print at 5
    local data = ts.extract(root); store.ingest(data)
    local c = call_to(data, 'print')
    ok(c.to == 'lua-factorio::LuaGameScript::print', 'print minted owner-precise')
    local h = lsp.handlers['textDocument/hover'](store, {
        textDocument = { uri = vim.uri_from_fname(root .. '/control.lua') },
        position = { line = 0, character = 6 }, -- on `print`
    })
    local val = h and h.contents and h.contents.value or ''
    ok(val:find('LocalisedString', 1, true), 'hover shows the runtime-api signature')
    ok(val:find('· factorio ', 1, true), 'provenance labels the sig source as `factorio`, not RBS')
    vim.fn.delete(root, 'rf')
end)
