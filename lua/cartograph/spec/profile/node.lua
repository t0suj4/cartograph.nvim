-- The NODE + JavaScript-language environment profile
-- ([[cartograph-stdlib-profile]]), CART-0800.
--
-- The DATA comes from `tools/nodedistill.lua` as `node-api.mpack` — 161
-- namespaces and 3959 members read out of the installed engine, an ORACLE rather
-- than a curated list. This module composes it with the one thing mpack cannot
-- hold: a function. Same split as otp.lua + otp-api.mpack.

local api = require('cartograph.spec.profile').load('node-api')

-- no artifact, no profile: one that activates while modelling nothing
-- dispositions zero calls and LOOKS installed, which is worse than absent
if not api or not api.nsset or not next(api.nsset) then return nil end

--- ★★★ MINTING, AND HERE THE VERIFICATION IS LOAD-BEARING IN A WAY IT WAS NOT
--- FOR ERLANG. `lists:foldl` names its module in the SYNTAX, so OTP's namespace
--- set is a statement about the language. JavaScript's `assert.equal()` names a
--- LOCAL BINDING that an import happened to call `assert` — `const _ =
--- require('lodash')` calls it `_`. So the ROOT is a convention and cannot carry
--- the claim on its own.
--- ⚠ WHAT CARRIES IT IS THE MEMBER. A local object that merely shares the name
--- `assert` will not have node's `deepStrictEqual` on it, so `sigs` refuses and
--- nothing is minted. The name gets us to a candidate; the oracle decides.
--- ★ AND `prof_ext` ONLY RUNS IN NODEF POSITION — project resolution has already
--- failed — so a real local `assert` would have answered before this is reached.
--- Those two together are the whole soundness argument for a conventional root.
local function mint_path(callee, full, why)
    if why ~= 'stdlib' then return nil end
    if full then
        -- exactly two segments. A deep chain (`a.b.c()`) names a receiver this
        -- profile cannot type, and guessing which segment is the namespace would
        -- be the fabrication the nodef gate exists to prevent.
        local ns, m = full:match('^([%w_$]+)%.([%w_$]+)$')
        if ns and m and api.sigs[ns .. '.' .. m] then return ns .. '.' .. m end
        return nil
    end
    -- a BARE call: only a callable GLOBAL is soundly the platform's. `free` holds
    -- the 26 non-constructor callables on globalThis (parseInt, setTimeout,
    -- fetch, ...) and nothing wider — not the 3959 member names, which would
    -- claim any unresolved project function sharing a name with some builtin.
    if api.free[callee] then return callee end
    return nil
end

return {
    schema = 1,
    runtime = 'node',
    lang = 'javascript',
    version = api.version,
    stamp = api.stamp,
    sig_kind = 'javascript',
    sig_root = api.sig_root,
    types = api.types or {},
    namespaces = api.namespaces,
    nsset = api.nsset,
    free = api.free,
    vocab = api.vocab,
    sigs = api.sigs,
    mint = true,
    mint_path = mint_path,
}
