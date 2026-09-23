-- drift.lua — RECOVER A FAMILY FROM OBSERVED STATE, THEN SAY WHAT A LATER OBSERVATION DID
-- TO IT, AND WHETHER THAT IS DRIFT (CART-1040, CART-1041).
--
-- USER (2026-09-23): "recovering some kind of plan or view from existing configuration,
-- system state, files on the machines, tolerating and reporting drift."
--
-- ── THREE STEPS, AND WHY THEY ARE SEPARATE ─────────────────────────────────────
--   anchor   recover the families ONCE: partition then generalize (positional terms), or
--            one keyed template (`kv_generalize`). ⚠ MEASURED ON THE k8s DEMO: re-partitioning
--            after drift MOVES THE BOUNDARY the drift is judged against (the resources plant
--            reshuffled the Deployment families), so the anchor is taken before and kept.
--   observe  classify one member's new state against its anchored family — `A.classify`
--            (positional) or `A.kv_classify` (keyed), ONE kind vocabulary (none / value /
--            template / mixed / straddle) — and render every location as a KEY PATH
--            (`$.spec.template.spec.securityContext.runAsNonRoot`), not a tree path.
--   verdict  decide per change whether it is drift, from PRIORS the caller supplies. The
--            classifier names the LEG that changed; it cannot say whether that was meant.
--
-- ── THE PRIORS, IN THE ORDER THEY DECIDE, AND WHAT EACH WAS MEASURED TO BE WORTH ──
--   authorised   a plan/journal entry covers this change            -> intended / drift
--   declared     the declared value at this path (a manifest, `en`)  -> intended / drift
--   parameter    the difference is a property OF THE MEMBER (plural forms per language:
--                0 errors over 341 parents x 49 locales)             -> parameter
--   history      the key is NEW in the declaration (lag) or was REMOVED from it (leftover);
--                the frequency prior got this exactly backwards (precision 0 on stale keys)
--   invariant    a straddle broke a shared-hole invariant ("image == the service's name")
--                                                                    -> suspect
--   none of them                                                      -> undecided
-- ⚠ THERE IS NO FREQUENCY PRIOR HERE ON PURPOSE. Measured: precision 1.0 / recall 0.22 in
-- one direction and precision 0.0 in the other, at 47 peers; noise at 4.

local M = {}

local function alg()
    local A, why = require('cartograph.algebra').load()
    if not A then error('the algebra is unavailable: ' .. tostring(why)) end
    return A
end

-- text of a term that may hold holes (a hole prints as «h»)
local function text(A, x)
    if x == nil then return nil end
    if type(x) ~= 'table' then return tostring(x) end
    if x == A.KV_ABSENT then return '(absent)' end
    local out = {}
    local function go(t)
        if type(t) ~= 'table' then out[#out + 1] = tostring(t); return end
        if A.is_hole(t) then out[#out + 1] = '«' .. tostring(t.h) .. '»'; return end
        if t.k == 'lit' then out[#out + 1] = tostring(t.v); return end
        if t.o then out[#out + 1] = A.kv_ser(t); return end
        for _, c in ipairs(t.kids or {}) do go(c) end
    end
    go(x)
    return table.concat(out)
end
M._text = text

local function at(t, path)
    for _, step in ipairs(path) do
        if type(t) ~= 'table' or not t.kids then return nil end
        t = t.kids[step]
    end
    return t
end

local PAIR = { block_mapping_pair = true, flow_pair = true }
local ITEM = { block_sequence_item = true }

--- ★ A TREE PATH AS A KEY PATH. Walks `term` along `path`, appending the key of every
--- mapping pair and the 1-based index of every sequence item it passes through; a hole met
--- before the path ends is written `«h»` and ends the walk. Returns nil when the path
--- crosses no mapping pair at all (not YAML-shaped) — the caller keeps the tree path.
--- @return string|nil
function M.key_path(term, path)
    local A = alg()
    local out, t, any = { '$' }, term, false
    for _, step in ipairs(path) do
        if type(t) ~= 'table' then break end
        if A.is_hole(t) then out[#out + 1] = '.«' .. tostring(t.h) .. '»'; break end
        local kid = t.kids and t.kids[step]
        if kid == nil then break end
        if type(kid) == 'table' and PAIR[kid.k] then
            local key
            for _, c in ipairs(kid.kids or {}) do
                if type(c) == 'table' and c.k ~= 'lit' then key = text(A, c); break end
            end
            out[#out + 1] = '.' .. tostring(key or '?'):gsub('^%s+', ''):gsub('%s+$', '')
            any = true
        elseif type(kid) == 'table' and ITEM[kid.k] then
            local n = 0
            for j = 1, step do
                local s = t.kids[j]
                if type(s) == 'table' and ITEM[s.k] then n = n + 1 end
            end
            out[#out + 1] = '[' .. n .. ']'
        end
        t = kid
    end
    if not any then return nil end
    return table.concat(out)
end

--- ★★ ANCHOR: recover the families once.
--- @param members table  positional: { {id, text} } with opts.lang; keyed: { {id, value} } with opts.keyed
--- @param opts table|nil { lang = 'yaml', keyed = bool, partition = bool (default true for >= 3) }
--- @return table|nil anchor, string|nil why
function M.anchor(members, opts)
    opts = opts or {}
    local A = alg()
    local anchor = { keyed = opts.keyed and true or false, lang = opts.lang, families = {}, family_of = {} }
    if opts.keyed then
        local values = {}
        for i, m in ipairs(members) do values[i] = m.value end
        local R = A.kv_generalize(values, {})
        local ids = {}
        for i, m in ipairs(members) do ids[i] = m.id; anchor.family_of[m.id] = { fam = 1, i = i } end
        anchor.families[1] = { ids = ids, R = R }
        return anchor
    end
    local rd = require 'cartograph.algebraread'
    local terms = {}
    for i, m in ipairs(members) do
        local t, why = rd.read(m.text, opts.lang)
        if not t then return nil, ('%s does not read as %s: %s'):format(tostring(m.id), tostring(opts.lang), tostring(why)) end
        terms[i] = t
    end
    local groups
    if opts.partition ~= false and #members >= 3 then
        groups = {}
        for _, f in ipairs(A.partition(terms, { cost = A.text_size }).families) do groups[#groups + 1] = f.members end
    else
        groups = { {} }
        for i = 1, #members do groups[1][i] = i end
    end
    for g, idxs in ipairs(groups) do
        local sub, ids = {}, {}
        for k, i in ipairs(idxs) do
            sub[k] = terms[i]; ids[k] = members[i].id
            anchor.family_of[members[i].id] = { fam = g, i = k }
        end
        local G = A.generalize(sub, {})
        anchor.families[g] = { ids = ids, T = G.template, Vs = G.values, env = G.env }
    end
    return anchor
end

--- ★★ OBSERVE: classify one member's new state against its anchored family.
--- Every change comes back as { leg = 'value' | 'template' | 'straddle', what, path,
--- sites?, hole?, from?, to? } with KEY PATHS wherever the shape allows one.
--- @param new string|table  positional: the new text; keyed: the new kv value
--- @return table|nil obs, string|nil why
function M.observe(anchor, id, new)
    local A = alg()
    local f = anchor.family_of[id]
    if not f then return nil, ('%s is not a member of this anchor'):format(tostring(id)) end
    local F = anchor.families[f.fam]
    local obs = { id = id, family = F.ids, changes = {} }
    local function add(c) obs.changes[#obs.changes + 1] = c end
    if anchor.keyed then
        local C = A.kv_classify(F.R, f.i, new)
        obs.kind, obs.why, obs.proposal, obs.rebuilds = C.kind, C.why, C.proposal, C.rebuilds
        for _, c in ipairs(C.changes) do
            add { leg = 'template', what = c.what, path = c.path, from = text(A, c.from), to = text(A, c.to) }
        end
        local presence_at = {}
        for _, c in ipairs(C.values) do
            if c.kind == 'presence' then for _, p in ipairs(c.sites) do presence_at[p] = true end end
        end
        for _, c in ipairs(C.values) do
            local what = 'changed'
            if c.kind == 'presence' then what = (c.to == true) and 'appeared' or 'vanished'
            elseif c.from == A.KV_ABSENT then what = 'appeared'
            elseif c.to == A.KV_ABSENT then what = 'vanished' end
            -- a key's TEXT going absent -> "X" is part of the key appearing, not a rewording:
            -- report the appearance once (the presence row), not twice
            if c.kind ~= 'presence' and what ~= 'changed' and presence_at[c.sites[1]] then goto skip end
            add { leg = 'value', what = what, path = c.sites[1], sites = c.sites, hole = c.hole,
                from = text(A, c.from), to = text(A, c.to) }
            ::skip::
        end
        for _, s in ipairs(C.straddles) do
            -- a straddle on a PRESENCE hole is about existence (one key of a group that always
            -- travels together came or went alone); on a VALUE hole it is about wording
            local what = 'broke a shared value'
            if s.kind == 'presence' then what = (s.to == true) and 'appeared' or 'vanished' end
            add { leg = 'straddle', hole_kind = s.kind, what = what, path = s.sites[1], sites = s.sites,
                hole = s.hole, from = text(A, s.from), to = text(A, s.to) }
        end
        return obs
    end
    local rd = require 'cartograph.algebraread'
    local I2, why = rd.read(new, anchor.lang)
    if not I2 then return nil, ('the observation does not read as %s: %s'):format(tostring(anchor.lang), tostring(why)) end
    local C, cwhy = A.classify(F.T, F.Vs[f.i], I2, F.env)
    if not C then return nil, tostring(cwhy) end
    obs.kind, obs.why, obs.hint, obs.proposal = C.kind, C.why, C.hint, C.proposal
    local H = A.sites(F.T)
    local function site_paths(h, which)
        local out = {}
        local e = H[h]
        if not e then return out end
        for k, s in ipairs(e.sites) do
            if not which or which[k] then out[#out + 1] = M.key_path(F.T.body, s.path) or table.concat(s.path, ',') end
        end
        return out
    end
    for _, c in ipairs(C.changed or {}) do
        local sites = site_paths(c.h)
        add { leg = 'value', what = 'changed', hole = c.h, path = sites[1], sites = sites,
            from = text(A, c.from), to = text(A, c.to) }
    end
    for _, tp in ipairs(C.regions or {}) do
        add { leg = 'template', what = 'changed', path = M.key_path(F.T.body, tp) or table.concat(tp, ','),
            from = text(A, at(F.T.body, tp)), to = text(A, at(I2, tp)) }
    end
    if C.kind == 'straddle' and C.hole then
        local which
        if C.sites then which = {}; for _, k in ipairs(C.sites) do which[k] = true end end
        local sites = site_paths(C.hole, which)
        add { leg = 'straddle', hole_kind = 'value', what = 'broke a shared value', hole = C.hole, path = sites[1], sites = sites }
    end
    return obs
end

--- ★★ VERDICT: per change, the first prior that can decide, named.
--- @param priors table { authorised = fn(id, change) -> bool|nil, declared = fn(id, path) ->
---   string|false|nil (false = declared absent; `change` is passed third, so a prior that declares
---   only EXISTENCE — a locale's keys — can answer presence changes alone), parameter = fn(id, change) -> bool|nil,
---   history = fn(path) -> 'new'|'removed'|nil }
--- @return table rows { {change, verdict, prior, why} }
function M.verdict(obs, priors)
    priors = priors or {}
    local rows = {}
    for _, c in ipairs(obs.changes) do
        local v, prior, why
        if c.leg == 'declared' then
            -- ★ A STATIC ROW AGAINST THE DECLARATION (`against_declared`): the row itself says the
            -- declaration disagrees; only the parameter prior can excuse it, and only history can
            -- say whether the member is BEHIND (lag: a new key never had) or KEPT what was dropped
            local h = priors.history and priors.history(c.path)
            if priors.parameter and priors.parameter(obs.id, c) then
                v, prior, why = 'parameter', 'parameter', 'the difference follows a pattern this member keeps everywhere'
            elseif c.what == 'missing' and h == 'new' then
                v, prior, why = 'lag', 'declared+history', 'new in the declaration; this member has not caught up'
            elseif c.what == 'extra' and h == 'removed' then
                v, prior, why = 'leftover', 'declared+history', 'removed from the declaration; this member kept it'
            else
                v, prior = 'drift', 'declared'
                why = c.what == 'missing' and 'the declaration has it and this member does not'
                    or 'this member has it and the declaration does not'
            end
            rows[#rows + 1] = { change = c, verdict = v, prior = prior, why = why }
            goto continue
        end
        do
        local a = priors.authorised and priors.authorised(obs.id, c)
        if a ~= nil then
            v, prior = a and 'intended' or 'drift', 'authorised'
            why = a and 'a recorded plan covers this change' or 'no recorded plan covers this change'
        end
        if not v and priors.declared and c.path then
            local d = priors.declared(obs.id, c.path, c)
            if d ~= nil then
                prior = 'declared'
                -- ⚠ NOT `cond and false or c.to`: that idiom yields c.to when cond holds, so a
                -- vanished key read as nil instead of absent (the history test caught it)
                local now = c.to
                if c.what == 'vanished' or c.what == 'removed' then now = false end
                if d == now or (d == false and now == false) then
                    v, why = 'intended', 'the change moves to the declared state'
                else
                    -- ⚠ NO LAG HERE: an OBSERVED vanish means the member HAD the key at anchor time
                    -- and lost it — a regression. Lag (never had it) is a STATIC row's verdict.
                    v, why = 'drift', ('declared %s, observed %s'):format(d == false and '(absent)' or tostring(d),
                        now == false and '(absent)' or tostring(now))
                end
            end
        end
        if not v and priors.parameter and priors.parameter(obs.id, c) then
            v, prior, why = 'parameter', 'parameter', 'the difference follows a pattern this member keeps everywhere'
        end
        if not v and c.leg == 'straddle' then
            v, prior, why = 'suspect', 'invariant', 'one site of a value the family always shares changed alone'
        end
        if not v then v, prior, why = 'undecided', nil, 'no prior can decide this change' end
        rows[#rows + 1] = { change = c, verdict = v, prior = prior, why = why }
        end
        ::continue::
    end
    return rows
end

--- ★★ AGAINST THE DECLARATION: a STATIC comparison, not an observed change — which keys the
--- declaration has that this member lacks (`missing`), and which it has that the declaration
--- lacks (`extra`). This is where LAG and LEFTOVER live (Discourse: 48,966 lag vs 44,065 gap
--- over 93,031 missing pairs, split by history). Keyed anchors only; leaves are scalar paths.
--- @param declared table  the declared kv value (e.g. the `en` locale)
--- @return table|nil obs, string|nil why
function M.against_declared(anchor, id, declared)
    if not anchor.keyed then return nil, 'against_declared reads a keyed anchor' end
    local f = anchor.family_of[id]
    if not f then return nil, ('%s is not a member of this anchor'):format(tostring(id)) end
    local mine = anchor.families[f.fam].R.instantiate(f.i)
    local function leaves(v, p, out)
        if type(v) == 'table' and v.o then
            for _, k in ipairs(v.keys) do leaves(v.o[k], p .. '.' .. k, out) end
        else out[#out + 1] = p end
        return out
    end
    local have, want = {}, {}
    for _, p in ipairs(leaves(mine, '$', {})) do have[p] = true end
    local changes = {}
    for _, p in ipairs(leaves(declared, '$', {})) do
        want[p] = true
        if not have[p] then changes[#changes + 1] = { leg = 'declared', what = 'missing', path = p } end
    end
    for _, p in ipairs(leaves(mine, '$', {})) do
        if not want[p] then changes[#changes + 1] = { leg = 'declared', what = 'extra', path = p } end
    end
    return { id = id, kind = 'declared', changes = changes }
end

--- ⚠ THE PARAMETER PRIOR SUPPRESSES FINDINGS, SO ITS DEFAULT IS THE CONSERVATIVE END. Measured
--- on Discourse (47 locales against en, missing rows): at >= 2 parents of a shape it excused
--- 5,619 NON-plural rows (be lacking `name` under two bookmark actions); 2,405 at 20; 2,063 at
--- 50; 0 at 100, still excusing 9,618 of the plural rows. Calling drift a parameter hides it;
--- calling a parameter drift is noisy but visible — the asymmetry picks the threshold.
M.MIN_PARENTS = 100
--- ★ THE PARAMETER PRIOR, MEASURED ON PLURAL FORMS: in a KEYED anchor, a difference under a
--- parent is the member's own parameter when, IN THE OBSERVED STATE, the member shows the
--- SAME child-key set at EVERY parent of that shape (the template's union of child keys) —
--- ru has one/few/many/other everywhere, so a `few` is Russian, not drift. A change that
--- leaves one parent unlike its siblings is not a parameter. Needs >= 2 parents of the shape.
--- ⚠ IT READS THE OBSERVATION, NOT THE ANCHOR: judged against the anchored sets, a drift
--- that drops one form at one parent would still look consistent (the first cut did that).
--- @param new table  the observed kv value of the member
--- @return function(id, change) -> bool|nil
function M.shape_consistent(anchor, new, opts)
    local min_parents = (opts and opts.min_parents) or M.MIN_PARENTS
    assert(anchor.keyed, 'shape_consistent reads a keyed anchor')
    local R = anchor.families[1].R
    local shapes, parent_sig = {}, {}
    local function sig(t) local ks = {}; for _, k in ipairs(t.keys) do ks[#ks + 1] = k end; table.sort(ks); return table.concat(ks, ',') end
    local function walk(t, path)
        if type(t) ~= 'table' then return end
        if t.opt then return walk(t.body, path) end
        if t.o then
            local s = sig(t)
            shapes[s] = shapes[s] or {}
            table.insert(shapes[s], path)
            parent_sig[path] = s
            for _, k in ipairs(t.keys) do walk(t.o[k], path .. '.' .. k) end
        end
    end
    walk(R.template, '$')
    local function get(v, path)
        for seg in path:gmatch('%.([^.]+)') do
            if type(v) ~= 'table' or not v.o then return nil end
            v = v.o[seg]
        end
        return v
    end
    local function keyset(path)
        local v = get(new, path)
        if type(v) ~= 'table' or not v.o then return '' end
        local ks = {}; for _, k in ipairs(v.keys) do ks[#ks + 1] = k end; table.sort(ks)
        return table.concat(ks, ',')
    end
    return function(_, change)
        if not change.path then return nil end
        local parent = change.path:match('^(.*)%.[^.]+$')
        local s = parent and parent_sig[parent]
        if not s or #shapes[s] < min_parents then return nil end
        local first
        for _, p in ipairs(shapes[s]) do
            local ks = keyset(p)
            if ks ~= '' then
                if first == nil then first = ks elseif ks ~= first then return false end
            end
        end
        return first ~= nil
    end
end

return M
