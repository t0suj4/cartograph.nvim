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
