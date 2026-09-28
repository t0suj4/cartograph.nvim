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

--- attribute a commit range -> { commits = { { sha, subject, explained, hand, entries = { id -> bytes } } }, explained, hand, journals, entries_used } | nil, why, class
function M.attribute(repo, range)
    local E = M.entries(repo)
    local pool = {} -- repo-relative file -> line -> { entry ids (a stack) }
    for _, e in ipairs(E.entries) do
        for rel, f in pairs(e.files or {}) do
            local key = e._prefix .. rel
            pool[key] = pool[key] or {}
            for _, l in ipairs(added(f.before, f.after)) do
                pool[key][l] = pool[key][l] or {}
                table.insert(pool[key][l], e.id)
            end
        end
    end
    local revs, why = git(repo, { 'rev-list', '--reverse', range })
    if not revs then return nil, ('git rev-list %s: %s'):format(range, tostring(why)), 'environment' end
    local v = { commits = {}, explained = 0, hand = 0, journals = E.journals, entries_used = #E.entries }
    for sha in revs:gmatch('%S+') do
        local diff = git(repo, { 'show', '--format=%s', '-U0', '--no-color', sha }) or ''
        local c = { sha = sha, subject = diff:match('^([^\n]*)'), explained = 0, hand = 0, entries = {} }
        local file
        for line in diff:gmatch('[^\n]*') do
            local f = line:match('^%+%+%+ b/(.*)$')
            if f then file = f
            elseif line:match('^%+%+%+ ') then file = nil
            elseif file and line:sub(1, 1) == '+' then
                local l = line:sub(2)
                local stack = pool[file] and pool[file][l]
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
    return { verb = e.invocation.verb, args = rw(e.invocation.args), where = e.invocation.where }, sens
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
    for id, bytes in pairs(c.entries) do
        local e = byid[id] or {}
        local inv, sens = travelling_invocation(repo, e)
        for rel in pairs(sens or {}) do
            local img = images[rel] or {}
            local f = (e.files or {})[rel] or {}
            img[#img + 1] = f.before; img[#img + 1] = f.after
            local fd = io.open((e.root or repo) .. '/' .. rel)
            if fd then img[#img + 1] = fd:read('a'); fd:close() end
            images[rel] = img
        end
        rows[#rows + 1] = { id = id, verb = e.verb, bytes = bytes, decided_by = e.decided_by or 'unrecorded',
            decisions = e.decisions or {}, invocation = inv }
    end
    table.sort(rows, function (a, b) return a.id < b.id end)
    local intents = {}
    for _, r in ipairs(require('cartograph.intents').open_intents(repo)) do intents[#intents + 1] = r end
    return { version = 1, commit = sha, explained = c.explained, hand = c.hand, entries = rows, open_intents = intents }, images
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
