-- FEEDBACK — a complaint about CARTOGRAPH, frozen at the node it happened on.
--
-- NOT a note about the user's code. That one belongs IN the code, as a comment
-- above the def, where txn.attach_above already makes three verbs (moveapply,
-- clonemerge, the source pane) carry it along for free — textual co-location IS
-- the anchor, so it can never go stale. This module is the other half: "I
-- descended on this node and expected X, got Y", a report about the TOOL, which
-- the project's source is the wrong place for, and which has to work when there
-- is no source to write in at all (a read-only corpus, a refused resolution, an
-- empty compartment, a node that should exist and does not).
--
-- Every design rule here is the INVERSE of a source comment's:
--
--   * an entry FREEZES; it does not track. A source note must follow the code as
--     it changes. A bug report must preserve what was on screen, because the
--     claim under dispute is "cartograph said this" and re-deriving it from
--     since-edited code destroys the evidence. journal.lua states the same rule
--     for its own case: hold BEFORE-CONTENT, never a re-derivation. So the node
--     id rides along for a same-session jump and (file, name, kind) + the frozen
--     bytes are what outlive it. There is deliberately NO re-anchoring
--     machinery: an id that no longer resolves is reported dead, never repaired,
--     because a repaired anchor silently points at different code.
--   * you type the EXPECTATION only. The observation is on your screen; asking
--     for it in prose invites a paraphrase, and the paraphrase is exactly where
--     a report stops being reproducible.
--   * an ENVIRONMENT fact can decide a verdict, so it is captured, not asked
--     for. MEASURED: with a python parser on the runtimepath the rung-0 lints
--     harvest 5 expression nodes, fire zero rules (they are Lua-authored), and a
--     surface called that "clean" — whether the tool lied depended on the rtp.
--   * a field the capture could not determine says UNAVAILABLE and is never
--     omitted. A missing key reads as an answer ("no hedge", "no empty"), which
--     is the absence-rendered-as-silence defect class this codebase keeps
--     re-finding.
--   * the SUBJECT MAY BE A HOLE and the report is still filed. The most useful
--     complaints are about absences; a capture that requires a node rejects
--     precisely those. The capture degrades, the message never does — with no
--     store, no pane and no node, the expectation still reaches disk.

local M = {}

M.SCHEMA = 1
--- An honest absence. Distinct from `false` and from a missing key: it says the
--- capture LOOKED and could not tell, which is a different fact from "no".
M.UNAVAILABLE = 'UNAVAILABLE'

--- Every key an entry carries. The loop over this list is what makes the
--- honesty rule mechanical rather than a habit: a field absent from the
--- sighting becomes UNAVAILABLE, it does not vanish.
M.FIELDS = { 'expected', 'gesture', 'from', 'altitude', 'lens',
    'before', 'after', 'subject', 'empty', 'why', 'env' }

-- ── where entries live ───────────────────────────────────────────────────────
-- journal.lua's convention, deliberately: the STATE dir, not the cache dir,
-- because a cache is something we are allowed to delete, and one JSON per entry
-- so the file is readable with no tool at all.
--- The entry directory for a root. Creates it only when `peek` is false: READING a
--- root must not bring its directory into existence, or merely listing a project
--- you never filed against litters the state dir with empty folders — and an
--- existing dir is the cheapest signal that a root HAS feedback.
local function dir_of(root, peek)
    local dir = vim.fn.stdpath('state') .. '/cartograph/'
        .. (root or 'no-root'):gsub('/+$', ''):gsub('[/\\:]', '%%') .. '.feedback'
    if not peek then vim.fn.mkdir(dir, 'p') end
    return dir
end
M.dir = dir_of

-- ── capture: the environment ─────────────────────────────────────────────────

--- Which treesitter parsers are REACHABLE, by name — an environment fact with
--- a measured history of deciding verdicts (see the header).
function M.parsers()
    local ok, files = pcall(vim.api.nvim_get_runtime_file, 'parser/*', true)
    if not (ok and type(files) == 'table') then return M.UNAVAILABLE end
    local set = {}
    for _, f in ipairs(files) do
        local n = f:match('([^/]+)%.%w+$')
        if n then set[n] = true end
    end
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return #out > 0 and out or 'none'
end

--- Which cartograph this was: the commit, so a report filed today is still
--- diagnosable after the code moves on.
function M.commit()
    local src = (debug.getinfo(1, 'S').source or ''):gsub('^@', '')
    local dir = src:match('^(.*)/lua/cartograph/feedback%.lua$')
    if not dir then return M.UNAVAILABLE end
    local ok, out = pcall(vim.fn.systemlist,
        { 'git', '-C', dir, 'rev-parse', '--short', 'HEAD' })
    if not ok or vim.v.shell_error ~= 0 or type(out) ~= 'table' or not out[1] then
        return M.UNAVAILABLE
    end
    return out[1]
end

--- The environment facts that can change what cartograph says. Gathered from
--- the store where it has them and from the editor otherwise; anything we
--- cannot read says so.
function M.env(store)
    local U = M.UNAVAILABLE
    local ok_v, v = pcall(vim.version)
    local e = {
        nvim = ok_v and ('%d.%d.%d'):format(v.major or 0, v.minor or 0, v.patch or 0) or U,
        cartograph = M.commit(),
        parsers = M.parsers(),
        cache_version = U, root = U, index_only = U, profile = U, packs = U,
    }
    local ok_c, cache = pcall(require, 'cartograph.cache')
    if ok_c and cache.VERSION then e.cache_version = cache.VERSION end
    if not store then return e end
    if store.is_index_only then
        local ok, r = pcall(store.is_index_only)
        if ok then e.index_only = r end
    end
    local d = store.data
    if not d then return e end
    e.root = d.root or U
    e.profile = d.profile or 'none'
    -- packs arrive as either a set or a list depending on the caller; read both
    local ps = {}
    for k, val in pairs(d.packs or {}) do
        ps[#ps + 1] = type(k) == 'number' and tostring(val) or tostring(k)
    end
    table.sort(ps)
    e.packs = #ps > 0 and ps or 'none'
    return e
end

-- ── capture: the subject ─────────────────────────────────────────────────────

--- The subject's source, frozen. The evidence has to survive you fixing the
--- code: after an edit an id may still resolve, and resolve to something ELSE,
--- so the bytes ride along. Capped, and says when it truncated.
function M.freeze(store, n, cap)
    cap = cap or 60
    if not (store and store.abs and n and n.range) then return M.UNAVAILABLE end
    -- Through cartograph.at, ALWAYS: in a live store ranges are FOLDED to a
    -- column index, so `n.range.start` is an index into nothing and indexing a
    -- number raises. The dual-mode accessors are the seam every consumer reads
    -- through ([[cartograph-shape-roster]]); the live drive found this module
    -- bypassing it, which no fixture-shaped spec could have caught.
    local ok_at, at = pcall(require, 'cartograph.at')
    if not ok_at then return M.UNAVAILABLE end
    local ok_s, s0 = pcall(at.sl, n.range)
    local ok_e, e0 = pcall(at.el, n.range)
    if not (ok_s and type(s0) == 'number') then return M.UNAVAILABLE end
    local ok, fd = pcall(io.open, store.abs(n.file), 'r')
    if not (ok and fd) then return M.UNAVAILABLE end
    local text = fd:read('a')
    fd:close()
    if not text then return M.UNAVAILABLE end
    local lines = vim.split(text, '\n', { plain = true })
    local s = s0 + 1
    local last = ((ok_e and type(e0) == 'number') and e0 or s0) + 1
    local stop = math.min(last, s + cap - 1)
    local out = {}
    for i = s, stop do out[#out + 1] = lines[i] or '' end
    return { first_line = s, last_line = last, truncated = last > stop, text = out }
end

--- WHY cartograph believed what it said about this node: the provenance of its
--- outgoing calls (which resolution pass or pack landed each one) and how many
--- it refused. Without this a report saying "this resolution is wrong" cannot
--- distinguish a linker bug from a spec-pack gap, which is the difference
--- between two entirely different fixes. There is no per-NODE tier to read —
--- trust lives on EDGES ([[cartograph.tier]]) — so this is a histogram, not a
--- verdict, and it says so.
function M.why(store, id)
    -- through Band:sites, never store.calls_by_fn directly: the wide indexes are
    -- band.lua's to read (the seam-guard caught this module doing otherwise).
    if not (store and store.topo) then return M.UNAVAILABLE end
    local ok_t, band = pcall(store.topo)
    if not (ok_t and band and band.sites) then return M.UNAVAILABLE end
    local ok_s, calls = pcall(band.sites, band, id)
    if not (ok_s and calls) then return M.UNAVAILABLE end
    local ok, callrec = pcall(require, 'cartograph.callrec')
    if not ok then return M.UNAVAILABLE end
    local by_prov, refused, total = {}, 0, 0
    for _, c in ipairs(calls) do
        total = total + 1
        local p = callrec.prov(c) or 'none'
        by_prov[p] = (by_prov[p] or 0) + 1
        if c.refused then refused = refused + 1 end
    end
    if total == 0 then return M.UNAVAILABLE end
    local parts = {}
    for p, n in pairs(by_prov) do parts[#parts + 1] = ('%s %d'):format(p, n) end
    table.sort(parts)
    return { calls = total, refused = refused, by_prov = parts }
end

-- ── capture: the sighting ────────────────────────────────────────────────────

--- Everything an entry needs EXCEPT the expectation, gathered from a live
--- browser. `pane` is injected (cartograph.panes.symbols in practice) so the
--- gather is testable against a stub, and so a capture with no cockpit open
--- still produces a usable sighting instead of failing.
function M.sight(store, pane)
    local s = { env = M.env(store) }
    if not pane then return s end
    local v = pane.view or {}
    s.altitude, s.lens = v.level, v.lens
    local rows, cur = nil, nil
    if pane.rows then rows, cur = pane.rows() end
    s.after = rows
    -- WHERE YOU WERE STANDING when the key fired, which is not where you are
    -- now — the whole point of a transition report.
    local g = pane.last_gesture
    if g then
        s.gesture = g.gesture
        s.before = g.rows
        s.from = { altitude = g.level, lens = g.lens, row = g.row }
    end
    -- the typed EMPTY as rendered: `why` non-nil means the pane was blank
    -- because nothing was COMPUTED, which is a different bug from a pane blank
    -- because there genuinely is nothing. Reports about absences hinge on it.
    if s.altitude then
        local ok, concerns = pcall(require, 'cartograph.panes.concerns')
        if ok and concerns.empty_of then
            local ok2, note, why = pcall(concerns.empty_of, s.altitude, store)
            if ok2 and note then
                s.empty = { rendered = note, uncomputed = why ~= nil }
            end
        end
    end
    -- the subject, which MAY BE A HOLE
    local id, whence
    if pane.row_subject then
        local ok, a, b = pcall(pane.row_subject)
        if ok then id, whence = a, b end
    end
    -- MEASURED live: row_subject needs a cursor row and abandons its own
    -- documented altitude fallback without one — which is the case whenever the
    -- browser window is not the current window, i.e. exactly when you are typing
    -- a complaint somewhere else. The altitude's subject needs no cursor, so ask
    -- for it directly rather than losing the subject and misreporting a content
    -- bug as an absence.
    if not id and pane.subject then
        local ok, a = pcall(pane.subject)
        if ok and a then id, whence = a, 'altitude' end
    end
    local n = (id and store and store.node) and store.node(id) or nil
    if n then
        s.subject = { kind = 'node', id = id, whence = whence or M.UNAVAILABLE,
            file = n.file, name = n.name, node_kind = n.kind,
            source = M.freeze(store, n) }
        s.why = M.why(store, id)
    else
        -- Three DIFFERENT holes, and saying the wrong one is the fabrication this
        -- module exists to prevent: claiming we "filed on the ROW" when no row
        -- could even be read is a false statement about our own evidence.
        local row_text = rows and cur and rows[cur] or nil
        s.subject = { kind = 'none',
            row = row_text or M.UNAVAILABLE,
            why = id and 'the row named a node the store cannot resolve'
                or row_text and 'the cursor row is about no node — filed on the ROW'
                or 'no cursor row could be read (the browser window was not'
                    .. ' current) and the altitude names no subject either' }
    end
    return s
end

-- ── the entry ────────────────────────────────────────────────────────────────

--- Which of the three kinds this is, DERIVED rather than asked: they differ in
--- what has to be captured, not in how you file them. An absence outranks a
--- transition because "I descended and got an empty pane" is diagnosed from the
--- empty's declared reason, not from the hop.
function M.classify(e)
    local hole = type(e.subject) == 'table' and e.subject.kind == 'none'
    if hole or type(e.empty) == 'table' then return 'absence' end
    if e.gesture and e.gesture ~= M.UNAVAILABLE then return 'transition' end
    return 'content'
end

--- Normalize a sighting into a schema-1 entry. PURE. Refuses only an empty
--- expectation — with nothing expected there is no report, just a bookmark.
--- @return table|nil entry, string|nil why
function M.entry(o)
    o = o or {}
    local expected = o.expected and vim.trim(o.expected) or ''
    if expected == '' then return nil, 'no expectation given' end
    local e = { version = M.SCHEMA, ts = o.ts or os.time() }
    for _, f in ipairs(M.FIELDS) do
        local val = o[f]
        -- An empty table is UNAVAILABLE, not "empty": a browser buffer is never
        -- zero lines (a blank pane is `{ '' }`), so nothing to read means the
        -- read failed.
        if val == nil or (type(val) == 'table' and next(val) == nil) then
            val = M.UNAVAILABLE
        end
        e[f] = val
    end
    e.expected = expected
    e.kind = M.classify(e)
    local ok, journal = pcall(require, 'cartograph.journal')
    local h = (ok and journal.hash) and journal.hash(expected) or 'nohash'
    e.id = ('%d-%s'):format(e.ts, h)
    return e
end

--- File an entry. Returns the path written.
function M.write(root, e)
    local path = dir_of(root) .. '/' .. e.id .. '.json'
    local fd = io.open(path, 'w')
    if not fd then return nil, 'cannot write ' .. path end
    fd:write(vim.json.encode(e))
    fd:close()
    return path
end

--- Entries for a root, newest first.
function M.list(root)
    local dir = dir_of(root, true) -- peek: listing must not create
    local out = {}
    local it = vim.uv.fs_scandir(dir)
    while it do
        local name = vim.uv.fs_scandir_next(it)
        if not name then break end
        if name:match('%.json$') then
            local fd = io.open(dir .. '/' .. name, 'r')
            if fd then
                local ok, e = pcall(vim.json.decode, fd:read('a'))
                fd:close()
                if ok and type(e) == 'table' and e.id then out[#out + 1] = e end
            end
        end
    end
    table.sort(out, function (a, b) return tostring(a.id) > tostring(b.id) end)
    return out
end

-- ── the dump ─────────────────────────────────────────────────────────────────
-- A log nobody reads is a diary. This is the read path that matters first: the
-- entries as text you can paste to whoever fixes cartograph, self-contained,
-- with no need to re-find or re-describe anything.

local function scalar(v)
    -- nil renders as the honest absence, never as the word "nil". entry() only
    -- normalizes TOP-LEVEL fields, so a nested nil (from.lens, subject.whence)
    -- reached the dump as `nil` while its sibling said UNAVAILABLE — the same
    -- fact printed two ways, one of which reads as an answer. Fixing it here
    -- fixes the class rather than the site.
    if v == nil then return M.UNAVAILABLE end
    if type(v) == 'table' then
        local parts = {}
        for _, x in ipairs(v) do parts[#parts + 1] = tostring(x) end
        return #parts > 0 and table.concat(parts, ', ') or vim.inspect(v, { newline = ' ', indent = '' })
    end
    return tostring(v)
end

local function block(L, title, rows, prefix)
    L[#L + 1] = title
    if type(rows) ~= 'table' then
        L[#L + 1] = '    ' .. tostring(rows)
        return
    end
    for _, r in ipairs(rows) do L[#L + 1] = (prefix or '    ') .. r end
end

--- The entries as pasteable markdown.
function M.markdown(entries, root)
    local L = { ('# cartograph feedback — %d entr%s'):format(#entries,
        #entries == 1 and 'y' or 'ies') }
    if root then L[#L + 1] = ('root: `%s`'):format(root) end
    if #entries == 0 then
        L[#L + 1] = ''
        L[#L + 1] = 'No entries filed for this root yet. `:CartographFeedback <text>`'
            .. ' files one from wherever you are standing.'
        return L
    end
    for i, e in ipairs(entries) do
        -- An UNAVAILABLE subject is NOT "a row with no node": we did not look, or
        -- could not. Rendering the two the same way is the fabrication this
        -- module exists to avoid, and the spec fences it.
        local subj = type(e.subject) == 'table' and e.subject or nil
        local title = (not subj) and 'subject UNAVAILABLE'
            or (subj.kind == 'node'
                and ('`%s` in `%s`'):format(subj.name or '?', subj.file or '?')
                or 'a row with no node')
        L[#L + 1] = ''
        L[#L + 1] = ('## %d. %s — %s'):format(i, e.kind or '?', title)
        L[#L + 1] = ('filed %s · altitude `%s` · lens `%s` · gesture `%s`'):format(
            os.date('%Y-%m-%d %H:%M', tonumber(e.ts) or 0),
            scalar(e.altitude), scalar(e.lens), scalar(e.gesture))
        if type(e.from) == 'table' then
            L[#L + 1] = ('came from altitude `%s` lens `%s`'):format(
                scalar(e.from.altitude), scalar(e.from.lens))
        end
        L[#L + 1] = ''
        L[#L + 1] = 'EXPECTED'
        for _, l in ipairs(vim.split(e.expected or '', '\n', { plain = true })) do
            L[#L + 1] = '    ' .. l
        end
        L[#L + 1] = ''
        block(L, 'OBSERVED — the rows as rendered, after the gesture', e.after)
        if e.before ~= M.UNAVAILABLE then
            L[#L + 1] = ''
            block(L, 'BEFORE — the rows the gesture was pressed on', e.before)
        end
        L[#L + 1] = ''
        L[#L + 1] = 'SUBJECT'
        if not subj then
            L[#L + 1] = '    ' .. scalar(e.subject)
        elseif subj.kind == 'node' then
            L[#L + 1] = ('    %s  %s/%s  in %s'):format(scalar(subj.id),
                scalar(subj.name), scalar(subj.node_kind), scalar(subj.file))
            L[#L + 1] = ('    anchored by: %s'):format(scalar(subj.whence))
            local src = subj.source
            if type(src) == 'table' and src.text then
                L[#L + 1] = ('    frozen source L%s-%s%s:'):format(
                    scalar(src.first_line), scalar(src.last_line),
                    src.truncated and ' (truncated)' or '')
                for _, l in ipairs(src.text) do L[#L + 1] = '      ' .. l end
            else
                L[#L + 1] = '    frozen source: ' .. scalar(src)
            end
        else
            L[#L + 1] = ('    none — %s'):format(scalar(subj.why))
            L[#L + 1] = ('    the row read: %s'):format(scalar(subj.row))
        end
        if type(e.empty) == 'table' then
            L[#L + 1] = ''
            L[#L + 1] = 'THE EMPTY AS RENDERED'
            L[#L + 1] = ('    %s'):format(scalar(e.empty.rendered))
            L[#L + 1] = ('    uncomputed: %s — %s'):format(tostring(e.empty.uncomputed),
                e.empty.uncomputed
                    and 'the pane was blank because nothing was COMPUTED'
                    or 'the pane was blank because there genuinely is nothing')
        end
        if type(e.why) == 'table' then
            L[#L + 1] = ''
            L[#L + 1] = 'WHY CARTOGRAPH BELIEVED IT — call provenance (a histogram, not a verdict)'
            L[#L + 1] = ('    %s call(s), %s refused'):format(scalar(e.why.calls),
                scalar(e.why.refused))
            L[#L + 1] = ('    by pass/pack: %s'):format(scalar(e.why.by_prov))
        end
        local env = type(e.env) == 'table' and e.env or nil
        L[#L + 1] = ''
        L[#L + 1] = 'ENVIRONMENT'
        if not env then
            -- one honest line beats eight fabricated fields
            L[#L + 1] = '    ' .. scalar(e.env)
        else
            L[#L + 1] = ('    cartograph %s · nvim %s · cache VERSION %s'):format(
                scalar(env.cartograph), scalar(env.nvim), scalar(env.cache_version))
            L[#L + 1] = ('    index_only %s · profile %s · packs %s'):format(
                scalar(env.index_only), scalar(env.profile), scalar(env.packs))
            L[#L + 1] = ('    parsers %s'):format(scalar(env.parsers))
        end
    end
    return L
end

return M
