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
