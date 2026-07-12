-- V0: lua metatable inheritance. `setmetatable(X, {__index = P})` emits an
-- extends edge X->P; resolve_super then resolves an AMBIGUOUS inherited
-- `X:m()`/`X.m()` call to the ancestor that defines m.

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

-- Animal AND Plant both define `speak` → the tail is ambiguous, so `Dog:speak()`
-- refuses; the extends edge Dog->Animal disambiguates to Animal:speak.
local SRC = table.concat({
    'local Animal = {}',                       -- 1
    'function Animal:speak() return 1 end',    -- 2
    'local Plant = {}',                        -- 3
    'function Plant:speak() return 2 end',     -- 4  (forces `speak` ambiguity)
    'local Dog = {}',                          -- 5
    'setmetatable(Dog, {__index = Animal})',   -- 6  Dog extends Animal
    'function Dog:bark() return 3 end',        -- 7
    'local function use() Dog:speak() end',    -- 8  inherited, ambiguous tail
    'return { use = use }',                    -- 9
}, '\n')

test('inherit: setmetatable(__index) emits an extends edge', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(SRC)
    local found
    for _, e in ipairs(data.extends or {}) do
        if e.child == 'Dog' and e.parent == 'Animal' then found = true end
    end
    ok(found, 'Dog->Animal extends edge present')
end)

test('inherit: an ambiguous inherited X:m() resolves to the ancestor def', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(SRC)
    local animal_speak
    for _, n in ipairs(data.nodes) do
        if n.name == 'Animal:speak' then animal_speak = n.id end
    end
    ok(animal_speak, 'Animal:speak node exists')
    local call
    for _, c in ipairs(data.calls) do
        if c.full == 'Dog:speak' then call = c end
    end
    ok(call, 'Dog:speak call found')
    eq(animal_speak, call.to)          -- resolved to the inherited ancestor
    ok(call.inferred, 'marked inferred (~), a derived resolution')
end)
