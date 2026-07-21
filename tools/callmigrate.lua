-- callmigrate — the CALL-store migration work-list (record-fold arc, brick 3,
-- [[cartograph-record-fold-arc]]). seammigrate's twin for the resident columnar
-- swap: it turns "flip config.callcols_store on" from an all-or-nothing hunt into
-- a checklist. callcols.view is a behaviour-faithful drop-in (tools/callgate.lua
-- proves it) BECAUSE the row-handle is a transparent proxy — so most reads Just
-- Work. What genuinely BREAKS under a proxy is a handful of table-identity
-- assumptions; this enumerates them, classified.
--
-- Two sections:
--   HAZARDS — sites that break when data.calls[i] is a proxy, not a record table:
--     * iter    pairs/next/ipairs over a call → a proxy yields NO fields (its
--               data lives in columns); iterate a known field list or
--               callcols.record(cc,i).
--     * write   a post-ingest write to a SYNTACTIC field (file/callee/fn/full/
--               line/method) → those are IMMUTABLE columns; the proxy refuses.
--               A remap must rebuild the store, not mutate the column. (Writes
--               under providers/ are INGEST-time — before the view wraps — SAFE.)
--   (A call used as a TABLE KEY — escalate's snapshot — is NOT a hazard: it is
--   safe because callrec.each yields STABLE rows, view.rows minted once. This
--   invariant is the reason the identity pattern needn't be rewritten; it is
--   noted in the report rather than fenced per-site.)
--   INVENTORY — owner-layer raw reads of a seamed field (via consumers.roster):
--     the optimization work-list (route to the callrec accessor / read the column
--     directly for the resident win). Not correctness — the proxy handles these.
--
--   nvim --headless -u NONE -l tools/callmigrate.lua
-- Exits non-zero while any post-ingest HAZARD remains (a pre-flip fence).

vim.opt.rtp:prepend('.')
local consumers = require 'cartograph.consumers'

local repo = '.'
local SYN = { file = true, callee = true, fn = true, full = true,
    line = true, method = true }
-- known call loop-var names (the codebase convention) + detected loop vars
local CALLVAR = { c = true, call = true }

local function rels()
    local out = {}
    for _, f in ipairs(vim.fn.glob(repo .. '/lua/**/*.lua', false, true)) do
        out[#out + 1] = f:gsub('^%./', '')
    end
    return out
end

-- a write under the parser provider is INGEST-time (records are built there,
-- before store wraps them in the columnar view) → not a post-flip hazard.
local function ingest(file) return file:find('providers/') ~= nil end

local hazards = {}          -- { file, line, kind, src, fix }
local function haz(file, line, kind, src, fix)
    hazards[#hazards + 1] = { file = file, line = line, kind = kind,
        src = src:gsub('^%s+', ''):gsub('%s+$', ''), fix = fix }
end

for _, file in ipairs(rels()) do
    local fd = io.open(repo .. '/' .. file, 'r')
    if fd then
        local lines = {}
        for line in fd:lines() do lines[#lines + 1] = line end
        fd:close()

        -- pass 1: call loop-vars bound in this file (`… in callrec.each(` or
        -- `… in ipairs(<x>.calls)`) plus the convention vars c/call.
        local localvars = {}
        for k in pairs(CALLVAR) do localvars[k] = true end
        for _, line in ipairs(lines) do
            local code = line:gsub('%-%-.*$', '')
            local v = code:match('for%s+[%w_%s,]-([%w_]+)%s+in%s+callrec%.each%(')
                or code:match('for%s+[%w_%s,]-([%w_]+)%s+in%s+ipairs%([%w_.]*%.calls%s*or')
                or code:match('for%s+[%w_%s,]-([%w_]+)%s+in%s+ipairs%(data%.calls')
            if v then localvars[v] = true end
        end

        -- pass 2: hazard patterns over the (comment-stripped) code
        for ln, line in ipairs(lines) do
            local code = line:gsub('%-%-.*$', '')
            -- iter: pairs/next over a call var (a proxy has no iterable fields)
            for fn2, v in code:gmatch('([%w_]-)pairs%(([%w_]+)%)') do
                if localvars[v] and fn2 ~= 'i' then -- exclude ipairs
                    haz(file, ln, 'iter', line,
                        'a proxy yields no fields via pairs — iterate a field list or callcols.record(cc,i)')
                end
            end
            for v in code:gmatch('next%(([%w_]+)%)') do
                if localvars[v] then haz(file, ln, 'iter', line,
                    'next() over a proxy sees only its backing handle — use a field list') end
            end
            -- write: a syntactic field assigned on a call var, post-ingest
            local w1, w2 = code:match('([%w_]+)%.([%w_]+)%s*=%s*')
            if w1 and w2 and localvars[w1] and SYN[w2]
                and not code:match('==') and not ingest(file) then
                haz(file, ln, 'write', line,
                    ('%s is an immutable column — a post-ingest remap must rebuild the store, not mutate'):format(w2))
            end
        end
    end
end

-- INVENTORY: owner-layer raw reads of a seamed field (the optimization list).
-- Reuse the taint roster with the guard spec, but INVERTED — report the OWNER
-- files (the ones the fence skips), where the raw reads legitimately still live.
local OWNER_ONLY = { 'fold%.lua$', 'cache%.lua$', 'argv%.lua$', 'at%.lua$',
    'refused%.lua$', 'refresh%.lua$', 'parallel%.lua$', 'validate%.lua$' }
local function owner_only(f)
    for _, p in ipairs(OWNER_ONLY) do if f:find(p) then return true end end
    return false
end
local ofiles = {}
for _, f in ipairs(rels()) do if owner_only(f) then ofiles[#ofiles + 1] = f end end
local spec = { rooted = consumers.CALL_PRODUCERS.rooted,
    calls = consumers.CALL_PRODUCERS.calls, bless = {} }
for field in pairs(consumers.SEAMED) do spec.bless[field] = true end
local r = consumers.roster(repo, ofiles, spec)
local inventory = {}
for _, s in ipairs(r.sites) do
    if consumers.SEAMED[s.path] then
        inventory[#inventory + 1] = { file = s.file, line = s.line, col = s.col,
            path = s.path, acc = consumers.SEAMED[s.path] }
    end
end

-- ── report ───────────────────────────────────────────────────────────────
local function sortsites(t)
    table.sort(t, function (a, b)
        return a.file < b.file or (a.file == b.file and a.line < b.line) end)
end
sortsites(hazards); sortsites(inventory)

io.write(('callmigrate — %d blocking hazard(s), %d owner raw-read(s)\n')
    :format(#hazards, #inventory))
io.write('\nHAZARDS (break under the callcols proxy — fix before flipping the flag):\n')
if #hazards == 0 then io.write('  (none)\n') end
for _, h in ipairs(hazards) do
    io.write(('  [%s] %s:%d\n      %s\n      -> %s\n'):format(h.kind, h.file, h.line, h.src, h.fix))
end
io.write('\nOWNER RAW READS (optimization — route to the column for the resident win):\n')
if #inventory == 0 then io.write('  (none — owners already on the accessor)\n') end
for _, s in ipairs(inventory) do
    io.write(('  %s:%d  c.%s  -> %s (or read the column directly)\n')
        :format(s.file, s.line, s.path, s.acc))
end
io.write('\nNOTE: a call used as a TABLE KEY (escalate snapshot) is safe — callrec.each\n'
    .. '      yields stable rows (view.rows minted once), so identity is preserved.\n')

if #hazards > 0 then
    io.write(('\nBLOCKED: %d hazard(s) must be resolved before config.callcols_store can flip on\n'):format(#hazards))
    vim.cmd('cquit 1')
else
    io.write('\nOK — no proxy-breaking hazard; the flag may flip (owners optimize incrementally)\n')
    vim.cmd('qall!')
end
