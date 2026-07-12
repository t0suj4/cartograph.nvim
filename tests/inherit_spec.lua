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

-- V1: `self` typed by the call site. Animal:describe() is called with a literal
-- class receiver → self=Animal inside it → self:speak() resolves to Animal:speak
-- (NOT the ambiguous Plant:speak).
local SELF_SRC = table.concat({
    'local Animal = {}',                                  -- 1
    'function Animal:speak() return 1 end',               -- 2
    'function Animal:describe() return self:speak() end', -- 3  self:speak
    'local Plant = {}',                                   -- 4
    'function Plant:speak() return 2 end',                -- 5  (speak ambiguous)
    'local function use() return Animal:describe() end',  -- 6  literal-class seed
    'return { use = use }',                               -- 7
}, '\n')

test('self: self:m() resolves via the call-site-typed class, not the ambiguous tail', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(SELF_SRC)
    local animal_speak
    for _, n in ipairs(data.nodes) do
        if n.name == 'Animal:speak' then animal_speak = n.id end
    end
    local call
    for _, c in ipairs(data.calls) do if c.full == 'self:speak' then call = c end end
    ok(call, 'self:speak call found')
    eq(animal_speak, call.to)     -- self typed to Animal via Animal:describe() call site
    ok(call.inferred, 'inferred (~)')
end)

-- V1 SOUNDNESS: when self's type is undetermined (an untypeable call site poisons
-- the method), self:member is LEFT UNRESOLVED — never guessed to the lexical owner.
local HEDGE_SRC = table.concat({
    'local A = {}',                              -- 1
    'function A:foo() return self:amb() end',    -- 2  self:amb
    'function A:amb() return 1 end',             -- 3
    'local B = {}',                              -- 4
    'function B:amb() return 2 end',             -- 5  (amb ambiguous)
    'local function use(x) return x:foo() end',  -- 6  untypeable receiver → poisons A:foo
    'return { use = use }',                      -- 7
}, '\n')

test('self: an untypeable call site hedges — self:m() stays unresolved, no lexical guess', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(HEDGE_SRC)
    local call
    for _, c in ipairs(data.calls) do if c.full == 'self:amb' then call = c end end
    ok(call, 'self:amb call found')
    eq(nil, call.to)              -- A:foo poisoned by x:foo() → self hedged, NOT A:amb
end)

-- V2: `local d = Dog.new()` types d as Dog → d:speak() resolves through Dog's
-- extends chain to Animal:speak (ambiguous tail; V2+V0 disambiguate).
local CTOR_SRC = table.concat({
    'local Animal = {}',                                  -- 1
    'function Animal:speak() return 1 end',               -- 2
    'local Dog = {}',                                     -- 3
    'setmetatable(Dog, {__index = Animal})',              -- 4  Dog extends Animal
    'function Dog.new() return setmetatable({}, Dog) end', -- 5 constructor
    'local Plant = {}',                                   -- 6
    'function Plant:speak() return 2 end',                -- 7  (speak ambiguous)
    'local function use()',                               -- 8
    '    local d = Dog.new()',                            -- 9  d : Dog
    '    return d:speak()',                               -- 10 d:speak → Animal:speak
    'end',                                                -- 11
    'return { use = use }',                               -- 12
}, '\n')

test('ctor: local = C.new() types the local; obj:m() resolves through the chain', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(CTOR_SRC)
    local animal_speak
    for _, n in ipairs(data.nodes) do
        if n.name == 'Animal:speak' then animal_speak = n.id end
    end
    local call
    for _, c in ipairs(data.calls) do if c.full == 'd:speak' then call = c end end
    ok(call, 'd:speak call found')
    eq(animal_speak, call.to)     -- d typed Dog → chain → Animal:speak
    ok(call.inferred, 'inferred (~)')
end)

-- V2 SOUNDNESS: a local rebound to a different constructor (n>1) is dropped —
-- obj:m() stays unresolved rather than committing to a stale type.
local REBIND_SRC = table.concat({
    'local Dog = {}',                                     -- 1
    'function Dog:speak() return 1 end',                  -- 2
    'local Cat = {}',                                     -- 3
    'function Cat:speak() return 2 end',                  -- 4  (speak ambiguous)
    'function Dog.new() return setmetatable({}, Dog) end',-- 5
    'function Cat.new() return setmetatable({}, Cat) end',-- 6
    'local function use()',                               -- 7
    '    local d = Dog.new()',                            -- 8  bind 1
    '    d = Cat.new()',                                  -- 9  rebind → n>1, dropped
    '    return d:speak()',                               -- 10
    'end',                                                -- 11
    'return { use = use }',                               -- 12
}, '\n')

test('ctor: a rebound local is dropped — obj:m() stays unresolved, no stale type', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(REBIND_SRC)
    local call
    for _, c in ipairs(data.calls) do if c.full == 'd:speak' then call = c end end
    ok(call, 'd:speak call found')
    eq(nil, call.to)              -- d bound twice → not typed → ambiguous speak stays unresolved
end)
