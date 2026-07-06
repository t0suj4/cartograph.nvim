-- Parallel-extraction worker. NOT a module: run as
--   nvim -u NONE -i NONE --headless -l worker.lua <job.json>
-- Phase 'parse': extract a slice of files (skip_idpass) -> chunk JSON.
-- Phase 'ids':   run the id pass with PARENT-built global lookups
--                (slice-local uniqueness is not global uniqueness).

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
        abs = abs,
    })
elseif job.phase == 'ids' then
    local ifd = assert(io.open(job.index_file, 'rb'))
    local index = codec.decode(ifd:read('a'))
    ifd:close()
    out = ts.id_pass(job.root, job.files, {
        fn_unique = index.fn_unique,
        var_named = index.var_named,
        scopes = index.scopes, -- confinement is global state too: without
        -- it a worker links bare names across scope boundaries the
        -- sequential path refuses
        fn_ranges = job.fn_ranges,
    }, abs)
else
    error('worker: unknown phase ' .. tostring(job.phase))
end

local ofd = assert(io.open(job.out, 'wb'))
ofd:write(codec.encode(out))
ofd:close()
