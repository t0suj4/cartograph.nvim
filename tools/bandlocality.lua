-- bandlocality — federation's VIABILITY number (merging-strategies Tier 2). If we
-- split a repo into BANDS (per-directory subtrees) and resolve within a band,
-- linking across bands lazily, the question is: what fraction of REAL resolutions
-- stay intra-band? High intra-band → federation is ~free (cross-band is a small
-- linkage problem). Low → federation pushes a big, already-hard bucket onto the
-- linkage layer = recall risk. Measured over the resolved ref edges at several
-- band granularities (directory depth), so we can see the sweet spot: bands small
-- enough to fit, coarse enough to keep resolutions local.
--
--   nvim --headless -u NONE -l tools/bandlocality.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'

local name = arg[1]
if not name then print('usage: bandlocality <corpus>'); os.exit(2) end
local data = bench.extract(name)

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

-- a file's band at directory depth d = its first d path components (the dir
-- subtree it lives in). depth 0 = the whole repo (one band).
local function band(file, d)
    if d == 0 then return '' end
    local parts, i = {}, 0
    for seg in file:gmatch('[^/]+') do
        i = i + 1
        if i > d then break end
        parts[i] = seg
    end
    -- the LAST segment is the filename at the leaf; a band is a directory, so if
    -- the path is shorter than d we still band by its dirname
    if #parts >= 1 and file:sub(-#parts[#parts]) == parts[#parts] and i <= d then
        parts[#parts] = nil -- drop the filename component when it's the tail
    end
    return table.concat(parts, '/')
end

local function file_of(id)
    local n = node_index[id]
    if n and n.file then return n.file end
    return id:match('^(.-)::') or id
end

print(('bandlocality %s — %d nodes'):format(name, #(data.nodes or {})))
for _, d in ipairs({ 1, 2, 3, 4 }) do
    local intra, cross, ext, bands = 0, 0, 0, {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'ref' then
            local src = file_of(e.from)
            local tgt = node_index[e.to]
            local occ = #(e.at or {})
            if occ == 0 then occ = 1 end
            if not (tgt and tgt.file) or tgt.external then
                ext = ext + occ
            else
                local bs, bt = band(src, d), band(tgt.file, d)
                bands[bs] = true; bands[bt] = true
                if bs == bt then intra = intra + occ else cross = cross + occ end
            end
        end
    end
    local internal = intra + cross
    local nb = 0; for _ in pairs(bands) do nb = nb + 1 end
    print(('  depth %d: %5d bands · intra %6d (%.1f%%) · cross %6d (%.1f%%) · external %d')
        :format(d, nb,
            intra, internal > 0 and 100 * intra / internal or 0,
            cross, internal > 0 and 100 * cross / internal or 0,
            ext))
end
vim.cmd('qall!')
