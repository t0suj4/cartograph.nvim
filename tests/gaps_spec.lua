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

-- (GAP 2 — PROTOTYPE-OOP self-typing — is FIXED as of v57: resolve_self types self to the
-- full dotted owner + overrides a foreign promiscuous self:member match. Its live regression
-- tests moved to proto_oop_spec.lua. Both surfaced gaps are now closed; this file keeps the
-- header as the pattern doc — add the next confident-wrong resolution here as a disabled spec.)
