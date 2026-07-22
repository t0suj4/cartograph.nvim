-- portgate — self-consistency gate for the per-band PORT SURFACE (ports.lua,
-- federation F1). Proves the "needs vs provides" split is sound BEFORE the cross-
-- band resolution pass consumes it:
--   (1) PROVIDES-COMPLETE: every cross-band resolved target is addressable through
--       its band's `provides` (a miss = a resolved def the linkage couldn't re-find
--       — e.g. torn/decl excluded from provides). Must be 0.
--   (2) CONSTANT-LINKAGE COVERAGE: of the constant-qualified cross-band resolutions,
--       what fraction does the const->band index route to the right band? = the F1
--       recall proxy via ports (should track bandruby's ~90% on Ruby). bare/no-owner
--       refs are the honest frontier residual (reconstruct selectively, not a miss).
--
--   nvim --headless -u NONE -l tools/portgate.lua <corpus>
-- Exit 1 if provides-complete fails.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ports = require 'cartograph.ports'

local name = arg[1]
if not name then print('usage: portgate <corpus>'); os.exit(2) end
local data = bench.extract(name)
local band_of = ports.default_band_of(3)
local surf = ports.surface(data, band_of)

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

local nbands, prov_total, needs_cross, needs_frontier = 0, 0, 0, 0
for _, b in pairs(surf.bands) do
    nbands = nbands + 1
    for _ in pairs(b.provides) do prov_total = prov_total + 1 end
    for _, rec in pairs(b.needs) do
        if rec.to then needs_cross = needs_cross + 1 else needs_frontier = needs_frontier + 1 end
    end
end

-- gates, computed from the raw resolved calls (precise: target name + band)
local incomplete, examples = 0, {}
local const_hit, const_total, bare = 0, 0, 0
for _, c in ipairs(data.calls or {}) do
    if c.to and c.file then
        local t = node_index[c.to]
        if t and t.file and not t.external then
            local sb, tb = band_of(c.file), band_of(t.file)
            if sb ~= tb then -- a cross-band resolution
                -- (1) is the target addressable through its band's provides?
                if not (surf.bands[tb] and surf.bands[tb].provides[t.name]) then
                    incomplete = incomplete + 1
                    if #examples < 8 then examples[#examples + 1] = (t.name .. ' @ ' .. tb) end
                end
                -- (2) constant-linkage: does const->band route the ref to tb?
                local owner = ports.owner_of(c.full or c.callee or '')
                if owner then
                    const_total = const_total + 1
                    if surf.const_index[owner] and surf.const_index[owner][tb] then
                        const_hit = const_hit + 1
                    end
                else
                    bare = bare + 1
                end
            end
        end
    end
end

print(('portgate %s — %d bands · %d provides · needs: %d cross-band + %d frontier')
    :format(name, nbands, prov_total, needs_cross, needs_frontier))
print(('  (1) provides-complete: %d cross-band targets NOT in provides%s')
    :format(incomplete, incomplete > 0 and (' e.g. ' .. table.concat(examples, ', ')) or ' — OK'))
print(('  (2) constant-linkage: %d/%d constant-qualified routed (%.1f%%) · %d bare (frontier residual)')
    :format(const_hit, const_total, const_total > 0 and 100 * const_hit / const_total or 0, bare))

if incomplete > 0 then
    print('FAIL: some cross-band resolutions are not addressable through provides')
    vim.cmd('cquit 1')
else
    print('OK — every cross-band resolution is addressable through the port surface')
    vim.cmd('qall!')
end
