-- CFG phase 1: structural guarded-region / dominance (cfg.guards_over).

local cfg = require 'cartograph.cfg'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'php')
end

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

test('cfg: positive nesting dominates; else and condition do not', function ()
    if not ready() then skip 'no php parser' end
    local root, src = parse(table.concat({
        'function f($x) {',
        '  if (valid($x)) {',
        '    sink_then($x);',      -- dominated by valid($x)
        '  } else {',
        '    sink_else($x);',      -- NOT dominated (else)
        '  }',
        '}',
    }, '\n'))
    local thenc = find(root, src, 'function_call_expression', 'sink_then')
    local elsec = find(root, src, 'function_call_expression', 'sink_else')
    eq(1, #guard_texts(thenc, src), 'then-branch has one dominating guard')
    ok(guard_texts(thenc, src)[1]:find('valid', 1, true))
    eq(0, #guard_texts(elsec, src), 'else-branch is not positively dominated')
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

local function ready_lang(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

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
