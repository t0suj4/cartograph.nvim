-- cartograph.propagate — AN EDIT ON ONE CLONE, CARRIED TO ITS FAMILY THROUGH THE JOURNAL (CART-1152).
--
-- `clones.family_propagate` classifies an edit made to one member and clusters its impact (value classes, the
-- members a template change migrates to, refusals grouped by reason) and hands back COMMIT closures: nothing outside
-- clones.lua called it, so a propagated edit could be previewed and never applied. This is the write half: a txn
-- plan whose edits are each member's re-rendered text.
--
--   plan(store, { node, text, scope })
--     node   the member the edit was made to (a function id)
--     text   that member's NEW source text
--     scope  'member' (default) | 'class' | 'all' (the VALUE part: who takes the new value — the algebra's own
--            commit scopes) | 'clean' (the TEMPLATE part: every member migrate keeps) | { indices }
--
-- ★★★ THE SCOPE IS A DECISION, and the design sentence is the user's (PROPAGATE.md): an edit lands on one instance;
-- whether the abstraction applies elsewhere is an OPERATOR decision, made per cluster. So without a scope the plan
-- is the ORIGIN ONLY and carries a `propagate-scope` DECISION hazard whose fixes name the wider scopes. A tactic stops
-- there BEFORE anything is written — and it must: once the origin holds the edit, planning from it again classifies
-- as `none`, so a wider scope can no longer be derived.
-- ★★ THE ALGEBRA'S COMMIT DECIDES WHO GETS WHAT (commit.values(scope), commit.template(members)); this module does
-- not recompute member / class / all. A second copy of the scope semantics is the drift CART-1153 removed.
-- ★ EVERY SIBLING'S TEXT IS VERIFIED (clones.family_member_text): its own source as the donor for a value change, an
-- identity-checked surface for a template change, and the reparse must equal the predicted instance.
local M = {}

local txn = require 'cartograph.txn'
local atr = require 'cartograph.at'
local hazard = require 'cartograph.hazard'

local function index_of(fam, id)
    for k, m in ipairs(fam.members or {}) do if m.id == id then return k end end
end

--- replace each member's span in one file's text with its new text, bottom-up
local function splice(before, edits)
    local lines = vim.split(before, '\n', { plain = true })
    table.sort(edits, function (a, b) return atr.sl(a.at) > atr.sl(b.at) end)
    for _, e in ipairs(edits) do
        local sl, sc, el, ec = atr.sl(e.at), atr.sc(e.at), atr.el(e.at), atr.ec(e.at)
        local prefix = (lines[sl + 1] or ''):sub(1, sc)
        local suffix = (lines[el + 1] or ''):sub(ec + 1)
        local new = vim.split(prefix .. e.text .. suffix, '\n', { plain = true })
        for _ = sl, el do table.remove(lines, sl + 1) end
        for k = #new, 1, -1 do table.insert(lines, sl + 1, new[k]) end
    end
    return table.concat(lines, '\n')
end

function M.edits_for(plan)
    return function (rel, before)
        local edits = plan.edits[rel]
        if not edits then return before end
        local copy = {}
        for k, e in ipairs(edits) do copy[k] = e end
        return splice(before, copy)
    end
end

function M.plan(store, opts)
    opts = opts or {}
    local n = opts.node and store.node(opts.node)
    if not n then return nil, 'no member to propagate from', 'ill-posed' end
    if type(opts.text) ~= 'string' or opts.text:gsub('%s', '') == '' then return nil, 'no edited text', 'ill-posed' end
    local clones = require 'cartograph.clones'
    local fam, fwhy = clones.family_of(store, n.id)
    if not fam then
        return nil, ('%s is in no clone family (%s) — an edit to one function is `replace`'):format(tostring(n.name),
            tostring(fwhy or 'no family')), 'ill-posed'
    end
    local i = index_of(fam, n.id)
    if not i then return nil, ('%s is not a member of its own family record'):format(tostring(n.name)), 'unbuilt' end
    local P, pwhy = clones.family_propagate(fam, i, opts.text, store)
    if not P then
        return nil, ('the edit cannot be classified: %s'):format(tostring(pwhy)),
            tostring(pwhy):find('does not parse', 1, true) and 'ill-posed' or 'unbuilt'
    end
    if P.kind == 'none' then
        return nil, ('the edit changes nothing the family abstracts over — if %s already holds this edit, a wider scope '
            .. 'can no longer be derived from it'):format(tostring(n.name)), 'empty'
    end
    if P.kind == 'straddle' or P.kind == 'unsupported' then
        return nil, ('a %s edit does not propagate: %s%s'):format(P.kind, tostring(P.why or P.hint or ''),
            P.proposal and ' (the abstraction must move first — a family_edit no verb performs yet)' or ''), 'unbuilt'
    end

    local A = require('cartograph.algebra').load()
    local Vs = fam.values
    local scope = opts.scope or 'member'
    -- who takes what, from the algebra's own commits
    local targets = {}   -- j -> { holes = { [h] = true }, template = bool, values = V }
    local function target(j)
        targets[j] = targets[j] or { holes = {}, template = false, values = nil }
        return targets[j]
    end
    if P.commit and P.commit.values then
        local vscope = (scope == 'clean') and 'member' or scope
        local new = P.commit.values(vscope)
        for j, W in pairs(new or {}) do
            for h, v in pairs(W) do
                if not A.eq(v, Vs[j] and Vs[j][h]) then target(j).holes[h] = true; target(j).values = W end
            end
        end
    end
    if P.commit and P.commit.template then
        local tm = {}
        if scope == 'member' then tm = { i }
        elseif type(scope) == 'table' then tm = scope
        else tm = P.template.clean or {} end
        local keep = {}
        for _, j in ipairs(P.template.clean or {}) do keep[j] = true end
        local chosen = {}
        for _, j in ipairs(tm) do if keep[j] then chosen[#chosen + 1] = j end end
        local res = P.commit.template(chosen)
        local yes = res and res.families and res.families[1]
        for _, j in ipairs(chosen) do
            local t = target(j)
            t.template = true
            -- the value part rides on top of the migrated values where both apply
            local V = {}
            for h, v in pairs((yes and yes.values[j]) or Vs[j] or {}) do V[h] = v end
            for h in pairs(t.holes) do V[h] = t.values[h] end
            t.values = V
        end
    end
    if not targets[i] then target(i).values = Vs[i] end

    -- render: the origin is the edited text as written; every sibling is verified
    local edits, touched, stamps, refspecs, hazards, members = {}, {}, {}, {}, {}, {}
    local root = store.data.root
    local function add_edit(file, id, at, text, name)
        if not edits[file] then edits[file] = {}; touched[#touched + 1] = file; stamps[file] = txn.disk_stamp(root, file) end
        table.insert(edits[file], { at = at, text = text })
        refspecs[#refspecs + 1] = { id = id, name = name, ref = store.ref_of(id), what = 'symbol' }
        members[#members + 1] = name
    end
    add_edit(n.file, n.id, n.range, opts.text, n.name)
    local order = {}
    for j in pairs(targets) do if j ~= i then order[#order + 1] = j end end
    table.sort(order)
    for _, j in ipairs(order) do
        local r, why = clones.family_member_text(fam, P, i, opts.text, j, store, targets[j])
        local m = fam.members[j]
        if r then add_edit(r.file, r.id, r.at, r.text, r.name)
        else
            hazards[#hazards + 1] = hazard.new('not-propagated', ('%s keeps its old text: %s'):format(tostring(m and m.name), tostring(why)),
                nil, { member = j, file = m and m.file }, 'unbuilt')
        end
    end
    -- the members migrate refused, grouped by the algebra's own reason
    for _, g in ipairs((P.template and P.template.refused) or {}) do
        local names = {}
        for _, j in ipairs(g.members or {}) do names[#names + 1] = tostring((fam.members[j] or {}).name) end
        hazards[#hazards + 1] = hazard.new('not-propagated', ('%s: the new fixed part does not fit (%s)'):format(table.concat(names, ', '),
            tostring(g.why)), nil, { members = g.members }, 'unbuilt')
    end
    -- ★ THE SCOPE DECISION, disclosed as a hazard with a fix per wider scope (moveset's surface/reexport pattern)
    if scope == 'member' and #fam.members > 1 then
        local wider = {}
        if P.commit and P.commit.values then
            -- offer a scope only when it REACHES someone the narrower one does not
            local class = {}
            for _, h in ipairs(P.holes or {}) do for _, j in ipairs(h.class or {}) do class[j] = true end end
            local nclass = 0
            for _ in pairs(class) do nclass = nclass + 1 end
            if nclass > 1 then wider[#wider + 1] = 'class' end
            if #fam.members > nclass then wider[#wider + 1] = 'all' end
        end
        if P.commit and P.commit.template and #(P.template.clean or {}) > 1 then wider[#wider + 1] = 'clean' end
        for _, w in ipairs(wider) do
            hazards[#hazards + 1] = hazard.new('propagate-scope', ('the edit is planned for %s only; %d family member(s) could take it — scope = %q widens it')
                :format(tostring(n.name), #fam.members - 1, w),
                { verb = 'txn_plan_propagate', args = { scope = w }, why = ('propagate to the %s scope'):format(w) },
                { scope = w }, 'decision')
        end
    end
    table.sort(touched)
    local plan = {
        verb = 'propagate',
        -- `parses` per touched file; each sibling was already reparsed against its PREDICTED instance
        guards = { 'parses' },
        generation = store.generation,
        touched = touched, stamps = stamps, refspecs = refspecs,
        edits = edits, hazards = hazards, members = members,
        kind = P.kind, scope = scope, origin = n.name,
        -- the edit was SUPPLIED, and it changes behaviour on purpose, in every member it reaches
        preserves = 'none', may_change = members,
        preserves_why = 'the edit was SUPPLIED and changes behaviour on purpose in every member it reaches; each sibling'
            .. ' render is verified against its PREDICTED values (the template instance), not against behaviour',
        desc = ('propagate: a %s edit to %s, over %d member(s) (scope %s)'):format(P.kind, tostring(n.name), #members,
            type(scope) == 'table' and 'a list' or tostring(scope)),
    }
    return txn.protocol(plan, M.edits_for)
end

return M
