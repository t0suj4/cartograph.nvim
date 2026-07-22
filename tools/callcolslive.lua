-- callcolslive — the LIVE-PATH parity gate for config.callcols_store (record-fold
-- arc, brick 3, [[cartograph-record-fold-arc]]). tools/callgate.lua checks the
-- columnar view over the PROVIDER output (pre-fold records); this checks the
-- WHOLE store pipeline: ingest a corpus with the flag OFF vs ON — the folds
-- (argv/at/df/flow), the index rebuild, the analyses — and assert the derived
-- products are IDENTICAL. The flag-on path runs every consumer against the
-- columnar store through the proxy seam, so an identical census + a clean
-- validate is end-to-end proof the swap is behaviour-faithful on real code.
--
--   nvim --headless -u NONE -l tools/callcolslive.lua <corpus>
-- Exit 1 on any divergence, 2 if not applicable.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/callcolslive%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local store = require 'cartograph.store'
local census = require 'cartograph.census'
local callrec = require 'cartograph.callrec'
local config = require 'cartograph.config'

local name = arg and arg[1]
if not name then print('usage: callcolslive <corpus>'); os.exit(2) end
local ok = pcall(bench.corpus, name)
if not ok then print('unknown corpus: ' .. name); os.exit(2) end

-- the full call inventory as a sorted multiset of logical tuples — the direct
-- faithfulness signal (every consumer read of the core call fields must agree).
local function call_tuples(data)
    local t = {}
    for _, c in callrec.each(data) do
        t[#t + 1] = table.concat({ tostring(callrec.fn(c)), tostring(callrec.callee(c)),
            tostring(callrec.full(c)), tostring(callrec.to(c)), tostring(callrec.prov(c)),
            tostring(callrec.line(c)), callrec.method(c) and 'm' or '-' }, '|')
    end
    table.sort(t)
    return t
end

-- ingest a FRESH extract under `flag`, return the derived products to compare.
-- Toggles ALL THREE columnar stores (calls + nodes + edges) so this validates the
-- whole columnar graph end to end: an identical census + call inventory with every
-- consumer reading calls/nodes/edges through the proxy stores is behaviour proof.
local function run(flag)
    config.callcols_store = flag
    config.nodecols_store = flag
    config.edgecols_store = flag
    local data = bench.extract(name)      -- fresh records each time (ingest mutates)
    store.ingest(data)
    return {
        census = table.concat(census.report(store.data), '\n'),
        tuples = call_tuples(store.data),
        ncalls = #(store.data.calls or {}),
        wrapped = store._callcols ~= nil and store._nodecols ~= nil and store._edgecols ~= nil,
    }
end

local off = run(false)
local on = run(true)
config.callcols_store, config.nodecols_store, config.edgecols_store = false, false, false

print(('callcolslive %s — %d calls (off) / %d calls (on), on.wrapped=%s')
    :format(name, off.ncalls, on.ncalls, tostring(on.wrapped)))

local fails = {}
if not on.wrapped then fails[#fails + 1] = 'flag-on did NOT install the columnar store (M._callcols nil)' end
if off.ncalls ~= on.ncalls then fails[#fails + 1] = ('call count moved %d -> %d'):format(off.ncalls, on.ncalls) end
-- the direct call-inventory diff (first divergence shown)
if #off.tuples ~= #on.tuples then
    fails[#fails + 1] = ('call tuple count moved %d -> %d'):format(#off.tuples, #on.tuples)
else
    for i = 1, #off.tuples do
        if off.tuples[i] ~= on.tuples[i] then
            fails[#fails + 1] = ('call tuple diverged at #%d:\n      off: %s\n      on:  %s')
                :format(i, off.tuples[i], on.tuples[i])
            break
        end
    end
end
if off.census ~= on.census then
    fails[#fails + 1] = 'census DIVERGED (off vs on) — a consumer reads the columnar store differently'
    print('  --- census OFF ---'); print(off.census)
    print('  --- census ON ---'); print(on.census)
end

if #fails > 0 then
    print('FAIL:')
    for _, f in ipairs(fails) do print('  - ' .. f) end
    vim.cmd('cquit 1')
else
    print('OK — flag-on is behaviour-identical to flag-off (census + call inventory), store installed')
    vim.cmd('qall!')
end
