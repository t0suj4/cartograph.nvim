-- PORTABILITY ([[cartograph-portability-lever]]): score this codebase's EXTERNAL
-- SURFACE against a target environment. "Will it run on <runtime>, and if not,
-- WHERE does it break?"
--
-- The whole verb is one intersection, which is why it is small: externals.lua
-- already computes what the code uses but does not define, and every L2 profile
-- already declares what a runtime provides (vocab / free / namespaces / types /
-- sigs). Porting is the difference between those two sets.
--
-- The design note called for hand-authored `<runtime>-provides` sets. It turned
-- out none were needed: a profile IS a provides set, so the audit reads the
-- artifacts that already ship and any new distilled profile becomes a target for
-- free.
--
-- The A-to-B DIFF (M.diff) is built, but note what it needs: TWO name-queryable
-- profiles for the SAME language. No shipped pair qualifies today — ruby-rails,
-- zig-std and lua-factorio are three different languages, and ruby-core is
-- signature-keyed — so the move report cannot be demonstrated on the artifacts in
-- the tree. It becomes useful the moment a sibling profile lands (an mruby or
-- opal provides-set, which is what the original design asked for). The mechanism
-- refuses clearly rather than producing a meaningless "everything is lost".
--
-- HONESTY — a portability claim is easy to overstate, so:
--   · Buckets are PROVIDED and NOT-IN-PROFILE. Never "missing": a name absent
--     from a profile may be supplied by a dependency (a gem, an npm package) or
--     simply absent from a partial artifact. Which of those it is, this cannot
--     know, and the report says so instead of ruling.
--   · The profile's own size is printed. A verdict against a 134-symbol profile
--     is worth less than one against 3,260, and the reader is entitled to that.
--   · Only the SILENT external surface is scored (calls that resolved to nothing
--     and were not even refused). Anything the project itself defines is out of
--     scope by construction, so a project method never counts as a blocker.
--   · A profile whose language differs from the code's is refused outright,
--     rather than reporting every name as not-provided.

local M = {}

--- Does `prof` provide `name`? Returns the EVIDENCE (which part of the profile
--- answered) or nil. Several sources because profile artifacts differ: a
--- distilled zig std is free-function-heavy, a hand-authored Factorio profile is
--- namespace-heavy, and an RBS-derived one is signature-keyed.
function M.provides(prof, name)
    if not (prof and name and name ~= '') then return nil end
    if prof.vocab and prof.vocab[name] then return 'vocab' end
    if prof.free and prof.free[name] then return 'free fn' end
    if prof.sigs and prof.sigs[name] then return 'signature' end
    local root, rest = name:match('^([%w_]+)[%.:#]+(.+)$')
    if root then
        -- A FULLY ENUMERATED CLASS ANSWERS FOR ITSELF, and must be consulted BEFORE
        -- the namespace prefix below. The prefix says only "this root is a known
        -- global", which is the right answer for a DISPOSITION (the call is external,
        -- not project) but the wrong one for PORTABILITY: it made
        -- `game.entity_prototypes` count as provided by `namespace game` and so
        -- hid the single clearest piece of porting work in the corpus — that name
        -- was renamed to prototypes.entity in 2.0.
        -- Only a SINGLE-segment member is adjudicated: a deeper chain
        -- (`game.surfaces[1].create_entity`) continues into receiver-typed territory
        -- the artifact cannot follow, so it keeps the prefix answer.
        local cls = (prof.global2class or {})[root]
        if cls and (prof.api_complete or {})[cls] and rest:match('^[%w_]+$') then
            if (prof.api_members or {})[cls .. '::' .. rest] then
                return 'member of ' .. cls
            end
            return nil -- enumerated and NOT there: genuinely absent
        end
        if prof.nsset and prof.nsset[root] then return 'namespace ' .. root end
        if prof.namespaces and prof.namespaces[root] then return 'namespace ' .. root end
        local ty = prof.types and prof.types[root]
        if ty then
            local mem = ty.members
            if mem then
                if mem[rest] then return 'member of ' .. root end
                for _, m in ipairs(mem) do
                    if m == rest then return 'member of ' .. root end
                end
            end
            return 'type ' .. root
        end
        -- NO tail-only fallback. `game.print` must not count as provided by
        -- LuaJIT merely because `print` is a base function: for a DOTTED name the
        -- profile has to provide the ROOT, or it does not provide the name.
        -- Dropping this cost some true positives where a receiver's type is
        -- unknown (`user.save` under rails), and that is the safe direction —
        -- claiming something is provided when it is not would HIDE a blocker,
        -- while under-claiming only over-reports the work.
    end
    return nil
end

--- The runtimes that can be audited against: whatever artifacts ship. Derived,
--- not listed, so a newly distilled profile becomes a target with no edit here
--- (and drives the command's completion).
function M.runtimes()
    local dir = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]+$')
        .. '/spec/profile'
    local out, seen = {}, {}
    for _, pat in ipairs({ '*.lua', '*.mpack' }) do
        for _, f in ipairs(vim.fn.globpath(dir, pat, false, true)) do
            local name = vim.fn.fnamemodify(f, ':t:r')
            if name ~= 'init' and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    table.sort(out)
    return out
end

--- Can this artifact answer a NAME query at all? An RBS-derived profile is keyed
--- by signature (`String#chomp`), so asking it about a callee name matches almost
--- nothing — and a resulting "0% covered" would read as a claim about the RUNTIME
--- when it is a fact about the ARTIFACT. Ranking says so instead.
function M.name_queryable(prof)
    for _, field in ipairs({ 'vocab', 'free', 'nsset', 'namespaces' }) do
        if next(prof[field] or {}) ~= nil then return true end
    end
    return false
end

--- How many symbols the profile actually claims — the weight of any verdict.
function M.profile_size(prof)
    local n = 0
    for _, field in ipairs({ 'vocab', 'free', 'sigs' }) do
        for _ in pairs(prof[field] or {}) do n = n + 1 end
    end
    return n
end

--- THE SYMMETRIC INVERSION ([[cartograph-portability-lever]] keystone): the code
--- has a profile too. An environment profile says what it PROVIDES; this derives
--- what the code REQUIRES, in the same currency — so every question downstream
--- is set algebra over the two:
---   portability to T      = requires.names ⊆ T.provides
---   version floor         = max of requires.features
---   tightest environment  = the smallest T that covers requires.names  (M.rank)
---   dependency manifest   = requires.names grouped by WHO provides them (M.manifest)
--- Returns { names = {name -> calls}, where = {name -> file}, langs = set,
--- features = {version facts}, floor, total }.
function M.requires(store)
    local externals = require 'cartograph.externals'
    local s = externals.surface(store)
    local r = { names = {}, where = {}, langs = {}, total = 0 }
    for base, e in pairs(s.bases) do
        local first
        for f in pairs(e.files) do
            if not first or f < first then first = f end
        end
        local function add(name, n)
            r.names[name] = (r.names[name] or 0) + n
            r.where[name] = r.where[name] or first
        end
        -- a bare call names the base itself; members name base.member. Both can
        -- occur for one base (`Foo()` and `Foo.bar()`), so neither is exclusive.
        if e.bare > 0 or next(e.members) == nil then add(base, e.bare > 0 and e.bare or e.calls) end
        for m, n in pairs(e.members) do add(base .. '.' .. m, n) end
    end
    for _ in pairs(r.names) do r.total = r.total + 1 end
    -- the VERSION half of the same requirement set
    local ts = require 'cartograph.providers.treesitter'
    local ext2lang = {}
    for lang, sp in pairs(ts.spec) do
        for _, e in ipairs(sp.exts or {}) do ext2lang[e] = lang end
    end
    for _, n in ipairs((store.data or {}).nodes or {}) do
        local e = n.file and n.file:match('%.([%w]+)$')
        local l = e and ext2lang[e:lower()]
        if l then r.langs[l] = true end
    end
    local vf = require 'cartograph.versionfloor'
    r.features = vf.facts(store)
    for _, f in ipairs(r.features) do
        if not r.floor or vf.older(r.floor, f.v) then r.floor = f.v end
    end
    r.scale = nil
    for l in pairs(r.langs) do
        if vf.SCALE[l] then r.scale = vf.SCALE[l] end
    end
    return r
end

--- Rank every shipped profile of a matching language by how much of the code's
--- requirement set it covers — the "tightest environment" query. COVERAGE, not a
--- verdict: a profile covering everything is not proof the code runs there, only
--- that this boundary holds no counter-evidence.
function M.rank(store)
    local pm = require 'cartograph.spec.profile'
    local req = M.requires(store)
    local out = {}
    for _, runtime in ipairs(M.runtimes()) do
        local prof = pm.load(runtime)
        if prof and (not prof.lang or req.langs[prof.lang]) then
            local hit, miss = 0, 0
            for name in pairs(req.names) do
                if M.provides(prof, name) then
                    hit = hit + 1
                else
                    miss = miss + 1
                end
            end
            out[#out + 1] = { runtime = runtime, size = M.profile_size(prof),
                provided = hit, unknown = miss, queryable = M.name_queryable(prof),
                pct = (hit + miss) > 0 and (hit / (hit + miss) * 100) or 0 }
        end
    end
    -- best coverage first; on a tie the SMALLER profile is the tighter fit
    table.sort(out, function (a, b)
        -- a non-queryable artifact is not "worst", it is UNRANKABLE: sink it so
        -- it never reads as the tightest or the loosest fit
        if a.queryable ~= b.queryable then return a.queryable end
        if math.abs(a.pct - b.pct) > 0.001 then return a.pct > b.pct end
        return a.size < b.size
    end)
    return out, req
end

--- Group the requirement set by WHO provides it — the dependency manifest. A name
--- no shipped profile claims is left in its own bucket, NOT called external: it
--- is most often a sibling module or a third-party dependency.
function M.manifest(store)
    local pm = require 'cartograph.spec.profile'
    local req = M.requires(store)
    local profs = {}
    for _, runtime in ipairs(M.runtimes()) do
        local p = pm.load(runtime)
        if p and (not p.lang or req.langs[p.lang]) then
            profs[#profs + 1] = { runtime = runtime, prof = p }
        end
    end
    local groups, unclaimed = {}, {}
    for name, calls in pairs(req.names) do
        local owners = {}
        for _, e in ipairs(profs) do
            if M.provides(e.prof, name) then
                owners[#owners + 1] = e.runtime
            end
        end
        if #owners == 0 then
            unclaimed[#unclaimed + 1] = { name = name, calls = calls }
        else
            local key = table.concat(owners, '+')
            groups[key] = groups[key] or { names = 0, calls = 0 }
            groups[key].names = groups[key].names + 1
            groups[key].calls = groups[key].calls + calls
        end
    end
    table.sort(unclaimed, function (a, b)
        if a.calls ~= b.calls then return a.calls > b.calls end
        return a.name < b.name
    end)
    return groups, unclaimed, req
end

--- WHY A NAME IS NOT IN THE PROFILE — which is a different question from whether
--- the environment has it, and conflating the two is how a list of things the
--- artifact cannot see got labelled "candidate porting work".
---
--- MEASURED on lua-factorio (2026-07-26), which is what these buckets are shaped
--- by rather than guessed at:
---   · the artifact distils METHODS ONLY. LuaGameScript::get_player and ::print are
---     in it; ::tick, ::players, ::surfaces, ::entity_prototypes are NOT. So a miss
---     on a global's member says nothing — game.entity_prototypes (genuinely renamed
---     in 2.0) is indistinguishable from game.tick (perfectly fine in 2.0).
---   · it models GLOBAL-ROOTED calls only (tools/factoriodistill.lua:6-11 says so),
---     so a receiver-typed name has no representation at all. On the Von Neumann mod
---     that is 66 of 92 names.
---   · Factorio EXTENDS the Lua stdlib namespaces (table.deepcopy via lualib) and
---     the profile omits those, so even a "complete" stdlib namespace is not a
---     closed set to test against.
---
--- THAT HAS CHANGED for the enumerated classes. The distiller now emits attributes
--- as well as methods (220 members, 104 of them attributes, across 9 classes) and
--- DECLARES which classes are fully enumerated. Inside a complete class a miss IS
--- evidence: `game.entity_prototypes` is absent from 2.0.72 because it was renamed
--- to prototypes.entity, while `game.tick` is present — the two are now
--- distinguishable, which is precisely what the methods-only artifact could not do.
--- So `absent` exists, and ONLY for names a complete class could have held. Every
--- other miss keeps its blindness label, because the artifact still models
--- global-rooted calls only and the stdlib namespaces are still not closed sets.
--- Returns 'other-language' | 'absent' | 'receiver-typed' |
--- 'unenumerated-namespace' | 'unclaimed-bare'. `file` is where the name was seen; a name from a file of
--- ANOTHER language is not the profile's business at all — one zipper.py in a
--- Factorio mod put 13 python names in this list, and calling them "a sibling
--- module or a third-party dependency" was a label I knew to be wrong. The
--- audit-level guard only refuses when the profile's language is absent ENTIRELY,
--- so a mixed corpus reaches here.
--- LIMIT: requires() keeps ONE file per name (the alphabetically first), so a name
--- seen in two languages is classified by that sample. Precise enough to pull an
--- obvious foreign-stdlib name out of a list where it was being called a third-party
--- dependency; not a per-occurrence judgement, and it does not pretend to be.
function M.unknown_reason(prof, name, file)
    local ext = file and file:match('%.([%w]+)$')
    if ext and prof.lang then
        local lang = ext_lang()[ext:lower()]
        if lang and lang ~= prof.lang then return 'other-language' end
    end
    local root, member = name:match('^([%w_]+)[.:]([%w_]+)$')
    -- ABSENT: the root is a global whose documented class is FULLY enumerated, and
    -- the member is not in it. The only bucket that is evidence about the target
    -- rather than about the artifact.
    if root and member then
        local cls = (prof.global2class or {})[root]
        if cls and (prof.api_complete or {})[cls]
            and not (prof.api_members or {})[cls .. '::' .. member] then
            return 'absent'
        end
    end
    if not root then
        -- a dotted CHAIN (a.b.c) or a call-shaped key: still receiver-typed, since
        -- nothing but the first segment could ever be a modelled namespace
        local first = name:match('^([%w_]+)[.:]')
        if first and not (prof.nsset or {})[first] then return 'receiver-typed' end
        if first then return 'unenumerated-namespace' end
        return 'unclaimed-bare'
    end
    if (prof.nsset or {})[root] then return 'unenumerated-namespace' end
    return 'receiver-typed'
end

-- ext -> language, from the specs themselves (memoised: the spec table does not
-- change within a process)
local _ext_lang
function ext_lang()
    if _ext_lang then return _ext_lang end
    _ext_lang = {}
    local ok, ts = pcall(require, 'cartograph.providers.treesitter')
    if ok then
        for lang, sp in pairs(ts.spec or {}) do
            for _, e in ipairs(sp.exts or {}) do _ext_lang[e:lower()] = lang end
        end
    end
    return _ext_lang
end

local ext_lang
local REASON_TEXT = {
    ['absent'] = 'ABSENT FROM THE TARGET — the documented class for this global is'
        .. ' FULLY enumerated (methods and attributes) and does not hold the name.'
        .. ' This is the group that is real porting work.',
    ['other-language'] = 'ANOTHER LANGUAGE — seen in files this profile does not'
        .. ' describe, so it is not the profile\'s business. Scoring them here was'
        .. ' noise: exclude those files, or score them against their own runtime.',
    ['receiver-typed'] = 'RECEIVER-TYPED — the artifact models global-rooted calls'
        .. ' only, so these have no representation in it at all. Needs receiver'
        .. ' typing; their absence is not evidence about the target.',
    ['unenumerated-namespace'] = 'NAMESPACE MEMBER, NOT ENUMERATED — the root IS a'
        .. ' modelled namespace but the artifact distils METHODS only (and omits'
        .. ' lualib extensions), so a miss here says nothing either way.',
    ['unclaimed-bare'] = 'BARE AND UNCLAIMED — no shipped profile claims these.'
        .. ' Most often a sibling module or a third-party dependency, NOT a gap in'
        .. ' the environment.',
}

--- Audit the open graph against a target runtime profile.
--- Returns (result, err) where result = { runtime, size, provided, unknown,
--- entries = { {name, calls, provided, why, files} } }.
function M.audit(store, runtime)
    local prof = require('cartograph.spec.profile').load(runtime)
    if not prof then
        return nil, ('no profile named %q (profiles ship under spec/profile/)'):format(runtime)
    end
    -- A profile for another language would mark EVERY name not-provided, which
    -- looks like a devastating verdict and means nothing. Refuse instead.
    local ts = require 'cartograph.providers.treesitter'
    local ext2lang = {}
    for lang, sp in pairs(ts.spec) do
        for _, e in ipairs(sp.exts or {}) do ext2lang[e] = lang end
    end
    local present = {}
    for _, n in ipairs((store.data or {}).nodes or {}) do
        local e = n.file and n.file:match('%.([%w]+)$')
        local l = e and ext2lang[e:lower()]
        if l then present[l] = true end
    end
    if prof.lang and next(present) and not present[prof.lang] then
        local got = {}
        for l in pairs(present) do got[#got + 1] = l end
        table.sort(got)
        return nil, ('%s is a %s profile, but this graph is %s — nothing to compare')
            :format(runtime, prof.lang, table.concat(got, '/'))
    end
    -- one requirement set, scored against this profile: the audit is now just
    -- `requires ∩ provides`, which is what the keystone says it should be
    local req = M.requires(store)
    local res = { runtime = runtime, lang = prof.lang, version = prof.version,
        size = M.profile_size(prof), provided = 0, unknown = 0, entries = {} }
    for name, n in pairs(req.names) do
        local w = M.provides(prof, name)
        res.entries[#res.entries + 1] = { name = name, calls = n,
            provided = w ~= nil, why = w, files = { req.where[name] },
            reason = (w == nil)
                and M.unknown_reason(prof, name, req.where[name]) or nil }
        if w then res.provided = res.provided + 1 else res.unknown = res.unknown + 1 end
    end
    table.sort(res.entries, function (a, b)
        if a.provided ~= b.provided then return not a.provided end -- unknown first
        if a.calls ~= b.calls then return a.calls > b.calls end
        return a.name < b.name
    end)
    return res
end

--- MOVING between environments: audit the SAME requirement set under two
--- profiles and diff the outcomes. The names whose status changes are the porting
--- work — which is why this is small: requires() already guarantees both sides
--- score the same set, so nothing can drift between them.
--- Returns (result, err); result = { from, to, lost, gained, kept, neither }.
function M.diff(store, from, to)
    local a, erra = M.audit(store, from)
    if not a then return nil, erra end
    local b, errb = M.audit(store, to)
    if not b then return nil, errb end
    local pm = require 'cartograph.spec.profile'
    for _, rt in ipairs({ from, to }) do
        local prof = pm.load(rt)
        if prof and not M.name_queryable(prof) then
            return nil, ('%s is a signature-keyed artifact with no name surface —'
                .. ' a diff against it would call everything lost'):format(rt)
        end
    end
    local res = M.diff_entries(a, b)
    res.size_from, res.size_to = M.profile_size(pm.load(from)), M.profile_size(pm.load(to))
    return res
end

--- The pure comparison of two audit results — the whole semantic of a move, with
--- no disk in it, so it is testable without inventing profile artifacts. Both
--- audits score the SAME requirement set, so a name present in one and absent
--- from the other is a genuine status change rather than a set mismatch.
function M.diff_entries(a, b)
    local bystatus = {}
    for _, e in ipairs(b.entries) do bystatus[e.name] = e.provided end
    local res = { from = a.runtime, to = b.runtime, lost = {}, gained = {},
        kept = 0, neither = 0 }
    for _, e in ipairs(a.entries) do
        local inB = bystatus[e.name]
        if e.provided and not inB then
            res.lost[#res.lost + 1] = { name = e.name, calls = e.calls, why = e.why,
                file = e.files and e.files[1] }
        elseif not e.provided and inB then
            res.gained[#res.gained + 1] = { name = e.name, calls = e.calls }
        elseif e.provided then
            res.kept = res.kept + 1
        else
            res.neither = res.neither + 1
        end
    end
    local function bycalls(x, y)
        if x.calls ~= y.calls then return x.calls > y.calls end
        return x.name < y.name
    end
    table.sort(res.lost, bycalls)
    table.sort(res.gained, bycalls)
    return res
end

--- The diff as lines. Direction matters and the wording says so.
function M.diff_report(store, from, to, opts)
    local res, err = M.diff(store, from, to)
    if not res then return { 'portability: ' .. err } end
    local cap = (opts and opts.cap) or 20
    local L = {}
    L[#L + 1] = ('portability — MOVING FROM %s TO %s'):format(res.from, res.to)
    L[#L + 1] = ('  %d name(s) LOST, %d gained, %d provided by both, %d by neither')
        :format(#res.lost, #res.gained, res.kept, res.neither)
    L[#L + 1] = ('  profiles claim %d and %d symbols — a thin target inflates "lost"')
        :format(res.size_from, res.size_to)
    L[#L + 1] = ''
    if #res.lost == 0 then
        L[#L + 1] = ('  nothing %s provides is absent from %s'):format(res.from, res.to)
    else
        L[#L + 1] = ('  LOST — %s provides these, %s does not (the porting work):')
            :format(res.from, res.to)
        for i = 1, math.min(cap, #res.lost) do
            local e = res.lost[i]
            L[#L + 1] = ('    %-34s %4d call(s)  %s'):format(e.name, e.calls, e.file or '')
        end
        if #res.lost > cap then
            L[#L + 1] = ('    … +%d more'):format(#res.lost - cap)
        end
        L[#L + 1] = '  Still NOT "missing": the target artifact may simply be thinner,'
        L[#L + 1] = '  and a dependency may supply the name in either environment.'
    end
    if #res.gained > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('  GAINED — %s provides these and %s did not:'):format(res.to, res.from)
        if #res.gained > #res.lost then
            -- lua-factorio ⊇ luajit, so that move only loses. ruby-rails does NOT
            -- contain plain ruby core, so it gains — read that as the profiles
            -- covering different ground, not as the target being richer.
            L[#L + 1] = '    (more gained than lost: these two profiles OVERLAP rather'
            L[#L + 1] = '    than nest, so this is a coverage difference between the'
            L[#L + 1] = '    artifacts — not evidence that the target is richer)'
        end
        for i = 1, math.min(5, #res.gained) do
            L[#L + 1] = ('    %-34s %4d call(s)'):format(res.gained[i].name, res.gained[i].calls)
        end
        if #res.gained > 5 then
            L[#L + 1] = ('    … +%d more'):format(#res.gained - 5)
        end
    end
    return L
end

--- THE VERSION THIS CODE DECLARES IT TARGETS, on the same ruler as the profile
--- being scored against — or nil. The link is by NAME: a runtime called
--- `lua-factorio` has an ecosystem spec of the same name, whose `version_scale`
--- says which ruler its environment versions sit on, and versionfloor reads the
--- declaration out of the package manifest.
---
--- This is the fact that turns "score against some profile" into "you are porting
--- 1.1 -> 2.0". It was sitting in info.json, in a file the resolver ALREADY parses,
--- and the report never read it — so the header printed the artifact's version and
--- said nothing about the code's.
function M.declared_for(store, runtime)
    local root = (store.data or {}).root
    if not root or root:match('^%w+://') then return nil end
    local ok_e, ecomod = pcall(require, 'cartograph.spec.ecosystem')
    if not ok_e then return nil end
    local eco = ecomod.load(runtime)
    local scale = eco and (eco.identity or {}).version_scale
    if not scale then return nil end
    return require('cartograph.versionfloor').declared(root, scale)
end

--- Display lines. `opts.cap` limits the not-in-profile list (default 25).
function M.report(store, runtime, opts)
    local res, err = M.audit(store, runtime)
    if not res then return { 'portability: ' .. err } end
    local cap = (opts and opts.cap) or 25
    local L = {}
    local decl = M.declared_for(store, runtime)
    if decl then
        -- both ends NAMED, on one ruler: the code's declared target and the
        -- artifact's version. Without this the header stated only the artifact's,
        -- which reads as a claim about the environment rather than about a MOVE.
        L[#L + 1] = ('portability — MOVING FROM %s %s (declared in %s) TO %s%s')
            :format(decl.scale, decl.raw, decl.source, res.runtime,
                res.version and (' ' .. tostring(res.version)) or '')
        L[#L + 1] = ('  %d of %d external name(s) provided by the target')
            :format(res.provided, res.provided + res.unknown)
    else
        L[#L + 1] = ('portability — %s%s: %d of %d external name(s) provided')
            :format(res.runtime, res.version and (' ' .. tostring(res.version)) or '',
                res.provided, res.provided + res.unknown)
    end
    L[#L + 1] = ('  the profile claims %d symbols; a verdict is only as good as that')
        :format(res.size)
    L[#L + 1] = ''
    local shown = 0
    if res.unknown == 0 then
        L[#L + 1] = '  every external name is accounted for by this profile'
    else
        -- GROUPED BY WHY, and NOT called porting work. This list used to be headed
        -- "candidate porting work", which was wrong for every entry rather than for
        -- most: with a methods-only artifact that models global-rooted calls, a miss
        -- is never evidence the target lacks the name. Saying which KIND of blindness
        -- produced each miss is the honest form, and it names what would fix it.
        L[#L + 1] = ('  NOT IN %s — %d name(s) the artifact cannot adjudicate,'
            .. ' grouped by WHY:'):format(res.runtime, res.unknown)
        -- the general disclaimer stays, above the per-group reasons: NOT-IN-PROFILE
        -- is not "missing", and a reader who skims past the groups should still meet
        -- that in one line
        L[#L + 1] = '    (NOT-IN-PROFILE is not "missing" — a dependency may supply'
            .. ' it, or the artifact may not model it at all.)'
        -- `absent` FIRST: it is the only group that says anything about the target
        local groups, order = {}, { 'absent', 'receiver-typed',
            'unenumerated-namespace', 'unclaimed-bare', 'other-language' }
        for _, e in ipairs(res.entries) do
            if not e.provided then
                local g = groups[e.reason]
                if not g then g = { n = 0, calls = 0, items = {} }; groups[e.reason] = g end
                g.n = g.n + 1; g.calls = g.calls + e.calls
                g.items[#g.items + 1] = e
            end
        end
        local per = math.max(3, math.floor(cap / 3))
        for _, key in ipairs(order) do
            local g = groups[key]
            if g then
                L[#L + 1] = ''
                L[#L + 1] = ('    %d name(s), %d call(s) — %s'):format(g.n, g.calls,
                    REASON_TEXT[key])
                for i = 1, math.min(per, #g.items) do
                    local e = g.items[i]
                    L[#L + 1] = ('      %-36s %4d call(s)  %s'):format(e.name,
                        e.calls, e.files[1] or '')
                    shown = shown + 1
                end
                if #g.items > per then
                    L[#L + 1] = ('      … and %d more'):format(#g.items - per)
                end
            end
        end
        L[#L + 1] = ''
        if not groups['absent'] then
            L[#L + 1] = '  no ABSENT group: nothing here is a name a fully-enumerated'
            L[#L + 1] = '  class could have held, so nothing is evidence about the target.'
        end
    end
    L[#L + 1] = ''
    L[#L + 1] = ('  provided by %s: %d name(s)'):format(res.runtime, res.provided)
    for _, e in ipairs(res.entries) do
        if e.provided then
            L[#L + 1] = ('    %-38s %4d call(s)  via %s'):format(e.name, e.calls, e.why)
            break
        end
    end
    if res.provided > 1 then
        L[#L + 1] = ('    … and %d more'):format(res.provided - 1)
    end
    return L
end

--- The code's OWN profile as a report: what it requires, which shipped
--- environment covers most of it, and where each requirement comes from.
function M.requires_report(store)
    local ranked, req = M.rank(store)
    local groups, unclaimed = M.manifest(store)
    local langs = {}
    for l in pairs(req.langs) do langs[#langs + 1] = l end
    table.sort(langs)
    local L = {}
    L[#L + 1] = ("this code REQUIRES — %s: %d external name(s)%s"):format(
        table.concat(langs, '/'), req.total,
        req.floor and (', version floor ' .. (req.scale and (req.scale .. ' ') or '')
            .. req.floor) or '')
    L[#L + 1] = '  the inverse of an environment profile: the same currency, other'
    L[#L + 1] = '  direction, so the questions below are set algebra over the two.'
    L[#L + 1] = ''
    L[#L + 1] = '  TIGHTEST ENVIRONMENT — shipped profiles by coverage of that set:'
    if #ranked == 0 then
        L[#L + 1] = '    (no shipped profile targets this language)'
    end
    for _, r in ipairs(ranked) do
        if r.queryable then
            L[#L + 1] = ('    %-16s %5.1f%% covered  (%d of %d; profile claims %d)')
                :format(r.runtime, r.pct, r.provided, r.provided + r.unknown, r.size)
        else
            L[#L + 1] = ('    %-16s   not rankable — signature-keyed artifact (%d'
                .. ' sigs), no name surface to query'):format(r.runtime, r.size)
        end
    end
    if #ranked > 0 then
        L[#L + 1] = '    coverage is not a verdict: full coverage means this boundary'
        L[#L + 1] = '    holds no counter-evidence, not that the code runs there.'
    end
    L[#L + 1] = ''
    L[#L + 1] = '  DEPENDENCY MANIFEST — the requirement set grouped by who provides it:'
    local keys = {}
    for k in pairs(groups) do keys[#keys + 1] = k end
    table.sort(keys, function (a, b) return groups[a].names > groups[b].names end)
    for _, k in ipairs(keys) do
        L[#L + 1] = ('    %-28s %4d name(s), %5d call(s)'):format(k,
            groups[k].names, groups[k].calls)
    end
    L[#L + 1] = ('    %-28s %4d name(s)'):format('claimed by no profile', #unclaimed)
    L[#L + 1] = '      — most often a sibling module or a third-party dependency,'
    L[#L + 1] = '        NOT evidence that anything is missing. Top by call volume:'
    for i = 1, math.min(10, #unclaimed) do
        L[#L + 1] = ('        %-34s %4d call(s)'):format(unclaimed[i].name,
            unclaimed[i].calls)
    end
    return L
end

return M
