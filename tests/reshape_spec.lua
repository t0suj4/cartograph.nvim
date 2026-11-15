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

-- CART-2095: a family entry is `file:LINE` (the outermost constructor starting there) or `file:LINE:COL`, 1-based bytes —
-- matched against flowtype's 0-based `tbl:` site labels through cartograph.pos. The COL form had no spec.
test('renamefield: file:LINE picks the outermost constructor, file:LINE:COL (1-based) the one starting there (CART-2095)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local line2 = 'function M.pt(a, b) return { o = { a }, p = { b } } end'
    local root = tree({
        ['lua/pt.lua'] = 'local M = {}\n' .. line2 .. '\nreturn M\n',
        ['lua/use.lua'] = 'local P = require "pt"\nlocal r = P.pt(1, 2)\nreturn r.o, r.p\n' })
    store.ingest(ts.extract(root))
    local rf = require 'cartograph.renamefield'
    local outer = assert(line2:find('{ o', 1, true))
    local inner = assert(line2:find('{ b', 1, true))
    local function site(spec)
        local fam, why = rf.family(store, { family = { spec } })
        ok(fam, spec .. ': ' .. tostring(why))
        return next(fam.fam)
    end
    eq('tbl:lua/pt.lua:1:' .. (outer - 1), site('lua/pt.lua:2'), 'the outermost')
    eq('tbl:lua/pt.lua:1:' .. (outer - 1), site('lua/pt.lua:2:' .. outer), 'COL names the outer one exactly')
    eq('tbl:lua/pt.lua:1:' .. (inner - 1), site('lua/pt.lua:2:' .. inner), 'COL names an inner one exactly')
    local none = rf.family(store, { family = { 'lua/pt.lua:2:' .. (inner - 1) } })
    eq(nil, none, 'one column off names no constructor')
    vim.fn.delete(root, 'rf')
end)
