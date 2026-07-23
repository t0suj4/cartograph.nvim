-- indexonly — gate + measure the INDEX-ONLY front-end ([[cartograph-thin-index]] M.index_only).
-- FAITHFULNESS: the thin index's node set must equal a FULL extract's SOURCE def nodes (same
-- id/kind/name/file) — resolution-minted externals (n.external, e.g. zig-std::…) are excluded,
-- they're resolution artifacts not source defs. index_only must also carry NO calls / df / flow.
-- COST: time + resident memory, index_only vs full (the 7-11x/62-106x leap the probe measured).
--
--   nvim --headless -u NONE -l tools/indexonly.lua [corpus]   (default: jquery)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ts = require 'cartograph.providers.treesitter'

local name = arg[1] or 'jquery'
local hr = vim.uv.hrtime
local function mb() collectgarbage(); collectgarbage(); return collectgarbage('count') / 1024 end

-- signature of a SOURCE def node (exclude resolution-minted externals + the module roster)
local function sigset(data)
    local s, n = {}, 0
    for _, node in ipairs(data.nodes or {}) do
        if not node.external and not node.unparsed then
            s[node.id] = (node.kind or '?') .. '\31' .. (node.name or '') .. '\31' .. (node.file or '')
            n = n + 1
        end
    end
    return s, n
end

-- === FULL extract ===
local b0 = mb(); local t0 = hr()
local full = bench.extract(name)
local t_full, m_full = (hr() - t0) / 1e6, mb() - b0
local root = full.root
local fsig, fn = sigset(full)
full = nil

-- === INDEX-ONLY ===
local b1 = mb(); local t1 = hr()
local idx = ts.index_only(root)
local t_idx, m_idx = (hr() - t1) / 1e6, mb() - b1
local isig, ineq = sigset(idx)

-- no calls / df / flow in the thin index
local ncalls = #(idx.calls or {})
local ndf, nflow = 0, 0
for _, node in ipairs(idx.nodes or {}) do
    if node.df or node._df then ndf = ndf + 1 end
    if node.flow or node._flow then nflow = nflow + 1 end
end

-- diff the def-node signatures
local missing, extra, changed = 0, 0, 0
local first = {}
for id, sg in pairs(fsig) do
    if not isig[id] then missing = missing + 1; if #first < 5 then first[#first+1] = 'MISSING ' .. id end
    elseif isig[id] ~= sg then changed = changed + 1; if #first < 5 then first[#first+1] = 'CHANGED ' .. id end end
end
for id in pairs(isig) do if not fsig[id] then extra = extra + 1; if #first < 5 then first[#first+1] = 'EXTRA ' .. id end end end

print(('indexonly %s'):format(name))
print(('  FULL      %8.0f ms  %8.1f MB  — %d source-def nodes'):format(t_full, m_full, fn))
print(('  INDEX     %8.0f ms  %8.1f MB  — %d nodes  (calls %d, df %d, flow %d)')
    :format(t_idx, m_idx, ineq, ncalls, ndf, nflow))
print(('  ==> %.1fx faster, %.1fx lighter'):format(t_idx > 0 and t_full / t_idx or 0, m_idx > 0 and m_full / m_idx or 0))
print(('  faithfulness: %d missing · %d extra · %d changed'):format(missing, extra, changed))
for _, s in ipairs(first) do print('    ' .. s) end

if missing == 0 and extra == 0 and changed == 0 and ncalls == 0 and ndf == 0 and nflow == 0 then
    print('OK — thin index == full extract\'s source def set, and carries no calls/df/flow')
    vim.cmd('qall!')
else
    print('FAIL — thin index diverges from the full def set, or carries deferred data')
    vim.cmd('cquit 1')
end
