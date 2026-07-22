-- bandrecall — federation's RECALL gate (merging-strategies Tier 2). bandlocality
-- said what fraction of resolutions cross a band; this asks the harder question:
-- of the CROSS-band ones, how many are RECOVERABLE by the linkage band — i.e.
-- backed by an `import`/require edge from the source file to the target's file
-- (the declared boundary crossing resolve_module_alias already follows)? A cross-
-- band resolution WITH a backing import is linkage-recoverable (precise, not a
-- guess); one WITHOUT is at-risk of being LOST under federation. at-risk% = the
-- federation recall risk. (Ruby crosses via ancestors/autoload more than explicit
-- require, so a low import count there means the proxy UNDER-counts Ruby recovery —
-- reported so it's read honestly.)
--
--   nvim --headless -u NONE -l tools/bandrecall.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'

local name = arg[1]
if not name then print('usage: bandrecall <corpus>'); os.exit(2) end
local data = bench.extract(name)

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

-- import map: importing-file -> { imported-file = true } (the linkage edges)
local imp, nimp = {}, 0
for _, e in ipairs(data.edges or {}) do
    if e.kind == 'import' and e.from and e.to then
        imp[e.from] = imp[e.from] or {}
        imp[e.from][e.to] = true
        nimp = nimp + 1
    end
end

local function band(file, d)
    local parts, i = {}, 0
    for seg in file:gmatch('[^/]+') do i = i + 1; if i > d then break end; parts[i] = seg end
    if #parts >= 1 and file:sub(-#parts[#parts]) == parts[#parts] and i <= d then parts[#parts] = nil end
    return table.concat(parts, '/')
end
local function file_of(id)
    local n = node_index[id]
    if n and n.file then return n.file end
    return id:match('^(.-)::') or id
end

print(('bandrecall %s — %d nodes · %d import edges'):format(name, #(data.nodes or {}), nimp))
for _, d in ipairs({ 2, 3 }) do
    local intra, recov, risk, ext = 0, 0, 0, 0
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'ref' then
            local src, tgt = file_of(e.from), node_index[e.to]
            local occ = #(e.at or {}); if occ == 0 then occ = 1 end
            if not (tgt and tgt.file) or tgt.external then
                ext = ext + occ
            elseif band(src, d) == band(tgt.file, d) then
                intra = intra + occ
            elseif imp[src] and imp[src][tgt.file] then
                recov = recov + occ -- cross-band, backed by a declared import → linkage recovers it
            else
                risk = risk + occ -- cross-band, NO import edge → at-risk under federation
            end
        end
    end
    local internal = intra + recov + risk
    print(('  depth %d: intra %6d (%.1f%%) · cross-recoverable %5d (%.1f%%) · AT-RISK %5d (%.1f%%)')
        :format(d,
            intra, internal > 0 and 100 * intra / internal or 0,
            recov, internal > 0 and 100 * recov / internal or 0,
            risk, internal > 0 and 100 * risk / internal or 0))
end
vim.cmd('qall!')
