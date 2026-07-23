-- build_symtab: the F2 light resolution index (federation step 3). Same exact/tail keying
-- as build_index, entries are compact stubs {id,kind,file,name}; torn/decl excluded; altkeys
-- included. The fields cross-band resolution reads, none of the analysis detail.

local ts = require 'cartograph.providers.treesitter'

local function nodes()
    return {
        { id = 'a', kind = 'function', file = 'x.lua', name = 'A.f', flow = { 1, 2, 3 }, df = { 4 } },
        { id = 'b', kind = 'method', file = 'y.lua', name = 'B.g', altkeys = { 'B#g' } },
        { id = 'c', kind = 'function', file = 'z.lua', name = 'h', torn = true },   -- torn: excluded
        { id = 'd', kind = 'function', file = 'w.lua', name = 'k', decl = true },   -- decl: excluded
        { id = 'e', kind = 'module', file = 'm.lua', name = 'M' },                  -- non-def: excluded
    }
end

test('build_symtab: exact keys mirror build_index for real defs', function ()
    local st = ts.build_symtab(nodes())
    eq('a', st.exact['A.f'][1].id)
    eq('b', st.exact['B.g'][1].id)
    eq(nil, st.exact['h'])   -- torn excluded
    eq(nil, st.exact['k'])   -- decl excluded
    eq(nil, st.exact['M'])   -- module excluded
end)

test('build_symtab: altkeys are indexed', function ()
    local st = ts.build_symtab(nodes())
    eq('b', st.exact['B#g'][1].id)
end)

test('build_symtab: tail index carries the last segment', function ()
    local st = ts.build_symtab(nodes())
    eq('a', st.tail['f'][1].id)
    eq('b', st.tail['g'][1].id)
end)

test('build_symtab: entries are STUBS — resolution fields only, no flow/df', function ()
    local st = ts.build_symtab(nodes())
    local stub = st.exact['A.f'][1]
    eq('a', stub.id); eq('function', stub.kind); eq('x.lua', stub.file); eq('A.f', stub.name)
    eq(nil, stub.flow) -- the heavy analysis payload is NOT carried
    eq(nil, stub.df)
end)
