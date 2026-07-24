-- rbsdistill — distill Ruby-core RBS into a checked-in, version-keyed profile
-- artifact ([[cartograph-stdlib-profile]] RBS enrichment, the INPUT ADAPTER of
-- kind 'export'). Reads the local rbs gem's core/*.rbs (declared API) and writes
-- spec/profile/ruby-core.mpack:
--   canon: member -> canonical `Owner<sep>member` (the DEFINING owner, RBS ground
--          truth — deprecates the profile's hand-authored owner guesses for core)
--   sigs:  `Owner<sep>member` -> { sig, file, line } (for the nav-time hover/def
--          enrichment follow-on; kept OUT of the graph = deterministic)
-- DEV-TIME regeneration (not run at extract): the artifact is checked in and
-- version-keyed to the rbs gem, so the graph depends on the artifact, never live
-- RBS. Run when the rbs gem version changes.
--
--   nvim --headless -u NONE -l tools/rbsdistill.lua

local RBS_ROOT = '/usr/lib/ruby/gems/3.2.0/gems/rbs-2.8.2'
local RBS = RBS_ROOT .. '/core'
if vim.fn.isdirectory(RBS) ~= 1 then print('no local rbs core at ' .. RBS); return end
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local OUT = repo .. '/lua/cartograph/spec/profile/ruby-core.mpack'
local version = RBS_ROOT:match('rbs%-([%d%.]+)$') or 'unknown'

-- ── parse: (owner, member, singleton) → first sig + location; + type graph ──
local defs = {}            -- key "owner\31member\31sing" → { owner, member, sing, sig, file, line }
local member_owners = {}   -- member → { {owner, sing} }
local function indent_of(s) return #(s:match('^%s*')) end

for _, path in ipairs(vim.fn.globpath(RBS, '*.rbs', false, true)) do
    local rel = path:sub(#RBS_ROOT + 2)
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
            -- capture `def [self.|self?.]NAME: <sig>` — sing = a plain `self.` singleton
            local pre, m, sig = line:match('^%s*def%s+(self%.?%??%.?)([%w_]+[?!=]?)%s*:%s*(.*)$')
            if not m then m, sig = line:match('^%s*def%s+([%w_]+[?!=]?)%s*:%s*(.*)$') end
            if m and #stack > 0 then
                local o = stack[#stack].name
                local sing = (pre == 'self.') -- self?. (module fn) counts as instance
                local key = o .. '\31' .. m .. '\31' .. (sing and 's' or 'i')
                if not defs[key] then
                    defs[key] = { owner = o, member = m, sing = sing,
                        sig = (sig ~= '' and sig or nil), file = rel, line = lineno }
                    member_owners[m] = member_owners[m] or {}
                    member_owners[m][#member_owners[m] + 1] = { owner = o, sing = sing }
                end
            end
        end
    end
end

-- canonical DEFINING owner among a member's owners: prefer the most-BASE
-- (Enumerable over Array, Object over Integer) via a base-preference order, then
-- alphabetical. RBS usually defines a method once in its base; overrides pick base.
local BASE_PREF = { BasicObject = 1, Kernel = 2, Object = 3, Comparable = 4,
    Enumerable = 5, Numeric = 6, Integer = 7, Float = 8, String = 9, Symbol = 10,
    Array = 11, Hash = 12, Range = 13, Time = 14, Module = 15, Struct = 16 }
local function pick(list)
    table.sort(list, function (a, b)
        local pa, pb = BASE_PREF[a.owner] or 99, BASE_PREF[b.owner] or 99
        if pa ~= pb then return pa < pb end
        return a.owner < b.owner
    end)
    return list[1]
end

local canon, sigs = {}, {}
local nmembers = 0
for m, list in pairs(member_owners) do
    local best = pick(list)
    local sep = best.sing and '.' or '#'
    local path = best.owner .. sep .. m
    canon[m] = path
    local d = defs[best.owner .. '\31' .. m .. '\31' .. (best.sing and 's' or 'i')]
    if d then sigs[path] = { sig = d.sig, file = d.file, line = d.line } end
    nmembers = nmembers + 1
end

local artifact = {
    schema = 1, runtime = 'ruby-core', lang = 'ruby', version = version,
    -- root = the gem dir sigs[].file is relative to (nav-time go-to-def joins it;
    -- a HINT resolved at nav time — config override wins, absent → honest frontier)
    stamp = { input_kind = 'export', origin = RBS, root = RBS_ROOT, version = version },
    canon = canon, sigs = sigs,
}
local blob = vim.mpack.encode(artifact)
local fd = assert(io.open(OUT, 'wb')); fd:write(blob); fd:close()
print(('rbsdistill — rbs %s → %s'):format(version, OUT:sub(#repo + 2)))
print(('  %d distinct members, %d canonical paths, %d with sigs, %d bytes')
    :format(nmembers, vim.tbl_count(canon), vim.tbl_count(sigs), #blob))
-- sample
local shown = 0
for _, m in ipairs({ 'nil?', 'each', 'map', 'send', 'dup', 'puts', 'to_s', 'keys' }) do
    if canon[m] then print(('    %-8s → %-22s  %s'):format(m, canon[m],
        sigs[canon[m]] and sigs[canon[m]].sig or '')); shown = shown + 1 end
end
