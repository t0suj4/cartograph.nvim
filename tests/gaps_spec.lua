-- KNOWN CORRECTNESS GAPS — executable specs for confident-WRONG resolutions the
-- lua-ls disagreement harvest surfaced ([[cartograph-goal-vm-linker]]/[[cartograph-
-- linker]]). Each asserts the CORRECT (lua-ls-matching) behavior and currently FAILS,
-- so it's DISABLED with an early skip(). Enable (delete the skip line) when fixing the
-- gap — the assertion is the acceptance test. Do NOT delete these to "make them pass".

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

-- (GAP 1 — REASSIGNMENT-OVERRIDE — is FIXED as of v56: resolve_reassign redirects a
-- call to the last-in-load-order def of an unconditional top-level slot. Its live
-- regression tests moved to reassign_spec.lua. [[graph-vm-type-resolution]].)

-- GAP 2 — PROTOTYPE-OOP self-typing. self:m inside `X.prototype:method` should resolve
-- to `X.prototype:m` (the same prototype's member). resolve_self truncates the dotted
-- owner to `X`, can't type self, and the call falls to a promiscuous member-name match
-- → an unrelated same-named def. (Fixing needs full-owner extraction AND a complete
-- resolve_self that doesn't lean on the promiscuous tail-match — [[cartograph-linker]].)
local PROTO_SRC = table.concat({
    'local Widget = {}',                                          -- 1
    'Widget.prototype = {}',                                      -- 2
    'function Widget.prototype:Clear() return 1 end',             -- 3  the RIGHT target
    'function Widget.prototype:Refresh() return self:Clear() end',-- 4  self:Clear
    'function Widget.prototype:Extra() return 2 end',             -- 5  (>=2 methods → object)
    'local Other = {}',                                           -- 6
    'function Other:Clear() return 9 end',                        -- 7  (forces the wrong pick)
    'return { Widget = Widget }',                                 -- 8
}, '\n')

test('GAP prototype-OOP self:m resolves to the same prototype member, not an unrelated one', function ()
    skip 'known gap: resolve_self truncates dotted owners + relies on the promiscuous self:member tail-match'
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(PROTO_SRC)
    local right = node(data, 'Widget.prototype:Clear')
    local c = call(data, 'self:Clear')
    ok(c, 'self:Clear call found')
    eq(right, c.to)                                   -- Widget.prototype:Clear, NOT Other:Clear
end)
