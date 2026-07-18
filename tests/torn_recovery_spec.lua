-- LUA PARSE-ERROR RESILIENCE (v58): a localized parse error must NOT torn every def after it.
-- Lua def names are self-contained (`function X:m` carries its qualifier — no enclosing block
-- to truncate), so torn is per-node (torn_by_node): only a def whose OWN subtree holds the error
-- is excluded from the call-target index. Regression guard for the Waterfall-1.0.lua case where
-- one invalid-escape string (`"[^\.]+"`) torned ~2000 downstream defs. [[cartograph-linker]].

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

-- An invalid-escape string (`"[^\.]+"`, the real Waterfall bug) makes tree-sitter-lua ERROR on
-- line 1. A CLEAN def far below it must still be indexed as a call target and resolve.
local SRC = table.concat({
    'local PAT = "[^\\.]+"',                            -- 1  invalid escape → parse ERROR
    'local Obj = {}',
    'function Obj:a() return 1 end',                    -- clean def AFTER the error
    'function Obj:b() return 2 end',                    -- (>=2 colon-methods → genuine object)
    'function Obj:run() return self:a() end',           -- self:a must resolve to Obj:a
    'return Obj',
}, '\n')

test('torn: a clean def after a localized parse error is still a resolvable call target', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(SRC)
    local defa = node(data, 'Obj:a')
    ok(defa, 'Obj:a is extracted AND indexed (not torned out by the line-1 error)')
    local c = call(data, 'self:a')
    ok(c, 'self:a call found')
    eq(defa, c.to)                                      -- resolves to Obj:a, not unresolved/foreign
end)

-- The def that ACTUALLY contains the error stays torn (its subtree is unreliable) — per-node,
-- not per-file. A clean sibling method still resolves.
test('torn: only the def whose own body holds the error is torned, not its clean siblings', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local M = {}',
        'function M:ok1() return 1 end',
        'function M:ok2() return 2 end',
        'function M:use() return self:ok1() end',       -- clean; must resolve
        'return M',
    }, '\n'))
    local c = call(data, 'self:ok1')
    ok(c, 'self:ok1 call found')
    eq(node(data, 'M:ok1'), c.to)
end)
