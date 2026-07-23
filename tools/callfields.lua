-- callfields — measure the CALL record's field occupancy + LOSSLESS narrowing opportunity
-- ([[cartograph-thin-index]]). The call schema is ~40 fields but most are sparse. Some are
-- pure FUNCTIONS of other fields (derive-on-read, drop from storage, no data lost):
--   line   =?= at.start.line          (the occurrence range's start line)
--   file   =?= file_of(fn)            (enclosing fn id's `file::` prefix)
--   callee =?= full's last segment    (tail after the last . / : / ::)
-- Reports per-field presence (how many calls carry it) + whether each derivation holds for
-- EVERY call (a violation = not safely derivable). Post-resolution, PRE-fold (raw records).
--
--   nvim --headless -u NONE -l tools/callfields.lua [corpus]   (default: libs)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'

local name = arg[1] or 'libs'
local data = bench.extract_parallel(name)
local calls = data.calls or {}
if data._callstore then calls = require('cartograph.rescols').materialize(data._callstore) end
local N = #calls

-- per-field presence
local present = {}
for _, c in ipairs(calls) do
    for k in pairs(c) do present[k] = (present[k] or 0) + 1 end
end
local order = {}
for k in pairs(present) do order[#order + 1] = k end
table.sort(order, function (a, b) return present[a] > present[b] end)

-- derivability checks (does the pure-function derivation hold for EVERY call?)
local function file_of(id) return id and id:match('^(.-)::') or nil end
local function tail(full) return full and full:match('[^.:]+$') or nil end
local line_ok, line_n = 0, 0      -- c.line == c.at.start.line
local file_ok, file_n = 0, 0      -- c.file == file_of(c.fn)
local callee_ok, callee_n = 0, 0  -- c.callee == tail(c.full)
for _, c in ipairs(calls) do
    if c.at and type(c.at) == 'table' then
        line_n = line_n + 1
        if c.line == c.at.start.line then line_ok = line_ok + 1 end
    end
    if c.fn then
        file_n = file_n + 1
        if c.file == file_of(c.fn) then file_ok = file_ok + 1 end
    end
    if c.full and c.callee then
        callee_n = callee_n + 1
        if c.callee == tail(c.full) then callee_ok = callee_ok + 1 end
    end
end

print(('callfields %s — %d calls'):format(name, N))
print('  ── field presence (fraction of calls carrying it) ──')
for _, k in ipairs(order) do
    print(('    %-12s %7d  (%.0f%%)'):format(k, present[k], 100 * present[k] / N))
end
print('  ── LOSSLESS derivation checks (holds for ALL → safe to derive, drop from storage) ──')
print(('    line = at.start.line : %d/%d hold%s'):format(line_ok, line_n, line_ok == line_n and '  ✓ derivable' or '  ✗ NOT always'))
print(('    file = file_of(fn)   : %d/%d hold%s  (fn present on %d of %d)'):format(file_ok, file_n,
    file_ok == file_n and '  ✓ derivable' or '  ✗ NOT always', file_n, N))
print(('    callee = tail(full)  : %d/%d hold%s  (both present on %d of %d)'):format(callee_ok, callee_n,
    callee_ok == callee_n and '  ✓ derivable' or '  ✗ NOT always', callee_n, N))
vim.cmd('qall!')
