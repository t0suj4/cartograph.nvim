-- The NODE + JavaScript-language environment profile
-- ([[cartograph-stdlib-profile]]), CART-0800.
--
-- The DATA comes from `tools/nodedistill.lua` as `node-api.mpack` — 161
-- namespaces and 3959 members read out of the installed engine, an ORACLE rather
-- than a curated list. This module composes it with the one thing mpack cannot
-- hold: a function. Same split as otp.lua + otp-api.mpack.

local api = require('cartograph.spec.profile').load('node-api')

-- ★★ THE PROJECT'S OWN npm SURFACE, UNIONED IN WHEN PRESENT (CART-0800).
-- `tools/npmdistill.lua` writes `npm-api.mpack` from the corpus's declared
-- dependencies, fetched INSIDE A CONTAINER, never installed, never executed.
-- ⚠ IT IS OPTIONAL BY DESIGN, and the reason is a real asymmetry: node's surface
-- is a property of the MACHINE (one engine, every project the same), while an npm
-- surface is a property of ONE PROJECT (ghost's 4833 members are not
-- converse.js's). A root gets exactly one profile — `select_env` is NEAREST-wins —
-- so npm cannot BE a second profile; it composes into this one or not at all.
-- Absent artifact => the node surface alone, which is the correct default.
local npm = require('cartograph.spec.profile').load('npm-api')

-- NODE WINS A COLLISION: a package cannot redefine `fs` for a call that already
-- reached the nodef gate.
local nsset, namespaces, sigs, vocab = {}, {}, {}, {}
for k, v in pairs(api.nsset or {}) do nsset[k] = v end
for k, v in pairs(api.sigs or {}) do sigs[k] = v end
for k, v in pairs(api.vocab or {}) do vocab[k] = v end
if npm then
    for k, v in pairs(npm.nsset or {}) do if nsset[k] == nil then nsset[k] = v end end
    for k, v in pairs(npm.sigs or {}) do if sigs[k] == nil then sigs[k] = v end end
    for k, v in pairs(npm.vocab or {}) do if vocab[k] == nil then vocab[k] = v end end
end
for k in pairs(nsset) do namespaces[#namespaces + 1] = k end
table.sort(namespaces) -- an artifact field: order is output (CART-0790)

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
        if ns and m and sigs[ns .. '.' .. m] then return ns .. '.' .. m end
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
    namespaces = namespaces,
    nsset = nsset,
    free = api.free,
    vocab = vocab,
    sigs = sigs,
    mint = true,
    mint_path = mint_path,
}
