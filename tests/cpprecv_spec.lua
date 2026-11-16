-- CART-2111: C++ had no route to its own declared types (CART-0694) — luanti/src resolved 15,196 of 37,302 calls, all
-- by name. The C-family scope model's binders now carry their declared CLASS (`ty`, tsutil.c_decl_type) and pointer
-- depth; cpp's recv_class records a call's receiver class as a SIDE fact (c.rcls) — a declared binder whose operator
-- fits its declarator, `this->`, or a bare call inside a member function — and the additive `recv` pass resolves a
-- still-unresolved call to `<class>::<callee>` when that key has exactly one definition. Measured, every resolved
-- target unchanged: luanti 15,196 -> 16,878 resolved (+1,682), 7kaa 13,970 -> 16,225 (+2,255); dav1d (C) unchanged.

local ts = require 'cartograph.providers.treesitter'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local FILES = {
    ['rng.h'] = 'class Rng {\npublic:\n  int range(int a, int b);\n  int next();\n};\nclass Other {\npublic:\n  int range(int a, int b);\n  int next();\n  int over(int a);\n  int over(double a);\n};\n',
    ['rng.cpp'] = '#include "rng.h"\nint Rng::range(int a, int b) { return next() + a + b; }\nint Rng::next() { return 4; }\n'
        .. 'int Other::range(int a, int b) { return a; }\nint Other::next() { return 5; }\nint Other::over(int a) { return 1; }\nint Other::over(double a) { return 2; }\n',
    ['use.cpp'] = table.concat({
        '#include "rng.h"',
        'template <typename Rng> int tmpl(Rng r) { return r.next(); }', -- 1: a template parameter named like the class
        'struct Ptr { Rng *operator->(); };',
        'int use(Rng *p, Rng &q, Other o, Ptr sp) {',
        '  int a = p->range(1, 2);', -- 4: pointer binder, ->
        '  int b = q.next();',       -- 5: reference binder, .
        '  int c = o.over(1);',      -- 6: an overload pair
        '  int d = sp->next();',     -- 7: operator-> on a class value
        '  int e = p.next();',       -- 8: `.` on a pointer
        '  return a + b + c + d + e;',
        '}', '' }, '\n'),
}
local function at(data, file, line)
    for _, c in ipairs(data.calls) do if c.file == file and c.line == line then return c end end
end

test('cpp recv: a declared binder whose operator fits, and an implicit this, resolve to the class\'s method (CART-2111)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local data = ts.extract(tree(FILES))
    local c4, c5, c1 = at(data, 'use.cpp', 4), at(data, 'use.cpp', 5), at(data, 'rng.cpp', 1)
    eq({ 'rng.cpp::Rng::range@1', 'recv', 'Rng', 'binder' }, { c4.to, c4.prov, c4.rcls, c4.qhow })
    eq({ 'rng.cpp::Rng::next@2', 'recv', 'binder' }, { c5.to, c5.prov, c5.qhow })
    eq({ 'rng.cpp::Rng::next@2', 'recv', 'self' }, { c1.to, c1.prov, c1.qhow }, 'next() inside Rng::range')
end)

test('cpp recv: a template parameter, operator-> on a value, `.` on a pointer and an overload pair key nothing (CART-2111)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local data = ts.extract(tree(FILES))
    for _, line in ipairs { 1, 7, 8 } do
        local c = at(data, 'use.cpp', line)
        eq({ nil, nil }, { c.to, c.rcls }, 'line ' .. line .. ': ' .. tostring(c.full))
    end
    local c6 = at(data, 'use.cpp', 6)
    eq('Other', c6.rcls); eq(nil, c6.to, 'two Other::over: the typed key does not choose')
end)

test('cpp recv: the class of `ns::Cls::m` is its INNERMOST scope; a resolved call is never re-targeted (CART-2111)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local data = ts.extract(tree({
        ['a.cpp'] = 'namespace ns { class Cls { public: int m(); int kick(); }; }\nint ns::Cls::m() { return kick(); }\nint ns::Cls::kick() { return 1; }\n',
    }))
    local c = at(data, 'a.cpp', 1)
    eq('Cls', c.rcls)
    ok(c.to and c.to:match('ns::Cls::kick@'), vim.inspect(c))
    eq('recv', c.prov)
end)
