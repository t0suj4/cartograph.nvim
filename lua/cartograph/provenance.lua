-- cartograph.provenance — WRITE-SIDE PROVENANCE (CART-1178): which bytes of a commit did cartograph write, through
-- which journal entries, under which decisions — and a LEDGER of that per commit that travels with the repository.
--
-- ATTRIBUTION (shared by the ledger and the provenance-audit discovery — one copy): every journal whose recorded root
-- lies inside the repo (journal.survey reads the root from the entries), each entry's ADDED lines (vim.diff of its
-- before/after per file, re-rooted to the repo), matched as a MULTISET against each commit's `git show -U0` added
-- lines — LINE level, so a commit mixing journaled and hand edits in one file splits honestly; each explained line
-- names the entry that explains it.
-- THE LEDGER is a git NOTE per commit (refs/notes/cartograph), written by the post-commit hook: the entries that
-- explain the commit, their decisions (who answered what: the term's accept list, a remembered decision) and the open
-- intents at commit time. ★ IT ONLY TIGHTENS: it is REPORTED (the audit, a push gate) and never read to skip a check
-- or as an accepted decision — the tree may select, never supply. A decision is accepted only by the caller's accept
-- list or the USER's remembered decisions (cartograph.decisions), never by a note. Notes travel only when pushed
-- (`git push origin refs/notes/cartograph`): a clone without them still has the journal where it was made.
local M = { NOTES_REF = 'refs/notes/cartograph' }

local function git(repo, args, input)
    local cmd = { 'git', '-C', repo }
    for _, a in ipairs(args) do cmd[#cmd + 1] = a end
    local obj = vim.system(cmd, { text = true, stdin = input }):wait(120000)
    if obj.code ~= 0 then return nil, ((obj.stderr or ''):gsub('%s+$', '')), 'environment' end
    return obj.stdout
end
M.git = git

local function lines_of(text) if type(text) ~= 'string' then return {} end return vim.split(text, '\n', { plain = true }) end

local function added(before, after)
    local b, a = type(before) == 'string' and before or '', type(after) == 'string' and after or ''
    local out, al = {}, lines_of(a)
    for _, h in ipairs(vim.diff(b, a, { result_type = 'indices' }) or {}) do
        for k = h[3], h[3] + h[4] - 1 do if al[k] ~= nil then out[#out + 1] = al[k] end end
    end
    return out
end

--- the journal entries of every root inside `repo` -> { entries = { entry… }, journals = n }
function M.entries(repo)
    local J = require 'cartograph.journal'
    local out, nj = {}, 0
    for _, row in ipairs(J.survey()) do
        local r = row.root and row.root:gsub('/+$', '')
        if r and (r == repo or r:sub(1, #repo + 1) == repo .. '/') then
            nj = nj + 1
            local prefix = r == repo and '' or (r:sub(#repo + 2) .. '/')
            for _, e in ipairs(J.list(r)) do
                if e.status == 'applied' or e.status == 'rolled_back' then e._prefix = prefix; out[#out + 1] = e end
            end
        end
    end
    return { entries = out, journals = nj }
end

--- a text's line counts for the LANDING check — a final line WITHOUT a newline is a different line from the same text
--- with one (MEASURED: adding a missing final newline re-adds the same text, and plain counts called it landed already)
local function line_counts(text)
    local counts, ls = {}, lines_of(text)
    if type(text) == 'string' and text ~= '' and text:sub(-1) ~= '\n' then ls[#ls] = ls[#ls] .. '\0no-newline' end
    for _, l in ipairs(ls) do counts[l] = (counts[l] or 0) + 1 end
    return counts
end

--- attribute a commit range -> { commits = { { sha, subject, explained, hand, entries = { id -> bytes } } }, explained, hand, journals, entries_used } | nil, why, class
--- ★ AN ENTRY EXPLAINS ONLY THE COMMIT ITS CHANGE LANDED IN (CART-1195). Line-multiset matching alone credited ONE entry
--- to SEVERAL commits (22 of 135 over 8 notes: an entry hours older than the work "explained" identical lines of a later
--- commit). Two DERIVED bounds, per commit C and per file:
---   TIME     the entry was made no later than C (its ts <= C's committer time) — a commit cannot hold a later edit
---   LANDING  the entry's change was not already in C's PARENT: it LANDED before C when, for every line it added, the
---            parent's file holds at least as many copies as the entry's after-image does
function M.attribute(repo, range)
    local E = M.entries(repo)
    -- per repo-relative file: the entries that touched it, each with its added lines and its after-image line counts
    local by_file = {}
    for _, e in ipairs(E.entries) do
        for rel, f in pairs(e.files or {}) do
            local key = e._prefix .. rel
            local add = added(f.before, f.after)
            if #add > 0 then
                local counts = line_counts(f.after)
                by_file[key] = by_file[key] or {}
                table.insert(by_file[key], { id = e.id, ts = e.ts or 0, added = add, after_counts = counts })
            end
        end
    end
    local revs, why = git(repo, { 'rev-list', '--reverse', range })
    if not revs then return nil, ('git rev-list %s: %s'):format(range, tostring(why)), 'environment' end
    local v = { commits = {}, explained = 0, hand = 0, journals = E.journals, entries_used = #E.entries }
    for sha in revs:gmatch('%S+') do
        local diff = git(repo, { 'show', '--format=%s%n%ct', '-U0', '--no-color', sha }) or ''
        local subject, ct = diff:match('^([^\n]*)\n(%d+)')
        ct = tonumber(ct) or math.huge
        -- the parent's commit time (a root commit has none: every entry is younger than it)
        local pt = tonumber(((git(repo, { 'log', '-1', '--format=%ct', sha .. '^' }) or ''):match('%d+'))) or -math.huge
        local c = { sha = sha, subject = subject, explained = 0, hand = 0, entries = {} }
        -- the pool for THIS commit, file by file: only entries within the time bound whose change had not landed yet
        local pools = {}
        local function pool_of(file)
            if pools[file] then return pools[file] end
            local parent = git(repo, { 'show', sha .. '^:' .. file })
            local pc = line_counts(parent)
            local pool = {}
            for _, en in ipairs(by_file[file] or {}) do
                local landed, any_landed = parent ~= nil, false
                if landed then
                    for _, l in ipairs(en.added) do
                        if (pc[l] or 0) < (en.after_counts[l] or 0) then landed = false
                        else any_landed = true end
                    end
                end
                -- ★ AN ENTRY OLDER THAN THE PARENT COMMIT belongs here only if NONE of its change is in the parent (an
                -- edit made before the parent was committed and left out of it). MEASURED: with the landing bound alone,
                -- 5 older entries still claimed a few bytes — lines they added were edited again later, so the parent
                -- no longer held them all and they read as "not landed"
                local eligible = en.ts <= ct and not landed and not (en.ts < pt and any_landed)
                if eligible then
                    for _, l in ipairs(en.added) do
                        pool[l] = pool[l] or {}
                        table.insert(pool[l], en.id)
                    end
                end
            end
            pools[file] = pool
            return pool
        end
        local file
        for line in diff:gmatch('[^\n]*') do
            local f = line:match('^%+%+%+ b/(.*)$')
            if f then file = f
            elseif line:match('^%+%+%+ ') then file = nil
            elseif file and line:sub(1, 1) == '+' then
                local l = line:sub(2)
                local stack = pool_of(file)[l]
                if stack and #stack > 0 then
                    local id = table.remove(stack)
                    c.explained = c.explained + #l + 1
                    c.entries[id] = (c.entries[id] or 0) + #l + 1
                else
                    c.hand = c.hand + #l + 1
                end
            end
        end
        v.commits[#v.commits + 1] = c
        v.explained, v.hand = v.explained + c.explained, v.hand + c.hand
    end
    local total = v.explained + v.hand
    v.ratio = total > 0 and (v.explained / total) or 0
    return v
end

--- an entry's invocation as it may TRAVEL (CART-1193): an entry that touched a SENSITIVE file (untracked, or marked by
--- user config — cartograph.sensitive) carries only a REFERENCE to its args; any other carries the args, with paths
--- under its world's root named by the world's portable identity (an absolute path would carry this machine's layout
--- into a pushed note). -> invocation | nil, and the sensitive rels
local function travelling_invocation(repo, e)
    local S = require 'cartograph.sensitive'
    local root = e.root or repo
    local rels = {}
    for rel in pairs(e.files or {}) do rels[#rels + 1] = rel end
    table.sort(rels)
    local sens = S.classify(root, rels)
    if type(e.invocation) ~= 'table' then return nil, sens end
    if next(sens) then
        local n = 0
        for _ in pairs(sens) do n = n + 1 end
        return { verb = e.invocation.verb, args = S.reference(e.invocation.args), sensitive_files = n }, sens
    end
    local name = '@' .. (require('cartograph.approvals').world_id(root) or 'root')
    local function rw(v)
        if type(v) == 'string' then
            if v == root then return name end
            if v:sub(1, #root + 1) == root .. '/' then return name .. '/' .. v:sub(#root + 2) end
            return v
        elseif type(v) == 'table' then
            local o = {}
            for k, x in pairs(v) do o[k] = rw(x) end
            return o
        end
        return v
    end
    return { verb = e.invocation.verb, args = rw(e.invocation.args), where = e.invocation.where, touched = e.invocation.touched }, sens
end

--- the row and, beside it, the IMAGES of every sensitive file its entries touched (the egress check's probes)
local function build(repo, sha)
    local v, why, class = M.attribute(repo, sha .. '^!')
    if not v then return nil, why, class end
    local c = v.commits[1]
    if not c then return nil, 'no such commit ' .. tostring(sha), 'ill-posed' end
    local byid = {}
    for _, e in ipairs(M.entries(repo).entries) do byid[e.id] = e end
    local rows, images = {}, {}
    -- an entry's travelling invocation, feeding the egress check the images of every sensitive file it touched
    local function travel(e)
        local inv, sens = travelling_invocation(repo, e)
        for rel in pairs(sens or {}) do
            local img = images[rel] or {}
            local f = (e.files or {})[rel] or {}
            img[#img + 1] = f.before; img[#img + 1] = f.after
            local fd = io.open((e.root or repo) .. '/' .. rel)
            if fd then img[#img + 1] = fd:read('a'); fd:close() end
            images[rel] = img
        end
        return inv
    end
    for id, bytes in pairs(c.entries) do
        local e = byid[id] or {}
        rows[#rows + 1] = { id = id, verb = e.verb, bytes = bytes, decided_by = e.decided_by or 'unrecorded',
            decisions = e.decisions or {}, invocation = travel(e) }
    end
    table.sort(rows, function (a, b) return a.id < b.id end)
    -- ★ THE REPLAY LIST (CART-1191): every APPLIED entry of this commit's window that touched a file the commit changed,
    -- in order — not only the entries that EXPLAIN its lines. A step whose lines a later step overwrote before the commit
    -- explains nothing, yet the later step was planned against it (MEASURED by replay_spec: without it, the follow-up
    -- replayed as a conflict against a clean parent). Plus the explaining entries (an older one left out of the parent).
    local changed = {}
    for f in (git(repo, { 'show', '--format=', '--name-only', sha }) or ''):gmatch('[^\n]+') do changed[f] = true end
    local ct = tonumber(((git(repo, { 'log', '-1', '--format=%ct', sha }) or ''):match('%d+'))) or math.huge
    local pt = tonumber(((git(repo, { 'log', '-1', '--format=%ct', sha .. '^' }) or ''):match('%d+'))) or -math.huge
    local want = {}
    for _, r in ipairs(rows) do want[r.id] = true end
    -- the lower bound is the parent's commit time AND "not already in the parent" (an entry of the parent's own second
    -- — MEASURED: a test commits and edits within one second — is told apart by the landing test the attribution uses)
    local parent_counts = {}
    local function landed_in_parent(key, f)
        if parent_counts[key] == nil then
            local txt = git(repo, { 'show', sha .. '^:' .. key })
            parent_counts[key] = txt and line_counts(txt) or false
        end
        local pc = parent_counts[key]
        if not pc then return false end
        local ac = line_counts(f.after)
        for _, l in ipairs(added(f.before, f.after)) do if (pc[l] or 0) < (ac[l] or 0) then return false end end
        return true
    end
    for id, e in pairs(byid) do
        if e.status == 'applied' and (e.ts or 0) >= pt and (e.ts or 0) <= ct then
            for rel, f in pairs(e.files or {}) do
                local key = (e._prefix or '') .. rel
                if changed[key] and not landed_in_parent(key, f) then want[id] = true; break end
            end
        end
    end
    local replay = {}
    for id in pairs(want) do replay[#replay + 1] = id end
    table.sort(replay)
    for i, id in ipairs(replay) do
        local e = byid[id] or {}
        replay[i] = { id = id, verb = e.verb, invocation = travel(e) }
    end
    local intents = {}
    for _, r in ipairs(require('cartograph.intents').open_intents(repo)) do intents[#intents + 1] = r end
    return { version = 1, commit = sha, explained = c.explained, hand = c.hand, entries = rows, replay = replay, open_intents = intents }, images
end

--- the LEDGER row for one commit: attribution + the decisions and (travelling) invocations of the entries behind it
--- + the open intents
function M.ledger_row(repo, sha)
    local row, why, class = build(repo, sha)
    if not row then return nil, why, class end
    return row
end

--- write the ledger note for `sha` (default HEAD) -> row | nil, why, class
function M.write_note(repo, sha)
    sha = sha or (git(repo, { 'rev-parse', 'HEAD' }) or ''):gsub('%s+$', '')
    local row, images, class = build(repo, sha)
    if not row then return nil, images, class end
    -- ★ THE EGRESS CHECK (CART-1193), INDEPENDENT of the redaction: no line of a sensitive file the row's entries
    -- touched may occur anywhere in the note. Refused by NAME (the file, never its bytes), and nothing is written.
    local hits = require('cartograph.sensitive').leaks(row, images)
    if #hits > 0 then
        local names = {}
        for _, h in ipairs(hits) do names[#names + 1] = h.file end
        return nil, ('the ledger note would carry bytes of a sensitive file (%s): nothing written'):format(table.concat(names, ', ')), 'decision'
    end
    local ok, nwhy = git(repo, { 'notes', '--ref', M.NOTES_REF, 'add', '-f', '-F', '-', sha }, vim.json.encode(row))
    if not ok then return nil, 'git notes: ' .. tostring(nwhy), 'environment' end
    return row
end

--- read the ledger note of `sha` -> row | nil (no note)
function M.read_note(repo, sha)
    local txt = git(repo, { 'notes', '--ref', M.NOTES_REF, 'show', sha })
    if not txt then return nil end
    local ok, row = pcall(vim.json.decode, txt)
    return ok and row or nil
end

return M
