-- determinism — "does this corpus produce the same graph twice?", per LAYER.
--
--   nvim --headless -u NONE -l tools/determinism.lua <corpus|dir> [--runs N]
--
-- ★★ WHY IT EXISTS, AND WHY IT RUNS SEPARATE PROCESSES. LuaJIT 2.1 randomises
-- its string hash SEED PER PROCESS, so `pairs` over identical keys inserted in
-- identical order yields a different order in every run (measured: 40 keys, four
-- processes, four orders). Every `pairs`-order dependence that reaches an output
-- is therefore a CROSS-PROCESS nondeterminism — and a graph is serialised into
-- caches, snapshots and gate baselines. An in-process A/B cannot see any of it:
-- both arms share one seed and agree perfectly. That is exactly how CART-0788
-- survived a parity check on eight corpora.
--
-- ★★★ AND THE OUTPUT IS THE EARLIEST MOVING LAYER, NOT A PASS/FAIL, which is
-- the whole design (user, 2026-09-06: "the iteration order instability surfaces a
-- different issue if node count differs"). Downstream layers inherit upstream
-- instability, so "the xlang edges moved" is not a diagnosis while the node ids
-- are unchecked. Naming the FIRST layer that moves says which mechanism to go
-- and look at:
--     files/nodes   the extractor or its file walk       — the worst case: ids
--                   move, so every cache and every pin is invalid
--     calls         resolution or the call record order
--     edges_pre     the extractor's edge construction
--     bindings      discovery (greenspun) — the CART-0788 class
--     xlang         the link post-pass
-- A digest of the SEQUENCE is compared, never a count: a count is stable under
-- permutation, and permutation is precisely what a hash-order bug does.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')

local name, runs, one = nil, 5, false
local i = 1
while arg[i] do
    if arg[i] == '--runs' then runs = tonumber(arg[i + 1]); i = i + 2
    elseif arg[i] == '--one' then one = true; i = i + 1
    else name = arg[i]; i = i + 1 end
end
if not name then print('usage: determinism.lua <corpus|dir> [--runs N]'); os.exit(2) end

-- the LAYERS, in pipeline order. Each yields (count, digest-of-sequence).
local LAYERS = { 'files', 'nodes', 'calls', 'edges_pre', 'bindings', 'xlang' }

local function digest(s) return vim.fn.sha256(s):sub(1, 12) end

local function one_run()
    bench.bootstrap()
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local xl = require 'cartograph.xlang'
    local c = bench.corpus(name)
    local raw = ts.extract(c.root, {})
    local out = {}
    local function put(layer, list)
        out[layer] = { n = #list, d = digest(table.concat(list, '\n')) }
    end
    local l = {}
    for _, f in ipairs(raw.files or {}) do l[#l + 1] = tostring(f) end
    put('files', l)
    l = {}
    for _, n in ipairs(raw.nodes or {}) do l[#l + 1] = tostring(n.id) end
    put('nodes', l)
    store.ingest(raw)
    local d = store.data
    l = {}
    for _, cc in ipairs(d.calls or {}) do
        l[#l + 1] = ('%s:%s:%s:%s'):format(tostring(cc.file), tostring(cc.line),
            tostring(cc.callee), tostring(cc.to))
    end
    put('calls', l)
    l = {}
    for _, e in ipairs(d.edges or {}) do
        l[#l + 1] = ('%s>%s:%s'):format(tostring(e.from), tostring(e.to), tostring(e.kind))
    end
    put('edges_pre', l)
    -- the binding list: its ORDER is output too, because link walks it in order
    -- and appends `at` sites to edges as it goes
    local bindings = xl.effective_bindings(d)
    l = {}
    for _, b in ipairs(bindings) do
        local iv = b.import and b.import.verb
        local names = {}
        if b.import and b.import.names then
            for k, v in pairs(b.import.names) do names[#names + 1] = k .. '=' .. tostring(v) end
            table.sort(names)
        end
        l[#l + 1] = ('%s/%s->%s@%s{%s}'):format(
            type(b.export.verb) == 'table' and table.concat(b.export.verb, '+')
                or tostring(b.export.verb),
            tostring(b.export.name),
            type(iv) == 'table' and table.concat(iv, '+') or tostring(iv),
            tostring(b.import and b.import.name), table.concat(names, ','))
    end
    put('bindings', l)
    xl.link(d, bindings)
    l = {}
    for _, e in ipairs(d.edges or {}) do
        if e.xlang then l[#l + 1] = ('%s>%s:%d'):format(tostring(e.from), tostring(e.to),
            #(e.at or {})) end
    end
    put('xlang', l)
    local parts = {}
    for _, k in ipairs(LAYERS) do
        parts[#parts + 1] = ('%s=%d/%s'):format(k, out[k].n, out[k].d)
    end
    return table.concat(parts, ' ')
end

if one then print(one_run()); os.exit(0) end

-- the parent spawns N children, because the seed is per PROCESS: running the
-- layers N times inside one process would compare a seed against itself
local seen = {}
for r = 1, runs do
    local res = vim.fn.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo .. '/tools/determinism.lua', name, '--one' })
    local line = res:match('[^\n]*=%d+/%x+[^\n]*')
    if not line then print(('run %d produced no result:\n%s'):format(r, res)); os.exit(2) end
    print(('  run %d  %s'):format(r, line))
    -- ⚠ `[%w_]`, not `%w`: `%w` stops at the underscore, so `edges_pre=...` was
    -- captured as `pre` and the edges_pre layer was never compared at all. It
    -- then printed "0 distinct values — stable", which is why the check below
    -- exists: A LAYER WITH NO OBSERVATIONS MUST NOT READ AS PASSING. This tool's
    -- entire job is to notice silent sameness, and its first version had a silent
    -- gap of its own.
    for k, v in line:gmatch('([%w_]+)=(%S+)') do
        seen[k] = seen[k] or {}
        seen[k][v] = (seen[k][v] or 0) + 1
    end
end

local first_moving, unchecked
for _, k in ipairs(LAYERS) do
    local n = 0
    for _ in pairs(seen[k] or {}) do n = n + 1 end
    local mark = n == 0 and '*** NOT MEASURED ***'
        or n > 1 and '*** MOVES ***' or 'stable'
    if n == 0 then unchecked = unchecked or k
    elseif n > 1 and not first_moving then first_moving = k end
    print(('  %-10s %d distinct value(s)   %s'):format(k, n, mark))
end
if unchecked then
    print(('\nHARNESS FAULT: layer %q produced no observations — this run proves'
        .. ' nothing about it.'):format(unchecked))
    os.exit(2)
end
if first_moving then
    print(('\nEARLIEST MOVING LAYER: %s — everything after it is downstream of this'
        .. ' and is not independent evidence.'):format(first_moving))
    os.exit(1)
end
print('\nDETERMINISTIC across ' .. runs .. ' processes, every layer.')
