-- INVARIANTS THAT ATTACK THEMSELVES, headless (CART-0285).
--
--   nvim --headless -u NONE -l tools/invariants.lua <corpus|path> <fn-name|file:line>
--        [--fill <id>=<value>@<basis>]... [--cap N] [--force]
--
-- A survey, so it is a TOOL rather than a command — the same shape as ablate, pathsat, holecensus
-- and answerkey. It proposes invariants from a run and then ATTACKS them along every axis that run
-- did not vary, which is where a wrong invariant hides.
--
-- EXIT CODE: 0 when the survey completed, 1 when it REFUTED at least one candidate (the finding
-- worth reacting to), 2 on a refusal. A refutation is not an error — it is the tool working — but a
-- caller that wants to notice one should not have to parse prose.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local inv = require 'cartograph.invariant'
local at = require 'cartograph.at'

local argv = arg or {}
local target, subject = argv[1], argv[2]
local fills, cap, force = {}, nil, false
local i = 3
while i <= #argv do
    local a = argv[i]
    if a == '--cap' then i = i + 1; cap = tonumber(argv[i])
    elseif a == '--force' then force = true
    elseif a == '--fill' then
        i = i + 1
        local spec = argv[i] or ''
        local id, rest = spec:match('^(.-)=(.*)$')
        local value, basis = (rest or ''):match('^(.-)@(.*)$')
        if not (id and value and basis) then
            print(('invariants: --fill needs <id>=<value>@<basis>, got %q'):format(spec))
            os.exit(2)
        end
        fills[id] = { value = value, basis = basis, by = 'agent' }
    else print('invariants: unknown argument ' .. a); os.exit(2) end
    i = i + 1
end
if not (target and subject) then
    print('usage: tools/invariants.lua <corpus|path> <fn-name|file:line>'
        .. ' [--fill <id>=<value>@<basis>] [--cap N] [--force]')
    os.exit(2)
end
local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) == 0 then print('not a directory: ' .. root); os.exit(2) end
local data = ts.extract(root); data.root = data.root or root
store.ingest(data)

local id
local file, line = subject:match('^(.+):(%d+)$')
if file and line then
    id = require('cartograph.characterize').at(store, file, tonumber(line))
else
    local hits = {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.name == subject and (n.kind == 'function' or n.kind == 'method') then
            hits[#hits + 1] = n
        end
    end
    -- AMBIGUITY IS REFUSED, not resolved by first-match: surveying the wrong function silently is
    -- worse than surveying nothing.
    if #hits > 1 then
        print(('invariants: %d functions are named %s — pass file:line:'):format(#hits, subject))
        for _, n in ipairs(hits) do
            print(('    %s:%d'):format(n.file, n.range and (at.sl(n.range) + 1) or 0))
        end
        os.exit(2)
    end
    id = hits[1] and hits[1].id
end
if not id then print('invariants: no such function: ' .. subject); os.exit(2) end

local res, why = inv.survey(store, id, { fills = fills, cap = cap, force = force })
if not res then print('invariants: refused — ' .. tostring(why)); os.exit(2) end
for _, l in ipairs(inv.report(res)) do print(l) end
if #res.refuted > 0 then os.exit(1) end
