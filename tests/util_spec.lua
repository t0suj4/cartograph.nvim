-- cartograph.util: the small shared helpers extracted from byte-identical local
-- copies — defaults (brush/textplates opts merge) and file_reader (django/symfony
-- source readers).

local util = require 'cartograph.util'

test('util.defaults: opts override the base, base is not mutated', function ()
    local base = { a = 1, b = 2, c = 3 }
    local o = util.defaults(base, { b = 20, d = 40 })
    eq(1, o.a, 'untouched key kept')
    eq(20, o.b, 'opts win over base')
    eq(3, o.c, 'other base key kept')
    eq(40, o.d, 'opts-only key added')
    eq(2, base.b, 'the base table is not mutated')
    ok(o ~= base, 'a fresh table is returned')
end)

test('util.defaults: nil opts yields a shallow copy of the base', function ()
    local base = { a = 1, b = 2 }
    local o = util.defaults(base, nil)
    eq(1, o.a); eq(2, o.b)
    ok(o ~= base, 'still a fresh table')
end)

test('util.file_reader: reads root-relative lines and memoizes', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/f.txt', 'w')); fd:write('one\ntwo\nthree'); fd:close()
    local read = util.file_reader(root)
    local lines = read('f.txt')
    eq({ 'one', 'two', 'three' }, lines, 'split into plain lines')
    ok(read('f.txt') == lines, 'a second read returns the SAME cached table')
    vim.fn.delete(root, 'rf')
end)

test('util.file_reader: a missing file is false, and the false is cached', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local read = util.file_reader(root)
    eq(false, read('nope.txt'), 'unopenable file → false')
    eq(false, read('nope.txt'), 'still false (cached, not retried as nil)')
    vim.fn.delete(root, 'rf')
end)
