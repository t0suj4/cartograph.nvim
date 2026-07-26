-- ROSTER REPORT: what packages an ecosystem's install actually holds, and what the
-- roster could NOT establish ([[cartograph-package-ecosystem]]).
--
-- `spec/ecosystem/init.lua` builds the roster — the corpus shape. This asks the
-- questions a person has before extracting one: where did these roots come from,
-- which packages are here in which form, which of them load, and which declared
-- dependency is not present. The roster answers all of that already and threw most
-- of it away; nothing consumed the fields.
--
-- IT IS ALSO WHERE THREE DECLARED RULES FINALLY GET READ. tools/specaudit.lua
-- reports rules nothing consults, and these three sat on that list because a roster
-- BUILDS a corpus and never explains itself:
--
--   enablement.affects        = 'honesty'  -> a disabled package stays in the roster
--                                            and still resolves; the report says so
--                                            IN THOSE TERMS rather than hiding it
--   identity.filename_hint                -> a search key, never identity. The report
--                                            AUDITS it: how often does the filename
--                                            disagree with the manifest?
--   roots.install.derivable   = false     -> "not found" and "not derivable, must be
--                                            specified" are different states, and
--                                            only the spec knows which this is
--
-- HONESTY: every count here is about THIS install. A dependency reported missing may
-- be satisfied by a package the user has not downloaded, by the install's builtins
-- when the install root is unknown, or by a version this report cannot compare — and
-- each of those is reported as its own bucket rather than folded into "missing".

local M = {}

local eco_mod = require 'cartograph.spec.ecosystem'

-- ── dependency syntax ────────────────────────────────────────────────────────
-- Factorio spells a dependency `"? other-mod >= 1.2.3"`. The PREFIX carries whether
-- an absence is a problem at all, which is the whole reason this is parsed rather
-- than counted: reporting an optional dependency as missing would make a healthy
-- install look broken (measured on the real mods dir: optionals outnumber required
-- misses).
local PREFIXES = {
    { tok = '(?)', kind = 'optional' },  -- hidden optional; longest first
    { tok = '!', kind = 'incompatible' },
    { tok = '?', kind = 'optional' },
    { tok = '~', kind = 'required' },    -- required, but does not fix load order
}

--- Parse one dependency string into { kind, name, op, version }. Never nil: an
--- unparseable entry becomes kind='unparsed' and is REPORTED, because silently
--- dropping it would understate what the manifest asked for.
function M.parse_dep(s)
    if type(s) ~= 'string' then return { kind = 'unparsed', raw = tostring(s) } end
    local rest = s:gsub('^%s+', '')
    local kind = 'required'
    for _, p in ipairs(PREFIXES) do
        if rest:sub(1, #p.tok) == p.tok then
            kind = p.kind
            rest = rest:sub(#p.tok + 1):gsub('^%s+', '')
            break
        end
    end
    local name, op, version = rest:match('^(.-)%s*([<>=]+)%s*([%w%.%-]+)%s*$')
    if not name or name == '' then
        name, op, version = rest:gsub('%s+$', ''), nil, nil
    end
    if name == '' then return { kind = 'unparsed', raw = s } end
    return { kind = kind, name = name, op = op, version = version, raw = s }
end

--- Does `have` satisfy `op version`? Returns true / false / nil, and nil is a real
--- answer: a constraint this cannot compare (a non-numeric version, an operator not
--- declared) must not be reported as either satisfied or violated.
function M.satisfies(have, op, version)
    if not op or not version or not have then return nil end
    if not (have:match('^%d[%d%.]*$') and version:match('^%d[%d%.]*$')) then
        return nil
    end
    -- both sides are on the ECOSYSTEM's own scale (identity.version_scale), so this
    -- comparison is inside one ruler — the mistake versionfloor records is comparing
    -- across them, not comparing at all
    local vf = require 'cartograph.versionfloor'
    local older, newer = vf.older(have, version), vf.older(version, have)
    local eq = not older and not newer
    if op == '=' or op == '==' then return eq end
    if op == '>=' then return eq or newer end
    if op == '>' then return newer end
    if op == '<=' then return eq or older end
    if op == '<' then return older end
    return nil
end

-- ── the audit ────────────────────────────────────────────────────────────────

--- Structured roster facts. opts is passed through to eco.roster (dir / user /
--- transport / enabled_only), so a caller can point this at a fixture.
--- Returns (audit, nil) or (nil, why).
function M.audit(name, opts)
    opts = opts or {}
    local eco = eco_mod.load(name)
    if not eco then return nil, 'no ecosystem spec ' .. tostring(name) end
    local roster, why = eco_mod.roster(name, opts)
    if not roster then return nil, why end

    local ident, enab = eco.identity or {}, eco.enablement or {}
    local A = {
        ecosystem = name, dir = roster.dir, root = roster.root,
        packages = roster.packages, files = #roster.files,
        transport = roster.transport,
        unsupported = eco_mod.stack_spec(eco).unsupported,
        -- WHAT the enablement fact is allowed to affect, from the spec. A report that
        -- hardcoded 'honesty' would be restating a rule it does not own.
        enablement_affects = enab.affects,
        by_form = {}, enabled = 0, disabled = 0, unlisted = 0,
        hint = { checked = 0, agree = 0, disagree = {} },
        inner = { checked = 0, disagree = 0 },
        deps = { required = 0, optional = 0, satisfied = 0, builtin = 0,
            missing = {}, missing_optional = {}, conflicts = {},
            version_bad = {}, version_unknown = 0, unparsed = {} },
    }

    -- the roots, and HOW each was established (override vs autodetection vs absent)
    A.roots = {}
    for _, which in ipairs({ 'user', 'install' }) do
        if (eco.roots or {})[which] then
            local path, how = eco_mod.root(eco, which, opts[which])
            A.roots[which] = { path = path, how = how,
                -- the spec's own claim about whether autodetection can be trusted
                derivable = eco.roots[which].derivable }
        end
    end

    local builtin = {}
    for _, b in ipairs(((eco.roots or {}).install or {}).builtin or {}) do
        builtin[b] = true
    end

    local present = {}
    for _, p in ipairs(roster.packages) do
        present[p.name] = p
        A.by_form[p.form] = (A.by_form[p.form] or 0) + 1
        if p.enabled == true then A.enabled = A.enabled + 1
        elseif p.enabled == false then A.disabled = A.disabled + 1
        else A.unlisted = A.unlisted + 1 end

        -- THE HINT AUDIT. `filename_hint` exists so a package can be FOUND without
        -- opening 199 archives; the rule attached to it is that identity always comes
        -- from the manifest. That rule is only credible if someone measures the
        -- disagreement, so this does.
        if p.form == 'archive' and type(p.base) == 'table' then
            if ident.filename_hint then
                local file = p.base.container:match('([^/]+)$') or ''
                local guess = file:match(ident.filename_hint)
                if guess then
                    A.hint.checked = A.hint.checked + 1
                    if guess == p.name then A.hint.agree = A.hint.agree + 1
                    else
                        A.hint.disagree[#A.hint.disagree + 1] =
                            { file = file, hint = guess, manifest = p.name }
                    end
                end
            end
            -- THE OTHER NAME, and the one the "never the filename" rule is really
            -- about: the archive's single top-level DIRECTORY. The hint and the inner
            -- directory are different guesses at identity and they do not fail
            -- together, so measuring only one would credit or condemn the wrong rule.
            if p.base.prefix then
                A.inner.checked = A.inner.checked + 1
                if p.base.prefix ~= p.name then A.inner.disagree = A.inner.disagree + 1 end
            end
        end
    end

    -- DEPENDENCIES, judged against this install only.
    --
    -- ENABLEMENT IS LOAD-BEARING HERE, which is what `affects = 'honesty'` licenses:
    -- a finding is ACTIVE only if the packages involved actually load. Without the
    -- split this reported 26 conflicts on a healthy install — every one between mods
    -- that are present and disabled, which is the normal state of a mods directory
    -- (186 of 197 disabled here). Counting them as faults would make "declared
    -- incompatible" useless. A latent finding is still reported, as latent.
    for _, p in ipairs(roster.packages) do
        local live = p.enabled ~= false
        for _, raw in ipairs(p.deps or {}) do
            local d = M.parse_dep(raw)
            local tgt = present[d.name]
            if d.kind == 'unparsed' then
                A.deps.unparsed[#A.deps.unparsed + 1] = { of = p.name, raw = d.raw }
            elseif d.kind == 'incompatible' then
                if tgt then
                    A.deps.conflicts[#A.deps.conflicts + 1] = { of = p.name,
                        name = d.name, active = live and tgt.enabled ~= false }
                end
            else
                if d.kind == 'required' then A.deps.required = A.deps.required + 1
                else A.deps.optional = A.deps.optional + 1 end
                if tgt then
                    local okv = M.satisfies(tgt.version, d.op, d.version)
                    if okv == false then
                        A.deps.version_bad[#A.deps.version_bad + 1] = { of = p.name,
                            name = d.name, want = (d.op or '') .. (d.version or ''),
                            have = tgt.version, active = live }
                    else
                        if okv == nil and d.op then
                            A.deps.version_unknown = A.deps.version_unknown + 1
                        end
                        A.deps.satisfied = A.deps.satisfied + 1
                    end
                elseif builtin[d.name] then
                    -- provided by the INSTALL, not the mods dir. Counted apart because
                    -- whether it is really present depends on the install root, which
                    -- may be unknown — see the roots section of the report.
                    A.deps.builtin = A.deps.builtin + 1
                elseif d.kind == 'optional' then
                    A.deps.missing_optional[#A.deps.missing_optional + 1] =
                        { of = p.name, name = d.name }
                else
                    A.deps.missing[#A.deps.missing + 1] =
                        { of = p.name, name = d.name, active = live,
                            want = d.op and (d.op .. (d.version or '')) or nil }
                end
            end
        end
    end
    return A
end

-- ── display ──────────────────────────────────────────────────────────────────

local function plural(n, one, many) return n == 1 and one or many end

--- Report lines. opts.cap limits each list (default 12).
function M.report(name, opts)
    opts = opts or {}
    local A, why = M.audit(name, opts)
    if not A then return { 'roster: ' .. tostring(why) } end
    local cap = opts.cap or 12
    local L = {}
    local function add(s) L[#L + 1] = s end

    add(('roster — %s'):format(A.ecosystem))
    add(('  %s'):format(A.root))
    add(('  %d package(s), %d source file(s)'):format(#A.packages, A.files))

    -- ROOTS: where each came from, and what "not found" means for it
    add('')
    add('  ROOTS')
    for _, which in ipairs({ 'user', 'install' }) do
        local r = A.roots[which]
        if r then
            if r.path then
                add(('    %-8s %s  (%s)'):format(which, r.path, r.how))
            elseif r.derivable == false then
                -- the distinction the spec exists to record: this is not a failed
                -- search, it is a root autodetection is declared unable to find
                add(('    %-8s NOT SPECIFIED — the spec declares it NOT DERIVABLE,'
                    .. ' so it must be configured; nothing is guessed'):format(which))
            else
                add(('    %-8s not found (%s)'):format(which, r.how))
            end
        end
    end
    if A.roots.install and not A.roots.install.path
        and A.deps.builtin > 0 then
        add(('      %d dependenc(ies) point at packages the install provides —'
            .. ' unverifiable while the install root is unknown'):format(A.deps.builtin))
    end

    -- FORMS + transport
    add('')
    local forms = {}
    for f, n in pairs(A.by_form) do forms[#forms + 1] = ('%s %d'):format(f, n) end
    table.sort(forms)
    add(('  FORMS   %s'):format(table.concat(forms, ' · ')))
    local kinds = {}
    for _, e in ipairs(A.transport or {}) do kinds[#kinds + 1] = e.kind end
    add(('  READ THROUGH  %s'):format(table.concat(kinds, ' -> ')))
    if #(A.unsupported or {}) > 0 then
        add(('    UNSUPPORTED here: %s — packages in that form are INVISIBLE, not'
            .. ' absent'):format(table.concat(A.unsupported, ' ')))
    end

    -- ENABLEMENT, in the terms the spec allows
    add('')
    add(('  ENABLEMENT   %d enabled · %d disabled · %d not listed'):format(
        A.enabled, A.disabled, A.unlisted))
    if A.enablement_affects == 'honesty' then
        add('    affects HONESTY, never resolution: a disabled package is still'
            .. ' present and still readable, so a require into it resolves and'
            .. ' carries that its target does not load in this configuration')
    elseif A.enablement_affects then
        add(('    the spec says enablement affects %q — this report only knows'
            .. ' how to explain \'honesty\''):format(A.enablement_affects))
    end
    if A.unlisted > 0 then
        add(('    %d package(s) appear in no mod list — present, load state UNKNOWN,'
            .. ' which is not the same as disabled'):format(A.unlisted))
    end

    -- THE TWO GUESSES AT IDENTITY, measured separately
    if A.hint.checked > 0 or A.inner.checked > 0 then
        add('')
        add('  IDENTITY   from the manifest, always. The two cheaper guesses, scored:')
        if A.hint.checked > 0 then
            local bad = #A.hint.disagree
            add(('    filename hint      %d of %d disagree%s'):format(bad,
                A.hint.checked, bad == 0
                    and ' — it held on every archive here, so it is a sound SEARCH'
                        .. ' key (which is all it is declared to be)' or ''))
            for i = 1, math.min(3, bad) do
                local d = A.hint.disagree[i]
                add(('      %-40s hint %-22s manifest %s'):format(d.file, d.hint,
                    d.manifest))
            end
            if bad > 3 then add(('      … and %d more'):format(bad - 3)) end
        end
        if A.inner.checked > 0 then
            add(('    inner directory    %d of %d disagree%s'):format(
                A.inner.disagree, A.inner.checked,
                A.inner.disagree > 0
                    and ' — THIS is why identity is never a path: an archive\'s top'
                        .. ' directory is not its package name' or ''))
        end
    end

    -- DEPENDENCIES
    add('')
    add(('  DEPENDENCIES   %d required · %d optional · %d satisfied here · %d from'
        .. ' the install'):format(A.deps.required, A.deps.optional,
        A.deps.satisfied, A.deps.builtin))
    if A.deps.version_unknown > 0 then
        add(('    %d version constraint(s) NOT COMPARED (non-numeric or an'
            .. ' undeclared operator) — counted satisfied on presence alone')
            :format(A.deps.version_unknown))
    end
    -- ACTIVE FIRST, LATENT COUNTED. A finding about a package that does not load is
    -- true and not a problem, and mixing the two buries the ones that are.
    local function split(items)
        local act, lat = {}, {}
        for _, it in ipairs(items) do
            if it.active == false then lat[#lat + 1] = it else act[#act + 1] = it end
        end
        return act, lat
    end
    local function list(items, label, fmt, latent_note)
        local act, lat = split(items)
        if #act > 0 then
            add(('    %s — %d:'):format(label, #act))
            for i = 1, math.min(cap, #act) do add('      ' .. fmt(act[i])) end
            if #act > cap then add(('      … and %d more'):format(#act - cap)) end
        end
        if #lat > 0 then
            add(('    %d LATENT — %s, so they are facts about the install, not'
                .. ' faults in it'):format(#lat, latent_note))
        end
    end
    list(A.deps.missing, 'REQUIRED BUT NOT PRESENT (this install, not "does not'
        .. ' exist")', function (d)
        return ('%-30s needs %s%s'):format(d.of, d.name, d.want and (' ' .. d.want) or '')
    end, 'the package declaring the dependency does not load')
    list(A.deps.version_bad, 'PRESENT AT THE WRONG VERSION', function (d)
        return ('%-30s needs %s %s, has %s'):format(d.of, d.name, d.want, d.have)
    end, 'the package declaring the constraint does not load')
    list(A.deps.conflicts, 'DECLARED INCOMPATIBLE, AND BOTH LOAD', function (d)
        return ('%-30s conflicts with %s'):format(d.of, d.name)
    end, 'at least one side is disabled')
    if #A.deps.missing_optional > 0 then
        add(('    %d optional dependenc%s absent — normal, not a fault'):format(
            #A.deps.missing_optional,
            plural(#A.deps.missing_optional, 'y is', 'ies are')))
    end
    list(A.deps.unparsed, 'UNPARSEABLE DEPENDENCY (reported, never dropped)',
        function (d) return ('%-30s %s'):format(d.of, d.raw) end, 'unreachable')
    local nact = select(1, split(A.deps.missing))
    local nver = select(1, split(A.deps.version_bad))
    local ncon = select(1, split(A.deps.conflicts))
    if #nact == 0 and #nver == 0 and #ncon == 0 then
        add('    among the packages that LOAD: nothing required is missing,'
            .. ' mis-versioned or in conflict')
    end
    return L
end

return M
