-- rbsaudit — validate the ruby-rails profile's hand-authored canonical owners
-- against Ruby-core RBS ground truth ([[cartograph-stdlib-profile]] RBS enrichment
-- layer, step 1). RBS is a DECLARED-API export (the free-answer-key shape): the
-- rbs gem ships core/*.rbs with `class X`/`module X` + `def m: sig`. We parse
-- owner→member + the inherit/include graph, then bucket each profile method:
--   exact   — my canonical owner defines it in RBS
--   ancestor— defined in an RBS ancestor of my owner (inherited → still correct)
--   differ  — in RBS under an UNRELATED owner → a candidate hand-list bug
--   absent  — not in core RBS (Rails/ActiveSupport, or a typo)
--
--   nvim --headless -u NONE -l tools/rbsaudit.lua
-- No network, no graph mutation — pure measurement over the local rbs gem.

local RBS = '/usr/lib/ruby/gems/3.2.0/gems/rbs-2.8.2/core'
if vim.fn.isdirectory(RBS) ~= 1 then print('no local rbs core at ' .. RBS); return end
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

-- ── parse core RBS ──────────────────────────────────────────────────────────
local member_owners = {}   -- member → { owner = true }
local inherit = {}         -- type → supertype (class X < Y)
local includes = {}        -- type → { mixin = true } (include Z)
local function indent_of(s) return #(s:match('^%s*')) end

for _, path in ipairs(vim.fn.globpath(RBS, '*.rbs', false, true)) do
    local stack = {} -- { {name, indent} } — nearest enclosing class/module
    for line in io.lines(path) do
        local ind = indent_of(line)
        local kw, name = line:match('^%s*(class)%s+([%w_:]+)')
        if not kw then kw, name = line:match('^%s*(module)%s+([%w_:]+)') end
        if kw then
            while #stack > 0 and stack[#stack].indent >= ind do stack[#stack] = nil end
            stack[#stack + 1] = { name = name, indent = ind }
            local sup = line:match('^%s*class%s+[%w_:]+%s*<%s*([%w_:]+)')
            if sup then inherit[name] = sup end
        else
            local inc = line:match('^%s*include%s+([%w_:]+)')
            if inc and #stack > 0 then
                local o = stack[#stack].name
                includes[o] = includes[o] or {}; includes[o][inc] = true
            end
            -- def [self.|self?.]NAME:  (word methods + predicates; operators skipped)
            local m = line:match('^%s*def%s+self%??%.([%w_]+[?!=]?)%s*:')
                or line:match('^%s*def%s+([%w_]+[?!=]?)%s*:')
            if m and #stack > 0 then
                local o = stack[#stack].name
                member_owners[m] = member_owners[m] or {}
                member_owners[m][o] = true
            end
        end
    end
end

-- ancestors of an owner: itself + supertypes + included modules, transitively
local function ancestors(o)
    local seen, q = {}, { o }
    while #q > 0 do
        local cur = table.remove(q)
        if not seen[cur] then
            seen[cur] = true
            if inherit[cur] then q[#q + 1] = inherit[cur] end
            for m in pairs(includes[cur] or {}) do q[#q + 1] = m end
        end
    end
    return seen
end
-- my profile owner ≈ RBS owner aliases (my coarse groupings → RBS concrete types)
local ALIAS = {
    Object = { Object = true, Kernel = true, BasicObject = true },
    Numeric = { Numeric = true, Integer = true, Float = true },
}

-- ── the audit against the profile canon ─────────────────────────────────────
local prof = require('cartograph.spec.profile').load('ruby-rails')
local exact, ancestor, differ, absent = 0, 0, 0, 0
local differ_list, absent_list = {}, {}
local total = 0
for m, path in pairs(prof.canon or {}) do
    total = total + 1
    local my_owner = path:match('^(.-)[#.]')
    local rbs = member_owners[m]
    if not rbs then
        absent = absent + 1
        if #absent_list < 30 then absent_list[#absent_list + 1] = m end
    else
        local anc = ancestors(my_owner)
        local myset = ALIAS[my_owner] or { [my_owner] = true }
        local hit_exact, hit_anc = false, false
        for o in pairs(rbs) do
            if myset[o] then hit_exact = true end
            if anc[o] then hit_anc = true end
        end
        if hit_exact then exact = exact + 1
        elseif hit_anc then ancestor = ancestor + 1
        else
            differ = differ + 1
            if #differ_list < 40 then
                local os = {}; for o in pairs(rbs) do os[#os + 1] = o end
                differ_list[#differ_list + 1] = ('%s: mine=%s rbs=%s'):format(m, my_owner, table.concat(os, ','))
            end
        end
    end
end

print(('rbsaudit — %d profile methods vs Ruby-core RBS'):format(total))
print(('  exact-owner agree:     %d'):format(exact))
print(('  agree-via-ancestor:    %d'):format(ancestor))
print(('  OWNER-DIFFERS (candidate bug): %d'):format(differ))
print(('  absent from core RBS (Rails/ActiveSupport/typo): %d'):format(absent))
print('  --- owner-differs (mine vs RBS) ---')
for _, l in ipairs(differ_list) do print('    ' .. l) end
print('  --- sample absent (expect Rails/AS verbs; a CORE name here = typo) ---')
print('    ' .. table.concat(absent_list, ' '))

-- ── Rails face: hand Rails surface vs gem_rbs_collection (rails_sigs) ─────────
-- The free-answer-key check for the FRAMEWORK half of the surface. rails_sigs is
-- the RBS for the AR/ActionController/ActionView gems (member-keyed). This keeps
-- the hand curation RBS-INFORMED without DERIVING from it — deriving is measured-
-- negative ([[cartograph-stdlib-profile]]): RBS owners are deep internal modules,
-- so the hand COARSE-owner map is the sound source; RBS's role is this audit +
-- hover sigs. Actionable output = the HAND-ONLY list (verify real Rails method vs
-- a typo/stale name), since those are the entries no ground truth backs.
local RAILS_OWNERS = {
    ['ActiveRecord::Base'] = true, ['ActiveRecord::Persistence'] = true,
    ['ActiveRecord::Relation'] = true, ['ActionController::Base'] = true,
    ['ActionView::Helpers'] = true, ['Rails'] = true,
}
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local rails_sigs = prof.rails_sigs
print('')
if not (rails_sigs and next(rails_sigs)) then
    print('rbsaudit(rails): no rails_sigs in the artifact (gem_rbs_collection not '
        .. 'distilled) — skipping the framework face')
    return
end
-- hand Rails members = canon entries whose coarse owner is a RAILS owner; also
-- note every member the profile already blesses in `free` (dispositions covered).
local hand_rails = {}
for m, path in pairs(prof.canon or {}) do
    if RAILS_OWNERS[path:match('^(.-)[#.]')] then hand_rails[m] = true end
end
local confirmed, hand_only = 0, {}
for m in pairs(hand_rails) do
    if rails_sigs[m] then confirmed = confirmed + 1 else hand_only[#hand_only + 1] = m end
end
-- RBS-only = RBS Rails methods the hand surface omits; split by whether the
-- profile already disposes the name (in `free`) — a name absent from `free` would
-- be a genuine disposition gap (expect ZERO: ruby's core surface covers them).
local rbs_only, rbs_only_gap = 0, {}
for m in pairs(rails_sigs) do
    if not hand_rails[m] then
        rbs_only = rbs_only + 1
        if not (prof.free and prof.free[m]) then rbs_only_gap[#rbs_only_gap + 1] = m end
    end
end
table.sort(hand_only); table.sort(rbs_only_gap)
print(('rbsaudit(rails) — %d hand Rails members vs %d gem_rbs_collection members')
    :format(count(hand_rails), count(rails_sigs)))
print(('  confirmed (hand ∩ RBS):            %d  (%.0f%% — RBS backs the curation)')
    :format(confirmed, count(hand_rails) > 0 and 100 * confirmed / count(hand_rails) or 0))
print(('  HAND-ONLY (RBS lacks → VERIFY):    %d  (real Rails method vs typo/stale)')
    :format(#hand_only))
print('    ' .. table.concat(hand_only, ' '))
print(('  RBS-only (not hand-listed):        %d  (already disposed via core owners;')
    :format(rbs_only))
print(('    owner-precision-only, receiver typing would disambiguate = measured-negative)'))
print(('  RBS-only DISPOSITION GAPS (name absent from `free` = a real hole): %d')
    :format(#rbs_only_gap))
if #rbs_only_gap > 0 then print('    ' .. table.concat(rbs_only_gap, ' ', 1, math.min(40, #rbs_only_gap))) end
