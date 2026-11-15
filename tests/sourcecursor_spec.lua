-- CART-2089: the source pane PUBLISHES its cursor address to the store (store.source_cursor / on_source_cursor) on a
-- settled cursor move — the node it renders, the 0-based file line and byte column, the word, and the base of those
-- numbers. Found on the way: its row -> file-line map counted from the def's own first line while the body starts at the
-- first SHOWN line (a leading doc comment), so <C-]> / gf and this address were off by the docblock's height.

local ts     = require 'cartograph.providers.treesitter'
local store  = require 'cartograph.store'
local source = require 'cartograph.panes.source'

test('source pane: a settled cursor publishes { node, file, line, col, cword, base } — doc comment counted, header row has no line (CART-2089)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local M = {}',                 -- 0
        '',                             -- 1
        '-- what helper does',          -- 2  (the doc comment the body shows above the def)
        '-- and a second line',         -- 3
        'function M.helper(x)',         -- 4
        '    return target(x)',         -- 5
        'end',                          -- 6
        'return M', '' }, '\n'))
    fd:close()
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local id
    for _, n in ipairs(store.data.nodes) do if n.name == 'M.helper' then id = n.id end end
    ok(id, 'the def is in the graph')

    vim.cmd('tabnew')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, source.create())
    source.attach(win)
    source.CURSOR_SETTLE_MS = 0
    local got = {}
    local unsub = store.on_source_cursor(function (a) got[#got + 1] = a end)
    source.render(id)
    local buf = vim.api.nvim_win_get_buf(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local row -- the buffer row holding `    return target(x)`
    for i, l in ipairs(lines) do if l:find('return target', 1, true) then row = i end end
    ok(row, 'the body shows the def: ' .. vim.inspect(lines))

    local function settle(r, c)
        local before = #got
        vim.api.nvim_win_set_cursor(win, { r, c })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
        vim.wait(200, function () return #got > before end, 5)
        return got[#got], #got - before
    end

    local a = settle(row, 11) -- on `target`
    ok(a, 'an address was published')
    eq(id, a.node)
    eq('m.lua', a.file)
    -- (a typed GRAPH position since CART-2086: 0-based line, 0-based byte column)
    eq({ line = 5, col = 11, lb = 0, cb = 0, unit = 'byte' }, a.pos, 'the REAL 0-based file line — the doc comment above the def is counted')
    eq(6, require('cartograph.pos').line(a.pos, 1))
    eq('target', a.cword)
    eq(a, store.source_cursor, 'and it is the store value')
    -- the same position again publishes nothing (deduped)
    local _, n = settle(row, 11)
    eq(0, n, 'an unchanged address fires nothing')
    -- a header row: the node, no line
    local h = settle(1, 0)
    eq(id, h.node); eq(nil, h.pos)

    unsub()
    vim.cmd('tabclose')
    vim.fn.delete(root, 'rf')
end)
