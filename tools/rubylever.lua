-- rubylever — decompose the rails corpus's UNRESOLVED calls to decide the real
-- next lever: is the win RECEIVER-TYPING (x = Model.find; x.m → Model#m, needs a
-- typed local receiver + the target method DEFINED locally) or VOCABULARY (bare
-- Rails DSL class methods with no local def)? levers.lua said vocab dominates;
-- this confirms by tallying unresolved callees by receiver-shape + top names.
--
--   nvim --headless -u NONE -l tools/rubylever.lua [rails]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'

local name = arg[1] or 'rails'
local data = bench.extract(name)

-- classify each call
local unresolved, resolved = 0, 0
local by_recv = {}          -- receiver-shape bucket -> count (unresolved only)
local recv_local_names = {} -- unresolved calls WITH a lowercase-local receiver: callee tally
local vocab_names = {}      -- unresolved calls with NO receiver (bare): callee tally
local FINDER = { find=1, find_by=1, first=1, last=1, create=1, ['create!']=1,
    build=1, new=1, find_or_create_by=1, find_or_initialize_by=1 }
local RELATION = { where=1, all=1, order=1, includes=1, joins=1, select=1, distinct=1, limit=1 }
local finder_bindings = 0   -- calls that ARE a finder (x = Model.find style, class-recv)

local function bump(t, k) t[k] = (t[k] or 0) + 1 end

for _, c in ipairs(data.calls or {}) do
    if c.to then resolved = resolved + 1 else
        unresolved = unresolved + 1
        local recv = c.recv           -- ruby recv_local (lowercase local receiver)
        local rk = recv and 'local-recv' or (c.recv_const and 'const-recv' or 'bare/other')
        bump(by_recv, rk)
        if recv then bump(recv_local_names, c.callee or '?') end
        if not recv then bump(vocab_names, c.callee or '?') end
        if FINDER[c.callee or ''] or RELATION[c.callee or ''] then
            finder_bindings = finder_bindings + 1
        end
    end
end

local function top(t, n)
    local arr = {}
    for k, v in pairs(t) do arr[#arr + 1] = { k, v } end
    table.sort(arr, function (a, b) return a[2] > b[2] end)
    local out = {}
    for i = 1, math.min(n, #arr) do out[#out + 1] = ('    %-22s %d'):format(arr[i][1], arr[i][2]) end
    return out
end

print(('rubylever %s — %d calls, %d resolved (%.1f%%), %d unresolved')
    :format(name, resolved + unresolved, resolved, 100 * resolved / (resolved + unresolved), unresolved))
print('  unresolved by receiver shape:')
for k, v in pairs(by_recv) do print(('    %-14s %d'):format(k, v)) end
print(('  ORM finder/relation call SITES (any recv): %d'):format(finder_bindings))
print('  top unresolved callees WITH a local receiver (the receiver-typing lever):')
for _, l in ipairs(top(recv_local_names, 20)) do print(l) end
print('  top unresolved BARE callees (the vocabulary lever):')
for _, l in ipairs(top(vocab_names, 25)) do print(l) end
