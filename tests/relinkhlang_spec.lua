-- CART-2113: what `.h` means is the TREE's (CART-0410), carried on the graph as data.h_lang. store.ingest re-adopts it,
-- but a relink reached WITHOUT an ingest (cache.load then relink — a fresh process, a world overlay, the parity tools)
-- resolved under the process default `c`: every C++ header definition became a foreign candidate, and a refused
-- ambiguity collapsed onto the one candidate left in a .cpp. luanti/src relinked warm: 1,289 calls resolved that cold
-- extraction refuses (`f.next` on a Strfnd -> PcgRandom::next); after the fix, cold == warm row for row.

local ts = require 'cartograph.providers.treesitter'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end

test('relink: resolves under the graph\'s own `.h` language, and leaves the process answer as it found it (CART-2113)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local root = tree({
        ['a.h'] = 'class Alpha { public: int advance() { return 1; } };\n',
        ['b.h'] = 'class Beta { public: int advance() { return 2; } };\n',
        ['c.cpp'] = 'class Gamma { public: int advance(); };\nint Gamma::advance() { return 3; }\n',
        ['use.cpp'] = 'int use(Unknown *f) { return f->advance(); }\n',
    })
    local data = ts.extract(root); data.root = root
    eq('cpp', data.h_lang)
    local function call()
        for _, c in ipairs(data.calls) do if c.file == 'use.cpp' and c.callee == 'advance' then return c end end
    end
    local c = call()
    eq(nil, c.to, 'three classes define advance(): ' .. vim.inspect(c.to))
    eq('ambiguous', c.refused and c.refused.rule)
    ts.set_h_lang('c') -- a fresh process: the default, no ingest
    ts.relink(data)
    c = call()
    eq(nil, c.to, 'the header candidates are still C++ candidates: ' .. tostring(c.to))
    eq('c', ts.h_lang(), 'the process answer is restored after the relink')
    vim.fn.delete(root, 'rf')
end)
