-- ONE COMPUTATION PER SUBJECT in an extraction: a per-function / per-scope fact asked by several passes is computed
-- once. Each was measured recomputed (CART-1659): every scope harvested by both the mention walk and the scope model,
-- derived_locals 2.4 walks per function (one entry point skipped the memo). A broken memo returns IDENTICAL graphs,
-- so only a counter can catch it.
local ts = require 'cartograph.providers.treesitter'

local SRC = table.concat({
    'local M = {}',
    'local function helper(opt, t)',
    '  for _, spec in pairs(opt) do local v = spec[2]; v.k = 1 end',
    '  if t then do local inner = t; inner.x = 1 end end',
    '  return function (a) local b = a; b.y = opt; return helper(b, a) end',
    'end',
    'function M.run(cfg, x) if cfg then cfg.n = 1 end; helper(cfg, x); return M end',
    'return M',
}, '\n')

local function extract_counting(wrapfn)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    local undo = wrapfn()
    local ok, err = pcall(ts.extract, root)
    undo()
    vim.fn.delete(root, 'rf')
    assert(ok, err)
end

test('extract: every lexical scope is harvested ONCE — the mention walk and the scope model share it', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local scopes = ts.spec.lua.lexical_scopes
    local per, total = {}, 0
    extract_counting(function ()
        local saved = {}
        for nt, entry in pairs(scopes) do
            saved[nt] = entry.harvest
            entry.harvest = function (n, src, out)
                local k = n:id(); per[k] = (per[k] or 0) + 1; total = total + 1
                return saved[nt](n, src, out)
            end
        end
        return function () for nt, f in pairs(saved) do scopes[nt].harvest = f end end
    end)
    ok(total > 3, 'the fixture has scopes to harvest: ' .. total)
    local worst = 0
    for _, c in pairs(per) do if c > worst then worst = c end end
    eq(1, worst, 'no scope harvested twice')
end)

test('extract: derived_locals runs ONCE per function — both entry points share the memo', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local G = ts.spec.lua.guards
    local per, total = {}, 0
    extract_counting(function ()
        local f = G.derived_locals
        G.derived_locals = function (fn, src, pm)
            local k = fn:id(); per[k] = (per[k] or 0) + 1; total = total + 1
            return f(fn, src, pm)
        end
        return function () G.derived_locals = f end
    end)
    ok(total >= 2, 'the fixture has functions with params: ' .. total)
    local worst = 0
    for _, c in pairs(per) do if c > worst then worst = c end end
    eq(1, worst, 'no function walked twice')
end)
