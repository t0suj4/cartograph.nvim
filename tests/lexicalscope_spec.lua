-- LEXICAL SCOPE for a same-file name (CART-1485): a name defined several times in one Lua file — nested `local
-- function walk` in many functions, as core.lua writes them — was refused `samefile` at every call. Each call has ONE
-- binding: the innermost definition whose enclosing function is on the call's chain, the latest one declared before
-- the call within a scope. Pinned: the recursive call and the outer call of two nested walks, a re-declaration, a
-- forward-declared local, and a name that is genuinely two file-level definitions (still refused).

local ts = require 'cartograph.providers.treesitter'

local SRC = table.concat({
    'local M = {}',
    'function M.a(t)',
    '  local function walk(x) if x > 0 then return walk(x - 1) end return 0 end',
    '  return walk(t)',
    'end',
    'function M.b(t)',
    '  local function walk(x) return x end',
    '  return walk(t)',
    'end',
    'function M.c(t)',
    '  local function pick(x) return 1 end',
    '  local function pick(x) return 2 end',
    '  return pick(t)',
    'end',
    'local build',
    'local function g() return build(1) end',
    'function build(x) return x end',
    'local function twice() return 1 end',
    'local function twice() return 2 end',
    'local function h() return twice() end',
    'local function walk(x) return -1 end',
    'function M.d(t) local function walk(x) return 9 end return walk(t) end',
    'function glob() return 1 end',
    'function M.e() return glob() end',
    'function glob() return 2 end',
    'return M', '' }, '\n')

local function calls_of(data, callee)
    local out = {}
    local cv = require('cartograph.callview').of(data) -- (calls are columnar: read through the view)
    for i = 1, cv.n do
        if cv.get(i, 'callee') == callee then
            local r = cv.get(i, 'refused')
            out[#out + 1] = { line = require('cartograph.at').sl(cv.get(i, 'at')) + 1, to = cv.get(i, 'to'), refused = type(r) == 'table' and r.rule or r }
        end
    end
    table.sort(out, function (x, y) return x.line < y.line end)
    return out
end

local function line_of(data, id)
    for _, n in ipairs(data.nodes) do if n.id == id then return require('cartograph.at').sl(n.range) + 1 end end
end

test('lexical scope: a nested local function\'s calls — its own recursion and its parent\'s — reach THAT definition, a re-declaration the later one, at file level too (CART-1485)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local walks = calls_of(data, 'walk')
    eq(4, #walks)
    eq(22, line_of(data, walks[4].to), 'the INNERMOST: M.d\'s own walk, not the file-level one')
    eq(3, line_of(data, walks[1].to), 'a\'s walk calling itself')
    eq(3, line_of(data, walks[2].to), 'a calling its walk')
    eq(7, line_of(data, walks[3].to), 'b calling ITS walk')
    eq(12, line_of(data, calls_of(data, 'pick')[1].to), 'the later of two declarations in one scope')
    eq(17, line_of(data, calls_of(data, 'build')[1].to), 'the forward-declared local')
    eq(19, line_of(data, calls_of(data, 'twice')[1].to), 'two FILE-LEVEL local functions: the later shadows')
    -- (two GLOBAL `function glob`: the call reaches whichever assignment ran last — a run-time order, not a scope —
    -- so it stays refused; "the latest before the call" would name the wrong one here)
    local g = calls_of(data, 'glob')[1]
    eq(nil, g.to); eq('samefile', g.refused)
end)

test('lexical scope: an INCREMENTAL refresh re-resolves the same way — the relink path has its own copy of the resolver (CART-1485)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    store.ingest(ts.extract(root))
    fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC:gsub('return 2 end', 'return 3 end')); fd:close()
    local stats = assert(require('cartograph.refresh').files({ 'm.lua' }, { incremental = true }))
    local data = store.data
    local walks = calls_of(data, 'walk')
    vim.fn.delete(root, 'rf')
    eq(4, #walks)
    eq({ 3, 3, 7, 22 }, { line_of(data, walks[1].to), line_of(data, walks[2].to), line_of(data, walks[3].to), line_of(data, walks[4].to) }, vim.inspect(stats))
    eq(12, line_of(data, calls_of(data, 'pick')[1].to))
end)