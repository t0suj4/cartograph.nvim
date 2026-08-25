-- THE SUITE RUNS OUT OF THE TREE IT IS IN. A fence, not a feature.
--
-- CART-0440, measured: four specs named the author's own checkout instead of the
-- running one. Two consequences, and the second is the worse:
--   1. THE SUITE WAS NOT LOCATION-INDEPENDENT. `profile.load` resolves its artifact
--      through the RUNNING tree while the fixed path pointed elsewhere, so the file
--      a test stamped was not the file it loaded: 1780/1 from a worktree against
--      1780/0 from the main tree, same commit.
--   2. A RUN FROM ANY OTHER TREE MUTATED THE MAIN CHECKOUT. One spec `touch`ed a
--      TRACKED artifact there. Content unchanged, mtime not — and mtime is exactly
--      what this project's cache validity is keyed on, so a worktree suite could
--      invalidate the main tree's warm cache, and two workers running suites in
--      parallel perturbed each other through a file neither was working on.
-- That is what made tools/worktree.sh's isolation claim true of edits and FALSE of the
-- suite. It survived because nothing fenced it; this is the fence.
--
-- Scope is tests/ only. tools/ drivers legitimately name external corpora
-- (~/git/discourse, ~/git/zig) — they are dev drivers a human points at a corpus,
-- not a suite that must be green from any checkout.

-- Built by concatenation so this fence does not match ITSELF: the needles must not
-- appear contiguously in this file's own source.
local NEEDLES = {
    ['~/gi' .. 't/'] = 'a checkout under the home dir',
    ['/hom' .. 'e/'] = 'an absolute home path',
    ['/User' .. 's/'] = 'an absolute home path',
    ['cartograph.nvi' .. 'm/'] = 'a named checkout of this project',
}

-- the ONE allowed home-relative path: the treesitter parser install, which is a
-- machine-level dependency of nvim itself and read-only (every use is guarded by an
-- isdirectory check and skips when absent). It is not a checkout of this project.

--- Every CODE line of the suite, as (basename, lineno, text). Full-line comments are
--- skipped and that is deliberate, measured on the first run of this fence: it flagged
--- three comments, all of them provenance citing an external corpus by path
--- (luals_known_wrong's LESSONS.md, treesitter_spec's zig census, and this file's own
--- prose). A comment naming where a fixture CAME FROM is documentation; it makes
--- nothing location-dependent, because nothing reads it. What must be fenced is a path
--- the suite USES.
local function code_lines(fn)
    for _, path in ipairs(vim.fn.glob(repo('tests') .. '/*.lua', false, true)) do
        local fd = io.open(path, 'rb')
        if fd then
            local n = 0
            for line in fd:lines() do
                n = n + 1
                if not line:match('^%s*%-%-') then
                    fn(vim.fn.fnamemodify(path, ':t'), n, line)
                end
            end
            fd:close()
        end
    end
end

test('isolation: no spec names a checkout — the suite reads only the RUNNING tree',
    function ()
    ok(vim.fn.isdirectory(repo('tests')) == 1, 'repo() found the suite: ' .. repo())
    local hits = {}
    code_lines(function (file, n, line)
        for needle, why in pairs(NEEDLES) do
            if line:find(needle, 1, true) then
                hits[#hits + 1] = ('%s:%d %s (%s)'):format(file, n, why, needle)
            end
        end
    end)
    table.sort(hits)
    -- use repo() from tests/run.lua instead: it resolves the tree this suite is
    -- running from, and a path built from it can never point at another checkout
    eq({}, hits)
end)

test('isolation: repo() names the very tree the modules were loaded from', function ()
    -- the fix is only worth anything if repo() and `require` agree. If a suite ever
    -- ran in tree A against modules from tree B, every repo()-resolved path would be
    -- honest about the wrong tree — the same class of bug one layer up.
    local root = repo()
    ok(root:sub(1, 1) == '/', 'repo() is absolute: ' .. root)
    eq(1, vim.fn.filereadable(root .. '/tests/run.lua'), 'and holds this runner')
    local src = vim.fn.fnamemodify(
        debug.getinfo(require('cartograph.validity').contribute, 'S').source:sub(2), ':p')
    eq(root .. '/lua/cartograph/validity.lua', src,
        'the loaded module comes from the tree repo() names')
end)

test('isolation: a spec that moves a file stamp owns the file it moves', function ()
    -- the WRITE half of CART-0440. A stamp-moving test either works in a temp dir or
    -- restores what it changed; what it must never do is leave a tracked artifact of
    -- ANY checkout with a moved mtime, because that silently invalidates a warm cache.
    -- Shelling out to `touch` is how the original did it, and it cannot restore
    -- (there is nothing to restore TO once the old mtime is gone) — so it is banned
    -- in tests/ outright. vim.uv.fs_utime takes an explicit time and is reversible.
    local hits = {}
    code_lines(function (file, n, line)
        if line:find("'touc" .. "h'", 1, true) or line:find('"touc' .. 'h"', 1, true) then
            hits[#hits + 1] = ('%s:%d'):format(file, n)
        end
    end)
    table.sort(hits)
    eq({}, hits) -- move a stamp with vim.uv.fs_utime and put it back
end)
