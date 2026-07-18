-- resolve_reassign — REASSIGNMENT-OVERRIDE (value-flow resolution, v56). A table
-- slot `Owner.field` written by >=2 UNCONDITIONAL top-level defs resolves to the
-- LAST-in-load-order def (the runtime-effective one): the monkey-patch idiom
-- `function T:m … end; T.m = function … end`. SOUND-GATED on node.top — a branch-
-- selected slot has no load-order winner and must be left as name-matched. The
-- negative cases (conditional, nested-runtime-patch) are the soundness guarantee:
-- the measured-dominant real shape is `if X then function k:m … else … end` and a
-- false redirect there would be confidently WRONG. [[graph-vm-type-resolution]].

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
local function call(data, full)
    for _, c in ipairs(data.calls) do if c.full == full then return c end end
end

-- POSITIVE: the monkey-patch. `T.doit = function` @4 overrides `function T:doit` @2;
-- a deferred `T:doit()` calls the override. Resolves to the LAST def.
test('reassign: T:m() resolves to the LAST unconditional def (the override)', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local T = {}',
        'function T:doit() return 1 end',                 -- 2  original (method)
        'local Old = T.doit',
        'T.doit = function(self) return Old(self)+1 end', -- 4  OVERRIDE (function)
        'function T:run() return self.x end',
        'local function use() return T:doit() end',       -- T:doit → the override @4
        'return { use = use }',
    }, '\n'))
    local override = node(data, 'T.doit')
    local c = call(data, 'T:doit')
    ok(c, 'T:doit call found')
    eq(override, c.to)                     -- the @4 reassignment, NOT T:doit@2
    ok(c.inferred, 'the override redirect is marked inferred (~)')
end)

-- NEGATIVE (soundness): branch-selected defs (the DebugLib `if nLog then … else …`
-- shape). No load-order winner — the two defs are alternatives, not a sequence. The
-- call must NOT be redirected to the "last" (else-branch) def: it stays name-matched.
test('reassign: branch-selected slot is NOT redirected (no false last-write winner)', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local kit = {}',
        'if nLog then',
        '  function kit:Debug() return 1 end',            -- 3  then-arm
        'else',
        '  function kit:Debug() return 2 end',            -- 5  else-arm
        'end',
        'function kit:Other() return 3 end',
        'local function use() return kit:Debug() end',
        'return { use = use }',
    }, '\n'))
    -- both defs live in `if`/`else` blocks → node.top is false for each → the slot
    -- has no winner. (The two same-file defs are also honestly REFUSED as ambiguous
    -- by the name-match, so c.to is nil — either way, resolve_reassign never fires.)
    local elsearm                                          -- the higher-line def @4
    for _, n in ipairs(data.nodes) do
        if n.name == 'kit:Debug' then
            if not elsearm or n.id > elsearm then elsearm = n.id end
        end
    end
    local c = call(data, 'kit:Debug')
    ok(c, 'kit:Debug call found')
    ok(c.to ~= elsearm, 'NOT redirected to the else-arm (no false last-write winner)')
    ok(not c.inferred, 'branch-selected call is not marked as an override inference')
end)

-- NEGATIVE (soundness): a runtime patch INSIDE a function is not a load-order sibling
-- (only ONE top-level def exists). The call resolves to the top-level def, untouched.
test('reassign: a nested (runtime) reassignment does not override the top-level def', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local T = {}',
        'function T:doit() return 1 end',                 -- 2  the only top-level def
        'function T:reload() T.doit = function() return 2 end end', -- runtime patch
        'function T:run() return 3 end',
        'local function use() return T:doit() end',
        'return { use = use }',
    }, '\n'))
    local top = node(data, 'T:doit')
    local c = call(data, 'T:doit')
    ok(c, 'T:doit call found')
    eq(top, c.to)                          -- the top-level def, not the nested patch
end)
