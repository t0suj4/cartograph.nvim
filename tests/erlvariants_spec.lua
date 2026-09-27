-- cartograph.erlvariants (CART-1133): a same-file refusal whose candidates sit in mutually exclusive preprocessor
-- branches reaches the SET — each definition is the target in one build. Pinned both ways: -ifdef/-ifndef pairs and
-- an -else become variants; two same-named definitions with no exclusive branch stay a plain refusal.

local ts = require 'cartograph.providers.treesitter'

local function run(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.erl', 'w')); fd:write(src); fd:close()
    local data = ts.extract(root)
    local stats = require('cartograph.erlvariants').attach(data)
    vim.fn.delete(root, 'rf')
    return data, stats
end

local function targets(data, from)
    local out = {}
    for _, e in ipairs(data.edges) do if e.variant and e.from:match('::' .. from .. '@') then out[#out + 1] = e.to end end
    table.sort(out)
    return out
end

test('erlvariants: -ifdef/-ifndef of one macro, and an -else, give the call BOTH definitions', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    -- two functions per branch, as ejabberd writes them: same-named definitions ADJACENT would be merged into one
    -- node by merge_equations (a separate inaccuracy, noted on CART-1133), and there would be nothing to refuse
    local data, s = run(table.concat({
        '-module(m).',
        'f(X) -> z(X), w(X).',
        '-ifdef(OLD).', 'z(X) -> {old, X}.', 'y(X) -> X.', '-endif.',
        '-ifndef(OLD).', 'z(X) -> {new, X}.', 'y(X) -> X.', '-endif.',
        '-ifdef(FAST).', 'w(X) -> X.', 'v(X) -> X.', '-else.', 'w(X) -> {slow, X}.', 'v(X) -> X.', '-endif.',
    }, '\n') .. '\n')
    eq(2, s.variants)
    eq(4, #targets(data, 'f'), 'each of the two calls reaches its two definitions')
    for _, c in ipairs(data.calls) do if c.callee == 'z' then eq('variants', c.refused.rule); eq('OLD', c.refused.macro) end end
end)

test('erlvariants: two definitions NOT separated by an exclusive branch stay a plain samefile refusal', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local data, s = run(table.concat({
        '-module(m).',
        'f(X) -> z(X).',
        '-ifdef(A).', 'z(X) -> {a, X}.', 'y(X) -> X.', '-endif.',
        '-ifdef(B).', 'z(X) -> {b, X}.', 'y(X) -> X.', '-endif.',  -- A and B may both be defined: not exclusive
        '-ifdef(A).', 'z(X) -> {a2, X}.', 'y(X) -> X.', '-endif.', -- the SAME polarity of A: not exclusive either
    }, '\n') .. '\n')
    eq(0, s.variants)
    eq({}, targets(data, 'f'))
    for _, c in ipairs(data.calls) do if c.callee == 'z' then eq('samefile', c.refused.rule) end end
end)

test('erlvariants: the SAME polarity of one macro is not exclusive (both compile when A is defined)', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local data, s = run(table.concat({
        '-module(m).',
        'f(X) -> z(X).',
        '-ifdef(A).', 'z(X) -> {a, X}.', 'y(X) -> X.', '-endif.',
        '-ifdef(A).', 'z(X) -> {a2, X}.', 'y(X) -> X.', '-endif.',
    }, '\n') .. '\n')
    eq(0, s.variants)
    eq({}, targets(data, 'f'))
end)
