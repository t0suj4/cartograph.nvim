-- THE ORACLE df SEES THROUGH A STATEMENT WRAPPER (CART-1104). nvim 0.12's tree-sitter-go puts a `statement_list`
-- between a block and its statements. flow's region() flattens it (CART-1088); the independent df that dfparity
-- compares flow against (the legacy dfreg walk in collect_mentions) took "a body's direct named children ARE its
-- statements" literally and saw ONE statement per block — 5405 partition mismatches on the go corpus that were the
-- oracle's, not flow's.

test('dfparity: a go body parses into the same statement partition on both sides (statement_list is not a statement)', function ()
    if not parser_available('go') then skip 'no go parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.go', 'w'))
    fd:write('package m\n\nfunc f(a int) int {\n\tb := a + 1\n\tc := b * 2\n\tif c > 3 {\n\t\tc = 0\n\t}\n\treturn c\n}\n')
    fd:close()
    local data = ts.extract(root, { legacy_df = true, cold = true })
    vim.fn.delete(root, 'rf')
    local f
    for _, n in ipairs(data.nodes) do if n.name == 'f' then f = n end end
    local df = require 'cartograph.df'
    ok(f and df.present(f), 'the oracle df was built')
    eq(4, df.count(f), 'four statements, not one wrapper')
    local r = dofile('tools/dfparity.lua').check(data)
    local cats = r and (r.cats or r) or {}
    eq(nil, cats['partition-mismatch'], 'no partition mismatch')
    eq(nil, cats['unpaired'], 'no unpaired statement')
end)
