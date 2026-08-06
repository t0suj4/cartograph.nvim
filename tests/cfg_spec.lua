-- CFG phase 1: structural guarded-region / dominance (cfg.guards_over).

local cfg = require 'cartograph.cfg'

local function ready_lang(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end
local function ready() return ready_lang('php') end

-- parse php, return (root, src)
local function parse(code)
    local src = '<?php\n' .. code
    local parser = vim.treesitter.get_string_parser(src, 'php')
    return parser:parse()[1]:root(), src
end

-- first node of `type` whose text contains `needle`
local function find(root, src, type_, needle)
    local hit
    local function rec(n)
        if hit then return end
        if n:type() == type_ then
            local t = vim.treesitter.get_node_text(n, src)
            if not needle or t:find(needle, 1, true) then hit = n; return end
        end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(root)
    return hit
end

local function guard_texts(node, src)
    local out = {}
    for _, g in ipairs(cfg.guards_over(node, src)) do
        out[#out + 1] = (g.neg and '!' or '') .. vim.treesitter.get_node_text(g.cond, src)
    end
    return out
end

test('cfg: positive nesting dominates; the else carries the NEGATION', function ()
    if not ready() then skip 'no php parser' end
    local root, src = parse(table.concat({
        'function f($x) {',
        '  if (valid($x)) {',
        '    sink_then($x);',      -- dominated by valid($x)
        '  } else {',
        '    sink_else($x);',      -- ¬valid($x) — NOT positively dominated
        '  }',
        '}',
    }, '\n'))
    local thenc = find(root, src, 'function_call_expression', 'sink_then')
    local elsec = find(root, src, 'function_call_expression', 'sink_else')
    eq(1, #guard_texts(thenc, src), 'then-branch has one dominating guard')
    ok(guard_texts(thenc, src)[1]:find('valid', 1, true))
    -- BEFORE CART-0257 this asserted 0: the else path was correctly excluded from
    -- POSITIVE domination and then nothing was said about it at all, so four
    -- consumers read `if (!p) {} else { use(p) }` as knowing nothing about p.
    local gs = guard_texts(elsec, src)
    eq(1, #gs, 'the else branch is dominated by exactly one fact')
    ok(gs[1]:sub(1, 1) == '!' and gs[1]:find('valid', 1, true),
        'and it is the NEGATED condition, not the positive one: ' .. gs[1])
end)

-- The chain, per grammar family. LUA/PYTHON are FLAT (the clauses are sibling
-- `alternative`s of one if_statement) and C/PHP are NESTED (`alternative` is a
-- single else the next if lives inside) — the same walk has to produce the same
-- conjunction from both shapes, which is the whole reason this is table-driven.
local CHAIN = {
    { 'lua', 'if x then A() elseif y then B() elseif z then C() else D() end' },
    { 'python', 'if x:\n  A()\nelif y:\n  B()\nelif z:\n  C()\nelse:\n  D()\n' },
    { 'c', 'void f(){ if (x) A(); else if (y) B(); else if (z) C(); else D(); }' },
}
-- guards as a normalized SET of `!?name` (paren/whitespace stripped), so one
-- expectation covers grammars that wrap the condition differently
local function guard_set(node, src)
    local out = {}
    for _, g in ipairs(cfg.guards_over(node, src)) do
        local t = vim.treesitter.get_node_text(g.cond, src):gsub('[%s()]', '')
        out[(g.neg and '!' or '') .. t] = true
    end
    return out
end
local function fmt(set)
    local ks = {}
    for k in pairs(set) do ks[#ks + 1] = k end
    table.sort(ks)
    return table.concat(ks, ' ')
end

for _, case in ipairs(CHAIN) do
    local lang, code = case[1], case[2]
    test('cfg: elseif chain — every earlier condition is negated (' .. lang .. ')', function ()
        if not ready_lang(lang) then skip('no ' .. lang .. ' parser') end
        local root = vim.treesitter.get_string_parser(code, lang):parse()[1]:root()
        local calltype = lang == 'lua' and 'function_call' or (lang == 'python' and 'call' or 'call_expression')
        local want = {
            ['A('] = { x = true },
            ['B('] = { y = true, ['!x'] = true },
            ['C('] = { z = true, ['!y'] = true, ['!x'] = true },
            ['D('] = { ['!z'] = true, ['!y'] = true, ['!x'] = true },
        }
        for needle, expect in pairs(want) do
            local n = assert(find(root, code, calltype, needle), 'no node for ' .. needle)
            eq(fmt(expect), fmt(guard_set(n, code)), needle .. ' in ' .. lang)
        end
    end)
end

test('cfg: python elif was UNSOUND, not merely imprecise', function ()
    if not ready_lang('python') then skip 'no python parser' end
    -- `elif_clause` was in neither the COND nor the ELSE table, so from the
    -- SECOND elif the walk reached the if_statement with a child that was
    -- neither `alternative`[1] nor a known else type — and positive_guard
    -- returned the if's condition. A consumer was told `x` HOLDS in `elif z`,
    -- which is exactly backwards. The first elif never showed it (it IS
    -- `alternative`[1], so the `same(child, alt)` arm caught it) — which is why
    -- a one-elif fixture would have passed and called the model sound.
    local src = 'if x:\n  A()\nelif z:\n  C()\n'
    local root = vim.treesitter.get_string_parser(src, 'python'):parse()[1]:root()
    local c = assert(find(root, src, 'call', 'C('))
    for _, g in ipairs(cfg.guards_over(c, src)) do
        local t = vim.treesitter.get_node_text(g.cond, src)
        if t == 'x' then ok(g.neg, 'x must be NEGATED inside `elif z`, never positive') end
    end
    eq('!x z', fmt(guard_set(c, src)))
end)

test('cfg: early-exit guard-clause post-dominates; non-terminating does not', function ()
    if not ready() then skip 'no php parser' end
    local root, src = parse(table.concat({
        'function f($x) {',
        '  if (bad($x)) { return; }',   -- terminating clause ⇒ ¬bad dominates after
        '  if (peek($x)) { log($x); }', -- NOT terminating ⇒ no post-dominance
        '  sink($x);',
        '}',
    }, '\n'))
    local sink = find(root, src, 'function_call_expression', 'sink(')
    local gs = guard_texts(sink, src)
    eq(1, #gs, 'only the terminating clause post-dominates the sink')
    ok(gs[1]:find('!', 1, true) and gs[1]:find('bad', 1, true), 'it is the negated early-exit guard')
end)

test('cfg: JS ternary condition dominates the consequence, not the alternative', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'javascript') then skip 'no javascript parser' end
    local src = 'function f(x) { const y = isValid(x) ? use(x) : bail(); }'
    local root = vim.treesitter.get_string_parser(src, 'javascript'):parse()[1]:root()
    local cons = find(root, src, 'call_expression', 'use(x)')
    local alt = find(root, src, 'call_expression', 'bail(')
    eq(1, #guard_texts(cons, src), 'the ternary consequence is dominated by the condition')
    ok(guard_texts(cons, src)[1]:find('isValid', 1, true), 'guard is the ternary condition')
    eq(0, #guard_texts(alt, src), 'the ternary alternative is NOT dominated')
end)

test('cfg: python ternary (positional, no condition field) dominates consequence', function ()
    if not ready_lang('python') then skip 'no python parser' end
    local src = 'y = use(x) if valid(x) else bail()'
    local root = vim.treesitter.get_string_parser(src, 'python'):parse()[1]:root()
    local cons = find(root, src, 'call', 'use(x)')
    local alt = find(root, src, 'call', 'bail(')
    eq(1, #guard_texts(cons, src), 'consequence dominated by the condition')
    ok(guard_texts(cons, src)[1]:find('valid', 1, true), 'guard is the condition')
    eq(0, #guard_texts(alt, src), 'the else value is NOT dominated')
end)

test('cfg: python comprehension if-clause guards the element body only', function ()
    if not ready_lang('python') then skip 'no python parser' end
    local src = 'r = [clean(x) for x in xs if pred(x)]'
    local root = vim.treesitter.get_string_parser(src, 'python'):parse()[1]:root()
    local body = find(root, src, 'call', 'clean(x)')
    local iter = find(root, src, 'identifier', 'xs')
    eq(1, #guard_texts(body, src), 'the element body is dominated by the if-clause')
    ok(guard_texts(body, src)[1]:find('pred', 1, true), 'guard is the if-clause filter')
    eq(0, #guard_texts(iter, src), 'the iterable is evaluated before the filter → not guarded')
end)

test('cfg: short-circuit && guards its right operand (positive), not the left', function ()
    if not ready_lang('javascript') then skip 'no javascript parser' end
    local src = 'function f(x) { const q = isOk(x) && use(x); const p = isOk(x); }'
    local root = vim.treesitter.get_string_parser(src, 'javascript'):parse()[1]:root()
    local rhs = find(root, src, 'call_expression', 'use(x)')
    local lhs = find(root, src, 'call_expression', 'isOk(x)')  -- the left operand
    local gs = guard_texts(rhs, src)
    eq(1, #gs, 'the right operand is guarded by the left')
    ok(gs[1] == 'isOk(x)', 'positive guard = the left operand (no negation)')
    eq(0, #guard_texts(lhs, src), 'the left operand is evaluated unconditionally')
end)

test('cfg: short-circuit || guards its right operand NEGATED', function ()
    if not ready_lang('javascript') then skip 'no javascript parser' end
    local src = 'function f(x) { const q = bad(x) || use(x); }'
    local root = vim.treesitter.get_string_parser(src, 'javascript'):parse()[1]:root()
    local rhs = find(root, src, 'call_expression', 'use(x)')
    local gs = guard_texts(rhs, src)
    eq(1, #gs, 'the right operand is guarded')
    ok(gs[1] == '!bad(x)', 'the || guard is NEGATED (right runs when left is falsy)')
end)

test('cfg: climbing stops at the function boundary', function ()
    if not ready() then skip 'no php parser' end
    local root, src = parse(table.concat({
        'if (outer()) {',
        '  function f($x) { sink($x); }',   -- outer guard must NOT leak in
        '}',
    }, '\n'))
    local sink = find(root, src, 'function_call_expression', 'sink(')
    eq(0, #guard_texts(sink, src), 'a guard around the fn definition does not dominate its body')
end)
