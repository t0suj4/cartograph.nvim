-- EDIT-IN (write, CART-1176): a span edit INSIDE ONE FUNCTION — the seam edit (a few lines added or changed inside a
-- long function) that was made by hand ~40 times on 2026-09-28. The GROUND edit verb, scoped to the function's own
-- source slice: the anchor must be unique inside THAT function (a snippet that also occurs in a sibling is fine, and
-- the sibling is not touched), idempotent by the same classification (pending / done / drifted), journaled, previewed
-- by default, parse-guarded. Text, so any language the graph has a range for.
-- ⚠ WHY NOT A RULE LEARNED BY EXAMPLE (measured 2026-09-28): a statement-SEQUENCE example is rooted at `chunk` while a
-- function body is a `block`, and a sequence pattern matches only a block made of EXACTLY those statements — a seam
-- line inserted between two statements of a long function can never match. Subsequence matching is not in the
-- algebra; the ground edit is the floor. (rewrite-by-example's own `within` still serves a rule whose region is a
-- whole node.)
local T = require('cartograph.tactic').T

local SRC = table.concat({
    'local M = {}',
    'function M.ingest(data)',
    '  local n = #data',
    '  local seen = {}',
    '  return n',
    'end',
    'function M.other(data)',
    '  local n = #data',
    '  local seen = {}',
    '  return n',
    'end',
    'return M', '' }, '\n')
local function ref_of(store, name)
    for _, n in ipairs(store.data.nodes) do if n.name == name then return store.ref_of(n.id) end end
end

return {
    name = 'edit-in',
    kind = 'write',
    summary = 'a span edit INSIDE one function: ref = the function (file::name), before = text unique inside it, after = its replacement; the sibling functions are never touched',
    params = { ref = 'ref', before = 'string', after = 'string' },
    build = function (p) return T.step('edit', { file = p.ref.file, before = p.before, after = p.after, within = p.ref }) end,
    examples = {
        {
            name = 'a SEAM line inserted inside one function; the identical text in its sibling is left alone',
            files = { ['m.lua'] = SRC },
            params = function (store) return { ref = ref_of(store, 'M.ingest'),
                before = '  local seen = {}\n', after = '  local seen = {}\n  if n == 0 then return 0 end\n' } end,
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/m.lua'):read('a')
                local _, guards = s:gsub('if n == 0 then return 0 end', '')
                return guards == 1 and s:find('function M.ingest%(data%)\n  local n = #data\n  local seen = {}\n  if n == 0') ~= nil, s
            end },
        },
        {
            name = 'text that exists only in a SIBLING is not inside this function: refused by name, nothing written',
            files = { ['m.lua'] = SRC:gsub('function M.other%(data%)\n  local n = #data', 'function M.other(data)\n  local n = #data + 1') },
            params = function (store) return { ref = ref_of(store, 'M.ingest'),
                before = 'local n = #data + 1', after = 'local n = #data + 2' } end,
            expect = { status = 'failed', applied = 0 },
        },
    },
}