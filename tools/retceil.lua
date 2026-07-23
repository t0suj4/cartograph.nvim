-- retceil — the RETURN-TYPE ceiling probe (federation, [[cartograph-consumer-federation]]
-- / [[cartograph-band-federation]] F2). Before graduating `ret` from "a build_symtab field"
-- to "the reason to build the symbol table", MEASURE it: of the f2gate MISS residual (calls
-- whole-graph resolved but the federated bandresolve missed), how much is a RECEIVER CHAIN
-- that a cross-band RET summary in the symbol table WOULD resolve — and at what tier, and
-- would it ever mis-link (would-be-WRONG)?
--
-- CEILING: for a MISS call carrying a determining-site marker (c.rt — the graph-VM chain
-- provenance), take the DETERMINING call's whole-graph target's `ret` (a type name), key
-- `ret .. methodsep .. member`, and resolve THAT through bandresolve against the symbol
-- table. Uses whole-graph's determining `to` (the best case = the determining call resolved),
-- so this is the UPPER bound of the recall `ret` buys. Reported per corpus; typed langs
-- (java/zig, declared def_ret) carry ret, dynamic langs mostly don't (the tier story).
--
--   nvim --headless -u NONE -l tools/retceil.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ports = require 'cartograph.ports'
local bandlink = require 'cartograph.bandlink'
local bandresolve = require 'cartograph.bandresolve'
local ts = require 'cartograph.providers.treesitter'

local name = arg[1]
if not name then print('usage: retceil <corpus>'); os.exit(2) end
local data = bench.extract(name)
local band_of = ports.default_band_of(3)
local surf = ports.surface(data, band_of)
local idx = bandlink.indexes(data, band_of)
local chains = bandlink.chains(data)
local witness = bandresolve.tail_witness(data, ts.lang_of)

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

-- callidx: (file, at.start.line, at.start.char) -> call, mirroring resolve_returns' index
-- so a call's c.rt = {r, c} finds its DETERMINING call.
local callidx = {}
for _, c in ipairs(data.calls or {}) do
    if c.file and c.at and c.at.start then
        callidx[c.file .. '\31' .. c.at.start.line .. '\31' .. c.at.start.char] = c
    end
end

local function methodsep(clang)
    local sp = ts.spec and ts.spec[clang]
    return (sp and sp.methodsep) or '::'
end

local miss, miss_rt, det_unres, rt_noret, rt_ret = 0, 0, 0, 0, 0
local recovered, wrong, ret_unres = 0, 0, 0
local rec_xband, rec_inband = 0, 0
local wrong_ex = {}

for _, c in ipairs(data.calls or {}) do
    if c.to and c.file then
        local t = node_index[c.to]
        if t and t.file and not t.external then
            local clang = ts.lang_of(c.file)
            local sb = band_of(c.file)
            local key0 = c.full or c.callee
            local got0 = bandresolve.resolve_call(key0, sb, idx, surf.const_index, chains, witness, clang, ts.lang_of, bandlink)
            if got0 == nil then -- the f2gate MISS residual
                miss = miss + 1
                local crt = c.rt
                if not crt then
                    -- not a return-chain miss (other cause: ambiguous/no-const/alias)
                else
                    miss_rt = miss_rt + 1
                    local det = callidx[c.file .. '\31' .. crt.r .. '\31' .. crt.c]
                    local dnode = det and det.to and node_index[det.to]
                    if not dnode then
                        det_unres = det_unres + 1
                    else
                        local ret = dnode.ret
                        -- generic Class<T>: the concrete return is the class-literal arg
                        if dnode.retclass and det.args and det.args[dnode.retclass] then
                            local a = det.args[dnode.retclass]
                            if a.k == 'class' and a.v then ret = a.v end
                        end
                        if not ret then
                            rt_noret = rt_noret + 1
                        else
                            rt_ret = rt_ret + 1
                            local key = ret .. methodsep(clang) .. (c.callee or '')
                            local got = bandresolve.resolve_call(key, sb, idx, surf.const_index, chains, witness, clang, ts.lang_of, bandlink)
                            if got == c.to then
                                recovered = recovered + 1
                                if band_of(t.file) == sb then rec_inband = rec_inband + 1
                                else rec_xband = rec_xband + 1 end
                            elseif got ~= nil then
                                wrong = wrong + 1
                                if #wrong_ex < 8 then wrong_ex[#wrong_ex + 1] =
                                    ('%s (ret %s) → %s vs whole %s'):format(tostring(c.callee), tostring(ret), got, c.to) end
                            else
                                ret_unres = ret_unres + 1
                            end
                        end
                    end
                end
            end
        end
    end
end

local function pc(x, d) return d > 0 and 100 * x / d or 0 end
print(('retceil %s — %d cross-band-federated MISS residual (f2gate)'):format(name, miss))
print(('  return-chain MISS (carry c.rt): %d (%.1f%% of miss)'):format(miss_rt, pc(miss_rt, miss)))
print(('    determining target has a RET: %d · no-ret (undeclared/dynamic): %d · det-unresolved: %d')
    :format(rt_ret, rt_noret, det_unres))
print(('  ==> RET-RECOVERABLE: %d  = %.1f%% of ALL miss · %.1f%% of return-chain miss  [xband %d · in-band %d]')
    :format(recovered, pc(recovered, miss), pc(recovered, miss_rt), rec_xband, rec_inband))
print(('  would-be-WRONG (ret-keyed → different target): %d   ret-known-but-unresolved: %d')
    :format(wrong, ret_unres))
for _, e in ipairs(wrong_ex) do print('  WRONG-ex ' .. e) end
vim.cmd('qall!')
