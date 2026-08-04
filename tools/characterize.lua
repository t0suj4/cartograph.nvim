-- CHARACTERIZE, HEADLESS — the agent entry point for CART-0262. No nvim session, no
-- cockpit, no live store: extract → plan → emit, and EXIT NONZERO WHILE HOLES REMAIN,
-- because a nonzero exit is how an agent learns it is not done
-- ([[cartograph-apply-for-agent]]).
--
--   nvim --headless -u NONE -l tools/characterize.lua <root> <fn-name|file:line>
--        [--write] [--dir <d>] [--fill <id>=<value>@<basis>]...
--
-- --write stages nothing and asks nothing: it writes through txn (journal + CAS +
-- a load gate on our own output), which is the same ladder every write verb rides.
-- Without it the spec goes to stdout, which is the mode to use when reading.
--
-- WHY THE EXIT CODE IS THE INTERFACE. The spec itself errors on an unfilled hole, so
-- running it tells you. But an agent that has just GENERATED one needs the same answer
-- before it runs anything, and "0 holes" is the only success this verb has: a spec full
-- of holes is a correct artifact and an incomplete answer. 0 = ready to run, 1 = holes
-- remain, 2 = refused (with the reason on stdout).
--
-- --fill TAKES A BASIS, and the syntax makes it unskippable: `id=value@basis`. A value
-- with no stated basis is a guess wearing an answer's clothes, so characterize.fill
-- refuses it, and this driver cannot express one. The ORACLE hole additionally refuses
-- any channel but a RUN or a SPEC — a predicted expected value makes a test that passes
-- because the prediction matched the prediction (CART-0263 is the run).

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local ch = require 'cartograph.characterize'

local argv = arg or {}
local target, subject, write, dir = argv[1], argv[2], false, nil
local fills = {}
local i = 3
while i <= #argv do
    local a = argv[i]
    if a == '--write' then write = true
    elseif a == '--dir' then i = i + 1; dir = argv[i]
    elseif a == '--fill' then
        i = i + 1
        local spec = argv[i] or ''
        local id, rest = spec:match('^(.-)=(.*)$')
        local value, basis = (rest or ''):match('^(.-)@(.*)$')
        if not (id and value and basis) then
            print(('characterize: --fill needs <id>=<value>@<basis>, got %q'):format(spec))
            os.exit(2)
        end
        -- `by` rides on the basis prefix (`run:`/`spec:`) so the CHANNEL is explicit;
        -- anything else is an agent-supplied value and is tiered as one.
        local by = basis:match('^(run):') or basis:match('^(spec):') or 'agent'
        fills[id] = { value = value, basis = basis, by = by }
    else print('characterize: unknown argument ' .. a); os.exit(2) end
    i = i + 1
end
if not (target and subject) then
    print('usage: tools/characterize.lua <root> <fn-name|file:line> [--write]'
        .. ' [--dir <d>] [--fill <id>=<value>@<basis>]')
    os.exit(2)
end

local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) == 0 then
    print('characterize: not a directory: ' .. root)
    os.exit(2)
end
local data = ts.extract(root)
data.root = data.root or root
store.ingest(data)

-- BY NAME or by file:line, and the two are not interchangeable: a name can be ambiguous
-- across files, so an ambiguous one is REFUSED with the candidates rather than resolved
-- by first-match, which is how a driver silently characterizes the wrong function.
local id
local file, line = subject:match('^(.+):(%d+)$')
if file and line then
    id = ch.at(store, file, tonumber(line))
    if not id then
        print(('characterize: no function encloses %s:%s'):format(file, line))
        os.exit(2)
    end
else
    local hits = {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.name == subject and (n.kind == 'function' or n.kind == 'method') then
            hits[#hits + 1] = n
        end
    end
    if #hits == 0 then
        print('characterize: no function named ' .. subject)
        os.exit(2)
    elseif #hits > 1 then
        print(('characterize: %d functions are named %s — pass file:line instead:')
            :format(#hits, subject))
        for _, n in ipairs(hits) do print('    ' .. n.file .. ':' .. (n.range and
            (require('cartograph.at').sl(n.range) + 1) or '?')) end
        os.exit(2)
    end
    id = hits[1].id
end

local plan, why = ch.plan(store, id, { dir = dir })
if not plan then
    print('characterize: refused — ' .. tostring(why))
    os.exit(2)
end
if next(fills) then
    local n, ferr = ch.fill(plan, fills)
    if not n then
        print('characterize: fill refused — ' .. tostring(ferr))
        os.exit(2)
    end
    print(('characterize: %d hole(s) filled'):format(n))
end

for _, l in ipairs(ch.report(plan)) do print(l) end

if write then
    local entry, aerr = ch.apply(store, plan)
    if not entry then
        print('characterize: write refused — ' .. tostring(aerr))
        os.exit(2)
    end
    print(('  WROTE %s/%s (journalled; :CartographUndo reverts it)'):format(root,
        plan.path))
else
    print('')
    print('-- the spec (pass --write to commit it through txn):')
    print(table.concat(ch.emit(plan), '\n'))
end

-- THE EXIT CODE IS THE ANSWER, and 0 means "runnable", not "written". A caller that
-- treats a hole-carrying spec as done has built exactly the false coverage the whole
-- arc exists to prevent.
if (plan.unfilled or 0) > 0 then
    print(('characterize: %d hole(s) UNFILLED — the spec will ERROR until they are'
        .. ' answered'):format(plan.unfilled))
    os.exit(1)
end
print('characterize: no holes remain — the spec is runnable')
