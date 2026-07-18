-- luals-known-wrong fixtures — cases where lua-ls is VERIFIED wrong and cartograph
-- resolves correctly. Each assertion is checked against GROUND TRUTH (the correct answer),
-- NOT against lua-ls — this is the inverse of the disagreement harvest, which treats lua-ls
-- as the oracle. Prior art / answer key: ~/git/luals-fuzz/LESSONS.md ([[luals-lessons-corpus]],
-- query `kb.py --issue N`). These double as (a) regression protection and (b) provenance for
-- the harvest triage rules (wraptriage's wrap-passthrough/nested-patch = the Lesson-1 family).
--
-- SCOPE (honest): only lessons cartograph can actually ADJUDICATE via its resolution surface
-- are here. Several verified lua-ls false positives are ones cartograph AVOIDS BY DECLINING the
-- unsound check, not by resolving better — those are NOT fixtures here:
--   * Lesson 1 need-check-nil lost on `n = n.next` (#bug1): cartograph has no null-deref lint.
--   * Lesson 3 undefined-global via `_G` alias (#2823): cartograph declines undefined-global on Lua.
--   * Lesson 3 missing-return on a user panic-helper (#bug2): cartograph has no missing-return.
-- Sound-first (declining unsound checks) is cartograph's mitigation for that whole column, but
-- "refuses to play" is not the same as "adjudicates correctly" — so we don't gate on it.

local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end
local function extract_src(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    local data = ts.extract(root); vim.fn.delete(root, 'rf'); return data
end
local function node(data, name)
    for _, n in ipairs(data.nodes) do if n.name == name then return n.id end end
end
local function call(data, name)
    for _, c in ipairs(data.calls) do if c.full == name or c.callee == name then return c end end
end

-- LESSON 5 (#2787): the metatable inheritance idiom `setmetatable(Parent.new(), Child)`.
-- lua-ls infers the result as `Parent|Child` (a union) instead of narrowing to Child, so a
-- Child-typed use false-positives param-type-mismatch. Ground truth: the object IS a Child
-- (its metatable is Child, whose __index chains to Parent) — so obj:cmethod dispatches to
-- Child's own method and obj:pmethod to Parent's inherited one. cartograph receiver-types obj
-- to Child and walks the extends chain — resolving BOTH correctly.
local META_SRC = table.concat({
    'local Parent = {}',
    'Parent.__index = Parent',
    'function Parent:pmethod() return 1 end',            -- inherited target
    'function Parent.new() return setmetatable({}, Parent) end',
    'local Child = setmetatable({}, {__index = Parent})',
    'Child.__index = Child',
    'function Child:cmethod() return 2 end',             -- own target
    'local obj = setmetatable(Parent.new(), Child)',     -- the #2787 idiom
    'obj:cmethod()',
    'obj:pmethod()',
    'return { obj = obj }',
}, '\n')

test('luals#2787: metatable inheritance resolves to Child (own) + Parent (inherited), not a Parent|Child muddle', function ()
    if not ready() then return skip 'no lua parser' end
    local d = extract_src(META_SRC)
    local cm, pm = call(d, 'obj:cmethod'), call(d, 'obj:pmethod')
    ok(cm and pm, 'both method calls found')
    eq(node(d, 'Child:cmethod'), cm.to)   -- own method
    eq(node(d, 'Parent:pmethod'), pm.to)  -- inherited via Child's __index chain
end)

-- LESSON 1 (value-flow family; measured on AtlasLootFu 12/12, not a single issue #): flow-
-- sensitivity that follows VALUE reassignment leads lua-ls to resolve a call to the reassigned
-- value's producer. For `compute = wrap(compute)` (wrap identity in prod / delegating otherwise),
-- lua-ls resolves a later `compute()` to the FACTORY `wrap`; cartograph keeps the original
-- delegating def, the correct/useful target. (The class wraptriage attributes to lua-ls — here
-- we assert the RESOLUTION cartograph gets right.)
local WRAP_SRC = table.concat({
    'local function wrap(v) return v end',
    'local function compute() return 41 end',            -- the real logic (ground truth)
    'compute = wrap(compute)',
    'local function use() return compute() end',
    'return use',
}, '\n')

test('luals value-flow: `x = wrap(x)` then call resolves to the original def, not the wrap factory', function ()
    if not ready() then return skip 'no lua parser' end
    local d = extract_src(WRAP_SRC)
    local c = call(d, 'compute')
    ok(c, 'the compute() call found')
    eq(node(d, 'compute'), c.to)          -- the original def, NOT wrap
end)

-- LESSON 1 (nested-runtime-patch, the Skada :ImportProfile family): a method reassigned
-- `T.m = function` INSIDE another method body is a runtime monkey-patch, not the load-time
-- binding. lua-ls follows the reassignment to the nested def; cartograph keeps the top-level
-- original where a call actually dispatches at load time. Ground truth: the top-level def.
local NESTED_SRC = table.concat({
    'local T = {}',
    'function T:doit() return 1 end',                    -- top-level = the binding (ground truth)
    'function T:reload() T.doit = function() return 2 end end', -- runtime patch (nested)
    'function T:extra() return 3 end',
    'local function use() return T:doit() end',
    'return use',
}, '\n')

test('luals-nested-patch: a call resolves to the top-level def, not a reassignment nested in a method', function ()
    if not ready() then return skip 'no lua parser' end
    local d = extract_src(NESTED_SRC)
    local c = call(d, 'T:doit')
    ok(c, 'the T:doit call found')
    eq(node(d, 'T:doit'), c.to)           -- top-level method, NOT the nested T.doit patch
end)
