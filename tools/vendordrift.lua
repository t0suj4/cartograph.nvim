-- vendordrift — HAS THE VENDORED COPY, OR ITS DONOR, MOVED? (CART-0912)
--
--   nvim --headless -u NONE -l tools/vendordrift.lua [--gate]
--
-- ★★★ WHY THIS EXISTS, AND WHAT IT ANSWERS. The standing objection to vendoring
-- is CART-0746's — A COPIED WALKER IS A COPIED BUG — stated as a rule in
-- `tools/algebradrive.lua`: "a copied algebra would be a SECOND AUTHORITY that
-- drifts". That objection is about drift being SILENT. A copy that records its
-- origin and a fence that reads the record cannot drift silently, which is the
-- whole of the answer: the copy is still a second artifact, but no longer a
-- second AUTHORITY, because at any moment this says which of the two moved.
--
-- ★★ THREE STATES, AND ONLY ONE OF THEM IS A SURPRISE.
--
--     IDENTICAL      copy == donor == the sha recorded at vendor time
--     DIVERGED       WE edited the copy. EXPECTED: the end goal is that this
--                    code is cartograph's own, so adaptation is the plan. What
--                    matters is that it is VISIBLE and dated, not that it is
--                    zero.
--     ORIGIN MOVED   the DONOR changed. The interesting one: an upstream fix we
--                    do not have, or a divergence we chose and did not record.
--
-- ⚠ A MISSING DONOR IS `UNAVAILABLE`, NEVER `IDENTICAL`. This machine has the
-- prototype; a clone of cartograph need not, and CI must not fail for a file it
-- was never meant to have. Reporting "identical" for "could not look" is
-- absence rendered as a plausible positive — the failure shape this repo has on
-- record more than any other. The transport layer draws the same line between
-- ABSENT and UNAVAILABLE and for the same reason.
--
-- ★ ONE UNIT TODAY, AND THE TABLE IS THE POINT. A second donor gets a row here,
-- not a second tool — but the shape is deliberately NOT generalised past one
-- instance (one instance is not a class), so `units` is a literal table rather
-- than a discovery walk.

local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path

local M = {}

local function read(path)
    local fd = io.open(path, 'rb'); if not fd then return nil end
    local s = fd:read('*a'); fd:close(); return s
end

--- sha256 of a file's bytes, via the tool the platform has. Returns nil when
--- neither exists — which is UNAVAILABLE, not a mismatch.
--- @return string|nil sha
local function sha256(path)
    for _, cmd in ipairs { 'sha256sum %q 2>/dev/null', 'shasum -a 256 %q 2>/dev/null' } do
        local p = io.popen(cmd:format(path))
        if p then
            local out = p:read('*a') or ''
            p:close()
            local h = out:match('^(%x+)')
            if h and #h == 64 then return h end
        end
    end
    return nil
end

M.units = {
    {
        name   = 'cartograph.algebra.core',
        copy   = REPO .. '/lua/cartograph/algebra/core.lua',
        origin = 'cartograph.algebra.origin',
        --- the donor is DECLARED, never read out of the analysed tree — the
        --- same rule the seam states, and the reason this asks the seam rather
        --- than hardcoding a path.
        donor  = function () return (require 'cartograph.algebra').path() end,
    },
    {
        -- ★ THE SECOND UNIT, WHICH THIS FILE'S HEADER PROMISED WOULD BE A ROW
        -- RATHER THAN A SECOND TOOL. The donor's 243 tests, vendored verbatim.
        name   = 'tests/vendor/algebra_spec.lua',
        copy   = REPO .. '/tests/vendor/algebra_spec.lua',
        origin = 'cartograph.algebra.origin',
        stamp_field = 'spec_sha256',
        -- the spec sits beside the module in the donor, so its path is derived
        -- from the DECLARED one rather than written again
        donor  = function ()
            local path = (require 'cartograph.algebra').path()
            return (path:gsub('algebra%.lua$', 'spec/algebra_spec.lua'))
        end,
    },
}

--- @return table report  { name, state, copy_sha, donor_sha, stamp_sha, note }
function M.check(u)
    -- a literal `stamp` is the spec's injection point: the classifier's three
    -- states are the whole of this tool, and a test that can only run against
    -- the real pair can only ever exercise ONE of them
    local stamp = u.stamp or require(u.origin)
    -- a unit may point at a different sha field of the same stamp record: one
    -- origin, several vendored artifacts
    if u.stamp_field then
        stamp = { sha256 = stamp[u.stamp_field], vendored_at = stamp.vendored_at,
            donor_repo = stamp.donor_repo, donor_rev = stamp.donor_rev }
    end
    local copy_sha = sha256(u.copy)
    if not copy_sha then
        return { name = u.name, state = 'UNAVAILABLE',
            note = 'no sha256 tool, or the copy is unreadable: ' .. u.copy }
    end

    local donor_path = select(1, u.donor())
    local donor_sha = read(donor_path) and sha256(donor_path) or nil

    local moved_local = copy_sha ~= stamp.sha256
    -- ⚠ THE DONOR'S STATE IS A SEPARATE QUESTION AND IS ANSWERED SEPARATELY.
    -- Comparing the copy to the DONOR alone cannot tell "we edited it" from
    -- "they edited it"; both sides are compared to the STAMP, which is the only
    -- fixed point. That is why the stamp records a sha and not just a revision.
    local moved_origin = donor_sha ~= nil and donor_sha ~= stamp.sha256

    local state
    if not donor_sha then state = moved_local and 'DIVERGED (donor unavailable)' or 'UNAVAILABLE'
    elseif moved_local and moved_origin then state = 'BOTH MOVED'
    elseif moved_local then state = 'DIVERGED'
    elseif moved_origin then state = 'ORIGIN MOVED'
    else state = 'IDENTICAL' end

    return { name = u.name, state = state, copy_sha = copy_sha, donor_sha = donor_sha,
        stamp_sha = stamp.sha256, donor_path = donor_path, stamp = stamp }
end

function M.run(opts)
    opts = opts or {}
    local worst = 0
    for _, u in ipairs(M.units) do
        local r = M.check(u)
        print(('VENDOR DRIFT  %s'):format(r.name))
        print(('  state        %s'):format(r.state))
        print(('  vendored     %s from %s@%s'):format(
            r.stamp.vendored_at, r.stamp.donor_repo, r.stamp.donor_rev:sub(1, 8)))
        print(('  stamp sha    %s'):format(r.stamp_sha:sub(1, 16)))
        print(('  copy  sha    %s  %s'):format((r.copy_sha or '?'):sub(1, 16),
            r.copy_sha == r.stamp_sha and '=' or '★ DIFFERS — we edited it'))
        print(('  donor sha    %s  %s'):format((r.donor_sha or '(unreadable)'):sub(1, 16),
            r.donor_sha == nil and '— UNAVAILABLE, not a match'
            or (r.donor_sha == r.stamp_sha and '=' or '★ DIFFERS — the donor moved')))
        print(('  donor path   %s'):format(r.donor_path))
        if r.state ~= 'IDENTICAL' and r.state ~= 'UNAVAILABLE' then worst = 1 end
    end
    -- a report by default; a gate only when asked, so a pre-commit hook can use
    -- it without every local edit to the vendored file failing a commit
    return opts.gate and worst or 0
end

if not pcall(debug.getlocal, 4, 1) then
    local gate = false
    for _, a in ipairs(arg or {}) do if a == '--gate' then gate = true end end
    os.exit(M.run { gate = gate })
end
return M
