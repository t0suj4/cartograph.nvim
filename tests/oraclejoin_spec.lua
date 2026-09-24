-- CART-1044: a reader joined against an independent oracle, per input.
-- ★ ACCEPTANCE ON REAL CORPORA (tools/oraclejoin.lua): the yaml join reproduces 266/270 agree with
-- 4 refused by both; the xml join 5,428/5,514 agree with ONE cause of disagreement — and the xml
-- count rose by two because NUL-separated inputs finally joined the files whose names hold spaces.

local J = require 'cartograph.oraclejoin'

local function obj(...)
    local args, o, keys = { ... }, {}, {}
    for i = 1, #args, 2 do o[args[i]] = args[i + 1]; keys[#keys + 1] = args[i] end
    return { o = o, keys = keys }
end

test('oraclejoin: SIX outcomes, none dropped — agree, disagree, refused, rejected, both, unopenable', function ()
    local ours = { a = obj('k', '1'), b = obj('k', '1'), c = nil, d = obj('k', '1'), e = nil, f = J.UNOPENABLE }
    local theirs = { a = { value = obj('k', '1') }, b = { value = obj('k', '2') }, c = { value = obj('k', '1') },
        d = { error = 'bad' }, e = { error = 'bad' }, f = { value = obj('k', '1') } }
    local r = J.run {
        inputs = { 'a', 'b', 'c', 'd', 'e', 'f' },
        oracle_map = theirs,
        read = function(id) if id == 'c' or id == 'e' then return nil, 'we refuse ' .. id end return ours[id] end,
    }
    local c = r.counts
    eq(6, c.total); eq(1, c.agree); eq(1, c.disagree); eq(1, c.refused); eq(1, c.rejected); eq(1, c.both); eq(1, c.unopenable)
    eq('we refuse c', r.refusals[1].why)
    eq('bad', r.rejections[1].why)
end)

test('oraclejoin: ★★ disagreements GROUP BY CAUSE — one defect read 3 times is one group of 3', function ()
    local inputs, theirs = {}, {}
    for i = 1, 3 do inputs[i] = 'x' .. i; theirs['x' .. i] = { value = obj('name', 'n' .. i, 'ns', 'urn:a') } end
    inputs[4] = 'y'; theirs.y = { value = obj('name', 'y', 'ns', 'urn:a', 'extra', '1') }
    local r = J.run {
        inputs = inputs, oracle_map = theirs,
        -- the "reader" gets the namespace wrong everywhere, and drops `extra` once
        read = function(id)
            local t = theirs[id].value
            local o = obj('name', t.o.name, 'ns', '{urn:a}')
            return o
        end,
    }
    eq(4, r.counts.disagree)
    eq(2, #r.groups)
    eq(3, r.groups[1].n)                       -- the namespace defect, once, with three examples
    ok(r.groups[1].cause:find('value at $.ns', 1, true), r.groups[1].cause)
    ok(r.groups[2].cause:find('missing-key', 1, true), r.groups[2].cause)
end)

test('oraclejoin: the first STRUCTURAL difference names its kind — type, keys, length, value, order', function ()
    eq('type', J.first_difference('s', obj('k', '1')).kind)
    eq('missing-key', J.first_difference(obj(), obj('k', '1')).kind)
    eq('extra-key', J.first_difference(obj('k', '1'), obj()).kind)
    eq('length', J.first_difference({ a = { '1' } }, { a = { '1', '2' } }).kind)
    local v = J.first_difference(obj('k', 'a b'), obj('k', 'ab'))
    eq('value', v.kind); eq('whitespace', v.detail); eq('$.k', v.path)
    eq('order', J.first_difference(obj('a', '1', 'b', '2'), obj('b', '2', 'a', '1')).kind)
    eq(nil, J.first_difference(obj('a', '1'), obj('a', '1')))
end)

test('oraclejoin: ⚠ a join with NO agreement is flagged VACUOUS — suspect the harness first', function ()
    local r = J.run { inputs = { 'a' }, oracle_map = { a = { value = '1' } }, read = function() return '2' end }
    eq(true, r.vacuous)
    ok(J.lines(r)[1]:find('VACUOUS', 1, true), J.lines(r)[1])
end)

test('oraclejoin: a reader that RAISES is a refusal with the error, not a crashed join', function ()
    local r = J.run { inputs = { 'a', 'b' }, oracle_map = { a = { value = '1' }, b = { value = '1' } },
        read = function(id) if id == 'b' then error('boom') end return '1' end }
    eq(1, r.counts.agree); eq(1, r.counts.refused)
    ok(r.refusals[1].why:find('RAISED', 1, true), r.refusals[1].why)
end)

test('oraclejoin: ★ paths travel NUL-separated — a name with a space and a newline stays ONE input', function ()
    if vim.fn.executable('python3') ~= 1 then skip('no python3') end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local odd = dir .. '/a file\nname.txt'
    local fd = assert(io.open(odd, 'w')); fd:write('x'); fd:close()
    local script = dir .. '/echo.py'
    fd = assert(io.open(script, 'w'))
    fd:write('import json,sys\nout={}\nfor p in sys.stdin.read().split("\\0"):\n    if p: out[p]={"value": open(p).read()}\njson.dump(out, sys.stdout)\n')
    fd:close()
    local map = assert(J.external({ 'python3', script }, { odd }))
    eq('x', map[odd] and map[odd].value)
    -- and git's own list is NUL-separated too
    vim.fn.system({ 'git', '-C', dir, 'init', '-q' })
    vim.fn.system({ 'git', '-C', dir, 'add', 'a file\nname.txt' })
    local files = J.ls_files(dir)
    eq(1, #files)
    eq('a file\nname.txt', files[1])
    vim.fn.delete(dir, 'rf')
end)

test('oraclejoin: an oracle\'s `partial` caveat travels with its value (the Maven oracle marks models built without a BOM)', function ()
    if vim.fn.executable('python3') ~= 1 then skip('no python3') end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local script = dir .. '/p.py'
    local fd = assert(io.open(script, 'w'))
    fd:write('import json,sys\njson.dump({"a": {"value": "1", "partial": True}, "b": {"value": "1"}}, sys.stdout)\n')
    fd:close()
    local map = assert(J.external({ 'python3', script }, { 'a', 'b' }))
    eq(true, map.a.partial); eq(nil, map.b.partial); eq('1', map.a.value)
    vim.fn.delete(dir, 'rf')
end)

test('oraclejoin: ⚠ the default join compares maps UNORDERED (kv_ser sorts keys); `ordered = true` makes key order count', function ()
    local a = { o = { x = '1', y = '2' }, keys = { 'x', 'y' } }
    local b = { o = { x = '1', y = '2' }, keys = { 'y', 'x' } }
    eq(1, J.run { inputs = { 'i' }, oracle_map = { i = { value = b } }, read = function() return a end }.counts.agree)
    local r = J.run { inputs = { 'i' }, oracle_map = { i = { value = b } }, read = function() return a end, ordered = true }
    eq(1, r.counts.disagree)
    ok(r.groups[1].cause:find('order', 1, true), r.groups[1].cause)
end)
