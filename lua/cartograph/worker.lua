-- Parallel-extraction worker. NOT a module: run as
--   nvim -u NONE -i NONE --headless -l worker.lua <job.json>
-- One phase, 'parse': extract a slice of files (skip_idpass) -> binary
-- chunk. The chunk carries packed mention buffers (fusion Stage B); the
-- id pass is a pure reduce in the PARENT (global lookups live there —
-- slice-local uniqueness is not global uniqueness).

-- LuaJIT's default trace budgets (maxtrace=1000, maxmcode=512K) are too
-- small for the extractor: traces flush and recompile in a churn loop that
-- profiled at 15-17% of wall. Raising them measured -14% on server /
-- -19% on libs (J: 16.5%->2.2%). This is OUR process — tune freely.
pcall(function () require('jit.opt').start('maxtrace=4000', 'maxmcode=8192') end)

local T0 = vim.uv.hrtime() -- whole-process work time (spawn cost is the
-- parent's dt minus this; the split says pipe-vs-process economics)

local jobfile = _G.arg and _G.arg[1]
assert(jobfile, 'worker: no job file')
local fd = assert(io.open(jobfile, 'r'))
local job = vim.json.decode(fd:read('a'))
fd:close()

for _, p in ipairs(job.rtp or {}) do vim.opt.rtp:append(p) end
local ts = require 'cartograph.providers.treesitter'
local codec = require 'cartograph.cache' -- binary encode/decode

-- a multi-root corpus (self://loaded) ships a label→dir map: file keys
-- are plugin-labelled, so resolution against disk goes through this.
local abs
if job.roots then
    local roots = job.roots
    abs = function (file)
        local label, rest = file:match('^([^/]+)/(.*)$')
        return (roots[label] or '') .. '/' .. (rest or file)
    end
end

local out
if job.phase == 'parse' then
    out = ts.extract(job.root, {
        files = job.files, fileset = job.fileset, skip_idpass = true,
        abs = abs, packs = job.packs, -- overlay packs (rails) apply in workers
    })
else
    error('worker: unknown phase ' .. tostring(job.phase))
end

-- self-reported footprint, riding the chunk (the parent strips + collects):
-- peak RSS is THE number for sizing a worker onto a small remote box (the
-- push-the-indexer-to-the-data deployment) — the map phase is the part
-- that leaves home, so its envelope must be known, not guessed
do
    local st = io.open('/proc/self/status', 'r')
    if st then
        local txt = st:read('a')
        st:close()
        out._metrics = {
            phase = job.phase,
            files = #(job.files or {}),
            hwm_kb = tonumber(txt:match('VmHWM:%s*(%d+)')),
            rss_kb = tonumber(txt:match('VmRSS:%s*(%d+)')),
            wall_ms = (vim.uv.hrtime() - T0) / 1e6,
        }
    end
end

codec.pack_calls(out) -- calls → columnar segment (smaller chunk on the wire)
local ofd = assert(io.open(job.out, 'wb'))
ofd:write(codec.encode(out))
ofd:close()
