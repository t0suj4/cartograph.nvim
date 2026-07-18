-- resolve_self PROTOTYPE-OOP self-typing (v57, GAP-2). A `self:m` call inside a DOTTED-owner
-- genuine-object method (`Widget.prototype:Refresh`) resolves to that owner's own member
-- (`Widget.prototype:Clear`), not an unrelated same-named def the promiscuous tail-match picked.
-- The fix: type self to the FULL dotted owner + OVERRIDE a foreign promiscuous match (receiver-
-- type beats name-match, gated on the genuine-object contract). The NEGATIVES are the guarantee
-- the reverted attempt lacked: non-dotted self:member (measured 1104 already-correct) must stay
-- untouched, and the >=2-colon-method gate must hold. [[cartograph-linker]] / [[graph-vm-type-resolution]].

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

-- POSITIVE: the prototype-OOP idiom. self:Clear inside Widget.prototype:Refresh resolves to
-- Widget.prototype:Clear — NOT the unrelated Other:Clear the tail-match would pick.
test('proto-oop: self:m in X.prototype:method resolves to X.prototype:m, not an unrelated same-named def', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local Widget = {}',
        'Widget.prototype = {}',
        'function Widget.prototype:Clear() return 1 end',              -- the RIGHT target
        'function Widget.prototype:Refresh() return self:Clear() end', -- self:Clear
        'function Widget.prototype:Extra() return 2 end',             -- >=2 methods → genuine object
        'local Other = {}',
        'function Other:Clear() return 9 end',                        -- the wrong pick to avoid
        'return { Widget = Widget }',
    }, '\n'))
    local c = call(data, 'self:Clear')
    ok(c, 'self:Clear call found')
    eq(node(data, 'Widget.prototype:Clear'), c.to)
    ok(c.to ~= node(data, 'Other:Clear'), 'did NOT resolve to the unrelated Other:Clear')
end)

-- SOUNDNESS: non-dotted genuine-object self:member is unchanged (this is the 1104-already-correct
-- population the reverted global-refuse regressed; the override must fire 0× here).
test('proto-oop: a plain (non-dotted) self:member still resolves to its own class member', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local Foo = {}',
        'function Foo:a() return 1 end',
        'function Foo:b() return 2 end',
        'function Foo:run() return self:a() end',   -- self:a → Foo:a
        'return Foo',
    }, '\n'))
    local c = call(data, 'self:a')
    ok(c, 'self:a call found')
    eq(node(data, 'Foo:a'), c.to)
end)

-- SOUNDNESS: the genuine-object gate holds — a dotted owner with only ONE colon-method is not
-- forced; self:m is not lexically resolved to that owner (no >=2 evidence self is really it).
test('proto-oop: a dotted owner with <2 colon-methods does not force a self: resolution', function ()
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(table.concat({
        'local W = {}',
        'W.proto = {}',
        'function W.proto:only() return self:gone() end',  -- owner W.proto has 1 colon-method
        'return W',
    }, '\n'))
    local c = call(data, 'self:gone')
    ok(c, 'self:gone call found')
    -- no `gone` def exists anywhere and the owner isn't a genuine object → left unresolved
    eq(nil, c.to)
end)
