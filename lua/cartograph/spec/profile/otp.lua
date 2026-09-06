-- The OTP environment profile ([[cartograph-stdlib-profile]]), CART-0793.
--
-- The DATA comes from `tools/erldistill.lua` as `otp-api.mpack` — 1047 modules
-- and 21212 exports read out of the installed runtime, an ORACLE rather than a
-- curated list. This module composes that artifact with the one thing mpack
-- cannot hold: a function. Same split as lua-factorio.lua + lua-factorio-api.mpack.

local api = require('cartograph.spec.profile').load('otp-api')

-- ★ NO ARTIFACT, NO PROFILE — and the failure is SILENT ON PURPOSE. A profile
-- that activates while modelling nothing would disposition zero calls and look
-- installed, which is worse than being absent: `env_usable` refuses an empty
-- surface, and returning nil here reaches that refusal honestly.
if not api or not api.nsset or not next(api.nsset) then return nil end

-- ★★★ MINTING: A DISPOSITION IS NOT A DESTINATION. Without this the profile says
-- "that call is the platform" and leaves `c.to` nil, so 9996 of ejabberd's calls
-- were CLASSIFIED and still unresolved — levers.lua scored them `other (stdlib)
-- 9996 +23.8`, points sitting on the table. Minting promotes the disposition into
-- a real node (`otp::lists:foldl`) that def and hover can target.
--
-- ⚠⚠ AND IT MINTS ONLY WHAT THE ORACLE CONFIRMS. Every branch below checks the
-- distilled surface before returning a path; an unconfirmed name returns nil and
-- stays an honest frontier. That is the whole difference between a profile that
-- SUBTRACTS uncertainty and one that manufactures it — the stdlib-profile design
-- calls a false guarantee unsound, and a minted node IS a guarantee: it asserts
-- that this function exists in the platform.
local function mint_path(callee, full, why)
    if why ~= 'stdlib' then return nil end
    if full then
        -- a remote call: spec/erlang.lua's qualify_call normalised `lists:foldl`
        -- to `lists.foldl`, which is the key the distiller used
        -- ★ THE KEY CARRIES THE CALL'S ARGUMENT COUNT, so the oracle can be asked
        -- the sharper question: does this module export this function AT THIS
        -- ARITY? `lists:foldl/2` does not exist — foldl is 3 — and minting a node
        -- for it would assert a platform function that is not there.
        local mod, fn, ar = full:match('^([%w_]+)%.([%w_]+)/(%d+)$')
        if not mod then mod, fn = full:match('^([%w_]+)%.([%w_]+)$') end
        local sig = mod and fn and api.sigs[mod .. '.' .. fn]
        if sig then
            -- the NODE NAME is erlang's own spelling, because it is what a reader
            -- sees in a hover or a jump target; the dot form is an internal key
            if not ar then return mod .. ':' .. fn end
            for _, a in ipairs(sig.arities or {}) do
                if a == tonumber(ar) then return mod .. ':' .. fn end
            end
            return nil -- exported, but NOT at this arity: not a claim to make
        end
        -- a dotted call the oracle does not confirm — a module we do not model, or
        -- a function that module does not export. Refusing here is the point:
        -- minting it would assert a platform function that may not exist.
        if full:find('%.') then return nil end
        -- not dotted: fall through to the bare/BIF path below
    end
    -- a BARE call disposed to the platform can only be an AUTO-IMPORTED BIF, and
    -- those all belong to `erlang`. `api.free` holds exactly that set (176 names,
    -- from erl_internal:bif/2) and nothing wider, so this cannot claim a project
    -- function that merely shares a name with some OTP export.
    -- ⚠ AND IT HAS TO ACCEPT THE ARITY-KEYED FORM. spec/erlang.lua now keys a
    -- LOCAL call as `is_map/1`, so `full` is no longer nil for bare calls and an
    -- earlier cut of this function fell through the dotted branch and minted
    -- NOTHING — 560 external nodes became 494 and `is_map/1` (430 sites) went to
    -- the top of the unresolved list. The arity is a gift here, not an obstacle:
    -- `api.free` carries each BIF's arities, so the claim can be checked rather
    -- than assumed.
    local bare, bar = (full or callee):match('^([%w_]+)/(%d+)$')
    bare = bare or callee
    local arities = api.free[bare]
    if not arities then return nil end
    if bar then
        for _, a in ipairs(arities) do
            if a == tonumber(bar) then return 'erlang:' .. bare end
        end
        return nil -- the name is a BIF, but not at THIS arity: not a claim to make
    end
    return 'erlang:' .. bare
end

return {
    schema = 1,
    runtime = 'otp',
    lang = 'erlang',
    version = api.version,
    stamp = api.stamp,
    sig_kind = 'erlang',
    sig_root = api.sig_root,
    types = api.types or {},
    namespaces = api.namespaces,
    nsset = api.nsset,
    free = api.free,
    vocab = api.vocab,
    sigs = api.sigs,
    -- opt in to the resolution face; without it this stays disposition-only
    mint = true,
    mint_path = mint_path,
}
