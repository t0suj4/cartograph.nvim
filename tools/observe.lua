-- The DISPATCH OBSERVER: cartograph's runtime/confirmed tier, driven
-- headlessly on cartograph's OWN code (self://loaded, [[graph-vm-type-resolution]]
-- "live calibration = the flywheel"). The confirm.lua mechanism (apply/diff/
-- report) was shipped + tested; observe_self only confirmed IMPORT edges. This
-- is the "real dispatch observer" that memo flagged as the remaining wiring:
-- run a bounded workload of cartograph code under a call hook, map every
-- observed (caller -> callee) dispatch back to static graph nodes
-- (self_oracle.resolve_fn), and feed confirm.apply.
--
-- Why it PROVES the tier: cartograph's spec hooks (spec.qualify_call,
-- spec.def_ret, ...) are dynamic dispatch through function-valued table
-- fields — static resolution REFUSES them (a field call on a dynamically
-- selected spec table). At runtime they dispatch to the concrete lua_*/js_*
-- implementations. So a workload extract RECOVERS those edges: the honest
-- product only the runtime tier can deliver, and lua-ls structurally cannot.
--
-- SOUNDNESS (confirm.lua's spec): observed ⊆ static; observation CONFIRMS +
-- RECOVERS, ABSENCE NEVER REFUTES. Session-live overlay, never folded/cached.
--
--   nvim --headless -u NONE -l tools/observe.lua [workload-corpus]
--
-- workload-corpus defaults to the deterministic synthetic lua corpus (small,
-- exercises the lua spec hooks). The SELF graph observed against is always
-- cartograph itself.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/observe%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()

local confirm = require 'cartograph.confirm'
local so = require 'cartograph.self_oracle'

local workload = arg and arg[1] or 'synlua'

io.write('extracting the SELF graph (cartograph on cartograph)...\n')
local data = bench.extract('self')
io.write(('  self: %d nodes, %d edges\n'):format(#data.nodes, #data.edges))

-- Collect RAW (caller_fn, callee_fn) value pairs during the workload. Doing
-- the node mapping INSIDE the hook would be too slow (resolve_fn scans nodes)
-- and reentrant; we dedup by function-value identity here (function values are
-- valid table keys) and resolve AFTER, hook off.
local pair_seen = {}   -- [caller_fn] = { [callee_fn] = true }
local npairs = 0
local in_hook = false

local function hook()
    if in_hook then return end
    in_hook = true
    local callee = debug.getinfo(2, 'f')
    local caller = debug.getinfo(3, 'f')
    if callee and caller and callee.func and caller.func then
        local cf, kf = caller.func, callee.func
        if cf ~= kf then
            local t = pair_seen[cf]
            if not t then t = {}; pair_seen[cf] = t end
            if not t[kf] then t[kf] = true; npairs = npairs + 1 end
        end
    end
    in_hook = false
end

io.write(('running the workload extract (%s) under a call hook...\n'):format(workload))
-- LuaJIT's call hook does NOT fire inside compiled traces, so hot functions
-- would be invisible. Disable + flush the JIT for the observed window so every
-- call is interpreted and seen (this is a measurement run, not a perf path).
local has_jit, jit = pcall(require, 'jit')
if has_jit and jit and jit.off then jit.off(true, true) end
debug.sethook(hook, 'c')
local ok, err = pcall(bench.extract, workload)
debug.sethook()
if has_jit and jit and jit.on then jit.on(true, true) end
if not ok then
    io.write('  workload extract failed: ' .. tostring(err) .. '\n')
end
io.write(('  observed %d distinct (caller -> callee) dispatch pairs\n'):format(npairs))

-- Resolve each unique function value to its static node id (memoized).
local id_of = setmetatable({}, { __mode = 'k' })
local function resolve(fn)
    local cached = id_of[fn]
    if cached ~= nil then return cached or nil end
    local r = so.resolve_fn(fn, data)
    local id = r and r.id or false
    id_of[fn] = id
    return id or nil
end

local observed = {}   -- "from_id\31to_id" set for confirm.apply
local n_obs, n_selfmapped = 0, 0
for cf, tset in pairs(pair_seen) do
    local from = resolve(cf)
    if from then
        n_selfmapped = n_selfmapped + 1
        for kf in pairs(tset) do
            local to = resolve(kf)
            if to and to ~= from then
                observed[from .. '\31' .. to] = true
                n_obs = n_obs + 1
            end
        end
    end
end
io.write(('  mapped to %d observed edge-keys (callers in-graph: %d)\n')
    :format(n_obs, n_selfmapped))

-- Apply to the graph: CONFIRM existing edges, RECOVER ones static missed.
-- Snapshot recovered edges BEFORE apply (apply mutates data.edges).
local had = {}
for _, e in ipairs(data.edges) do
    if e.kind == 'ref' or e.kind == 'import' then had[e.from .. '\31' .. e.to] = true end
end
local res = confirm.apply(data, observed)

-- name a node id for the report
local byid = {}
for _, n in ipairs(data.nodes) do byid[n.id] = n end
local function nm(id)
    local n = byid[id]
    if not n then return tostring(id) end
    return (n.file or '?') .. '::' .. (n.name or '?')
end

io.write(('\nCONFIRMED %d edges · RECOVERED %d edges (static refused, runtime saw)\n')
    :format(res.confirmed, res.recovered))

-- list a sample of the recovered edges — the disagreement product
local recovered = {}
for key in pairs(observed) do
    if not had[key] then
        local from, to = key:match('^(.-)\31(.*)$')
        recovered[#recovered + 1] = { from = from, to = to }
    end
end
table.sort(recovered, function (a, b)
    if a.from ~= b.from then return a.from < b.from end
    return a.to < b.to
end)
io.write(('\nrecovered dispatch edges (up to 30 of %d):\n'):format(#recovered))
for i = 1, math.min(30, #recovered) do
    io.write(('  %s  ->  %s\n'):format(nm(recovered[i].from), nm(recovered[i].to)))
end
