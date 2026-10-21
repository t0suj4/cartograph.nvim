-- cartograph.reshape — positional records to named fields, by provenance. Its refusals that are about WHERE an access
-- sits rather than what it does.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function tree(files)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        vim.fn.mkdir((root .. '/' .. rel):match('^(.*)/[^/]+$'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'wb')); fd:write(src); fd:close()
    end
    return root
end

-- (CART-1796: code loaded from a string LITERAL is tree code — the analysis follows the record into it — but the access
-- there sits inside a string, which no rewrite can edit: a FRONTIER, never an edit)
test('reshape: a position read in code loaded from a literal is a frontier, not an edit (CART-1796)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/pt.lua'] = 'local M = {}\nfunction M.pt(a, b) return { a, b } end\nreturn M\n',
        ['lua/use.lua'] = table.concat({
            'local P = require "pt"', 'local p = P.pt(1, 2)',
            'local get = load("return function (q) return q[1] end")()', 'return get(p)' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local plan, why, class = require('cartograph.reshape').plan(store, { family = { 'lua/pt.lua:2' }, positional = { '1=x', '2=y' } })
    vim.fn.delete(root, 'rf')
    eq(nil, plan, 'not planned')
    eq('frontier', class, 'a frontier: ' .. tostring(why))
    ok(tostring(why):find('loaded from a string literal', 1, true), 'naming the loaded code: ' .. tostring(why))
end)
