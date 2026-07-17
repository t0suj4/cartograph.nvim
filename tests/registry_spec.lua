-- resolve_registry (the string-keyed registry linker, stage 3): LibStub("X")
-- resolves to the :NewLibrary-registered lib table. The class-owner fix: a
-- register line `local Lib, oldminor = LibStub:NewLibrary("X")` binds BOTH vars
-- at start.char 0, so the "leftmost var" tiebreak was a pairs()-order coin-flip —
-- the retrieve must resolve to the CLASS-owner (Lib, owns methods), not oldminor.

local function ts_ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
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
