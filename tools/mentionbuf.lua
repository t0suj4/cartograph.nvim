-- mentionbuf — SIZE the per-file mention buffers, i.e. price KEEPING them past
-- extraction ([[cartograph-merging-strategies]]).
--
-- WRITTEN FOR A MOTIVE THAT NO LONGER APPLIES: I built this to justify retention as the
-- only way to give relink the id pass's cbarg marks up front, on the theory that the
-- extract-vs-relink divergence needed relink to see them. It did not — the divergence
-- was one field answering three questions, and the registry class simply stopped being
-- resolution input (cache v103). Feeding both drivers the replayed marks instead was
-- built and MEASURED WORSE (lua-spec lost 5 confirmed calls). The numbers below stand;
-- the reason to want them is now only:
--   1. the thin-index mention index (data.names, use/reg edges) without a re-parse;
--   2. the postings, which today rebuild from data.names.
-- Both are query-side, so neither is urgent — retention was a NO-GO in step 1 of this
-- arc for refresh's candidate scan (a 280 ms build serving three lookups), and nothing
-- since has produced the REPEATED-query consumer that would pay for it.
-- Retention costs nothing to COMPUTE (phase 1 already produces the buffers, already
-- packed for a process boundary). What it costs is BYTES, and that is what this reports.
--
-- The comparison is against data.names, which the cache already persists per-file
-- shard — so it prices the new field against a field of known, accepted cost.
--
--   nvim --headless -u NONE -l tools/mentionbuf.lua [corpus ...]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'

local targets = {}
for i = 1, #arg do targets[#targets + 1] = arg[i] end
if #targets == 0 then targets = { 'lua-spec', 'ruby', 'rust' } end

local function root_of(name)
    if name == 'lua-spec' then return repo .. '/lua/cartograph/spec' end
    local okx, c = pcall(bench.corpus, name)
    return okx and c.root or name
end

print('mentionbuf — per-file mention buffers vs the data.names the cache already keeps')
for _, name in ipairs(targets) do
    local root = root_of(name)
    -- extract exposes data.mentions ONLY on the slice path (skip_idpass) — the branch the
    -- parallel workers take, because the parent runs the reduce later. A full inline
    -- extract replays them and lets them go. So ask via skip_idpass to price the artifact,
    -- and take the data.names baseline from a normal extract.
    local data = ts.extract(root, { skip_idpass = true })
    local bufs = data.mentions
    local named = ts.extract(root)
    data.names = named.names
    if not bufs or not next(bufs) then
        print(('  %-10s no buffers on this corpus (no parsed language emits mentions)')
            :format(name))
    else
        local nb, packed, pool = 0, 0, 0
        for _, b in pairs(bufs) do
            nb = nb + 1
            packed = packed + #(b.m or '')
            for _, s in ipairs(b.names or {}) do pool = pool + #s + 1 end
        end
        local names_bytes, nfiles = 0, 0
        for _, s in pairs(data.names or {}) do
            nfiles = nfiles + 1; names_bytes = names_bytes + #s
        end
        local blob = #vim.mpack.encode(bufs)
        print(('  %-10s %d buffers · packed %.1f KB + name pool %.1f KB · mpack %.1f KB')
            :format(name, nb, packed / 1024, pool / 1024, blob / 1024))
        print(('             data.names %.1f KB over %d files  ==>  buffers are %.1fx that')
            :format(names_bytes / 1024, nfiles,
                names_bytes > 0 and (blob / names_bytes) or 0))
    end
end
vim.cmd('qall!')
