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
    local f
    for _, n in ipairs(data.nodes) do if n.name == 'f' then f = n end end
    local df = require 'cartograph.df'
    ok(f and df.present(f), 'the oracle df was built')
    eq(4, df.count(f), 'four statements, not one wrapper')
    -- (check() re-reads the file: the root is deleted AFTER it — deleted first, it compared nothing and every assertion
    -- below passed vacuously, found by CART-2099's mutation check)
    local r = dofile('tools/dfparity.lua').check(data)
    vim.fn.delete(root, 'rf')
    eq(1, r.nfn, 'the function was compared')
    local cats = r and (r.cats or r) or {}
    eq(nil, cats['partition-mismatch'], 'no partition mismatch')
    eq(nil, cats['unpaired'], 'no unpaired statement')
end)

-- CART-2100: flow made php's `list($p, $q) = …` / `[$x, $y] = …` a def-position wrapper (CART-1667) and the INDEPENDENT
-- builder was never told, so dfparity read every destructuring as both a df- and a flow-over-collect (mantisbt +4 / +4,
-- red at HEAD for a month). Bisected to 8781adcb; this pins the builder's half.
test('dfparity: php destructuring defines its names in the independent builder too — no divergence (CART-2100)', function ()
    if not parser_available('php') then skip 'no php parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.php', 'w'))
    fd:write('<?php\nfunction f($pair) {\n  list($p, $q) = $pair;\n  [$x, $y] = $pair;\n  return $p + $q + $x + $y;\n}\n')
    fd:close()
    local data = require('cartograph.providers.treesitter').extract(root, { legacy_df = true, cold = true })
    local r = dofile('tools/dfparity.lua').check(data) -- (before the delete: check() re-reads the file)
    vim.fn.delete(root, 'rf')
    eq(1, r.nfn, 'the function was compared')
    eq({}, r.cats or {}, 'the builder and flow agree on both destructuring forms')
end)
