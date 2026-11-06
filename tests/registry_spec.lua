-- resolve_registry (the string-keyed registry linker, stage 3): LibStub("X")
-- resolves to the :NewLibrary-registered lib table. The class-owner fix: a
-- register line `local Lib, oldminor = LibStub:NewLibrary("X")` binds BOTH vars
-- at start.char 0, so the "leftmost var" tiebreak was a pairs()-order coin-flip —
-- the retrieve must resolve to the CLASS-owner (Lib, owns methods), not oldminor.

local function ts_ready()
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

local function extract_src(src)
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(src); fd:close()
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    return data
end

-- Lib (owns a method) is the registered table; oldminor is the returned minor —
-- both bound on the same line at char 0. The retrieve must pick Lib.
local REG_SRC = table.concat({
    'local Lib, oldminor = LibStub:NewLibrary("L-1.0", 1)', -- 1
    'function Lib:M() return 1 end',                        -- 2  Lib owns a method
    'local function use()',                                 -- 3
    '  local r = LibStub("L-1.0")',                         -- 4  retrieve → Lib
    '  return r',                                           -- 5
    'end',                                                  -- 6
    'return { use = use }',                                 -- 7
}, '\n')

test('registry: LibStub("X") resolves to the class-owner, not the returned minor', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(REG_SRC)
    local lib_id, minor_id
    for _, n in ipairs(data.nodes) do
        if n.name == 'Lib' then lib_id = n.id
        elseif n.name == 'oldminor' then minor_id = n.id end
    end
    ok(lib_id, 'the Lib node exists')
    local call
    for _, c in ipairs(data.calls) do
        if c.callee == 'LibStub' and not c.method then call = c end
    end
    ok(call, 'the LibStub("L-1.0") retrieve call is found')
    eq(lib_id, call.registry)     -- the class-owner Lib, NOT oldminor
    ok(call.registry ~= minor_id, 'never the returned-minor var')
end)

-- (CART-0725: a DISCOVERED registry binding is a name/shape hypothesis. xlang.link cleared `inferred` and set `xlang`
-- on every edge any binding minted, so greenspun's guesses entered the graph as key-matched — and ladder counts xlang
-- as PROVEN. On our own lua/ that was 34 edges, every one wrong. The same binding DECLARED keeps the old standing)
test('xlang: a discovered binding mints inferred, xdisc edges — the same binding declared mints xlang (CART-0725)', function ()
    if not parser_available('lua') then return skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, t) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close() end
    -- (`fire` has no project def, so the import calls are unresolved until the binding links them)
    put('reg.lua', 'local M = {}\nlocal tbl = {}\nfunction M.hook(fn, key) tbl[key] = fn end\nreturn M\n')
    put('a.lua', table.concat({ "local R = require 'reg'",
        'local function on_alpha() return 1 end', 'local function on_beta() return 2 end',
        'local function on_gamma() return 3 end', 'local function setup()',
        "    R.hook(on_alpha, 'alpha')", "    R.hook(on_beta, 'beta')", "    R.hook(on_gamma, 'gamma')",
        'end', 'return setup', '' }, '\n'))
    put('b.lua', table.concat({ "local R = require 'reg'", 'local function go()',
        "    R.fire('alpha')", "    R.fire('beta')", "    R.fire('gamma')", 'end', 'return go', '' }, '\n'))
    local ts, xl = require 'cartograph.providers.treesitter', require 'cartograph.xlang'
    local function linked(declared)
        local data = ts.extract(root); data.root = root
        local found = require('cartograph.greenspun').registries(data)
        local b
        for _, x in ipairs(found) do if x.export.verb == 'hook' then b = x end end
        assert(b and b.discovered, 'greenspun discovers hook/fire (the fixture reaches the seam)')
        if declared then b = vim.tbl_extend('force', {}, b, { discovered = false }) end
        xl.link(data, { b })
        local out, calls = {}, {}
        for _, e in ipairs(data.edges) do
            if e.kind == 'ref' and e.from == 'b.lua::go@1' and e.to:match('^a%.lua::on_') then out[e.to] = e end
        end
        for _, c in ipairs(data.calls) do if c.full == 'R.fire' then calls[#calls + 1] = c end end
        return out, calls
    end
    local disc, dcalls = linked(false)
    eq(3, #dcalls)
    for _, c in ipairs(dcalls) do ok(c.to and c.inferred, 'the import call a discovered binding resolved is inferred') end
    eq(3, vim.tbl_count(disc))
    for to, e in pairs(disc) do
        ok(e.inferred and e.xdisc and not e.xlang, to .. ': discovered — inferred, xdisc, never xlang')
    end
    local decl, ccalls = linked(true)
    for _, c in ipairs(ccalls) do ok(c.to and not c.inferred, 'declared: the resolved call is not a hedge') end
    eq(3, vim.tbl_count(decl))
    for to, e in pairs(decl) do
        ok(e.xlang and not e.inferred and not e.xdisc, to .. ': declared — xlang, inferred cleared')
    end
    vim.fn.delete(root, 'rf')
end)
