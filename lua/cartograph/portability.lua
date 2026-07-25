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

--- How many symbols the profile actually claims — the weight of any verdict.
function M.profile_size(prof)
    local n = 0
    for _, field in ipairs({ 'vocab', 'free', 'sigs' }) do
        for _ in pairs(prof[field] or {}) do n = n + 1 end
    end
    return n
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
    local externals = require 'cartograph.externals'
    local s = externals.surface(store)
    local res = { runtime = runtime, lang = prof.lang, version = prof.version,
        size = M.profile_size(prof), provided = 0, unknown = 0, entries = {} }
    for base, e in pairs(s.bases) do
        -- score the base, then each member under it: a provided namespace
        -- covers its members, an unprovided one may still have provided members
        local why = M.provides(prof, base)
        local names = {}
        if next(e.members) == nil then
            names[base] = e.calls
        else
            for m, n in pairs(e.members) do names[base .. '.' .. m] = n end
        end
        for name, n in pairs(names) do
            local w = why or M.provides(prof, name)
                or M.provides(prof, name:match('([%w_]+[!?]?)$') or '')
            local files = {}
            for f in pairs(e.files) do files[#files + 1] = f end
            table.sort(files)
            res.entries[#res.entries + 1] = { name = name, calls = n,
                provided = w ~= nil, why = w, files = files }
            if w then res.provided = res.provided + 1 else res.unknown = res.unknown + 1 end
        end
    end
    table.sort(res.entries, function (a, b)
        if a.provided ~= b.provided then return not a.provided end -- unknown first
        if a.calls ~= b.calls then return a.calls > b.calls end
        return a.name < b.name
    end)
    return res
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

return M
