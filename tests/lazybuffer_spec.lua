-- lazybuffer: an append-only buffer allocates its table on the SECOND piece — the rewrite is checked DIFFERENTIALLY:
-- each function runs before and after on the same inputs (none, one, many pieces; nil and number pieces; separators;
-- `b[1]` reads; the counter form), and every refused shape stays as it was
local LB = require 'cartograph.lazybuffer'

local SRC = table.concat({
    'local M = {}',
    'local concat, tinsert = table.concat, table.insert',
    -- the LENGTH form: #b + 1, table.insert, a separator, b[1]
    'function M.join(xs, sep)',
    '  local b = {}',
    '  for i = 1, #xs do b[#b + 1] = xs[i] end',
    '  local head = b[1]',
    '  return table.concat(b, sep), head',
    'end',
    'function M.ins(xs)',
    '  local b = {}',
    '  for _, x in ipairs(xs) do table.insert(b, x) end',
    '  tinsert(b, "!")',
    '  return concat(b)',
    'end',
    -- the COUNTER form (dkjson scanstring's shape)
    'function M.count(xs)',
    '  local b, n = {}, 0',
    '  for i = 1, #xs do',
    '    n = n + 1',
    '    b[n] = xs[i]',
    '  end',
    '  if n == 1 then return b[1], n elseif n > 1 then return concat(b), n end',
    '  return "", n',
    'end',
    -- a nil piece in the middle: a no-op in both
    'function M.holes(a, b2, c)',
    '  local b = {}',
    '  b[#b + 1] = a',
    '  b[#b + 1] = b2',
    '  b[#b + 1] = c',
    '  return concat(b, ","), b[1]',
    'end',
    -- REFUSED shapes: returned, measured, written at another key, shadowed, captured by a closure
    'function M.escapes() local b = {}; b[#b + 1] = "x"; return b end',
    'function M.len() local b = {}; b[#b + 1] = "x"; return #b end',
    'function M.key() local b = {}; b[#b + 1] = "x"; b[5] = "y"; return concat(b) end',
    'function M.shadow(xs) local b = {}; for _, b in ipairs(xs) do end; b[#b + 1] = "x"; return concat(b) end',
    'function M.closure() local b = {}; local f = function () b[#b + 1] = "x" end; f(); return concat(b) end',
    'return M', '' }, '\n')

local function load_src(s) return assert(loadstring(s))() end

test('lazybuffer: four sites rewritten, five shapes refused by name', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local sites, refusals = LB.sites(SRC, 'lua')
    local got = {}
    for _, s in ipairs(sites) do got[#got + 1] = s.form .. '@' .. (s.decl[1] + 1) end
    eq('length@4 length@10 counter@16 length@25', table.concat(got, ' '), 'the sites and their forms')
    local why = {}
    for _, r in ipairs(refusals) do why[#why + 1] = r.line .. ':' .. r.why end
    local w = table.concat(why, ' | ')
    -- (each refused shape, by its line and its reason: returned, measured, another key, shadowed, captured)
    for _, want in ipairs { '31:used otherwise (expression_list)', '32:used otherwise (unary_expression)', '33:a write at another key',
        '34:the name is bound again', '35:a nested function mentions it' } do
        ok(w:find(want, 1, true), want .. ' in ' .. w)
    end
end)

test('lazybuffer: DIFFERENTIAL — every rewritten function returns what the original returns, on none / one / many / nil / number pieces', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local sites = LB.sites(SRC, 'lua')
    local out = LB.apply(SRC, sites)
    ok(out ~= SRC and out:find('b_first', 1, true), 'rewritten')
    local A, B = load_src(SRC), load_src(out)
    local inputs = { {}, { 'a' }, { 'a', 'b' }, { 'a', 'b', 'c', 'd' }, { 1, 2.5, 'x' }, { 7 } }
    local bad = {}
    local function same(name, ...)
        local ra, rb = { pcall(A[name], ...) }, { pcall(B[name], ...) }
        if vim.inspect(ra) ~= vim.inspect(rb) then bad[#bad + 1] = name .. ' ' .. vim.inspect({ ... }) .. ': ' .. vim.inspect(ra) .. ' vs ' .. vim.inspect(rb) end
    end
    for _, xs in ipairs(inputs) do
        same('join', xs, nil); same('join', xs, '-'); same('ins', xs); same('count', xs)
    end
    same('holes', 'a', nil, 'c'); same('holes', nil, 'b', nil); same('holes', nil, nil, nil); same('holes', 1, 2, 3)
    eq('', table.concat(bad, '\n'), 'no function differs')
    -- the refused ones are untouched
    for _, name in ipairs { 'escapes', 'len', 'key', 'shadow', 'closure' } do
        ok(out:find('function M.' .. name .. '%(.-local b = {}'), name .. ' left as written')
    end
end)

test('lazybuffer: a rewrite of the rewrite finds nothing (idempotent)', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local once = LB.apply(SRC, (LB.sites(SRC, 'lua')))
    local again = LB.sites(once, 'lua')
    eq(0, #again, 'no site in the rewritten text')
end)
