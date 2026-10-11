-- HOIST-EMPTY (write, CART-1657): the general optimizer's first tree-wide pass — every `t or {}` built only to be READ
-- (a builtin that reads it, pairs / ipairs as a for iterator, `#`) reads one read-only empty table per file instead of
-- allocating a fresh one per call. Its hand-made first instance: flowtype's 40 fallbacks, 16 M of 27 M tables per solve
-- of lua/cartograph, ~8% faster (935e310). A file that would not compile with the constant is skipped by name.
local T = require('cartograph.tactic').T

local SRC = table.concat({
    "local M, SEP = {}, ','",
    'function M.f(t)',
    '  local n = 0',
    '  for _, x in ipairs(t or {}) do n = n + x end',
    '  local len = #(t or {})',
    '  local s = table.concat(t or {}, SEP)',
    '  local it = pairs(t or {})',
    '  local first = select(1, t or {})',
    '  local same = rawequal(t or {}, t)',
    '  local str = tostring(t or {})',
    '  return n, len, s, it, first, same, str',
    'end',
    'function M.g(t)',
    '  local ipairs = function (z) return function () end, z, 0 end',
    '  for _ in ipairs(t or {}) do end',
    'end',
    'return M', '' }, '\n')

return {
    name = 'hoist-empty',
    kind = 'write',
    tags = { 'code', 'optimize' },
    summary = 'the optimizer\'s empty-fallback pass: every `t or {}` built only to be READ (a builtin that reads it — effects.reads —, pairs / ipairs as a for iterator, `#`) reads one read-only empty table per file; files = the files (default every Lua file); a file that would not compile with the constant is skipped by name',
    params = { files = 'list?' },
    build = function (p) return T.step('hoist-empty', { files = p.files }) end,
    examples = {
        {
            name = 'the iterator, the length and table.concat read the constant; a named, selected, compared or locally rebound one stays',
            files = { ['m.lua'] = SRC },
            params = {},
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/m.lua'):read('a')
                local ok = s:find("local EMPTY_RO = {}; local M, SEP = {}, ','", 1, true) and s:find('ipairs(t or EMPTY_RO)', 1, true)
                    and s:find('#(t or EMPTY_RO)', 1, true) and s:find('table.concat(t or EMPTY_RO', 1, true)
                    and s:find('pairs(t or {})', 1, true) and s:find('select(1, t or {})', 1, true)
                    and s:find('rawequal(t or {}, t)', 1, true) and s:find('for _ in ipairs(t or {})', 1, true)
                    and s:find('tostring(t or {})', 1, true)
                return ok and true or false, s
            end },
        },
        {
            name = 'a CLOSED function (it reads no outer local) stays closed: its fallback is left — it may be lifted as code',
            files = { ['k.lua'] = 'local function kernel(t)\n  local n = 0\n  for _, x in ipairs(t or {}) do n = n + x end\n  return n\nend\nreturn kernel\n' },
            params = {},
            expect = { applied = 0, check = function (root)
                return io.open(root .. '/k.lua'):read('a'):find('EMPTY_RO', 1, true) == nil, 'untouched'
            end },
        },
        {
            name = 'nothing provably unnameable: nothing is written',
            files = { ['m.lua'] = 'local function f(t) local it = pairs(t or {}); return it end\nreturn f\n' },
            params = {},
            expect = { applied = 0, check = function (root)
                return io.open(root .. '/m.lua'):read('a'):find('EMPTY_RO', 1, true) == nil, 'untouched'
            end },
        },
    },
}
