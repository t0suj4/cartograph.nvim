-- CART-0999: the near index's candidate generation drops a function whose EVERY row key
-- is shared with more than POST_CAP others — and says nothing, because absence and "no
-- near-clone" render identically.
--
-- ★★★ THE HOLE IS ANTI-CORRELATED WITH GENERICITY. A small general-purpose helper is MADE
-- of the commonest row shapes, so being the kind of thing worth de-duplicating is exactly
-- what hides it. `tools/variants.lua` states the same inversion for similarity search.
--
-- THE WITNESS IS OUR OWN: `untangle.range_contains` and `hoistclosure.contains` are
-- byte-identical but for one free name, and the near tier could not see them.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

-- a tiny generic predicate, duplicated in two files with ONE name differing — plus enough
-- NOISE functions sharing its row shapes to push every one of its keys over POST_CAP (30).
local function noise(i)
    return ('local function noise%d(p, q)\n  if not (p and q) then return false end\n'
        .. '  if p.a > q.a or p.b < q.b then return false end\n'
        .. '  if p.a == q.a and p.c > q.c then return false end\n'
        .. '  if p.b == q.b and p.d < q.d then return false end\n'
        .. '  return true\nend\n'):format(i)
end
local BODY = [[
local function %s(outer, inner)
  if not (outer and inner) then return false end
  if %s.sl(outer) > %s.sl(inner) or %s.el(outer) < %s.el(inner) then return false end
  if %s.sl(outer) == %s.sl(inner) and %s.sc(outer) > %s.sc(inner) then return false end
  if %s.el(outer) == %s.el(inner) and %s.ec(outer) < %s.ec(inner) then return false end
  return true
end
]]
-- ⚠ `table.unpack or unpack` ONCE, AND NEVER INSIDE AN `and`/`or`: that expression
-- TRUNCATES A MULTIPLE RETURN TO ONE VALUE, so `format` got the alias once and nil
-- twelve times. `algebra.lua` carries this exact warning; it is the sixth time in this
-- arc, and the first where the warning was already written down in the file next door.
local tunpack = table.unpack or unpack
local function copy(name, alias)
    local a = {}
    for i = 1, 13 do a[i] = alias end
    return BODY:format(name, tunpack(a))
end

local function proj(nnoise)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local pad = {}
    for i = 1, nnoise do pad[#pad + 1] = noise(i) end
    local common = table.concat(pad, '\n')
    local f1 = assert(io.open(root .. '/one.lua', 'w'))
    f1:write('local at = require "at"\n\n' .. copy('contains', 'at') .. '\n' .. common)
    f1:close()
    local f2 = assert(io.open(root .. '/two.lua', 'w'))
    f2:write('local at_mod = require "at"\n\n' .. copy('range_contains', 'at_mod') .. '\n')
    f2:close()
    store.ingest(ts.extract(root))
    return root
end
local function fn_id(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name and n.name:match('[%w_]+$') == name
            and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

test('★★★ a duplicated GENERIC helper is found — the shapes that hide it are the common ones', function ()
    if not ready() then return end
    -- 40 noise functions put every row key of the pair over POST_CAP = 30
    proj(40)
    local hits = clones.near_of(store, fn_id('contains'), { max_dist = 3 }) or {}
    local found
    for _, p in ipairs(hits) do
        if (p.a.name or ''):match('range_contains') or (p.b.name or ''):match('range_contains') then
            found = p
        end
    end
    ok(found, 'the near tier relates the two copies at DEFAULT settings')
    if not found then return end
    -- ★ and the analysis is right about them: a clean value fold with one hole
    local a = clones.analyze_pair(found, store)
    eq('value', a.kind)
    eq(1, #a.holes)
    eq('name', a.holes[1].kind)
end)

test('index_blindspot NAMES who the index cannot see, and the cap each would need', function ()
    if not ready() then return end
    proj(40)
    local b = clones.index_blindspot(store)
    ok(b.total > 0, 'it counts the indexed functions')
    -- ⚠ THE DIAGNOSTIC IS THE POINT, NOT THE NUMBER. A function absent from candidate
    -- generation is indistinguishable from one with no near-clone; this is the only
    -- thing that tells them apart.
    ok(type(b.blind_ids) == 'table', 'and lists them')
    for _, id in ipairs(b.blind_ids) do
        -- `needed` is the cap at which it becomes visible, or nil when no key is shared
        -- with anyone at any cap — a REAL answer, not a missing one.
        local n = b.needed[id]
        ok(n == nil or n > 30, ('a blind function needs a cap above POST_CAP, got %s')
            :format(tostring(n)))
    end
end)

test('the floor does not widen a function that already had candidates', function ()
    if not ready() then return end
    -- ⚠ THE PAIR SET MUST BE A SUPERSET, NOT A DIFFERENT SET. With no noise, every key is
    -- rare, nothing is blind, and the rescue must therefore change nothing at all.
    proj(0)
    local b = clones.index_blindspot(store)
    local hits = clones.near_of(store, fn_id('contains'), { max_dist = 3 }) or {}
    ok(#hits >= 1, 'the pair is found without any rescue at all')
    for _, id in ipairs(b.blind_ids) do
        ok(not id:match('contains'), 'and neither copy is blind here: ' .. id)
    end
end)
