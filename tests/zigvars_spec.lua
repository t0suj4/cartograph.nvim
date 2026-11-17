-- CART-0538 / CART-0485: zig declared no `vars` query, so it minted ZERO var nodes and every var consumer (the write
-- axis, the atlas ladder, use edges) was empty for zig. A zig file IS a struct: its container-scope `var` / `const`
-- declarations are its state. The name is the identifier right after the `const` / `var` token (never the value
-- after `=`); a declaration with no `=` (`extern var x: T;`, `extern const x: T addrspace(.input);`) is @vdecl.
-- zig lib/std: 10,922 of the 10,928 column-0 declarations a regex finds (the 6 are files the grammar cannot parse),
-- 0 var nodes the regex does not find.

local ts = require 'cartograph.providers.treesitter'

local SRC = table.concat({
    'const std = @import("std");',                                      -- 0
    'var counter: u32 = 0;',                                            -- 1
    'const limit = other;',                                             -- 2 the value is an identifier: not a var
    'pub const Pub: u8 = 3;',                                           -- 3
    'extern var ext: c_int;',                                           -- 4 no value
    'pub extern const vid: u32 addrspace(.input);',                     -- 5 no value, addrspace after the type
    'threadlocal var tl: u8 = undefined;',                              -- 6 an anonymous-token value
    'const S = struct { a: u8, var inner: u8 = 0; };',                  -- 7 inner is S's, not the file's
    'pub fn f() u32 { var loc: u32 = 1; loc += 1; counter = loc; return counter + limit; }', -- 8 loc is f's
}, '\n') .. '\n'

test('zig vars: container-scope var / const are var nodes; a value, a struct member and a local are not (CART-0538)', function ()
    if not parser_available('zig') then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.zig', 'w')); fd:write(SRC); fd:close()
    local data = ts.extract(root)
    local vars, decl = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'var' then vars[#vars + 1] = n.name; decl[n.name] = n.decl end
    end
    table.sort(vars)
    eq({ 'Pub', 'S', 'counter', 'ext', 'limit', 'std', 'tl', 'vid' }, vars)
    eq(true, decl.ext, 'extern var: declared, not defined')
    eq(true, decl.vid, 'extern const with addrspace')
    eq(nil, decl.tl, '= undefined is a value')
    local used = {}
    for _, e in ipairs(data.edges) do if e.kind == 'use' and e.from == 'm.zig::f@8' then used[e.to] = true end end
    ok(used['m.zig::var:counter@1'] and used['m.zig::var:limit@2'], 'f uses the container state: ' .. vim.inspect(used))
    vim.fn.delete(root, 'rf')
end)
