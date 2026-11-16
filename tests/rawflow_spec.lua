-- CART-2105: the matrix's `fold` oracle round-trips RAW flow rows through flow.fold, and since flow is folded at
-- PRODUCTION (P3, 7b389039) no extracted graph held any — the column declined on every corpus and checked nothing
-- (found by CART-1927's liveness collector). opts.raw_flow skips ONLY the production fold, so the oracle re-extracts a
-- sample raw. Measured after re-arming: fold spoke on jquery / nio / libs (304..507 fns sampled), and a fold that drops
-- `pol` fails 124 of 304 sampled jquery functions.

local ts   = require 'cartograph.providers.treesitter'
local flow = require 'cartograph.flow'

local SRC = 'local M = {}\nfunction M.f(a)\n  if a then return 1 end\n  local b = a + 1\n  return b\nend\nreturn M\n'

test('raw_flow: an extraction with opts.raw_flow keeps the RAW flow rows; the production fold is the default (CART-2105)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    local folded = ts.extract(root, { cold = true })
    local raw = ts.extract(root, { cold = true, raw_flow = true })
    vim.fn.delete(root, 'rf')
    local function fnode(d) for _, n in ipairs(d.nodes) do if n.name == 'M.f' then return n end end end
    ok(folded._flowcol ~= nil and fnode(folded).flow == nil, 'production: folded, no raw rows')
    eq(nil, raw._flowcol, 'raw_flow: not folded')
    local rn = fnode(raw)
    ok(rn.flow and rn.flow.stmts and #rn.flow.stmts > 0, 'raw rows are there to round-trip')
    -- and the round trip the oracle runs holds on them: the same rows read back through the fold
    local before = vim.inspect(flow.record(rn).stmts)
    flow.fold(raw)
    eq(before, vim.inspect(flow.record(rn).stmts))
    eq(0, flow.fold(raw), 'a second fold no-ops')
end)
