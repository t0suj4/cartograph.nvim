-- CART-2076: a mention whose innermost visible binding is a LOCAL or PARAMETER names that local — with or without an
-- outer binding of the name in its scope chain (CART-1010 / CART-2075 marked it only as a SHADOW of one). Without one,
-- the same-file / unique name match linked it to whatever var bore the name: java `IndexInput input` in
-- Int4VectorScorer.create -> the NESTED class ScorerImpl's field `input`. Measured, use edges removed / added:
-- elasticsearch libs 323 / 0, lua/cartograph 193 / 0, hugo 90 / 0, gforth's java 14 / 0, mantisbt 0 (php declares function_vars_reach_file); ruby, python,
-- c++, rust, js unchanged. Every sample read was false: a parameter -> a nested class's field, functions' own `c` / `x`
-- -> a `local c, x` inside a chunk-level for body, go's blank `_`. PHP keeps its links by declaration (spec.function_vars_reach_file).

local ts = require 'cartograph.providers.treesitter'

local function uses(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, t in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local out = {}
    for _, e in ipairs(data.edges) do if e.kind == 'use' then out[#out + 1] = e.from .. ' -> ' .. e.to .. ' ' .. #(e.at or {}) end end
    table.sort(out)
    return out
end

test('inner-bound: a java local / parameter never links to a NESTED class\'s same-named field; the field\'s own uses stay (CART-2076)', function ()
    if not parser_available('java') then skip 'no java parser' end
    eq({ 'V.java::Impl::Impl@10 -> V.java::var:input@9 1', 'V.java::Impl::score@11 -> V.java::var:input@9 1' }, uses({ ['V.java'] = table.concat({
        'package a;', 'public final class V {',
        '    public static Object create(Values values) {',
        '        Object input = values.getSlice();', '        if (input == null) { return null; }', '        return new Impl(input);', '    }',
        '    public Object delegateTo(Object input) { return input; }',
        '    static class Impl {', '        private final Object input;',
        '        Impl(Object input) { this.input = input; }',  -- the WRITE of the field stays, the parameter read does not
        '        int score() {', '            return input.hashCode();', '        }', '    }', '}', '' }, '\n') }))
end)

test('inner-bound: lua — a function\'s own local never links to a `local` declared inside a chunk-level loop body (CART-2076)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local u = uses({ ['m.lua'] = table.concat({
        'local M = {}',
        'for i = 0, 3 do local c, x = 0, i; M[i] = c + x end',
        'function M.f()', '  local c = 1', '  return c', 'end', 'return M', '' }, '\n') })
    for _, l in ipairs(u) do ok(not l:match('^m%.lua::M%.f.* %-> .*var:c'), 'M.f\'s own c is no loop-body local: ' .. l) end
end)

test('inner-bound: go\'s blank `_` links to no package variable; php, which declares function_vars_reach_file, keeps its link (CART-2076)', function ()
    if parser_available('go') then
        local u = uses({ ['m.go'] = 'package m\n\nvar _ = 1\n\nfunc f(xs []int) int {\n\tfor _, x := range xs {\n\t\treturn x\n\t}\n\treturn 0\n}\n' })
        for _, l in ipairs(u) do ok(not l:match('var:_'), 'the blank identifier is no package var\'s use: ' .. l) end
    end
    if parser_available('php') then
        -- php DECLARES the opposite (spec.function_vars_reach_file): an included file runs in its includer's function
        -- scope, so a bound function variable keeps its same-file link (CART-1010's rule as it was)
        local u = uses({ ['l.php'] = '<?php\n$g_active = "";\nfunction push($l) {\n  $g_active = $l;\n}\n' })
        ok(table.concat(u, '\n'):find('push@2 -> l.php::var:g_active', 1, true), 'php keeps its link: ' .. table.concat(u, '\n'))
    end
end)
