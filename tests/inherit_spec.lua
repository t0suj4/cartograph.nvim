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

-- V2 CUT 2: a constructor NOT named `.new` (`.create`), returning the anonymous
-- `setmetatable({}, {__index = Widget})` form. Cut 1 (name) can't type it; cut 2
-- reads the constructor's return-class (Widget) → x:render resolves to Widget:render.
local RETCLASS_SRC = table.concat({
    'local Widget = {}',                                            -- 1
    'function Widget:render() return 1 end',                        -- 2
    'local Gadget = {}',                                            -- 3
    'function Gadget:render() return 2 end',                        -- 4  (render ambiguous)
    'function Widget.create() return setmetatable({}, {__index = Widget}) end', -- 5 NOT .new
    'local function use()',                                         -- 6
    '    local x = Widget.create()',                               -- 7  x : Widget (cut 2)
    '    return x:render()',                                        -- 8
    'end',                                                          -- 9
    'return { use = use }',                                         -- 10
}, '\n')

test('ctor cut2: return-class types the local for a non-.new constructor', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(RETCLASS_SRC)
    local widget_render
    for _, n in ipairs(data.nodes) do
        if n.name == 'Widget:render' then widget_render = n.id end
    end
    local call
    for _, c in ipairs(data.calls) do if c.full == 'x:render' then call = c end end
    ok(call, 'x:render call found')
    eq(widget_render, call.to)    -- x typed Widget via Widget.create's return-class
    ok(call.inferred, 'inferred (~)')
end)

-- V3: Widget:OnAcquire is FRAMEWORK-INVOKED (no in-corpus call site → V1 hedges).
-- Widget owns >=2 colon-methods (a genuine object), so self=Widget by contract;
-- self:shared() is inherited from Base — the chain walk finds Base:shared (the
-- naive lexical "owner has no such member" miss, fixed). shared is ambiguous.
local FW_SRC = table.concat({
    'local Base = {}',                                       -- 1
    'function Base:shared() return 1 end',                   -- 2
    'local Widget = {}',                                     -- 3
    'setmetatable(Widget, {__index = Base})',                -- 4  Widget extends Base
    'function Widget:OnAcquire() return self:shared() end',  -- 5  framework-invoked
    'function Widget:extra() return 2 end',                  -- 6  (Widget owns 2 methods)
    'local Deco = {}',                                       -- 7
    'function Deco:shared() return 9 end',                   -- 8  (shared ambiguous)
    'return { Widget = Widget }',                            -- 9
}, '\n')

test('framework self (V3): a framework-invoked method types self by contract, chain-walked', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(FW_SRC)
    local base_shared
    for _, n in ipairs(data.nodes) do
        if n.name == 'Base:shared' then base_shared = n.id end
    end
    local call
    for _, c in ipairs(data.calls) do if c.full == 'self:shared' then call = c end end
    ok(call, 'self:shared call found')
    eq(base_shared, call.to)      -- self=Widget (contract) → chain → Base:shared
    ok(call.inferred, 'inferred (~)')
end)

-- V3 GATE: a single-method owner is NOT treated as an object (too weak a signal) —
-- self:m() there stays hedged rather than lexically guessed.
local FW_WEAK_SRC = table.concat({
    'local T = {}',                                          -- 1
    'function T:only() return self:amb() end',               -- 2  T owns just ONE method
    'local A = {}',                                          -- 3
    'function A:amb() return 1 end',                         -- 4
    'local B = {}',                                          -- 5
    'function B:amb() return 2 end',                         -- 6  (amb ambiguous)
    'return { T = T }',                                      -- 7
}, '\n')

test('framework self (V3): a single-method owner is too weak — stays hedged', function ()
    if not ts_ready() then return skip 'no lua parser' end
    local data = extract_src(FW_WEAK_SRC)
    local call
    for _, c in ipairs(data.calls) do if c.full == 'self:amb' then call = c end end
    ok(call, 'self:amb call found')
    eq(nil, call.to)              -- T owns 1 method → not a genuine object → hedged
end)
