-- cartograph.pos (CART-2086, the user-approved design): a position carries its base and unit, is made through a named
-- profile, and converts only through pos.to — which REFUSES (nil, reason) rather than guess.

local pos = require 'cartograph.pos'
local at  = require 'cartograph.at'

test('pos: GRAPH is at.BASE; a profile is required — there is no default base', function ()
    eq({ lb = at.BASE.line, cb = at.BASE.col, unit = at.BASE.unit }, pos.PROFILES.GRAPH)
    local p, why = pos.new(3, 4)
    eq(nil, p); eq('no-profile', why)
    local g = pos.new(3, 4, 'GRAPH')
    eq({ line = 3, col = 4, lb = 0, cb = 0, unit = 'byte' }, g)
end)

test('pos: the LINE converts between bases freely; a line-only position stays col-less', function ()
    local g = pos.new(9, nil, 'GRAPH')
    eq(10, pos.line(g, 1)); eq(9, pos.line(g, 0))
    local h = pos.to(g, 'HUMAN')
    eq({ line = 10, lb = 1 }, h)
    local c, why = pos.col(g, 'AGENT')
    eq(nil, c); eq('no-column', why)
end)

test('pos: a COLUMN in another unit needs the line text, and converts byte <-> character on a non-ASCII line', function ()
    local text = 'local é = f(x)' -- `é` is two bytes: the byte column of `f` is 12, its character column 11
    local g = pos.new(0, 12, 'GRAPH')
    local q, why = pos.to(g, 'AGENT')
    eq(nil, q); eq('needs-line-text', why)
    local a = pos.to(g, 'AGENT', text)
    eq({ line = 1, col = 12, lb = 1, cb = 1, unit = 'char' }, a, '1-based character 12 is the 11th 0-based char + 1')
    -- and back: an agent's 1-based character column is the stored byte column
    local back = pos.to(pos.new(1, 12, 'AGENT'), 'GRAPH', text)
    eq({ line = 0, col = 12, lb = 0, cb = 0, unit = 'byte' }, back)
    -- a same-unit change of base needs no text
    eq({ line = 1, col = 13, lb = 1, cb = 1, unit = 'byte' }, pos.to(g, 'QUICKFIX'))
end)

test('pos: refusals — mid-character, out-of-line, unknown base / unit, a surrogate half, an unknown LSP encoding', function ()
    local text = 'local é = 1'
    local _, why = pos.to(pos.new(0, 7, 'GRAPH'), 'AGENT', text) -- byte 7 is inside `é` (bytes 6-7)
    eq('mid-character', why)
    _, why = pos.to(pos.new(0, 99, 'GRAPH'), 'AGENT', text)
    eq('out-of-line', why)
    _, why = pos.to(pos.new(1, 99, 'AGENT'), 'GRAPH', text) -- a CHARACTER column past the line: refused, not clamped
    eq('out-of-line', why)
    _, why = pos.to({ line = 1, col = 2 }, 'GRAPH', text)
    eq('unknown-base', why)
    _, why = pos.to({ line = 1, col = 2, lb = 1, cb = 1 }, 'GRAPH', text)
    eq('unknown-unit', why)
    -- an astral character is TWO utf-16 units: index 1 is inside the pair
    local astral = 'a😀b'
    local u16 = pos.lsp('utf-16')
    _, why = pos.to(pos.new(0, 2, u16), 'GRAPH', astral)
    eq('mid-character', why)
    eq({ line = 0, col = 5, lb = 0, cb = 0, unit = 'byte' }, pos.to(pos.new(0, 3, u16), 'GRAPH', astral), '`b` is utf-16 unit 3, byte 5')
    local p, w = pos.lsp('latin-1')
    eq(nil, p); eq('unknown-encoding', w)
end)

test('pos: of_range reads a stored range as GRAPH', function ()
    local r = { start = { line = 4, char = 2 }, ['end'] = { line = 6, char = 3 } }
    eq({ line = 4, col = 2, lb = 0, cb = 0, unit = 'byte' }, pos.of_range(r))
    eq({ line = 6, col = 3, lb = 0, cb = 0, unit = 'byte' }, pos.of_range(r, 'end'))
end)

-- CART-2092: the LSP wire is not storage. A wire column is in the NEGOTIATED encoding (utf-16 unless agreed otherwise);
-- every crossing goes through pos.to_lsp / from_lsp / range_from_lsp — clangd had stored the wire column as a byte one.
test('pos: the LSP wire converts both ways in the negotiated encoding; a wire range becomes a stored BYTE range (CART-2092)', function ()
    local text = 'x = "é"; f(1)' -- `é`: 2 bytes, 1 utf-16 unit; `f` is byte 10, utf-16 9
    eq({ line = 3, character = 9 }, pos.to_lsp(3, 10, 'utf-16', text))
    eq({ line = 3, character = 10 }, pos.to_lsp(3, 10, 'utf-8', text), 'utf-8 IS bytes: no text needed')
    local l, b = pos.from_lsp({ line = 3, character = 9 }, 'utf-16', text)
    eq(3, l); eq(10, b)
    local r = pos.range_from_lsp({ start = { line = 3, character = 9 }, ['end'] = { line = 3, character = 13 } }, 'utf-16',
        function () return text end)
    eq({ start = { line = 3, char = 10 }, ['end'] = { line = 3, char = 14 } }, r)
    local none, why = pos.from_lsp({ line = 3, character = 9 }, 'utf-16', nil)
    eq(nil, none); eq('needs-line-text', why)
    eq('utf-16', pos.client_encoding({}), 'a client carrying no encoding is the LSP default')
    eq('utf-8', pos.client_encoding({ offset_encoding = 'utf-8' }))
end)

test('clangd: a wire range is STORED in bytes through the client\'s encoding, never copied (CART-2092)', function ()
    local clangd = require 'cartograph.providers.clangd'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.c', 'w')); fd:write('int z;\nchar *s = "é"; int y = g(1);\n'); fd:close()
    local rd = pos.line_reader(root, nil)
    local line = 'char *s = "é"; int y = g(1);'
    local gb = line:find('g%(') - 1                          -- 0-based BYTE column of g
    local gu = vim.str_utfindex(line, 'utf-16', gb, false)   -- its UTF-16 column
    local wire = { start = { line = 1, character = gu }, ['end'] = { line = 1, character = gu + 1 } }
    local stored = clangd._wire_at({ offset_encoding = 'utf-16' }, rd, 'a.c', wire)
    eq({ start = { line = 1, char = gb }, ['end'] = { line = 1, char = gb + 1 } }, stored, 'the byte column, not the wire one')
    eq(nil, clangd._wire_at({ offset_encoding = 'utf-16' }, rd, 'missing.c', wire), 'no line text: dropped, never stored wrong')
    vim.fn.delete(root, 'rf')
end)
