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

-- ★★★ THE BROWSER HALF (CART-0805). node's surface is the running ENGINE's, so it
-- has no `document`, no `window`, no `Element` — and two of the three JS corpora
-- are browser code. `tools/domdistill.lua` reads TypeScript's own `lib.dom.d.ts`
-- into `dom-api.mpack`: 27 globals, 18873 keys, the extends chains expanded so
-- `document.appendChild` (declared seven interfaces up, on Node) is a key.
-- ⚠ WHY IT UNIONS RATHER THAN BEING ITS OWN PROFILE, and it is not a preference:
-- `select_env` gives a root exactly ONE profile, NEAREST-wins, and a repo is
-- routinely both — ghost serves a browser frontend out of a node server, and
-- converse.js has a `headless/` node half beside its browser one. A second profile
-- would force a choice the tree does not make. Unioning is safe because MINTING IS
-- GATED ON THE MEMBER: a server-only project never calls `document.createElement`,
-- so the extra names cost it nothing, which is the measurement that decided this.
-- NODE STILL WINS A COLLISION — its answer came from a running engine, the DOM's
-- from a declaration.
local dom = require('cartograph.spec.profile').load('dom-api')

-- NODE WINS A COLLISION: a package cannot redefine `fs` for a call that already
-- reached the nodef gate.
local nsset, namespaces, sigs, vocab = {}, {}, {}, {}
for k, v in pairs(api.nsset or {}) do nsset[k] = v end
for k, v in pairs(api.sigs or {}) do sigs[k] = v end
for k, v in pairs(api.vocab or {}) do vocab[k] = v end
for _, extra in ipairs({ dom, npm }) do
    if extra then
        for k, v in pairs(extra.nsset or {}) do if nsset[k] == nil then nsset[k] = v end end
        for k, v in pairs(extra.sigs or {}) do if sigs[k] == nil then sigs[k] = v end end
        for k, v in pairs(extra.vocab or {}) do if vocab[k] == nil then vocab[k] = v end end
    end
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
        -- ★★★ ASK THE ORACLE FOR THE WHOLE PATH (CART-0804). This used to demand
        -- EXACTLY two segments, on the reasoning that a deeper path names a
        -- receiver the profile cannot type. That is true of a CHAIN
        -- (`fs.remove(p).catch`) and false of a nested NAMESPACE
        -- (`sinon.assert.calledOnce`, `path.posix.normalize`, `Intl.NumberFormat
        -- .supportedLocalesOf`) — and the two are not told apart by counting dots,
        -- they are told apart by whether the surface declares the path. So the
        -- segment count stops being a rule and the lookup decides: a chain's text
        -- carries parentheses and quotes and can never be a key, while a declared
        -- nested path is one. `sinon.assert.calledOnce` alone is 1090 sites on
        -- ghost, `notCalled` 731 and `calledWith` 571.
        -- The soundness argument is UNCHANGED and is the reason this is safe to
        -- widen: nothing is minted that the distilled surface does not state.
        if full:match('^[%w_$]+%.[%w_$][%w_$%.]*$') then
            local sig = sigs[full]
            -- ★ THE SECOND RETURN IS THE DECLARED RETURN TYPE. `sinon.stub` yields
            -- `SinonStub`, which the distilled surface carries and mint_nodes now
            -- puts on the node — so a chain has a bottom to terminate on.
            if sig then return full, sig.ret end
        end
        return nil
    end
    -- a BARE call: only a callable GLOBAL is soundly the platform's. `free` holds
    -- the 26 non-constructor callables on globalThis (parseInt, setTimeout,
    -- fetch, ...) and nothing wider — not the 3959 member names, which would
    -- claim any unresolved project function sharing a name with some builtin.
    if api.free[callee] then return callee end
    -- and the browser's own callable globals (fetch, alert, requestAnimationFrame,
    -- getComputedStyle): the same rule, from the same nodef position.
    if dom and dom.free and dom.free[callee] then return callee end
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
    free = (function ()
        local f = {}
        for k, v in pairs(api.free) do f[k] = v end
        if dom then for k, v in pairs(dom.free or {}) do if f[k] == nil then f[k] = v end end end
        return f
    end)(),
    vocab = vocab,
    sigs = sigs,
    mint = true,
    mint_path = mint_path,
}
