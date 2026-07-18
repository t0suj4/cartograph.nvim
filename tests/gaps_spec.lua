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

-- GAP 1 — REASSIGNMENT-OVERRIDE. `T.m = function…` reassigns (overrides) `function
-- T:m` at load time; at runtime T:m() calls the OVERRIDE (last-in-load-order wins,
-- the Skada:ReloadSettings monkey-patch). lua-ls resolves to the override; cartograph
-- resolves to the original colon-def (separator/first-def match, no load-order model).
local OVERRIDE_SRC = table.concat({
    'local T = {}',                                  -- 1
    'function T:doit() return 1 end',                -- 2  original
    'local Old = T.doit',                            -- 3  (the monkey-patch idiom)
    'T.doit = function(self) return Old(self)+1 end',-- 4  OVERRIDE — runtime-effective
    'function T:run() return self.x end',            -- 5  (T a genuine object)
    'local function use() return T:doit() end',      -- 6  T:doit → should be the override @4
    'return { use = use }',                          -- 7
}, '\n')

test('GAP reassignment-override: T:m() resolves to the LAST def (the override), not the original', function ()
    skip 'known gap: no load-order/last-write model — cartograph picks the colon-def, lua-ls the override'
    if not ready() then return skip 'no lua parser' end
    local data = extract_src(OVERRIDE_SRC)
    local override = node(data, 'T.doit')            -- the @4 reassignment
    local c = call(data, 'T:doit')
    ok(c, 'T:doit call found')
    eq(override, c.to)                                -- runtime-effective def, not T:doit@2
end)

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
