-- CART-1933 (the BNW 2.1 port bot): "where is set_quick_bar_slot called" had no verb — mentions answers per FILE, and
-- node_find is absent for an engine method (no definition in the graph). `sites` lists every call / reference SITE of a
-- name from the graph's own call records and edge sites, with file, 1-based line and 1-based CHARACTER column.

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local agent = require 'cartograph.agent'

local function setup()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, text) local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close() end
    w('control.lua', table.concat({
        'local M = {}',
        'local function helper(x) return x end',
        'function M.on_tick(player)',
        '  local s = "é"; player.set_quick_bar_slot(1, s)', -- 4: `é` is 2 bytes — the char column differs from the byte one
        '  player:set_quick_bar_slot(2, "y")',               -- 5
        '  helper(1)',                                       -- 6
        '  game.print(helper)',                              -- 7: a value REFERENCE; `game.print` is the passing call
        'end',
        'return M', '' }, '\n'))
    w('other.lua', 'local O = {}\nfunction O.f(p)\n  p.set_quick_bar_slot(3)\nend\nreturn O\n')
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    return root
end
local function sites(args) return agent.answer(store, 'sites', args) end

test('sites: an EXTERNAL name is listed per call site with file, line and CHARACTER column, its status and qualified callee (CART-1933)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup()
    local a = sites({ name = 'set_quick_bar_slot' })
    eq(true, a.ok, vim.inspect(a.refusal))
    eq(3, #a.result, vim.inspect(a.result))
    local r1 = a.result[1]
    eq('control.lua', r1.file); eq(4, r1.line)
    local line4 = '  local s = "é"; player.set_quick_bar_slot(1, s)'
    local bytecol = line4:find('player', 1, true)
    eq(bytecol - 1, r1.col, 'a CHARACTER column: one less than the byte column after `é`')
    eq('call', r1.kind); eq('external', r1.status); eq('no-def', r1.why)
    eq('player.set_quick_bar_slot', r1.qualified)
    eq(5, a.result[2].line); eq('player:set_quick_bar_slot', a.result[2].qualified, 'the method-call spelling too')
    eq('other.lua', a.result[3].file); eq(3, a.result[3].line)
    -- narrowed: one file, one kind
    local f = sites({ name = 'set_quick_bar_slot', file = 'other.lua' })
    eq(1, #f.result); eq('other.lua', f.result[1].file)
    eq(0, #(sites({ name = 'set_quick_bar_slot', kind = 'reference' }).result or {}), 'no reference sites for an engine method')
    vim.fn.delete(root, 'rf')
end)

test('sites: a defined function — its resolved call and its value reference, never the call it is passed to (CART-1933)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup()
    local a = sites({ name = 'helper' })
    eq(2, #a.result, vim.inspect(a.result))
    eq({ 'call', 6, 3, 'resolved' }, { a.result[1].kind, a.result[1].line, a.result[1].col, a.result[1].status })
    ok(a.result[1].target and a.result[1].target:find('helper', 1, true), 'the call names its target')
    eq({ 'reference', 7, 14 }, { a.result[2].kind, a.result[2].line, a.result[2].col }, 'the identifier, not `game.print`')
    local passing
    for _, n in ipairs(a.notes or {}) do if n.kind == 'passing-call-sites' then passing = n end end
    ok(passing and passing.evidence.passing == 1, 'the passing call is counted in a note, not reported as a site: ' .. vim.inspect(a.notes))
    vim.fn.delete(root, 'rf')
end)

test('sites: absent for a name nothing calls; clipped with a note; withheld on a thin graph (CART-1933)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup()
    local none = sites({ name = 'nothing_calls_this' })
    eq('absent', none.absence); eq('no-site', none.absence_why.premise)
    local clip = sites({ name = 'set_quick_bar_slot', limit = 1 })
    eq(1, #clip.result)
    local noted
    for _, n in ipairs(clip.notes or {}) do if n.kind == 'clipped' then noted = n end end
    ok(noted and noted.evidence.total == 3, 'the clip says how many there were: ' .. vim.inspect(clip.notes))
    eq(true, agent.VERBS.sites.needs_calls, 'a thin graph has no call records, so the verb is unavailable there, not empty')
    vim.fn.delete(root, 'rf')
end)
