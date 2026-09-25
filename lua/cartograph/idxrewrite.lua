-- idxrewrite.lua — INDEX A SCAN: a loop that filters a list by one field's equality iterates that
-- key's bucket instead of the whole list (CART-1057, remedy 4).
--
-- USER (2026-09-25): "then do 4". The shape loopcost ranks first is a callee that SCANS a collection
-- once per element of an outer walk (fn_at). Its general cure is an index built once. This verb does
-- the one case that is sound by construction, and refuses the rest with reasons:
--
--   for _, v in ipairs(E) do if v.F == K then ... end end
--     ->
--   for _, v in ipairs(cg_bucket(E, 'F', K) or E) do if v.F == K then ... end end
--
-- `cg_bucket` (written ONCE into the file, no runtime dependency on cartograph) returns the elements
-- of E whose F equals K, IN LIST ORDER, cached per list and REBUILT WHEN #E CHANGES. The `if` stays,
-- so the body can never see an element the original would not have shown it; a key that is not a
-- string, boolean or non-NaN number gets nil and the loop scans E exactly as written. What the
-- rewrite must still get right is that no matching element is MISSING, and that is what the guards are
-- for: the list is appended to only (nothing removed or replaced in the file), and no element's F is
-- reassigned anywhere in the file. What it cannot see is stated as premises on the plan (another file
-- mutating the list; an element that is not a table, which the index build would touch where an
-- early-exiting scan would not; a non-sequence list).
--
-- ⚠ AN INDEX COSTS MORE THAN ONE SCAN, AND HOLDS MEMORY. Statically a site is a candidate where its loop
-- REPEATS (its function is a callee inside an input-sized loop, loopcost) over the SAME list; the
-- decision that pays is PROFILE-GUIDED (`instrument` + `decide`, `plan{ profile = ... }`): measured
-- element touches saved against bucket entries held.
--
-- Found by reading loopcost's top candidates by hand (2026-09-25): of ~870 inner loops behind the
-- certified call findings on cartograph, 15 are filter-shaped — 4 equality filters (this verb), 11
-- range containments (`x >= r.from and x <= r.to`, fn_at's kind: an interval index, not this one).

local txn = require 'cartograph.txn'

local M = {}

M.HELPER = [[
-- cartograph index-a-scan (CART-1057): a list's elements bucketed by one field, in list order, cached
-- per list and rebuilt when its length changes; only a string / boolean / non-NaN number key uses it,
-- any other key scans the list as written
local cg_buckets = setmetatable({}, { __mode = 'k' })
local cg_none = {}
local function cg_bucket(list, field, key)
    local kt = type(key)
    if kt ~= 'string' and kt ~= 'boolean' and not (kt == 'number' and key == key) then return nil end
    local per = cg_buckets[list]
    if not per or per.n ~= #list then per = { n = #list, by = {} }; cg_buckets[list] = per end
    local by = per.by[field]
    if not by then
        by = {}
        for _, v in ipairs(list) do
            local k = v[field]
            local t = type(k)
            if t == 'string' or t == 'boolean' or (t == 'number' and k == k) then
                local b = by[k]
                if not b then b = {}; by[k] = b end
                b[#b + 1] = v
            end
        end
        per.by[field] = by
    end
    return by[key] or cg_none
end
]]

local function text(src, n) return vim.treesitter.get_node_text(n, src) end

-- pure and cheap to evaluate again: a name, a field/index chain of names and literals, optionally
-- `(<chain> or {})`
local CHAIN = '^[%a_][%w_]*[%w_%.%[%]\'"]*$'
local function pure(e)
    e = e:gsub('^%s+', ''):gsub('%s+$', '')
    if e:match(CHAIN) and not e:find('%(') then return true end
    local inner = e:match('^%((.-)%s+or%s+{}%)$') or e:match('^(.-)%s+or%s+{}$')
    return inner ~= nil and inner:match(CHAIN) ~= nil and not inner:find('%(')
end
local function literal_or_chain(e)
    return pure(e) or e:match('^%-?%d+%.?%d*$') ~= nil or e:match('^"[^"\\]*"$') ~= nil or e:match("^'[^'\\]*'$") ~= nil
end

--- recognize one loop node: the site, or (nil, reason) when it is a near miss worth reporting
local function recognize(n, src)
    if n:type() ~= 'for_statement' then return nil end
    local clause
    for c in n:iter_children() do if c:type() == 'for_generic_clause' then clause = c end end
    if not clause then return nil end
    local head = text(src, clause)
    local iv, v, e = head:match('^([%a_][%w_]*)%s*,%s*([%a_][%w_]*)%s+in%s+ipairs%s*%((.*)%)%s*$')
    if not iv then return nil end
    local body = n:field('body')[1]
    if not body then return nil end
    local stmts = {}
    for c in body:iter_children() do if c:named() and c:type() ~= 'comment' then stmts[#stmts + 1] = c end end
    if #stmts ~= 1 or stmts[1]:type() ~= 'if_statement' then return nil end
    local ifn = stmts[1]
    for c in ifn:iter_children() do
        if c:type() == 'elseif_statement' or c:type() == 'else_statement' then return nil, 'the if has an else branch' end
    end
    local cond = ifn:field('condition')[1]
    local ct = cond and text(src, cond) or ''
    local pv = v:gsub('%p', '%%%0')
    local F, K = ct:match('^' .. pv .. '%.([%a_][%w_]*)%s*==%s*(.-)%s*$')
    if not F then K, F = ct:match('^(.-)%s*==%s*' .. pv .. '%.([%a_][%w_]*)%s*$') end
    if not F then return nil end
    if K:find('%f[%w_]' .. pv .. '%f[^%w_]') then return nil, 'the key reads the element' end
    if not literal_or_chain(K) then return nil, ('the key `%s` is not a plain name, field or literal'):format(K) end
    if K == 'nil' then return nil, 'the key is nil (a bucket can never serve it)' end
    if not pure(e) then return nil, ('the list `%s` is not a plain name or field (it would be evaluated twice)'):format(e) end
    local btext = text(src, body)
    if iv ~= '_' and btext:find('%f[%w_]' .. iv:gsub('%p', '%%%0') .. '%f[^%w_]') then
        return nil, ('the loop index `%s` is used in the body (bucket positions are not list positions)'):format(iv)
    end
    local base = e:match('^%(?%s*([%a_][%w_]*)') or e
    local pb = base:gsub('%p', '%%%0')
    if btext:find('table%.remove%(%s*' .. pb) or btext:find('table%.insert%(%s*' .. pb)
        or btext:find('%f[%w_]' .. pb .. '%s*%[[^%]]*%]%s*=[^=]') then
        return nil, ('the body writes the list `%s`'):format(base)
    end
    if btext:find('%f[%w_]' .. pv .. '%.' .. F .. '%s*=[^=]') then
        return nil, ('the body reassigns `%s.%s`'):format(v, F)
    end
    local sr, sc, er, ec = clause:range()
    return { v = v, F = F, K = K, E = e, base = base, line = n:range() + 1,
        clause_at = { start = { line = sr, char = sc }, ['end'] = { line = er, char = ec } }, clause_text = head, node = n }
end

-- file-wide guards: an element's F reassigned, or the list's base name losing/replacing elements
local function file_guards(site, src)
    local lines = vim.split(src, '\n', { plain = true })
    local pF = site.F:gsub('%p', '%%%0')
    local pb = site.base:gsub('%p', '%%%0')
    for i, l in ipairs(lines) do
        local code = l:gsub('%-%-.*$', '')
        if code:find('[%w_%]%)]%.' .. pF .. '%s*=[^=]') then
            return ('`.%s` is reassigned at line %d — an element\'s key could change after the index is built'):format(site.F, i)
        end
        if code:find('table%.remove%(%s*' .. pb .. '[%s,%)]') then
            return ('the list `%s` loses elements at line %d (table.remove) — same length, different contents'):format(site.base, i)
        end
        local idx = code:match('%f[%w_]' .. pb .. '%s*%[([^%]]*)%]%s*=[^=]')
        if idx and not idx:match('^%s*#%s*' .. pb .. '%s*%+%s*1%s*$') then
            return ('the list `%s` has an element replaced at line %d (`%s[%s] =`)'):format(site.base, i, site.base, idx)
        end
    end
    return nil
end

--- every candidate loop in one Lua source: sites (rewritable) and declined (near misses, with reasons)
function M.sites(src)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not ok then return {}, { { reason = 'cannot parse' } } end
    local root = parser:parse()[1]:root()
    local sites, declined = {}, {}
    local function visit(n)
        if n:type() == 'for_statement' then
            local s, why = recognize(n, src)
            if s then
                local g = file_guards(s, src)
                if g then declined[#declined + 1] = { line = s.line, reason = g }
                else sites[#sites + 1] = s end
            elseif why then
                declined[#declined + 1] = { line = n:range() + 1, reason = why }
            end
        end
        for c in n:iter_children() do if c:named() then visit(c) end end
    end
    visit(root)
    if src:find('%f[%w_]cg_bucket%f[^%w_]') and #sites > 0 then
        return {}, { { line = sites[1].line, reason = 'the file already defines `cg_bucket`' } }
    end
    -- the top-level statement enclosing each site: the helper goes above the earliest
    for _, s in ipairs(sites) do
        local t = s.node
        while t:parent() and t:parent():type() ~= 'chunk' do t = t:parent() end
        s.top = t:range()
        s.node = nil
    end
    return sites, declined
end

-- ── PROFILE-GUIDED: the CPU-for-memory trade, measured ──────────────────────────────
-- USER (2026-09-25): "Will probably need profile-guided application to gauge the CPU time vs memory
-- tradeoff". Static repetition says a site CAN repeat, not how often, over how many lists, of what
-- size. `instrument` rewrites every candidate loop head into a PROBE that returns the list untouched
-- and counts, per site: calls, element TOUCHES (sum of #list over calls: the scan's cost), DISTINCT
-- lists and their lengths (the index's build cost and its memory), and MATCHES (the bucket walk).
-- Run a workload under it (tools/idxprofile.lua), then `decide` prices both sides.
M.PROBE = [[
local cg_prof = rawget(_G, '__cg_idx_profile') or {}
rawset(_G, '__cg_idx_profile', cg_prof)
local function cg_probe(id, list, field, key)
    local st = cg_prof[id]
    if not st then st = { calls = 0, touches = 0, matches = 0, lists = setmetatable({}, { __mode = 'k' }), distinct = 0, distinct_len = 0 }; cg_prof[id] = st end
    st.calls = st.calls + 1
    local n = #list
    st.touches = st.touches + n
    local seen = st.lists[list]
    if not seen then st.lists[list] = n; st.distinct = st.distinct + 1; st.distinct_len = st.distinct_len + n
    elseif n > seen then st.lists[list] = n; st.distinct_len = st.distinct_len + (n - seen) end
    for _, v in ipairs(list) do if v[field] == key then st.matches = st.matches + 1 end end
    return list
end
]]

--- the source with every candidate loop head probed (ids = `<line>`), and the sites it probed
function M.instrument(src)
    local sites = select(1, M.sites(src))
    local edits = {}
    for _, s in ipairs(sites) do
        local new = s.clause_text:gsub('ipairs%s*%((.*)%)%s*$', function(inner)
            return ('ipairs(cg_probe(%d, %s, %q, %s))'):format(s.line, inner, s.F, s.K)
        end, 1)
        edits[#edits + 1] = { at = s.clause_at, to = new }
    end
    local lines = vim.split(src, '\n', { plain = true })
    table.sort(edits, function(a, b)
        if a.at.start.line ~= b.at.start.line then return a.at.start.line > b.at.start.line end
        return a.at.start.char > b.at.start.char
    end)
    for _, e in ipairs(edits) do
        local l = lines[e.at.start.line + 1]
        lines[e.at.start.line + 1] = l:sub(1, e.at.start.char) .. e.to .. lines[e.at['end'].line + 1]:sub(e.at['end'].char + 1)
        for k = e.at['end'].line, e.at.start.line + 1, -1 do table.remove(lines, k + 1) end
    end
    return M.PROBE .. table.concat(lines, '\n'), sites
end

--- price one site's measured profile: element touches the scan cost vs the index's build + walk, and
--- the memory the buckets hold. `opts.ratio` (default 4): apply when the scan costs that many times more.
--- @return boolean apply, table detail
function M.decide(st, opts)
    opts = opts or {}
    if not st or st.calls == 0 then return false, { why = 'not exercised by the workload' } end
    local scan = st.touches
    local index = st.distinct_len + st.matches + st.calls
    local d = { calls = st.calls, scan = scan, index = index, memory = st.distinct_len, distinct = st.distinct,
        saved = scan - index, ratio = index > 0 and scan / index or math.huge }
    if d.ratio >= (opts.ratio or 4) then return true, d end
    d.why = ('the scan costs %d element touches, the index %d (ratio %.1f < %s): not worth %d bucket entries'):format(
        scan, index, d.ratio, tostring(opts.ratio or 4), d.memory)
    return false, d
end

--- which functions of `rel` run inside an input-sized loop somewhere (loopcost, scoped to the file and
--- its callers' files): fn id -> the finding's location
local function repeated_fns(store, rel)
    local lc = require 'cartograph.loopcost'
    local data = store.data or {}
    local mine, fileset = {}, { [rel] = true }
    for _, n in ipairs(data.nodes or {}) do
        if n.file == rel and (n.kind == 'function' or n.kind == 'method') then mine[n.id] = n end
    end
    for _, c in ipairs(data.calls or {}) do
        if c.file and c.to and mine[c.to] then fileset[c.file] = true end
    end
    local R = lc.analyze(store, data, { fileset = fileset })
    local rep = {}
    for _, f in ipairs(R.findings) do
        if f.callee and mine[f.callee] and f.kind ~= 'possible' then rep[f.callee] = rep[f.callee] or (f.file .. ':' .. f.line) end
    end
    return rep, mine
end

--- a txn PLAN indexing the repeated scans of one file (`opts.all`: every recognized site)
--- @return table? plan, string? why, string? code
function M.plan(store, rel, opts)
    opts = opts or {}
    local lines = store.content and store.content({ file = rel })
    if not lines then return nil, 'cannot read ' .. rel, 'unreadable' end
    local src = table.concat(lines, '\n')
    local sites, declined = M.sites(src)
    local rep, mine = repeated_fns(store, rel)
    local atr = require 'cartograph.at'
    local function enclosing_fn(line)
        local best
        for id, n in pairs(mine) do
            local s, e = atr.sl(n.range) + 1, atr.el(n.range) + 1
            if s <= line and line <= e and (not best or s > best.s) then best = { id = id, s = s } end
        end
        return best and best.id
    end
    -- ★ REPEATED OVER THE SAME LIST. A function run inside a loop pays for an index only if it filters
    -- the SAME list each time: an upvalue/global (shared), or the whole parameter (the caller's list —
    -- a premise). A field of a parameter (`e.kids`) or a local built in the call is a fresh list per
    -- call: the index would be built and thrown away. (The first cut asked only "is the function
    -- repeated" and proposed prototypes.lua's per-node `e.kids` scans.)
    local expr = require 'cartograph.expr'
    local function list_class(fid, s)
        local got = fid and expr.of(store, fid)
        local fl = got and got.fl
        if not fl then return 'unknown' end
        local params, defs = {}, {}
        for _, p in ipairs(fl.params or {}) do params[p] = true end
        for _, r in ipairs(fl.stmts or {}) do for _, d in ipairs(r.def or {}) do defs[d] = true end end
        -- a loop BINDER is per element too (du records Lua binders as uses — CART-0393 — so `defs` alone
        -- read `kid.kids` of an outer loop's `kid` as shared state)
        for name in pairs(got.bound or {}) do defs[name] = true end
        local e = s.E:gsub('^%(', ''):gsub('%s+or%s+{}%)?$', '')
        if params[e] then return 'param' end
        if params[s.base] then return 'param-field' end
        if defs[s.base] then return 'local' end
        return 'shared'
    end
    local chosen = {}
    for _, s in ipairs(sites) do
        local fid = enclosing_fn(s.line)
        s.fn, s.repeated = fid, fid and rep[fid] or nil
        s.list = list_class(fid, s)
        if opts.profile then
            -- PROFILE-GUIDED: the measurement decides, the static guess does not
            local apply, d = M.decide(opts.profile[s.line] or opts.profile[tostring(s.line)], opts)
            s.measured = d
            if apply then chosen[#chosen + 1] = s
            else declined[#declined + 1] = { line = s.line, reason = 'profile: ' .. (d.why or '?') } end
        elseif not (s.repeated or opts.all) then
            declined[#declined + 1] = { line = s.line, reason = 'not repeated: no input-sized loop runs its function (an index costs more than one scan)' }
        elseif s.list == 'param-field' or s.list == 'local' then
            declined[#declined + 1] = { line = s.line, reason = ('`%s` is %s: a fresh list per call, so the index would be rebuilt every time'):format(
                s.E, s.list == 'local' and 'built inside the call' or 'a field of a parameter') }
        else chosen[#chosen + 1] = s end
    end
    -- the declines travel even when nothing is chosen: a plan-level refusal (not repeated, a fresh list
    -- per call, a measured loss) is the answer the reader needs most then
    if #chosen == 0 then return nil, 'no repeated equality-filter scan in ' .. rel, 'no-candidates', declined end
    local reps, moves = {}, {}
    local top = math.huge
    for _, s in ipairs(chosen) do
        local new = s.clause_text:gsub('ipairs%s*%((.*)%)%s*$', function(inner)
            return ('ipairs(cg_bucket(%s, %q, %s) or %s)'):format(inner, s.F, s.K, inner)
        end, 1)
        reps[#reps + 1] = { at = s.clause_at, to = new, old = s.clause_text }
        local premises = { ('`%s` is appended to only, in every file (removal/replacement is checked in this one)'):format(s.base),
            ('every element of `%s` is a table (the index touches all of them once)'):format(s.base) }
        if s.list == 'param' then premises[#premises + 1] = ('callers pass the SAME `%s` across the repeated calls (else the index is rebuilt each time, still correct)'):format(s.E) end
        moves[#moves + 1] = { line = s.line, field = s.F, key = s.K, list = s.E, sharing = s.list,
            repeated = s.measured and ('measured: %d calls, scan %d vs index %d touches (x%.1f), %d bucket entries'):format(
                s.measured.calls, s.measured.scan, s.measured.index, s.measured.ratio, s.measured.memory)
                or s.repeated or '(forced: opts.all)', premises = premises }
        if s.top < top then top = s.top end
    end
    local helper = vim.split(M.HELPER, '\n', { plain = true })
    if helper[#helper] == '' then helper[#helper] = nil end
    -- above the statement's own comment block, which stays attached to it (txn.attach_above's rule)
    local at = top
    while at > 0 and (lines[at] or ''):match('^%s*%-%-') do at = at - 1 end
    local ins = { { after = at - 1, lines = helper } }
    return txn.protocol({ verb = 'index-a-scan', guards = { 'parses', 'spans-unchanged' }, refspecs = {},
        touched = { rel }, generation = store.generation,
        stamps = { [rel] = txn.disk_stamp(store.data.root, rel) }, rel = rel,
        reps = reps, ins = ins, moves = moves, declined = declined },
        function(p)
            return function(r, before)
                if r ~= p.rel then return before end
                return txn.edit_file(before, {}, p.reps, p.ins)
            end
        end)
end

--- dry-run lines for the cockpit
function M.report(store, rel, opts)
    local plan, why, _, declined = M.plan(store, rel, opts)
    local out = { ('index-a-scan — %s'):format(rel), '' }
    if not plan then
        out[#out + 1] = why
        for _, d in ipairs(declined or {}) do out[#out + 1] = ('  %s:%d DECLINED: %s'):format(rel, d.line or 0, d.reason) end
        return out
    end
    for _, m in ipairs(plan.moves) do
        out[#out + 1] = ('  %s:%d  ipairs(%s) [%s] filtered by .%s == %s  — repeated by %s'):format(rel, m.line, m.list, m.sharing, m.field, m.key, m.repeated)
        for _, p in ipairs(m.premises) do out[#out + 1] = '        premise: ' .. p end
    end
    for _, d in ipairs(plan.declined or {}) do out[#out + 1] = ('  %s:%d DECLINED: %s'):format(rel, d.line or 0, d.reason) end
    out[#out + 1] = ''
    local before, after, err = txn.dryrun(store, plan)
    if not before then out[#out + 1] = 'dry-run failed: ' .. tostring(err); return out end
    for _, l in ipairs(txn.difftext(before, after, plan.touched)) do out[#out + 1] = l end
    return out
end

return M
