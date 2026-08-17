-- The dev loop's WARM extract (CART-0429) — tools/bench.lua.
--
-- ★★ WHY THIS IS GATED AT ALL. `bench.extract` is COLD by design: a gate must never verify
-- a cached artifact, and CART-0245 is the proof it matters — a warm zig graph once carried
-- 4122 edges into nodes that were never saved while the `valid` column stayed green. Warm
-- is therefore opt-in, and every property that keeps it safe is a claim someone can break
-- later without any other spec noticing: the cold default, the `cold` override winning over
-- the environment, and the refusal to let a NON-CANONICAL extract touch the corpus cache.
--
-- ★ EACH ASSERTION BELOW HAS A STATED RED CONDITION, because a green spec is not evidence
-- until you know what would make it red. The cache is redirected to a scratch dir for the
-- whole file (as tools/matrix.lua's `cache` column does) so a test run never reads or
-- writes the developer's real cache.

local bench = dofile('tools/bench.lua')
bench.bootstrap()

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

-- a two-file lua corpus in a temp root
local function corpus()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local a = assert(io.open(root .. '/a.lua', 'w'))
    a:write('local M = {}\nfunction M.f(t)\n  local x = t.k\n  return x\nend\nreturn M\n')
    a:close()
    local b = assert(io.open(root .. '/b.lua', 'w'))
    b:write('local A = require "a"\nlocal B = {}\nfunction B.g(z)\n  return A.f(z)\nend\n'
        .. 'return B\n')
    b:close()
    return root
end

--- run `f` with the cache redirected into a scratch dir, then clean up
local function with_scratch_cache(f)
    local cache = require 'cartograph.cache'
    local realpath = cache.path
    local scratch = vim.fn.tempname() .. '.benchcache'
    local base = vim.fn.stdpath('cache') .. '/cartograph'
    cache.path = function (root)
        local p, nroot = realpath(root)
        vim.fn.mkdir(scratch, 'p')
        return scratch .. p:sub(#base + 1), nroot
    end
    local ok, err = pcall(f)
    cache.path = realpath
    vim.fn.delete(scratch, 'rf')
    if not ok then error(err) end
end

local function counts(data)
    return ('%d/%d'):format(#(data.nodes or {}), #(data.edges or {}))
end

test('bench: extract is COLD by default and warm only when asked', function ()
    if not ready() then skip 'no lua parser' end
    with_scratch_cache(function ()
        local root = corpus()
        -- RED IF: a future change makes warm the default. Two cold runs in a row must both
        -- report cold even though the first one could have populated a cache.
        local _, s1 = bench.extract(root)
        local _, s2 = bench.extract(root)
        eq(false, s1.warm, 'first default extract is cold')
        eq(false, s2.warm, 'and so is the second — the default never writes or reads')
    end)
end)

test('bench: warm reuses the cache and serves an identical graph', function ()
    if not ready() then skip 'no lua parser' end
    with_scratch_cache(function ()
        local root = corpus()
        -- first warm run is necessarily COLD (nothing cached yet) and writes the cache
        local cold, s1 = bench.extract(root, { warm = true })
        eq(false, s1.warm, 'the first warm-requested run has nothing to reuse')
        -- RED IF: the save or the open breaks — this flips to false and the loop is back
        -- to re-extracting every time, silently, with results still correct.
        local hot, s2 = bench.extract(root, { warm = true })
        eq(true, s2.warm, 'the second warm-requested run is served from the cache')
        -- RED IF: the warm graph differs from the cold one at all. This is the property
        -- CART-0245 broke, and the reason the warm path validates before returning.
        eq(counts(cold), counts(hot), 'the warm graph has the cold graph\'s nodes and edges')
    end)
end)

test('bench: cold BEATS warm, so a gate cannot inherit warm from anywhere', function ()
    if not ready() then skip 'no lua parser' end
    with_scratch_cache(function ()
        local root = corpus()
        bench.extract(root, { warm = true })          -- populate
        eq(true, select(2, bench.extract(root, { warm = true })).warm, 'cache is populated')
        -- RED IF: the precedence is ever reversed or `cold` is dropped. This is the exact
        -- guarantee tools/gate.lua and tools/matrix.lua rely on when they pass `cold`.
        local _, s = bench.extract(root, { warm = true, cold = true })
        eq(false, s.warm, 'an explicit cold request wins over an explicit warm one')
    end)
end)

test('bench: a NON-CANONICAL extract never touches the corpus cache', function ()
    if not ready() then skip 'no lua parser' end
    with_scratch_cache(function ()
        local root = corpus()
        bench.extract(root, { warm = true })
        eq(true, select(2, bench.extract(root, { warm = true })).warm, 'cache is populated')
        -- ★ THE ONE THAT PROTECTS `--file`. A scoped extract holds a SUBSET of the corpus:
        -- reading the full cache would silently undo the scoping the caller just asked for,
        -- and writing it back would poison the cache for every later reader.
        -- RED IF: `files` leaves WARM_REFUSING — the scoped run would return the whole
        -- corpus while still printing SCOPED, which is worse than being slow.
        local sub, s = bench.extract(root, { warm = true, files = { 'a.lua' } })
        eq(false, s.warm, 'a scoped extract refuses the cache')
        local seen = {}
        for _, n in ipairs(sub.nodes or {}) do seen[n.file or '?'] = true end
        ok(seen['a.lua'], 'the scoped extract has the file it asked for')
        eq(nil, seen['b.lua'], 'and NOT the one it excluded — so it was really scoped')
    end)
end)
