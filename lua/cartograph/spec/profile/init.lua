-- L2 environment-profile loader ([[cartograph-stdlib-profile]], the P2 layering
-- artifact). A profile is a distilled stdlib surface (type→members, ctors,
-- derived vocab) written by tools/distill.lua as `<runtime>.mpack` beside this
-- file. Version-keyed data, NOT code — loaded once, composed at L2 into the
-- effective spec (vocab gate + stdlib-TIER minting) and served as a band for
-- LSP. Missing/corrupt = a clean nil (no profile, honest), never a half-load.

local M = {}

local DIR = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/init%.lua$')
local validity = require 'cartograph.validity'

--- Load the profile for a runtime (e.g. 'zig-std', 'lua-factorio'). Returns the
--- profile table or nil. Memoized. Two artifact forms: a HAND-AUTHORED `.lua`
--- module (reviewable, git-diffable — Factorio) or a DISTILLED `.mpack` blob
--- (extracted from source — zig). The .lua form wins if both exist.
--- KEYED ON THE ARTIFACT STAMP, not cached forever. It used to be the latter,
--- which was measurably wrong in a way the stamp made worse: an edited profile
--- returned the OLD table for the rest of the session while cache.lua recorded the
--- NEW stamp in its manifest, so a warm graph claimed a profile that extraction
--- never used ([[cartograph-repo-shapes]] stamping gap, the in-process half).
M.load = validity.memo {
    name = 'profile',
    stamp = function (runtime) return M.stamp_of(runtime) end,
    compute = function (runtime)
    local prof
    -- EVICT Lua's own module cache first. Without this the memo recomputes on a
    -- moved stamp and `require` hands back the identical stale table — the loader
    -- cache was never the only thing holding an edited artifact. Compute only runs
    -- when the stamp actually moved (or on first load), so this is not a re-read
    -- per call.
    local modname = 'cartograph.spec.profile.' .. runtime
    package.loaded[modname] = nil
    local ok_lua, mod = pcall(require, modname)
    if ok_lua and type(mod) == 'table' and mod.schema == 1 then
        prof = mod
    else
        local fd = io.open(DIR .. '/' .. runtime .. '.mpack', 'rb')
        if fd then
            local blob = fd:read('*a'); fd:close()
            local ok, dec = pcall(vim.mpack.decode, blob)
            if ok and type(dec) == 'table' and dec.schema == 1 then prof = dec end
        end
    end
    return prof
end,
}

--- Register as a graph-validity CONTRIBUTOR: a cached graph is only valid while
--- every profile artifact its resolution consulted is unchanged. cache.lua folds
--- whatever registers here, so this needs no edit there.
validity.contribute('profile', function ()
    local parts = {}
    local it = vim.uv.fs_scandir(DIR)
    while it do
        local n = vim.uv.fs_scandir_next(it)
        if not n then break end
        local base = n:match('^(.+)%.lua$') or n:match('^(.+)%.mpack$')
        if base and base ~= 'init' then parts[base] = true end
    end
    local names = {}
    for b in pairs(parts) do names[#names + 1] = b end
    table.sort(names)
    local out = {}
    for _, b in ipairs(names) do
        local st = M.stamp_of(b)
        if st then out[#out + 1] = b .. ':' .. st end
    end
    return #out > 0 and table.concat(out, ',') or nil
end)

--- A content-identity STAMP of the artifact(s) backing a profile — the file
--- mtime+size of the hand `.lua` module and/or the distilled `.mpack` blob (both
--- if present; the same files load() consults). ANY edit to a profile artifact
--- changes it, so a cached graph whose resolution used the profile can be
--- invalidated ([[cartograph-repo-shapes]] stamping gap: profiles are re-derived
--- but never stamped). Returns a stable string, or nil when no artifact exists
--- (an unknown runtime). Cheap: two fs_stat calls, no read/decode. NOTE: a hand
--- profile that internally loads ANOTHER runtime's .mpack (ruby-rails → ruby-core)
--- is not transitively covered — only its direct artifact; documented limit.
function M.stamp_of(runtime)
    local parts = {}
    for _, ext in ipairs({ 'lua', 'mpack' }) do
        local st = vim.uv.fs_stat(DIR .. '/' .. runtime .. '.' .. ext)
        if st then
            parts[#parts + 1] = ('%s:%d:%d'):format(ext, st.mtime.sec, st.size)
        end
    end
    return #parts > 0 and table.concat(parts, '|') or nil
end

--- Is `runtime` usable as an EXTRACTION environment? Returns (profile, nil) or
--- (nil, reason). The fence for an override that names a profile by STRING
--- (CART-0217), and it exists because naming an artifact by string is exactly how
--- an INGREDIENT once became selectable as a portability target and silently
--- reported "0 LOST" (CART-0209). An override is the same hazard one layer down: a
--- typo, or a plausible-looking artifact name, would otherwise change how a whole
--- graph resolves with no complaint at all.
---
--- Four ways to fail, and each is a different mistake:
---   · no such artifact — a typo, or a profile that was never distilled
---   · an INGREDIENT, declared — an input to a hand-authored profile
---   · no `lang` — a profile is applied PER LANGUAGE (eff_spec wraps it that way),
---     so one that does not name its language cannot be applied at all
---   · no NAMESPACE/TYPE surface — the positive test, and the one that carries the
---     weight (see below)
---
--- THE MARKER IS NOT ENOUGH, WHICH IS WHY BOTH CHECKS EXIST. `ingredient = true`
--- was added when prototypedistill was written; the three OLDER runtime-api
--- artifacts predate it and carry no marker, and they hold 3 free functions each —
--- enough to pass any "does it claim any names" test. Measured: the marker check
--- alone accepted `lua-factorio-api-11` as an environment, which is exactly the
--- CART-0209 failure one layer down. So the fence also asks positively for what an
--- extraction environment must have: `prof_ext` adjudicates a dotted call through
--- `nsset`/`namespaces`/`types`, and those are the bulk of every disposition, so an
--- artifact modelling none of them would change essentially nothing while reading
--- as though a whole environment had been applied.
---
--- Measured surfaces, which is what makes this a clean separation rather than a
--- guess: environments carry 10-97 types/namespaces (lua-factorio 21, luajit 10,
--- cruby 87, ruby-rails 40, zig-std 97); every ingredient carries 0.
---
--- `ruby-core` IS REFUSED, AND THAT IS CORRECT — do not "fix" it. It is the RBS
--- signature-keyed artifact (`String#chomp`), documented as not name-queryable, and
--- as an extraction environment it would disposition nothing. It remains perfectly
--- usable everywhere it is used today (hover, signature lookup); it is only not an
--- environment to activate.
function M.env_usable(runtime)
    if type(runtime) ~= 'string' or runtime == '' then
        return nil, 'not a profile name'
    end
    local prof = M.load(runtime)
    if not prof then
        return nil, ('no profile named %q (profiles ship under spec/profile/)')
            :format(runtime)
    end
    if prof.ingredient then
        return nil, ('%s is an INGREDIENT, not an environment — it is an input to a'
            .. ' hand-authored profile (see tools/*distill.lua) and disposes no'
            .. ' names of its own'):format(runtime)
    end
    if not prof.lang then
        return nil, ('%s names no `lang`, and a profile is applied per-language, so'
            .. ' it cannot be activated'):format(runtime)
    end
    local surface = next(prof.types or {}) ~= nil or next(prof.nsset or {}) ~= nil
        or (type(prof.namespaces) == 'table' and next(prof.namespaces) ~= nil)
    if not surface then
        return nil, ('%s models no namespace or type surface (nsset / namespaces /'
            .. ' types are all empty), so activating it would disposition almost'
            .. ' nothing while reading as a whole environment — it is a distilled'
            .. ' INGREDIENT or a signature-keyed artifact, not an environment')
            :format(runtime)
    end
    return prof, nil
end

return M
