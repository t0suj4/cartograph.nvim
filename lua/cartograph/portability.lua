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
        if prof.vocab and prof.vocab[rest] then return 'vocab' end
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
                if M.provides(prof, name)
                    or M.provides(prof, name:match('([%w_]+[!?]?)$') or '') then
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
            if M.provides(e.prof, name)
                or M.provides(e.prof, name:match('([%w_]+[!?]?)$') or '') then
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
            or M.provides(prof, name:match('([%w_]+[!?]?)$') or '')
        res.entries[#res.entries + 1] = { name = name, calls = n,
            provided = w ~= nil, why = w, files = { req.where[name] } }
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
        for i = 1, math.min(5, #res.gained) do
            L[#L + 1] = ('    %-34s %4d call(s)'):format(res.gained[i].name, res.gained[i].calls)
        end
        if #res.gained > 5 then
            L[#L + 1] = ('    … +%d more'):format(#res.gained - 5)
        end
    end
    return L
end

--- Display lines. `opts.cap` limits the not-in-profile list (default 25).
function M.report(store, runtime, opts)
    local res, err = M.audit(store, runtime)
    if not res then return { 'portability: ' .. err } end
    local cap = (opts and opts.cap) or 25
    local L = {}
    L[#L + 1] = ('portability — %s%s: %d of %d external name(s) provided')
        :format(res.runtime, res.version and (' ' .. tostring(res.version)) or '',
            res.provided, res.provided + res.unknown)
    L[#L + 1] = ('  the profile claims %d symbols; a verdict is only as good as that')
        :format(res.size)
    L[#L + 1] = '  NOT-IN-PROFILE is not "missing": a dependency may supply it, or the'
    L[#L + 1] = '  artifact may be partial. This scores the boundary, it does not rule.'
    L[#L + 1] = ''
    local shown = 0
    if res.unknown == 0 then
        L[#L + 1] = '  every external name is accounted for by this profile'
    else
        L[#L + 1] = ('  NOT IN %s (candidate porting work, most-used first):'):format(res.runtime)
        for _, e in ipairs(res.entries) do
            if not e.provided and shown < cap then
                shown = shown + 1
                L[#L + 1] = ('    %-38s %4d call(s)  %s'):format(e.name, e.calls,
                    e.files[1] or '')
            end
        end
        if res.unknown > shown then
            L[#L + 1] = ('    … +%d more'):format(res.unknown - shown)
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
