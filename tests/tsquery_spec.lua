-- tsquery: a tree-sitter query compiled to a per-node matcher must be the QUERY — the same (pattern, captures) rows
-- in the same order as query:iter_matches (CART-1659); a construct outside the subset is refused by name
local TQ = require 'cartograph.tsquery'

local function has(lang) return parser_available(lang) end

local function rng(n) if not n then return '-' end local a, b, c, d = n:range(); return ('%d:%d-%d:%d'):format(a, b, c, d) end
-- both sides' rows: pattern index and every capture's range, capture names sorted
local function rows(lang, qtext, src)
    local root = vim.treesitter.get_string_parser(src, lang):parse()[1]:root()
    local q = vim.treesitter.query.parse(lang, qtext)
    local function row(pat, caps)
        local ks = vim.tbl_keys(caps); table.sort(ks)
        local parts = { tostring(pat) }
        for _, k in ipairs(ks) do parts[#parts + 1] = k .. '=' .. rng(caps[k]) end
        return table.concat(parts, ' ')
    end
    local A = {}
    for pat, match in q:iter_matches(root, src, 0, -1) do
        local caps = {}
        for id, ns in pairs(match) do caps[q.captures[id]] = (type(ns) == 'table' and ns[1] ~= nil) and ns[#ns] or ns end
        A[#A + 1] = row(pat, caps)
    end
    local B = {}
    TQ.all(assert(TQ.compile(qtext)), root, function (pat, caps) B[#B + 1] = row(pat, caps) end)
    return A, B
end

test('tsquery: a construct outside the subset is REFUSED by name — never approximated', function ()
    for _, q in ipairs { '(call (identifier) @x (#eq? @x "a"))', '[(a) (b)] @x', '(call (identifier)* @x)', '(call "(" @p)', '(call !field)' } do
        local m, why = TQ.compile(q)
        eq(nil, m, q); ok(type(why) == 'string' and #why > 0, q)
    end
    local m, why = TQ.compile('(a . (b) . (c))')
    eq(nil, m); ok(tostring(why):find('anchor', 1, true), tostring(why))
end)

test('tsquery: lua calls — the extractor\'s own query, every row the query gives, in its order', function ()
    if not has('lua') then skip 'no lua parser' end
    local A, B = rows('lua', '(function_call name: (_) @name) @call', 'local x = f(g(1), h.i(2))(3)\nobj:m(k(4))\n')
    ok(#A >= 5, 'the fixture has calls: ' .. #A)
    eq(A, B)
end)

test('tsquery: ruby method chains — a match is yielded when it COMPLETES: `a.b(x).c do end` gives b before c', function ()
    if not has('ruby') then skip 'no ruby parser' end
    local q = '(call method: (identifier) @name) @call (call method: (constant) @name) @call'
    local A, B = rows('ruby', q, 'a.b(x).c do |y| y.d end\nFoo.Bar(1).baz\n')
    ok(#A >= 4, #A)
    eq(A, B)
end)

test('tsquery: an ANCHOR (scheme\'s first symbol), a two-level chain (zig), several kids (interpreted), a wildcard root', function ()
    if has('scheme') then
        local A, B = rows('scheme', '(list . (symbol) @name) @call', '(define (f x) (g (h x) 1))\n(1 2)\n')
        ok(#A >= 3, #A); eq(A, B)
    end
    if has('zig') then
        local A, B = rows('zig', '(call_expression function: (identifier) @name) @call (call_expression function: (field_expression member: (identifier) @name)) @call',
            'fn f() void { a(b.c(d(1))); }\n')
        ok(#A >= 3, #A); eq(A, B)
    end
    if has('lua') then
        -- (two child patterns: the interpreted path, ordered siblings)
        local A, B = rows('lua', '(function_call name: (identifier) @n arguments: (arguments) @a) @c', 'f(1)\ng.h(2)\nk(l(3))\n')
        ok(#A >= 3, #A); eq(A, B)
        -- (a wildcard root BEFORE a typed one: rows interleave by completion, not by which list holds the pattern)
        local A2, B2 = rows('lua', '(_ (identifier) @x) @w (function_call name: (identifier) @n) @c', 'f(a)\nlocal b = c\n')
        ok(#A2 >= 3, #A2); eq(A2, B2)
        -- (an anchor WITH a field: the first named child must BE that field's node — `a + b`'s first is `left`)
        local A3, B3 = rows('lua', '(binary_expression . right: (identifier) @r) @b (binary_expression . left: (identifier) @l) @b', 'local x = a + b\n')
        eq(1, #A3, 'only the left-anchored pattern: ' .. vim.inspect(A3)); eq(A3, B3)
    end
end)
