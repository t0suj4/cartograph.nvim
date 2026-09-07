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

-- ── PROFILE-SUPPLIED REGISTRY TEMPLATES (CART-0226) ─────────────────────────
-- User design: "I think the profiles should supply certain templates to turn
-- suggestions into lints." greenspun GUESSES a registry from call sites; the declared
-- API export KNOWS the shape from its signatures, so the environment states its own
-- idioms and a project definition carrying the same verb is an ad-hoc reimplementation
-- of a facility the platform already provides.

test('factorio templates: derived from the DECLARED signatures, with call positions',
    function ()
    local prof = require('cartograph.spec.profile').load('lua-factorio')
    if not (prof and prof.templates) then skip 'no lua-factorio templates' end
    local by = {}
    for _, t in ipairs(prof.templates) do by[t.verb] = t end

    -- a STRING key + a CALLABLE: greenspun's own export heuristic, over declared types
    local add = by['commands.add_command']
    ok(add, 'commands.add_command is an idiom')
    eq('string-key', add.kind)
    -- `order` IS THE CALL POSITION, NOT THE ARRAY INDEX: the JSON lists
    -- [function, help, name] with orders 2,1,0, so the real call is
    -- add_command(name, help, fn). Using the array index would have put the key at
    -- arg 3 and every binding built from it would have matched nothing, silently.
    eq(1, add.key, 'the key is the FIRST argument')
    eq(3, add.fn, 'and the callable the third')

    -- a whole registry in ONE argument
    local iface = by['remote.add_interface']
    ok(iface, 'remote.add_interface is an idiom')
    eq('dict', iface.kind, '{[string]: function()} is a registry by itself')
    eq(1, iface.key)

    -- ENUM-KEYED, which greenspun could never have suggested: it looks for STRING keys
    local ev = by['script.on_event']
    ok(ev, 'script.on_event is an idiom')
    eq('enum-key', ev.kind, 'keyed by a declared concept (LuaEventType), not a string')
    eq(1, ev.key); eq(2, ev.fn)

    -- KEYLESS HOOKS: one handler slot, no key at all
    ok(by['script.on_init'], 'on_init is an idiom')
    eq('hook', by['script.on_init'].kind)
    eq(nil, by['script.on_init'].key, 'a hook has no key')
end)

test('factorio templates: idiom-shadow names what a project reimplements', function ()
    local gs = require 'cartograph.greenspun'
    local R = { start = { line = 45, char = 0 }, ['end'] = { line = 50, char = 0 } }
    local templates = {
        { verb = 'script.on_event', kind = 'enum-key', key = 1, fn = 2 },
        { verb = 'commands.add_command', kind = 'string-key', key = 1, fn = 3 },
    }
    local data = { nodes = {
        { id = 'a', name = 'script.on_event', kind = 'function', file = 'k.lua', range = R },
        { id = 'b', name = 'my_own_thing', kind = 'function', file = 'k.lua', range = R },
    } }
    local out = gs.idiom_shadows(data, templates)
    eq(1, #out, 'only the definition that collides with an idiom')
    eq('k.lua', out[1].file)
    eq(46, out[1].line, '1-based, via the range accessor (the range may be FOLDED)')
    ok(out[1].message:find('script%.on_event'), 'names the idiom')
    ok(out[1].message:find('enum%-key'), 'and which KIND of idiom it is')

    -- SILENT for an environment that declares none — every profile but factorio today
    eq(0, #gs.idiom_shadows(data, nil), 'no templates, no findings')
    eq(0, #gs.idiom_shadows(data, {}), 'and an empty list is not an excuse to guess')
end)

test('xlang: profile templates COMPOSE with the built-in bindings', function ()
    local xl = require 'cartograph.xlang'
    local cfg = require 'cartograph.config'
    local saved, saved_only = cfg.bindings, cfg.bindings_only
    cfg.bindings, cfg.bindings_only = nil, nil

    -- no profile: just the language-boundary defaults
    local base = xl.effective_bindings({ nodes = {}, calls = {}, edges = {} })
    local nbase = #base
    ok(nbase >= 3, 'the built-in boundaries are there (' .. nbase .. ')')

    -- with a profile, its idioms are ADDED, not substituted
    local withp = xl.effective_bindings({ nodes = {}, calls = {}, edges = {},
        profile = 'lua-factorio' })
    ok(#withp > nbase, 'the profile contributes idioms on top (' .. #withp .. ')')
    local tmpl, chromium = 0, false
    for _, b in ipairs(withp) do
        if b.template then tmpl = tmpl + 1 end
        if b.export.verb == 'RegisterMessageCallback' then chromium = true end
    end
    ok(tmpl >= 5, 'the idioms are marked with their template (' .. tmpl .. ')')
    ok(chromium, 'and the built-in boundaries SURVIVE — they are not replaced')

    -- cfg.bindings ADDS, which is what config.lua always documented ("Add your own");
    -- the code used to do `cfg.bindings or M.default_bindings`, so declaring one
    -- binding silently dropped chromium, guile, lua_register and wordpress
    cfg.bindings = { { export = { verb = 'MyRegister', name = 1 },
        import = { any_call = true } } }
    local withuser = xl.effective_bindings({ nodes = {}, calls = {}, edges = {} })
    local mine, keptdefault = false, false
    for _, b in ipairs(withuser) do
        if b.export.verb == 'MyRegister' then mine = true end
        if b.export.verb == 'RegisterMessageCallback' then keptdefault = true end
    end
    ok(mine, 'the user binding is in effect')
    ok(keptdefault, 'and it did not silently replace the built-ins')

    -- the old replace-everything behaviour is still reachable, explicitly
    cfg.bindings_only = true
    local only = xl.effective_bindings({ nodes = {}, calls = {}, edges = {} })
    local hasdefault = false
    for _, b in ipairs(only) do
        if b.export.verb == 'RegisterMessageCallback' then hasdefault = true end
    end
    ok(not hasdefault, 'bindings_only DISPOSES, and it has to be asked for')
    cfg.bindings, cfg.bindings_only = saved, saved_only
end)

test('xlang: a one-sided binding REGISTERS its handler but does not LINK', function ()
    -- ★★ THE DISTINCTION THIS TEST USED TO MISS (CART-0226). A platform idiom is
    -- ENGINE-dispatched: nothing in mod code imports script.on_event, the game
    -- does, so there is no importer to pair an export with and inventing one would
    -- fabricate. LINKING needs two sides. REGISTERING does not — "something
    -- outside the call graph invokes this function" is true the moment the
    -- registration is seen, and it is the alibi that keeps a handler off every
    -- dead-code list.
    -- Its previous form asserted "adds no edge", and passed for the wrong reason:
    -- the fixture handed link() a plain string array where argv entries were
    -- expected, so find_handler saw no kinds and could not have resolved anything
    -- either way.
    local xl = require 'cartograph.xlang'
    local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
    local data = {
        root = '/x',
        nodes = {
            { id = 'm.lua', name = 'm.lua', kind = 'module', file = 'm.lua', range = R, order = 0 },
            { id = 'm.lua::h', name = 'h', kind = 'function', file = 'm.lua', range = R, order = 0 },
        },
        edges = {},
        calls = { { fn = 'm.lua', callee = 'script.on_event', full = 'script.on_event',
            file = 'm.lua', line = 0, at = R,
            -- ⚠ `args` IS THE STRING VIEW argv.str READS, and argv the typed one.
            -- A fixture carrying only argv makes every key read as '' — which is
            -- how the first cut of these tests failed, in the harness rather than
            -- in the code.
            args = { 'on_tick', '' },
            argv = { { k = 'lit', v = 'on_tick' }, { k = 'local', name = 'h' } } } },
    }
    local stats = xl.link(data, { { export = { verb = 'script.on_event', name = 1, fn = 2 },
        template = { verb = 'script.on_event', kind = 'enum-key' } } })
    ok(stats ~= nil, 'link survives an import-less binding instead of crashing')
    eq(0, stats.links, 'no LINK: there is no importer to pair with')
    eq(1, stats.registered, 'but the registration IS recorded')
    eq(1, #data.edges)
    eq('m.lua::h', data.edges[1].to, 'and it points at the handler')
end)

test('xlang: a MODULE argument disambiguates an ambiguous handler name', function ()
    -- erlang registers `add_iq_handler(Component, Host, NS, mod_mam, process_iq)`
    -- and `process_iq` is defined by a dozen modules, so the uniqueness test
    -- refuses every one of them. The module names the FILE, and a name ambiguous
    -- corpus-wide is unique inside it.
    local xl = require 'cartograph.xlang'
    local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
    local function mk(mod)
        return { id = mod .. '.erl::process_iq', name = 'process_iq', kind = 'function',
            file = 'src/' .. mod .. '.erl', range = R, order = 0 }
    end
    local data = {
        root = '/x',
        nodes = { { id = 'src/mod_mam.erl', name = 'mod_mam.erl', kind = 'module',
                    file = 'src/mod_mam.erl', range = R, order = 0 },
                  mk('mod_mam'), mk('mod_ping'), mk('mod_time') },
        edges = {},
        calls = { { fn = 'src/mod_mam.erl', callee = 'add_iq_handler',
            full = 'gen_iq_handler.add_iq_handler/5', file = 'src/mod_mam.erl',
            line = 0, at = R,
            args = { 'ejabberd_local', '', 'urn:xmpp:mam:2', 'mod_mam', 'process_iq' },
            argv = {
                { k = 'lit', v = 'ejabberd_local' }, { k = 'local', name = 'Host' },
                { k = 'macro', name = 'NS_MAM_2', v = 'urn:xmpp:mam:2' },
                { k = 'lit', v = 'mod_mam' }, { k = 'lit', v = 'process_iq' } } } },
    }
    local B = { { export = { verb = 'add_iq_handler', name = 3, mod = 4, fn = 5 } } }
    local stats = xl.link(data, B)
    eq(1, stats.registered)
    eq('mod_mam.erl::process_iq', data.edges[1].to,
        'the module picked the right one of three same-named handlers')

    -- ⚠ AND IT DISAMBIGUATES WITHOUT WIDENING: a module naming no file we have
    -- must leave the ambiguity intact, never turn a refusal into a guess.
    data.edges = {}
    data.calls[1].argv[4] = { k = 'lit', v = 'mod_not_in_this_tree' }
    local s2 = xl.link(data, B)
    eq(0, s2.registered or 0, 'an unknown module leaves three candidates, so it refuses')
end)

test('xlang: a HOOK idiom names no key and still registers', function ()
    -- `script.on_init(handler)` has no key argument at all, and requiring one
    -- dropped the whole class before find_handler was ever reached
    local xl = require 'cartograph.xlang'
    local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
    local data = {
        root = '/x',
        nodes = {
            { id = 'm.lua', name = 'm.lua', kind = 'module', file = 'm.lua', range = R, order = 0 },
            { id = 'm.lua::boot', name = 'boot', kind = 'function', file = 'm.lua', range = R, order = 0 },
        },
        edges = {},
        calls = { { fn = 'm.lua', callee = 'script.on_init', full = 'script.on_init',
            file = 'm.lua', line = 0, at = R,
            args = { '' }, argv = { { k = 'local', name = 'boot' } } } },
    }
    local stats = xl.link(data, { { export = { verb = 'script.on_init', fn = 1 } } })
    eq(1, stats.registered)
    eq('m.lua::boot', data.edges[1].to)
end)
