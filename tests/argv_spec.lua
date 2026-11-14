-- The argv fold: the dual-mode accessor reads raw entry tables and folded
-- columns IDENTICALLY, so consumers migrate with zero behavior change and
-- fold() can drop the raw tables safely. Parser-free (pure over a data
-- table shaped like extract's output).

local argv = require 'cartograph.argv'

local function mkdata()
    return {
        calls = {
            { callee = 'f', fn = 'a', args = { 'SELECT 1', '', '' },
              argv = {
                { k = 'lit', v = 'SELECT 1' },
                { k = 'local', name = 'handler', l = 3 },
                { k = 'concat', prefix = 'ns/' },
              } },
            { callee = 'g', fn = 'a', args = { '' },
              argv = { { k = 'expr' } } },
            { callee = 'h', fn = 'b', args = {}, argv = {} },
            { callee = 'k', fn = 'b', args = { 'x' }, -- args[i]==v for a lit
              argv = { { k = 'lit', v = 'x', kw = 'query' } } }, -- kwarg
        },
    }
end

local function snapshot(data) -- read every arg through the accessor
    local out = {}
    for ci, c in ipairs(data.calls) do
        local row = { n = argv.n(c) }
        for i = 1, argv.n(c) do
            local a = argv.at(c, i)
            row[i] = (a.k or '?') .. '|' .. (a.name or '') .. '|'
                .. (a.v or '') .. '|' .. (a.prefix or '') .. '|'
                .. (a.kw or '') .. '|str:' .. argv.str(c, i)
        end
        out[ci] = row
    end
    return out
end

test('argv: the accessor reads raw and folded IDENTICALLY', function ()
    local raw = mkdata()
    local before = snapshot(raw)          -- raw-backed reads
    local folded = mkdata()
    local n = argv.fold(folded)
    eq(5, n, 'total entries folded across calls')
    local after = snapshot(folded)        -- column-backed reads
    eq(before, after, 'dual-mode: folded reads == raw reads, field for field')
end)

test('argv: fold drops the fat tables, keeps the slice', function ()
    local data = mkdata()
    argv.fold(data)
    local c = data.calls[1]
    ok(c.argv == nil and c.args == nil, 'raw entry tables dropped')
    ok(c._av and c._avn == 3, 'call carries its column slice')
    eq('handler', argv.at(c, 2).name)
    eq('SELECT 1', argv.str(c, 1))
    eq('', argv.str(c, 2), 'non-literal str is empty, as args[] was')
    eq(0, argv.n(data.calls[3]), 'a no-arg call folds to an empty slice')
end)

test('argv: fold is idempotent (a second fold is a no-op)', function ()
    local data = mkdata()
    local n1 = argv.fold(data)
    local n2 = argv.fold(data) -- already folded: nothing to do
    eq(0, n2, 'no raw tables left to fold')
    eq(5, n1)
end)

-- (CART-0342: the receiver convention, PINNED — argv.lua's header and callrec.method's doc state it, and nothing else
-- held it: a Lua `:` call is desugared (argv[1] the receiver, method = true); every other form, and python /
-- javascript, is the syntactic list (method nil, never false); a `:` function's params begin with `self`)
test('argv: a Lua `:` call carries its receiver at position 1; a `.` call and python / javascript do not (CART-0342)', function ()
    local ts = require 'cartograph.providers.treesitter'
    local cr = require 'cartograph.callrec'
    local function have(l) return pcall(vim.treesitter.language.add, l) end
    if not have('lua') then skip('no lua parser') end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t) local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
    w('m.lua', 'local M = {}\nfunction M:req(a) return a end\nfunction M.f() M:req("x"); M.req(M, "y") end\nreturn M\n')
    local langs = { lua = true }
    if have('python') then w('p.py', 'class C:\n    def req(self, a): return a\n\ndef f(o):\n    o.req("x")\n'); langs.python = true end
    if have('javascript') then w('j.js', 'function f(o) { o.req("x"); }\n'); langs.js = true end
    local d = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, c in ipairs(d.calls) do by[c.file .. ' ' .. tostring(cr.full(c) or cr.callee(c))] = c end
    local colon, dot = by['m.lua M:req'], by['m.lua M.req']
    eq(2, argv.n(colon), 'M:req("x") is (receiver, "x")')
    eq('expr', argv.at(colon, 1).k, 'the receiver is argv[1]')
    eq('x', argv.at(colon, 2).v)
    eq(true, cr.method(colon), 'method is TRUE for a `:` call')
    eq(2, argv.n(dot), 'M.req(M, "y") is the written list')
    eq('local', argv.at(dot, 1).k, 'its first argument is written, an ordinary local')
    eq(nil, cr.method(dot), 'method is nil, not false, for a `.` call')
    eq('req', cr.callee(colon), 'callee is the last segment, not the expression as written')
    for _, n in ipairs(d.nodes) do
        if n.name == 'M:req' then eq({ 'self', 'a' }, n.params, 'a `:` function\'s params begin with self') end
    end
    if langs.python then
        local pc = by['p.py o.req']
        eq(1, argv.n(pc), 'python o.req("x") is the syntactic list, receiver excluded')
        eq(nil, cr.method(pc))
    end
    if langs.js then eq(1, argv.n(by['j.js o.req']), 'javascript likewise') end
end)
