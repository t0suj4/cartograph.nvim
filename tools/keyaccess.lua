-- THE KEY-ACCESS CENSUS (per-corpus CLI).
--   nvim --headless -u NONE -l tools/keyaccess.lua <corpus> [--sites N]
--
-- CART-0504's MEASURE-FIRST GATE. cartograph.keyaccess DERIVES which functions
-- turn a string argument into a variable access, from those functions' own
-- bodies, and resolves their literal call sites to var nodes. Nothing is minted:
-- this reports what minting WOULD claim, so the decision to put derived reads in
-- the graph is taken with the numbers in hand rather than on the strength of the
-- idea.
--
-- WHAT TO READ IN THE OUTPUT, in order of what would kill the design:
--   AMBIGUOUS > 0 with no explanation -- a derived name with several bearers.
--       Resolved to nothing here; if minting ever picks one it repeats CART-0505.
--   NO NODE -- the derived name names nothing. Expected to be nonzero and to
--       overlap CART-0490 (an option backed by `define()` has no var node), but
--       a large unexplained share means the transform is wrong.
--   ALREADY HAD EDGES -- a derived read landing on a var that already has use
--       edges. Small is right (these vars are invisible by construction); large
--       means the roster is re-finding syntactic reads and the yield is inflated.
--   DYNAMIC -- a call whose key argument is not a literal. An honest frontier,
--       and the number that makes the roster a stated LOWER BOUND.
--   OPAQUE -- a function that touches the global table and could not be reduced,
--       with the reason. This is the derivation refusing rather than guessing.
--
-- A CONTROL IS PART OF THE RUN, not an afterthought: a corpus with no
-- string-keyed accessor must derive ZERO accessors. A census that finds
-- something everywhere is measuring its own pattern-matching.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/keyaccess%.lua$')
local bench = dofile(here .. '/bench.lua')

local name = arg and arg[1]
local nsites = 12
for i = 2, #(arg or {}) do
    if arg[i] == '--sites' then nsites = tonumber(arg[i + 1]) or nsites end
end
if not name then
    print('usage: nvim --headless -u NONE -l tools/keyaccess.lua <corpus> [--sites N]')
    os.exit(2)
end

bench.bootstrap()
local store = require 'cartograph.store'
local keyaccess = require 'cartograph.keyaccess'

local data = bench.extract(name)
store.ingest(data)

local accs, opaque = keyaccess.accessors(store)
local sites, st = keyaccess.sites(store, accs)

local nacc, ndirect = 0, 0
local order = {}
for id, sig in pairs(accs) do
    nacc = nacc + 1
    if sig.via == 'direct' then ndirect = ndirect + 1 end
    order[#order + 1] = { id = id, sig = sig }
end
table.sort(order, function (a, b) return a.id < b.id end)

print(('\n== ACCESSORS DERIVED (%s) =='):format(name))
if nacc == 0 then
    print('  (none — no function reduces a global-table key to a parameter)')
end
for _, e in ipairs(order) do
    local s = e.sig
    print(('  %-56s arg%d  %s<key>%s  %s  %s')
        :format(e.id, s.param, s.prefix ~= '' and ('"' .. s.prefix .. '"..') or '',
            s.suffix ~= '' and ('.."' .. s.suffix .. '"') or '',
            s.rw == 'w' and 'WRITE' or (s.rw == 'rw' and 'read+write' or 'read '),
            s.via == 'direct' and 'derived from its own body'
                or ('forwards to ' .. (s.from or '?'))))
end

local nop = 0
local ops = {}
for id, why in pairs(opaque) do nop = nop + 1; ops[#ops + 1] = id .. '  ' .. why end
table.sort(ops)
if nop > 0 then
    print(('\n== OPAQUE: touches the global table, NOT reduced (%d) =='):format(nop))
    for i = 1, math.min(#ops, 10) do print('  ' .. ops[i]) end
    if #ops > 10 then print(('  … %d more'):format(#ops - 10)) end
end

print('\n== CALL SITES ==')
print(('  calls to an accessor        %6d'):format(st.calls))
print(('    key is a LITERAL         %6d'):format(st.calls - st.dynamic))
print(('    key is DYNAMIC           %6d   <- the roster is a lower bound')
    :format(st.dynamic))
print(('  resolved to ONE var        %6d'):format(st.unique))
print(('    of which already had edges %4d   <- overlap; small is right')
    :format(st.had_edges))
print(('  AMBIGUOUS (>1 bearer)      %6d   resolved to nothing (CART-0505)')
    :format(st.ambiguous))
print(('  derived name has NO NODE   %6d   overlaps CART-0490')
    :format(st.nonode))
print(('  BLOCKED by the language     %6d   no global_scope_vars guarantee')
    :format(st.blocked))

local uniq = 0
for _ in pairs(st.names) do uniq = uniq + 1 end
print(('  DISTINCT vars reached      %6d'):format(uniq))

if nsites > 0 and #sites > 0 then
    print(('\n== SAMPLE SITES (%d of %d) =='):format(math.min(nsites, #sites), #sites))
    for i = 1, math.min(nsites, #sites) do
        local s = sites[i]
        print(('  %s:%d  %s -> %s'):format(s.file, (s.line or 0) + 1,
            s.fn or '(file scope)', s.var))
    end
end

local amb = {}
for n, k in pairs(st.ambiguous_names) do amb[#amb + 1] = ('%s (%d bearers)'):format(n, k) end
table.sort(amb)
if #amb > 0 then
    print('\n== AMBIGUOUS NAMES ==')
    for i = 1, math.min(#amb, 10) do print('  ' .. amb[i]) end
    if #amb > 10 then print(('  … %d more'):format(#amb - 10)) end
end

local nn = {}
for n, k in pairs(st.nonode_names) do nn[#nn + 1] = { n = n, k = k } end
table.sort(nn, function (a, b) return a.k > b.k end)
if #nn > 0 then
    print('\n== TOP NAMES WITH NO NODE (is the transform right?) ==')
    for i = 1, math.min(#nn, 10) do print(('  %-40s %d sites'):format(nn[i].n, nn[i].k)) end
end
print('')
