-- The .toc load-order adapter: manifest parsing, XML flattening, and the
-- end-to-end load-order lint over the fixture addon (which has the classic
-- bugs baked in: a load-time call into a later file, an unlisted file, and
-- a listed-but-missing file).

local store = require 'cartograph.store'
local toc   = require 'cartograph.toc'
local lint  = require 'cartograph.lint'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/toc'

test('toc: parses directives and the ordered file list', function ()
    local p = toc.parse_toc([[
## Interface: 30300
## SavedVariables: ADB, BDB

# comment
Libs\Libs.xml
core.lua ]] .. '\r\n' .. [[
]])
    eq('30300', p.directives.Interface)
    eq('ADB, BDB', p.directives.SavedVariables)
    eq({ 'Libs/Libs.xml', 'core.lua' }, p.files)
end)

test('toc: xml yields ordered includes and handler names', function ()
    local x = toc.parse_xml([[
<Ui>
  <!-- <Script file="dead.lua"/> -->
  <Include file="more\more.xml"/>
  <Script file="a.lua"/>
  <Frame><Scripts>
    <OnClick function="Btn:OnClick"/>
    <OnEvent>
      HandleEvent(self, event)
    </OnEvent>
  </Scripts></Frame>
</Ui>]])
    eq({ 'more/more.xml', 'a.lua' }, x.files)
    ok(x.handlers['Btn:OnClick'], 'attribute handler')
    ok(x.handlers['HandleEvent'], 'inline body handler')
    ok(not x.handlers['dead'], 'commented content ignored')
end)

test('toc: loads the fixture manifest in order, case/backslash-proof', function ()
    local model = assert(toc.load(FIX))
    eq('mini.toc', model.toc)
    eq('core.lua', model.entries[1].file)
    eq('widgets/late.lua', model.entries[2].file)
    eq(1, model.entries[2].depth) -- reached through ui.xml
    eq('ui.xml', model.entries[2].via)
    ok(model.handlers.OnMiniClick and model.handlers.InlineBoot, 'xml handlers collected')
    eq(1, #model.missing)
    eq('ghost.lua', model.missing[1].file)
end)

local ADDONS = vim.fn.getcwd() .. '/tests/fixtures/addons'

test('toc: folder model — client load order, missing deps, cycles, LoD', function ()
    local fol = assert(toc.folder(ADDONS))
    -- alphabetical with dependency promotion: CycB (CycA's dep) is
    -- promoted before it; Demand (LoadOnDemand) never loads at startup
    eq({ 'AlphaBar', 'BaseLib', 'CycB', 'CycA' }, fol.order)
    ok(not fol.addons.demand.pos, 'LoadOnDemand addon not in the startup order')
    eq({ { addon = 'AlphaBar', dep = 'Ghost' } }, fol.missing)
    eq(1, #fol.cycles)
    local cy = fol.cycles[1]
    ok((cy.addon == 'CycA' and cy.dep == 'CycB')
        or (cy.addon == 'CycB' and cy.dep == 'CycA'), 'cycle pair found')
end)

test('toc: cross-addon lint — missing dep, cycle, undeclared sibling call', function ()
    -- synthetic store for AlphaBar: one load-time call to BaseRegister,
    -- which the sibling dump (BaseLib/.luals-graph.json) defines
    store.ingest({ schema = 1, root = ADDONS .. '/AlphaBar',
        nodes = { { id = 'main.lua::AlphaBar_OnLoad@3', name = 'AlphaBar_OnLoad',
            kind = 'function', file = 'main.lua', order = 3,
            range = { start = { line = 3, char = 0 }, ['end'] = { line = 5, char = 3 } } } },
        edges = {},
        calls = { { callee = 'BaseRegister', args = { 'alphabar' },
            argv = { { k = 'lit', v = 'alphabar' } },
            file = 'main.lua', line = 1, method = false, top = true } } })
    assert(toc.attach(store))
    ok(store.toc.folder and store.toc.self == 'AlphaBar', 'folder model attached')

    local blob = ''
    for _, f in ipairs(lint.run(store, { only = { ['load-order'] = true } })) do
        blob = blob .. f.message .. '\n'
    end
    ok(blob:match("requires addon 'Ghost'"), 'missing required dep: ' .. blob)
    ok(blob:match("load%-time call to 'BaseRegister', defined by addon 'BaseLib'"),
        'undeclared sibling dependency caught')
    ok(not blob:match('cycle'), "AlphaBar isn't part of the cycle")

    -- the cycle shows up for the addons IN it
    store.ingest({ schema = 1, root = ADDONS .. '/CycA', nodes = {}, edges = {} })
    toc.attach(store)
    blob = ''
    for _, f in ipairs(lint.run(store, { only = { ['load-order'] = true } })) do
        blob = blob .. f.message .. '\n'
    end
    ok(blob:match('dependency cycle'), 'cycle reported for a member: ' .. blob)
end)

test('toc: end-to-end — load-order lint and classification', function ()
    local BIN = vim.fn.expand '~/.local/lib/lua-language-server/bin/lua-language-server'
    if vim.fn.executable(BIN) == 0 then skip 'graph CLI not installed' end
    local out = vim.fn.tempname()
    os.execute(("'%s' --graph='%s' --graphout='%s' --logpath='%s' >/dev/null 2>&1")
        :format(BIN, FIX, out, out .. 'log'))
    store.load(out .. '.json')
    assert(toc.attach(store))

    -- the manifest is exact: listed files are quiet, unlisted never load
    eq('used', store.classify('core.lua'))
    eq('orphan', store.classify('stray.lua'))

    local blob = ''
    for _, f in ipairs(lint.run(store, { only = { ['load-order'] = true } })) do
        blob = blob .. f.message .. '\n'
    end
    ok(blob:match("load%-time call to 'LateHelper'"), 'use-before-load caught: ' .. blob)
    ok(blob:match("'stray%.lua' is not reachable"), 'unlisted file caught')
    ok(blob:match("lists 'ghost%.lua'"), 'missing file caught')

    -- xml handlers are engine entry points, not dead code
    blob = ''
    for _, f in ipairs(lint.run(store, { only = { ['dead-function'] = true } })) do
        blob = blob .. f.message .. '\n'
    end
    ok(not blob:match('OnMiniClick'), 'xml attribute handler exempt')
    ok(not blob:match('InlineBoot'), 'inline body handler exempt')
    ok(blob:match('genuinely_dead'), 'real dead local still flagged')
end)
