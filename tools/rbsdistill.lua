-- rbsdistill — distill Ruby RBS into a checked-in, version-keyed profile artifact
-- ([[cartograph-stdlib-profile]] RBS enrichment, INPUT ADAPTER kind='export').
-- Two sources, both DEV-TIME (never run at extract; the artifact is checked in and
-- version-keyed → the graph depends on the artifact, never live RBS):
--   CORE  — the rbs gem's core/*.rbs (bundled with ruby). Yields `canon` (member →
--           canonical DEFINING `Owner<sep>member`, RBS ground truth for owners) +
--           `sigs` (path → {sig,file,line}).
--   RAILS — ruby/gem_rbs_collection Rails gems (network-fetched sibling checkout).
--           Rails' RBS owners are deep internal modules (ActiveRecord::QueryMethods),
--           NOT the profile's recognizable coarse owners, and the payoff is the
--           SIGNATURE — so Rails yields `rails_sigs` (member → {sig, owner, gem,
--           file, line}) keyed BY NAME; hover looks it up by member, keeping the
--           profile's own owner in the node id.
--
--   nvim --headless -u NONE -l tools/rbsdistill.lua

local RBS_ROOT = '/usr/lib/ruby/gems/3.2.0/gems/rbs-2.8.2'
local GRC = vim.fn.expand('~/git/gem_rbs_collection/gems')  -- Rails RBS (optional)
local RAILS_GEMS = { 'activerecord', 'activesupport', 'actionpack', 'actionview', 'activemodel' }
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local OUT = repo .. '/lua/cartograph/spec/profile/ruby-core.mpack'
local version = RBS_ROOT:match('rbs%-([%d%.]+)$') or 'unknown'

-- the profile's method universe — distill only what the profile actually blesses
-- (its free set is mpack-independent), so the artifact stays lean + is all consumed
local prof = require('cartograph.spec.profile').load('ruby-rails')
local MEM = {}
for m in pairs(prof.free or {}) do MEM[m] = true end

local function indent_of(s) return #(s:match('^%s*')) end

-- parse a list of .rbs files → { defs = { {owner, member, sing, sig, file, line} },
-- member_owners = { member → { {owner, sing} } } }. owner = the stack-joined module
-- path (ActiveRecord::QueryMethods). rel_to = strip prefix for the stored file path.
local function parse_rbs(files, rel_to)
    local defs, member_owners = {}, {}
    local seen = {}
    for _, path in ipairs(files) do
        local rel = path:sub(#rel_to + 2)
        local stack, lineno = {}, 0
        for line in io.lines(path) do
            lineno = lineno + 1
            local ind = indent_of(line)
            local kw, name = line:match('^%s*(class)%s+([%w_:]+)')
            if not kw then kw, name = line:match('^%s*(module)%s+([%w_:]+)') end
            if kw then
                while #stack > 0 and stack[#stack].indent >= ind do stack[#stack] = nil end
                stack[#stack + 1] = { name = name, indent = ind }
            else
                local pre, m, sig = line:match('^%s*def%s+(self%.?%??%.?)([%w_]+[?!=]?)%s*:%s*(.*)$')
                if not m then m, sig = line:match('^%s*def%s+([%w_]+[?!=]?)%s*:%s*(.*)$') end
                if m and #stack > 0 then
                    local names = {}
                    for _, s in ipairs(stack) do names[#names + 1] = s.name end
                    local owner = table.concat(names, '::')
                    local sing = (pre == 'self.')
                    local key = owner .. '\31' .. m .. '\31' .. (sing and 's' or 'i')
                    if not seen[key] then
                        seen[key] = true
                        defs[#defs + 1] = { owner = owner, member = m, sing = sing,
                            sig = (sig ~= '' and sig or nil), file = rel, line = lineno }
                        member_owners[m] = member_owners[m] or {}
                        member_owners[m][#member_owners[m] + 1] = { owner = owner, sing = sing }
                    end
                end
            end
        end
    end
    return { defs = defs, member_owners = member_owners }
end

-- ── CORE: canonical owners + sigs ───────────────────────────────────────────
local core = parse_rbs(vim.fn.globpath(RBS_ROOT .. '/core', '*.rbs', false, true), RBS_ROOT)
local BASE_PREF = { BasicObject = 1, Kernel = 2, Object = 3, Comparable = 4,
    Enumerable = 5, Numeric = 6, Integer = 7, Float = 8, String = 9, Symbol = 10,
    Array = 11, Hash = 12, Range = 13, Time = 14, Module = 15, Struct = 16 }
local defmap = {} -- (owner,member,sing) → def
for _, d in ipairs(core.defs) do defmap[d.owner .. '\31' .. d.member .. '\31' .. (d.sing and 's' or 'i')] = d end
local canon, sigs = {}, {}
for m, list in pairs(core.member_owners) do
  if MEM[m] then
    table.sort(list, function (a, b)
        local pa, pb = BASE_PREF[a.owner] or 99, BASE_PREF[b.owner] or 99
        if pa ~= pb then return pa < pb end
        return a.owner < b.owner
    end)
    local best = list[1]
    local path = best.owner .. (best.sing and '.' or '#') .. m
    canon[m] = path
    local d = defmap[best.owner .. '\31' .. m .. '\31' .. (best.sing and 's' or 'i')]
    if d then sigs[path] = { sig = d.sig, file = d.file, line = d.line } end
  end
end

-- ── RAILS: signatures keyed by member name (owner = provenance only) ─────────
local function version_gt(a, b)
    local a1, a2 = a:match('^(%d+)%.(%d+)'); local b1, b2 = b:match('^(%d+)%.(%d+)')
    a1, a2, b1, b2 = tonumber(a1), tonumber(a2), tonumber(b1), tonumber(b2)
    if a1 ~= b1 then return a1 > b1 end
    return (a2 or 0) > (b2 or 0)
end
local function segs(o) local n = 1; for _ in o:gmatch('::') do n = n + 1 end; return n end
local rails_sigs, rails_ok = {}, (vim.fn.isdirectory(GRC) == 1)
local rails_version
if rails_ok then
    for _, gem in ipairs(RAILS_GEMS) do
        local gemdir = GRC .. '/' .. gem
        if vim.fn.isdirectory(gemdir) == 1 then
            local ver
            for _, d in ipairs(vim.fn.readdir(gemdir)) do
                if d:match('^%d+%.%d+$') and (not ver or version_gt(d, ver)) then ver = d end
            end
            if ver then
                rails_version = rails_version or ver
                -- non-recursive glob → excludes the _test/ subdir automatically
                local r = parse_rbs(vim.fn.globpath(gemdir .. '/' .. ver, '*.rbs', false, true), gemdir .. '/' .. ver)
                for _, d in ipairs(r.defs) do
                    -- only the profile's own methods. On the common by-name collision
                    -- (render/find/… defined in many Rails modules), prefer the most
                    -- CENTRAL owner — fewest `::` segments (ActionController::Base beats
                    -- ActiveRecord::FixtureSet::File) — then with-sig, then first.
                    if MEM[d.member] then
                        local prev = rails_sigs[d.member]
                        local take
                        if not prev then take = true
                        else
                            local ds, ps = segs(d.owner), segs(prev.owner)
                            if ds ~= ps then take = ds < ps
                            else take = (d.sig ~= nil) and (prev.sig == nil) end
                        end
                        if take then
                            rails_sigs[d.member] = { sig = d.sig, owner = d.owner,
                                gem = gem, file = gem .. '/' .. ver .. '/' .. d.file, line = d.line }
                        end
                    end
                end
            end
        end
    end
end

local artifact = {
    schema = 1, runtime = 'ruby-core', lang = 'ruby', version = version,
    stamp = { input_kind = 'export', origin = RBS_ROOT .. '/core', root = RBS_ROOT,
        version = version, rails_source = rails_ok and GRC or nil, rails_version = rails_version },
    canon = canon, sigs = sigs, rails_sigs = rails_sigs,
}
local blob = vim.mpack.encode(artifact)
local fd = assert(io.open(OUT, 'wb')); fd:write(blob); fd:close()
print(('rbsdistill — core rbs %s + rails %s → %s')
    :format(version, rails_version or '(absent)', OUT:sub(#repo + 2)))
print(('  core: %d canon owners, %d sigs · rails: %d member sigs · %d bytes')
    :format(vim.tbl_count(canon), vim.tbl_count(sigs), vim.tbl_count(rails_sigs), #blob))

-- AUDIT: how much of the profile's hand-authored RAILS surface does RBS confirm?
local RAILS_OWNERS = { ['ActiveRecord::Base'] = true, ['ActiveRecord::Persistence'] = true,
    ['ActiveRecord::Relation'] = true, ['ActionController::Base'] = true,
    ['ActionView::Helpers'] = true, ['Rails'] = true }
local rails_total, rails_confirmed, missing = 0, 0, {}
for m, path in pairs(prof.canon or {}) do
    local owner = path:match('^(.-)[#.]')
    if RAILS_OWNERS[owner] then
        rails_total = rails_total + 1
        if rails_sigs[m] then rails_confirmed = rails_confirmed + 1
        elseif #missing < 30 then missing[#missing + 1] = m end
    end
end
print(('  RAILS-surface audit: %d/%d hand methods confirmed by RBS (%.0f%%)')
    :format(rails_confirmed, rails_total, 100 * rails_confirmed / math.max(1, rails_total)))
print('    unconfirmed (RBS lacks / hand-list extra): ' .. table.concat(missing, ' '))
for _, m in ipairs({ 'save', 'where', 'find', 'belongs_to', 'validates', 'render' }) do
    local s = rails_sigs[m]
    if s then print(('    %-12s → %s  [%s]'):format(m, s.sig or '(no sig)', s.owner)) end
end
