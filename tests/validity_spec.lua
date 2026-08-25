-- WHEN MAY A DERIVED VALUE BE REUSED (validity.lua). The layer exists because the
-- same discipline was written nine times and five of those had NO validity key at
-- all. These tests cover the contract, then the two REAL bugs it closed — both
-- measured before the fix, not hypothesised.

local validity = require 'cartograph.validity'

test('validity: a memo with neither epoch nor stamp is REFUSED', function ()
    -- the whole point: a memo with no validity key is the bug, so it cannot be
    -- expressed rather than merely discouraged
    local ok1 = pcall(validity.memo, { name = 'x', compute = function () return 1 end })
    eq(false, ok1)
    -- ... and so is declaring both, which would leave the key ambiguous
    local ok2 = pcall(validity.memo, { name = 'x', epoch = 'e',
        stamp = function () return 's' end, compute = function () return 1 end })
    eq(false, ok2)
end)

test('validity: a STAMP-keyed memo recomputes exactly when the stamp moves',
    function ()
    local stamp, runs = 'a', 0
    local f = validity.memo { name = 't', stamp = function () return stamp end,
        compute = function (k) runs = runs + 1; return k .. ':' .. runs end }
    eq('x:1', f('x'))
    eq('x:1', f('x'))       -- reused
    eq(1, runs)
    stamp = 'b'
    eq('x:2', f('x'))       -- stamp moved -> recomputed
    eq(2, runs)
end)

-- a nil stamp means "cannot determine validity". Caching under that is exactly how
-- a stale value outlives its input, so it computes every time instead.
test('validity: a NIL stamp is never cached', function ()
    local runs = 0
    local f = validity.memo { name = 'n', stamp = function () return nil end,
        compute = function () runs = runs + 1; return runs end }
    eq(1, f('k')); eq(2, f('k')); eq(3, f('k'))
end)

test('validity: an EPOCH-keyed memo turns over on bump, and epochs are independent',
    function ()
    local runs = 0
    local f = validity.memo { name = 'e', epoch = 'testepoch',
        compute = function () runs = runs + 1; return runs end }
    eq(1, f('k')); eq(1, f('k'))
    validity.bump('otherepoch')
    eq(1, f('k'))                  -- an unrelated epoch does not disturb it
    validity.bump('testepoch')
    eq(2, f('k'))                  -- its own does
end)

test('validity: memo slots are per KEY', function ()
    local f = validity.memo { name = 'k', epoch = 'ke',
        compute = function (key) return 'v:' .. tostring(key) end }
    eq('v:a', f('a')); eq('v:b', f('b')); eq('v:a', f('a'))
    eq('v:nil', f(nil)) -- a nil key is a slot too, not a crash
end)

-- ── artifact contributors ────────────────────────────────────────────────────
-- The recurrence guard for the bug in 6bc1254: a declarative artifact began
-- shaping resolution while graph validity summed only file stamps, VERSION and the
-- profile. Contributors register themselves; cache.lua folds whatever registered.

test('validity: artifact_key folds contributors and is ORDER-STABLE', function ()
    validity.contribute('zzz_test', function () return 'Z' end)
    validity.contribute('aaa_test', function () return 'A' end)
    local k1 = validity.artifact_key()
    ok(k1:find('aaa_test=A', 1, true) < k1:find('zzz_test=Z', 1, true),
        'sorted by name, so load order cannot change the key: ' .. k1)
    -- an unstable key would invalidate every cache on every start, which is
    -- indistinguishable from having no cache at all
    eq(k1, validity.artifact_key())
    validity.contribute('zzz_test', function () return nil end)
    ok(not validity.artifact_key():find('zzz_test', 1, true),
        'a contributor returning nil contributes nothing')
end)

test('validity: the real artifact kinds are registered', function ()
    require 'cartograph.spec.profile'
    require 'cartograph.spec.ecosystem'
    local names = {}
    for _, n in ipairs(validity.contributors()) do names[n] = true end
    ok(names.profile, 'profile contributes to graph validity')
    ok(names.ecosystem, 'ecosystem contributes to graph validity')
end)

-- ── BUG 1: an edited artifact was stale for the rest of the session ──────────
-- Measured before the fix: profile.load cached forever and IGNORED the stamp it
-- publishes to others — so an edited profile returned the old table while cache.lua
-- recorded the NEW stamp in its manifest. A warm graph claimed a profile that
-- extraction never used. Two causes, and the second is the one that surprised me:
-- the loader cache AND Lua's own package.loaded, which returns the identical stale
-- table even after the memo correctly recomputes.
test('validity: an edited artifact is re-read, not served from either cache',
    function ()
    local prof = require 'cartograph.spec.profile'
    -- THE FILE WE STAMP MUST BE THE FILE THE LOADER READS (CART-0440). Resolve the
    -- artifact from the loader module's OWN source — the same `DIR` its stamp_of and
    -- load compute from — rather than naming a checkout. `stamp_of` and not `load`:
    -- load is a validity.memo CLOSURE, so its source is validity.lua, not this dir.
    -- Measured before the fix: with a fixed path, a run from a worktree loaded the
    -- running tree's artifact and stamped the OTHER tree's, so the stamp never moved
    -- and this test went red — while perturbing a checkout it was not testing.
    local dir = vim.fn.fnamemodify(debug.getinfo(prof.stamp_of, 'S').source:sub(2), ':p:h')
    local art = dir .. '/lua-factorio.lua'
    if vim.fn.filereadable(art) ~= 1 then skip 'profile artifact not present' end
    local p1 = prof.load('lua-factorio')
    ok(p1 ~= nil, 'loads')
    eq(p1, prof.load('lua-factorio')) -- stable while unchanged: the SAME table
    -- MOVE THE STAMP WITHOUT LEAVING THE TREE PERTURBED. mtime is what this project's
    -- cache validity keys on, so a permanent bump on a TRACKED artifact would
    -- invalidate this checkout's warm graph cache as a side effect of running the
    -- suite. Set it forward, observe the recompute, put it back. (fs_utime over
    -- `touch`: no subprocess, and an explicit offset — `touch` writes the current
    -- second, which does not move a stamp on a file already written this second.)
    local st0 = assert(vim.uv.fs_stat(art))
    local was = st0.mtime.sec + st0.mtime.nsec / 1e9
    local atime = st0.atime.sec + st0.atime.nsec / 1e9
    -- luv's sync fs calls RETURN nil+err, they do not raise: check the value
    if not vim.uv.fs_utime(art, atime, was + 5) then skip 'cannot set mtime here' end
    local p2 = prof.load('lua-factorio')
    vim.uv.fs_utime(art, atime, was)  -- restore BEFORE asserting, so a red test
                                      -- still leaves the artifact as it found it
    ok(p2 ~= nil and p1 ~= p2, 'a moved stamp yields a FRESH table')
    eq(1, p2.schema)                  -- ... and a valid one
    -- THE SIDE-EFFECT FENCE: the tree under test is left exactly as found. This is
    -- the half that made a parallel worktree run unsafe, not the red cell.
    eq(st0.mtime.sec, assert(vim.uv.fs_stat(art)).mtime.sec,
        'the artifact mtime is restored — a suite run mutates no tracked file')
end)

-- ── BUG 2: a tree that changed between extractions was invisible ─────────────
-- The per-root memos (package identity, addon/plugin layout) were memoized for the
-- session with no key, so adding a package left the identity map stale. A stamp is
-- not cheaply available — knowing whether the map is stale means statting every
-- candidate manifest, which is what computing it does — so they key on an epoch
-- bumped per extraction run. This drives the whole path: a cross-package require
-- that CANNOT resolve until the package appears.
test('validity: a second extraction sees a package added since the first',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/modA', 'p')
    local function w(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    w('modA/info.json', '{"name":"A","version":"1.0"}')
    -- a cross-package require in the __name__/path form
    w('modA/control.lua', "local lib = require '__B__/lib'\n"
        .. 'local function run() return lib.helper(1) end\nreturn { run = run }\n')

    local function resolves()
        local d = ts.extract(root)
        for _, e in ipairs(d.edges or {}) do
            if e.kind == 'import' and tostring(e.to):match('^modB/') then return true end
        end
        return false
    end

    eq(false, resolves()) -- package B does not exist yet
    -- ... now it does
    vim.fn.mkdir(root .. '/modB', 'p')
    w('modB/info.json', '{"name":"B","version":"1.0"}')
    w('modB/lib.lua', 'local function helper(x) return x + 1 end\n'
        .. 'return { helper = helper }\n')
    eq(true, resolves()) -- WAS FALSE: the identity map was memoized forever
    vim.fn.delete(root, 'rf')
end)
