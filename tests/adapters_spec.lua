-- A SKELETON GRAPH WITH GENERATED ADAPTERS (CART-1160 step 8). The skeleton is the thin index; each detail field is
-- filled on demand by the producer an adapter was DERIVED for (probe the producer, record what it wrote and whether it
-- stayed local). ★ THE ACCEPTANCE TEST IS THE STEP-3 RULE: a query answered through skeleton + adapters EQUALS the same
-- query on the fully materialized graph, row by row — with a residency bound small enough that the detail never all
-- fits at once.
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local A = require 'cartograph.adapters'
local df = require 'cartograph.df'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local function body(k)
    return ([[
local M = {}
function M.sum%d(t)
  local acc = 0
  for i = 1, #t do acc = acc + t[i] * %d end
  local out = acc
  return out
end
function M.pick%d(t, key)
  local v = t[key]
  if v == nil then v = %d end
  return v
end
return M
]]):format(k, k, k, k)
end

local function tree(n)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for k = 1, n do local fd = assert(io.open(('%s/f%d.lua'):format(root, k), 'w')); fd:write(body(k)); fd:close() end
    return root
end

--- the ROWS a dataflow consumer sees, per function: every statement's line, defs, uses and deps
local function rows()
    local out = {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            local st = {}
            for i, s in ipairs(df.stmts(n)) do
                local deps = {}
                for j, d in ipairs(s.dep or {}) do deps[j] = tostring(d.from) .. ':' .. tostring(d.var) end
                st[i] = ('%s|%s|%s|%s'):format(tostring(s.l), table.concat(s.def or {}, ','), table.concat(s.use or {}, ','), table.concat(deps, ','))
            end
            out[n.id] = st
        end
    end
    return out
end

test('adapters: DERIVED by probing the producers — dataflow is local and fills df/flow; the call producer is not local', function ()
    if not ready() then skip 'no lua parser' end
    local d = assert(A.derive())
    ok(d.dataflow and d.dataflow.is_local, vim.inspect(d))
    ok(d.dataflow.fields.df and d.dataflow.fields.flow, 'the fields the producer WROTE')
    if d.calls then eq(false, d.calls.is_local, 'a relink touches graph-level tables: never triggered by a field read') end
end)

test('adapters: skeleton + adapters answers df EXACTLY as the full graph, row by row — under a budget of ONE file', function ()
    if not ready() then skip 'no lua parser' end
    local root = tree(4)
    store.ingest(ts.extract(root))
    local full = rows()
    local nfn = 0
    for _, st in pairs(full) do nfn = nfn + 1; ok(#st > 0, 'the full graph has statements (a non-vacuous oracle)') end
    eq(8, nfn)
    local saved = A.budget
    A.budget = 1
    local ok_run, err = pcall(function ()
        store.ingest(ts.index_only(root))
        eq(true, store.data.index_only)
        -- before any read: no file's detail is resident
        eq({}, A.resident(store))
        local e0, f0 = A.stats.evictions, A.stats.fills
        local skel = rows()
        eq(full, skel, 'every function, every statement: the skeleton reads what the full graph holds')
        eq(4, A.stats.fills - f0, 'one fill per file')
        ok(A.stats.evictions - e0 >= 3, 'the budget evicted as it went')
        ok(#A.resident(store) <= 1, 'never more than the budget resident: ' .. vim.inspect(A.resident(store)))
        -- read the first file again after it was evicted: it is filled again, and still exact
        eq(full, rows(), 'a second pass (re-filling evicted files) is still exact')
    end)
    A.budget = saved
    if not ok_run then error(err, 0) end
end)

test('adapters: an unmaterialized node no longer answers df with a silent empty; a FULL graph gets no adapters', function ()
    if not ready() then skip 'no lua parser' end
    local root = tree(1)
    store.ingest(ts.index_only(root))
    local fn
    for _, n in ipairs(store.data.nodes) do if n.name == 'M.sum1' then fn = n end end
    eq(nil, rawget(fn, 'df'), 'the skeleton holds no dataflow')
    local gen, nedges, ncalls = store.generation, #(store.data.edges or {}), #(store.data.calls or {})
    ok(#df.stmts(fn) > 0, 'reading it FILLS it — before this the accessor returned {}')
    eq(gen, store.generation, 'a field read runs only a LOCAL producer: no relink, no generation bump')
    eq(nedges, #(store.data.edges or {})); eq(ncalls, #(store.data.calls or {}))
    store.ingest(ts.extract(root))
    for _, n in ipairs(store.data.nodes) do eq(nil, getmetatable(n), 'a full graph is not a skeleton') end
end)

test('adapters: PREFETCH fills exactly the producer a task\'s fields need, once per file, and the reads cost nothing after', function ()
    if not ready() then skip 'no lua parser' end
    local root = tree(3)
    store.ingest(ts.index_only(root))
    local gen = store.generation
    eq(2, A.prefetch(store, { 'f1.lua', 'f2.lua' }, { 'df' }), 'two files, one producer')
    eq(gen, store.generation, 'df asked for: the LOCAL producer, never the relink')
    eq({ 'f1.lua', 'f2.lua' }, A.resident(store))
    local f0 = A.stats.fills
    for _, n in ipairs(store.data.nodes) do if n.file ~= 'f3.lua' then local _ = n.df end end
    eq(f0, A.stats.fills, 'prefetched files are not filled again')
    eq(0, A.prefetch(store, { 'f1.lua' }, { 'df' }), 'already resident: nothing to do')
end)

test('adapters: a node is filled only while ITS graph is the lens — never from another graph\'s store', function ()
    if not ready() then skip 'no lua parser' end
    local root = tree(1)
    store.ingest(ts.index_only(root))
    local fn
    for _, n in ipairs(store.data.nodes) do if n.name == 'M.sum1' then fn = n end end
    local other = ts.index_only(tree(2))
    store.scoped(other, function ()
        eq(nil, fn.df, 'read while another graph is the lens: not filled from it')
        eq({}, A.resident(store), 'and the read did not fill the OTHER graph either (it has an f1.lua too)')
    end)
    ok(fn.df and #fn.df.stmts > 0, 'back in its own graph: filled')
end)
