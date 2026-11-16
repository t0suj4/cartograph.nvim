-- CART-2117: refresh.splice replaced a refreshed file's nodes, edges and calls but never its RESOLVER INPUT rows
-- (cache.RESOLVER_INPUTS: extends, implements, fieldtypes, … per file), so an edit that added a base class or renamed
-- a field relinked against the OLD rows until a cold re-open.

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

test('refresh: a refreshed file\'s resolver-input rows are replaced, a deleted file\'s dropped (CART-2117)', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(p, t) local fd = assert(io.open(root .. '/' .. p, 'w')); fd:write(t); fd:close() end
    w('b.h', 'class Base { public: int one(); };\nclass D { public: int two(); Base *m_b; };\n')
    w('e.h', 'class Base;\nclass E : public Base { Base *m_e; };\n')
    w('b.cpp', '#include "b.h"\nint Base::one() { return 1; }\nint D::two() { return 2; }\n')
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local function rows()
        local ex, ft = {}, {}
        for _, e in ipairs(store.data.extends or {}) do ex[#ex + 1] = e.child .. '<' .. e.parent end
        for _, f in ipairs(store.data.fieldtypes or {}) do ft[#ft + 1] = f.typename .. '.' .. f.field end
        table.sort(ex); table.sort(ft)
        return { ex, ft }
    end
    eq({ { 'E<Base' }, { 'D.m_b', 'E.m_e' } }, rows())
    vim.uv.sleep(1100)
    w('b.h', 'class Base { public: int one(); };\nclass D : public Base { public: int two(); Base *m_c; };\n')
    require('cartograph.refresh').file('b.h')
    eq({ { 'D<Base', 'E<Base' }, { 'D.m_c', 'E.m_e' } }, rows(), 'the edit is in the rows')
    local stats = require('cartograph.refresh').splice(store.data, {}, { 'e.h' })
    ok(stats, 'a deletion splices')
    eq({ { 'D<Base' }, { 'D.m_c' } }, rows(), 'a deleted file leaves no rows')
    vim.fn.delete(root, 'rf')
end)
