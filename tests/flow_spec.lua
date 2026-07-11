-- flow.lua (df strangler, increment 1): the fine statement model — coarse
-- projection == df's top-level partition, plus nested rows with a control
-- parent (the region tree df collapses away).

local flow = require 'cartograph.flow'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'php')
end

local function parse_fn(code)
    local src = '<?php\n' .. code
    local root = vim.treesitter.get_string_parser(src, 'php'):parse()[1]:root()
    local fn
    local function rec(n)
        if fn then return end
        if n:type() == 'function_definition' or n:type() == 'method_declaration' then
            fn = n; return
        end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(root)
    return fn
end

test('flow: fine nesting with control-parent; coarse == top-level partition', function ()
    if not ready() then skip 'no php parser' end
    local fn = parse_fn(table.concat({
        'function f($x) {',
        '  $a = 1;',            -- top-level
        '  if ($x > 0) {',      -- top-level control
        '    $b = $a + $x;',    -- nested under the if
        '    return $b;',       -- nested under the if
        '  }',
        '  $c = 2;',            -- top-level
        '}',
    }, '\n'))
    ok(fn, 'found the function node')
    local f = flow.build(fn)

    -- coarse projection = the 3 top-level statements ($a, if, $c)
    eq(3, #flow.coarse(f), 'three top-level statements (df-coarse partition)')

    -- the fine model has MORE rows than df would (the nested $b/return)
    ok(#f.stmts >= 5, 'fine model emits the nested statements too')

    -- find the `if` row and a nested row; the nested row's parent IS the if
    local ifidx, nested
    for i, s in ipairs(f.stmts) do
        if s.kind == 'if_statement' then ifidx = i end
        if s.parent ~= 0 and s.kind == 'stmt' and not nested then nested = s end
    end
    ok(ifidx, 'the if is a control row')
    ok(nested and nested.parent == ifidx, 'a nested statement points at the if as its control parent')
    ok(nested.pol == 'body', 'nested statement is in the then/body region')
end)
