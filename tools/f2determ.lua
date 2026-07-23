-- f2determ — the CACHE-DETERMINISM probe (F2 step 3 gate, [[cartograph-thin-index]]).
-- The step-3 question: can the df/flow fold move per-chunk (arrival order, in merge_chunk)
-- without perturbing the cache? Prerequisite fact to establish FIRST: is the cache
-- deterministic TODAY (fold whole-graph in the parent, canonical fileset order)? If two
-- independent PARALLEL extracts of the same corpus produce byte-identical shards, the
-- baseline is deterministic and step 3 must PRESERVE that (either order-independent bytes,
-- or a fileset reorder at finalize). If they already differ, determinism is not a step-3
-- regression to guard — it's a pre-existing hole.
--
-- Also reports the SERIALIZATION SANITY post-P3: the fold stamps every df node with
-- n._df = the ONE shared packed store. string.buffer.encode does NOT dedup shared table
-- refs, so if build_shards serializes _df per node the shared store would be DUPLICATED
-- into every shard (bloat). We compare total shard bytes to the resident store size to
-- catch that.
--
-- MEMORY-FRUGAL: shards are HASHED (djb2) not held; the graph is freed between the two
-- runs. Default corpus is small — a 12 GB blowup on mid-size libs first flagged that
-- cache.save may duplicate the shared store, so this must not itself OOM the box.
--
--   nvim --headless -u NONE -l tools/f2determ.lua [corpus]   (default: jquery)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local cache = require 'cartograph.cache'

local name = arg[1] or 'jquery'

-- djb2 over a string (so we compare shard HASHES, never hold raw bytes)
local function djb2(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return h
end

-- resident byte size of a packed column store {col={s,w}, names={...}}
local function store_bytes(st)
    if not st then return 0 end
    local b = 0
    for _, v in pairs(st) do
        if type(v) == 'table' then
            if type(v.s) == 'string' then b = b + #v.s
            else for _, x in pairs(v) do if type(x) == 'string' then b = b + #x end end end
        end
    end
    return b
end

local function count_df(data)
    local nd, nf = 0, 0
    for _, n in ipairs(data.nodes or {}) do
        if n._df then nd = nd + 1 end
        if n._flow then nf = nf + 1 end
    end
    return nd, nf
end

-- extract in parallel, save the cache, HASH every shard from disk (bytes discarded
-- immediately). Returns a frugal summary; the graph is dropped before the caller GCs.
local function run()
    local data = bench.extract_parallel(name)
    local root = data.root
    cache.wipe(root)                    -- clean slate so we read only THIS run's shards
    cache.save(data)                    -- sync, whole-graph
    local dir = cache.path(root)
    local hashes, total, biggest, shards = {}, 0, 0, 0
    local it = vim.uv.fs_scandir(dir)
    while it do
        local fn = vim.uv.fs_scandir_next(it)
        if not fn then break end
        if fn ~= 'manifest.tmp' then
            local fd = io.open(dir .. '/' .. fn, 'rb')
            if fd then
                local bytes = fd:read('a'); fd:close()
                hashes[fn] = djb2(bytes) .. ':' .. #bytes
                total = total + #bytes
                if fn ~= 'manifest.bin' and #bytes > biggest then biggest = #bytes end
                shards = shards + 1
                bytes = nil             -- discard at once
            end
        end
    end
    local nd, nf = count_df(data)
    local r = {
        hashes = hashes, total = total, biggest = biggest, shards = shards, root = root,
        df_nodes = nd, flow_nodes = nf,
        df_store = store_bytes(data._dfcol),
        flow_store = store_bytes(data._flcol or data._flowcol),
        nodes = #(data.nodes or {}),
    }
    return r
end

print(('f2determ %s — two independent parallel extracts, diffing cached shards'):format(name))
local a = run()
collectgarbage(); collectgarbage()   -- drop run A's graph before run B extracts
local b = run()

-- ── determinism verdict ──────────────────────────────────────────────
local names = {}
for k in pairs(a.hashes) do names[k] = true end
for k in pairs(b.hashes) do names[k] = true end
local sorted = {}
for k in pairs(names) do sorted[#sorted + 1] = k end
table.sort(sorted)

local diff, only_a, only_b, same = 0, 0, 0, 0
local first = {}
for _, k in ipairs(sorted) do
    local x, y = a.hashes[k], b.hashes[k]
    if x and not y then only_a = only_a + 1
    elseif y and not x then only_b = only_b + 1
    elseif x == y then same = same + 1
    else
        diff = diff + 1
        if #first < 6 then first[#first + 1] = ('%s (%s vs %s)'):format(k, x, y) end
    end
end

print(('  run A: %d nodes, %d shards, %d KB total (biggest shard %d KB); df-nodes %d, _dfcol store %d KB; flow-nodes %d, store %d KB')
    :format(a.nodes, a.shards, math.floor(a.total / 1024), math.floor(a.biggest / 1024),
        a.df_nodes, math.floor(a.df_store / 1024), a.flow_nodes, math.floor(a.flow_store / 1024)))
print(('  run B: %d nodes, %d shards, %d KB total')
    :format(b.nodes, b.shards, math.floor(b.total / 1024)))
print(('  shard diff: %d identical · %d DIFFER · %d only-in-A · %d only-in-B')
    :format(same, diff, only_a, only_b))
for _, s in ipairs(first) do print('    differ: ' .. s) end

-- byte-determinism is COSMETIC (f2graphdet proves the reconstructed graph is stable; load
-- reassembles shards in sorted file order). Report it, but it is NOT the gate.
if diff == 0 and only_a == 0 and only_b == 0 then
    print('  byte-determinism: shards byte-identical across runs (bonus; not required).')
else
    print('  byte-determinism: shards vary run to run (COSMETIC — see f2graphdet for graph parity).')
end

-- ── THE GATE: per-node shared-store DUPLICATION (the P3 bloat bug) ─────
-- If build_shards serialized the folded form, every df/flow node would carry a copy of the
-- ONE shared store → total ≈ df_nodes×df_store + flow_nodes×flow_store (string.buffer does
-- not dedup shared refs). With the raw-on-disk fix each node stores only its OWN small
-- record, so total is a small FRACTION of that duplication bound. Gate on the ratio.
local dup_bound = a.df_nodes * a.df_store + a.flow_nodes * a.flow_store
local frac = dup_bound > 0 and a.total / dup_bound or 0
print(('  DUPLICATION GATE: total %d KB vs per-node-copy bound %d KB = %.3f of bound')
    :format(math.floor(a.total / 1024), math.floor(dup_bound / 1024), frac))
if frac > 0.25 then
    print(('FAIL: cache is ~%.2f of the per-node duplication bound — the shared df/flow store is'):format(frac))
    print('      being DUPLICATED per node (the P3 bloat). build_shards must persist RAW df/flow.')
    vim.cmd('cquit 1')
else
    print(('OK — cache is %.1f%% of the duplication bound: no per-node store copies; shards are raw+compact.')
        :format(frac * 100))
    vim.cmd('qall!')
end
