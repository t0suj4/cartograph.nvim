-- LAZY-BUFFER (write, CART-1663): the optimizer's buffer pass — every append-only buffer cartograph.lazybuffer proves (a
-- function-local `local b = {}` or `local b, n = {}, 0`, appended to by `b[#b + 1] = e` / table.insert / `n = n + 1;
-- b[n] = e`, read only by b[1] and a final table.concat) allocates its table on the SECOND piece; the first lives in a
-- local. Its hand-made first instance: dkjson's scanstring, a table per JSON string (1.31 M of 1.62 M tables of its
-- workload), -12% under LuaJIT and -9.5% under PUC Lua 5.1, the output equal. Refused buffers are counted, a file that
-- would not compile after the rewrite is skipped by name.
local T = require('cartograph.tactic').T

local SRC = table.concat({
    'local M = {}',
    'local concat = table.concat',
    'function M.join(xs, sep)',
    '  local b = {}',
    '  for i = 1, #xs do b[#b + 1] = xs[i] end',
    '  return concat(b, sep)',
    'end',
    'function M.scan(xs)',
    '  local buf, n = {}, 0',
    '  for i = 1, #xs do n = n + 1; buf[n] = xs[i] end',
    '  if n == 1 then return buf[1] end',
    '  return concat(buf)',
    'end',
    'function M.keep(xs) local b = {}; b[#b + 1] = xs[1]; return b end',
    'return M', '' }, '\n')

return {
    name = 'lazy-buffer',
    kind = 'write',
    tags = { 'code', 'optimize' },
    summary = 'the optimizer\'s buffer pass: every append-only buffer (a function-local `local b = {}` / `local b, n = {}, 0` appended to and read only by b[1] and a final table.concat) allocates its table on the SECOND piece, the first kept in a local; files = the files (default every Lua file); nodes = a SCOPE (ids or file::name — e.g. the functions alloc-census found hot): only the buffers inside them',
    params = { files = 'list?', nodes = 'list?' },
    build = function (p) return T.step('lazy-buffer', { files = p.files, nodes = p.nodes }) end,
    examples = {
        {
            name = 'the length form and the counter form are made lazy, an escaping buffer stays — and the module still answers the same',
            files = { ['m.lua'] = SRC },
            params = {},
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/m.lua'):read('a')
                local ok = s:find('local b, b_first', 1, true) and s:find('local buf, n, buf_first = nil, 0, nil', 1, true)
                    and s:find('return buf_first end', 1, true) and s:find('function M.keep(xs) local b = {}', 1, true)
                if not ok then return false, s end
                local A, B = assert(loadstring(SRC))(), assert(loadstring(s))()
                for _, xs in ipairs { {}, { 'a' }, { 'a', 'b', 'c' }, { 5 } } do
                    if A.join(xs, '-') ~= B.join(xs, '-') or A.scan(xs) ~= B.scan(xs) then return false, 'differs on ' .. vim.inspect(xs) end
                end
                return true
            end },
        },
        {
            name = 'a SCOPE narrows the pass: nodes = { m.lua::M.join } — M.scan\'s buffer stays',
            files = { ['m.lua'] = SRC },
            params = { nodes = { 'm.lua::M.join' } },
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/m.lua'):read('a')
                return s:find('local b, b_first', 1, true) ~= nil and s:find('local buf, n = {}, 0', 1, true) ~= nil, s
            end },
        },
        {
            name = 'no provable buffer: nothing is written',
            files = { ['m.lua'] = 'local function f(xs) local b = {}; b[#b + 1] = xs; return #b end\nreturn f\n' },
            params = {},
            expect = { applied = 0, check = function (root)
                return io.open(root .. '/m.lua'):read('a'):find('_first', 1, true) == nil, 'untouched'
            end },
        },
    },
}
