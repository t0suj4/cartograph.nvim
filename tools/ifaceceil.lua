-- ifaceceil — the INTERFACE→IMPL hop CEILING probe (federation F1, [[cartograph-band-
-- federation]]). Before building the implements hop, MEASURE it: of the cross-band MISS
-- residual bandlink.resolve leaves today (const path + ancestor/extends hops), how much
-- is INTERFACE→IMPL-recoverable — a call typed to an interface whose implementer set
-- (UNIONED across bands from data.implements) collapses to a UNIQUE impl that defines
-- the method — vs a genuine frontier? And crucially: would recovering it be SOUND (the
-- unique impl's def == the whole-graph target c.to, i.e. WRONG=0)?
--
-- This DRY-RUNS resolve_interface's union logic (allimpls/beanimpls/ifext/service-
-- markers, the two fixpoints) against the whole-graph ground truth, cross-band. The
-- unioned data.implements IS the complete union here (single-process extract), so this
-- is the CEILING — the most the hop could recover if every band is loaded.
--
--   nvim --headless -u NONE -l tools/ifaceceil.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ports = require 'cartograph.ports'
local bandlink = require 'cartograph.bandlink'
local ts = require 'cartograph.providers.treesitter'
local javaspec = require 'cartograph.spec.java'

local name = arg[1]
if not name then print('usage: ifaceceil <corpus>'); os.exit(2) end
local data = bench.extract(name)
local band_of = ports.default_band_of(3)
local surf = ports.surface(data, band_of)
local idx = bandlink.indexes(data, band_of)
local chains = bandlink.chains(data)
local markers = javaspec._service_markers or {}

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

-- === the UNIONED interface structures (mirrors resolve_interface, cross-band) ===
local beans = data.beans or {}
local allimpls, beanimpls, ifext = {}, {}, {}
local function add(map, iface, cls)
    local s = map[iface]; if not s then s = {}; map[iface] = s end
    s[cls] = true
end
for _, e in ipairs(data.implements or {}) do
    if e.cintf then
        local l = ifext[e.child]; if not l then l = {}; ifext[e.child] = l end
        l[#l + 1] = e.iface
    else
        add(allimpls, e.iface, e.child)
        if beans[e.child] then add(beanimpls, e.iface, e.child) end
    end
end
-- service types: interfaces transitively extending a marker
local svc = {}
for _ = 1, 32 do
    local changed = false
    for child, parents in pairs(ifext) do
        if not svc[child] then
            for _, p in ipairs(parents) do
                if markers[p] or svc[p] then svc[child] = true; changed = true; break end
            end
        end
    end
    if not changed then break end
end
-- push members up the interface-extends chain (I extends J ⟹ J's impls include I's)
for _ = 1, 32 do
    local changed = false
    for child, parents in pairs(ifext) do
        for _, p in ipairs(parents) do
            for _, map in ipairs({ allimpls, beanimpls }) do
                if map[child] then
                    for cls in pairs(map[child]) do
                        if not (map[p] and map[p][cls]) then add(map, p, cls); changed = true end
                    end
                end
            end
        end
    end
    if not changed then break end
end

-- the dry-run of the hop: an interface-typed key -> its UNIQUE implementer's def id
-- (cross-band, via bandlink.resolve on the impl's own key, which walks the impl's own
-- extends chain). Returns (id, why) or (nil, why): 'not-iface', 'ambiguous' (>1 impl,
-- no qualifier narrowing), 'impl-miss' (unique impl but its def unresolved cross-band).
local function iface_recover(key, sep, method, clang, qual)
    local head = key:match('^([%w_]+)[:.]+[%w_]+$')
    local set = head and (svc[head] and allimpls[head] or beanimpls[head])
    if not set then return nil, 'not-iface' end
    local only, cnt = nil, 0
    for cls in pairs(set) do cnt = cnt + 1; only = cls end
    if cnt > 1 and qual then
        for cls in pairs(set) do
            local bn = beans[cls]
            local nm = (type(bn) == 'string' and bn) or (cls:sub(1, 1):lower() .. cls:sub(2))
            if nm == qual then only = cls; cnt = 1; break end
        end
    end
    if cnt ~= 1 then return nil, 'ambiguous' end
    local id = bandlink.resolve(only .. sep .. method, surf.const_index, idx, chains, clang, ts.lang_of)
    if id then return id, 'iface' end
    return nil, 'impl-miss'
end

-- === walk the ground-truth cross-band MISS residual ===
local miss, iface_ok, iface_wrong, ambiguous, impl_miss, not_iface = 0, 0, 0, 0, 0, 0
local wrong_ex = {}
for _, c in ipairs(data.calls or {}) do
    if c.to and c.file then
        local t = node_index[c.to]
        if t and t.file and not t.external and band_of(c.file) ~= band_of(t.file) then
            local key = c.full or c.callee
            local clang = ts.lang_of(c.file)
            local got = bandlink.resolve(key, surf.const_index, idx, chains, clang, ts.lang_of)
            if got == nil then -- the current MISS residual
                miss = miss + 1
                local head, sep, method = (key or ''):match('^([%w_]+)([:.]+)([%w_]+)$')
                if head then
                    local rid, why = iface_recover(key, sep, method, clang, c.qualifier)
                    if rid == c.to then iface_ok = iface_ok + 1
                    elseif rid ~= nil then
                        iface_wrong = iface_wrong + 1
                        if #wrong_ex < 8 then wrong_ex[#wrong_ex + 1] =
                            ('%s: iface→%s vs whole→%s'):format(key, rid, c.to) end
                    elseif why == 'ambiguous' then ambiguous = ambiguous + 1
                    elseif why == 'impl-miss' then impl_miss = impl_miss + 1
                    else not_iface = not_iface + 1 end
                else not_iface = not_iface + 1 end
            end
        end
    end
end

print(('ifaceceil %s — %d cross-band MISS residual (const + ancestor/extends hops)'):format(name, miss))
print(('  INTERFACE→IMPL recoverable (unique impl, def == whole-graph): %d (%.1f%% of miss)')
    :format(iface_ok, miss > 0 and 100 * iface_ok / miss or 0))
print(('  would-be WRONG (unique impl but ≠ whole-graph target): %d  <- MUST be 0 for a sound hop')
    :format(iface_wrong))
print(('  interface-typed but NOT uniquely recoverable: ambiguous(>1 impl) %d · impl-def-miss %d')
    :format(ambiguous, impl_miss))
print(('  not interface-typed (genuine frontier / bare): %d'):format(not_iface))
for _, e in ipairs(wrong_ex) do print('  WRONG-ex ' .. e) end
vim.cmd('qall!')
