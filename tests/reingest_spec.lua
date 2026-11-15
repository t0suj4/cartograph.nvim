-- CART-2102: an ingest of ANOTHER root left the previous graph's preview context and highlight in the store, and the
-- source pane's rendered node (source.cur / source.ctx) as an object of the old graph. Its packed range indexes the old
-- store, so the next source.attach -> context(nil) -> body_lines read past the new one and crashed (bytecol.lua:77).
-- Found when nav_spec ran before selection_spec in one worker.

local ts     = require 'cartograph.providers.treesitter'
local store  = require 'cartograph.store'
local source = require 'cartograph.panes.source'

local function root_with(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    local data = ts.extract(root); data.root = root
    return root, data
end
local function id_of(name)
    for _, n in ipairs(store.data.nodes) do if n.name == name then return n.id end end
end

test('re-ingest: another root drops the old context / highlight, and the source pane re-attaches without reading the old graph (CART-2102)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- root A: several functions, so its node columns are longer than B's
    local fa = { 'local M = {}' }
    for i = 1, 30 do fa[#fa + 1] = ('function M.f%d(x)\n  return x + %d\nend'):format(i, i) end
    fa[#fa + 1] = 'return M'
    local ra, da = root_with({ ['a.lua'] = table.concat(fa, '\n') .. '\n' })
    store.ingest(da)
    vim.cmd('tabnew')
    local w1 = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w1, source.create()); source.attach(w1)
    source.render(id_of('M.f30'))
    store.set_context({ node = id_of('M.f29') }); source.context({ node = id_of('M.f29') }) -- a preview is SHOWING
    store.set_highlight({ file = 'a.lua', ranges = { { start = { line = 1, char = 0 }, ['end'] = { line = 2, char = 0 } } } })
    ok(source.cur and source.ctx, 'the pane shows a node with a preview over it')
    vim.cmd('tabclose')

    -- root B: a different project, one function
    local rb, db = root_with({ ['b.lua'] = 'local M = {}\nfunction M.g(y)\n  return y\nend\nreturn M\n' })
    store.ingest(db)
    eq(nil, store.context, 'another project\'s preview context is dropped')
    eq(nil, store.highlight, 'and its highlight')
    vim.cmd('tabnew')
    local w2 = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w2, source.create())
    local okattach, err = pcall(source.attach, w2)
    ok(okattach, 'attach after another root does not read the old graph: ' .. tostring(err))
    eq(nil, source.cur, 'the old node is gone from this graph, so the pane holds none')
    eq(nil, source.ctx)
    vim.cmd('tabclose')
    vim.fn.delete(ra, 'rf'); vim.fn.delete(rb, 'rf')
end)

test('re-ingest: a refresh of the SAME root keeps the preview context and re-resolves the rendered node by id (CART-2102)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local r, d = root_with({ ['c.lua'] = 'local M = {}\nfunction M.h(z)\n  return z\nend\nreturn M\n' })
    store.ingest(d)
    vim.cmd('tabnew')
    local w = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w, source.create()); source.attach(w)
    local id = id_of('M.h')
    source.render(id)
    store.set_context({ node = id })
    local old = source.cur
    local d2 = ts.extract(r); d2.root = r
    store.ingest(d2) -- the same root again: a refresh
    eq(id, store.context and store.context.node, 'a refresh keeps the context: its id follows')
    eq(id, source.cursor_address(w) and source.cursor_address(w).node, 'the pane still answers for the node')
    ok(source.cur ~= old and source.cur == store.node(id), 'and now holds the NEW graph\'s record for it')
    vim.cmd('tabclose')
    vim.fn.delete(r, 'rf')
end)
