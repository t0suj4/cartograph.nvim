-- cartograph.replay — MERGE BY REPLAYING INTENTS (CART-1191 leaf 2). Another person's work arrives as the INVOCATIONS
-- their journal recorded (verb + args — leaf 1, travelling in the ledger notes); merging it into this world is
-- RE-RUNNING those steps here, in order, through the ordinary tactic runner, so decisions, signed approvals,
-- compensation and indeterminate intents all apply unchanged. Each step classifies ITSELF through its verb's own goal
-- check — nothing here knows the representation (text, terms, deployments):
--     done       the change is already here (the same edit made on both sides, or an earlier replay) -> EMPTY
--     applied    it was pending, and now it is here
--     conflict   the verb refused the step as STALE at plan time: this world moved at the step's site (the edit verb's
--                drifted — neither the pre- nor the post-image). A DECISION (keep mine / take theirs), never a guess;
--                the replay stops there, because later steps may have been planned against it
--     frontier   the step cannot be replayed from what travelled: its args are a REFERENCE (it touched a sensitive
--                file, CART-1193 — the bytes stayed home), or its paths name ANOTHER world
-- ★ ORDER: commits in range order, entries by id within a commit (journal ids sort by time). A step after a stop is
-- NOT attempted — it is reported as `not reached`, never as skipped-and-fine.
local M = {}

local function git(repo, args)
    local cmd = { 'git', '-C', repo }
    vim.list_extend(cmd, args)
    local r = vim.system(cmd, { text = true }):wait()
    return r.code == 0 and r.stdout or nil
end

-- ── TRANSPORT (CART-1191 leaf 4): a GIT store ─────────────────────────────────────────────────────────────────────
-- A teammate's work travels as their branch AND their ledger notes, both pushed to a shared remote. `fetch` brings both
-- here: the branches as usual (refs/remotes/<remote>/…), the notes into a MIRROR ref of their own —
-- refs/notes/cartograph-remotes/<remote> — force-updated to theirs and NEVER merged into this repo's notes (this repo's
-- ledger records what happened HERE; theirs is evidence of what they asked, read only to replay it).
-- The store's capabilities, as CART-1183 derives them for a git remote: read by key (a note per commit), conditional
-- write (a push is refused when the remote moved — the CAS), and no change feed (fetch is a POLL).
M.MIRROR = 'refs/notes/cartograph-remotes/'

--- fetch `remote`'s branches and its ledger notes into the mirror -> the mirror ref | nil, why
function M.fetch(repo, remote)
    if type(remote) ~= 'string' or not remote:match('^[%w._-]+$') then return nil, 'a remote NAME (as `git remote` lists it)' end
    local ref = M.MIRROR .. remote
    local ok = git(repo, { 'fetch', '-q', remote })
    if not ok then return nil, ('git fetch %s failed'):format(remote) end
    -- a remote with no notes yet is not an error: nothing to replay from it
    git(repo, { 'fetch', '-q', remote, '+' .. require('cartograph.provenance').NOTES_REF .. ':' .. ref })
    return ref
end

--- the invocations the ledger notes of `range` (in `repo`; `ref` = a notes ref, default this repo's) carry, in replay
--- order -> { { commit, id, invocation } }
function M.from_notes(repo, range, ref)
    local P = require 'cartograph.provenance'
    local out, seen = {}, {}
    for sha in (git(repo, { 'rev-list', '--reverse', range }) or ''):gmatch('%x+') do
        local row = P.read_note(repo, sha, ref)
        local entries = {}
        -- ⚠ ONE ENTRY, ONE STEP: the line-level attribution can credit an entry to SEVERAL commits (MEASURED: 22 of 135
        -- entries over the last 8 notes of this repo — an old entry "explains" identical lines of a later commit), so
        -- an entry is replayed once, at the FIRST commit of the range that names it
        -- the note's REPLAY list (every applied step of the commit's window, superseded ones included) when it has one;
        -- an older note has only the entries that explain the commit's lines
        for _, e in ipairs(row and (row.replay or row.entries) or {}) do
            if not seen[e.id] then seen[e.id] = true; entries[#entries + 1] = e end
        end
        table.sort(entries, function (a, b) return tostring(a.id) < tostring(b.id) end)
        for _, e in ipairs(entries) do
            out[#out + 1] = { commit = sha, id = e.id, invocation = e.invocation, verb = e.verb }
        end
    end
    return out
end

--- a travelling invocation's args, localized to the world rooted at `root` -> args | nil, why
function M.localize(args, root)
    if type(args) == 'table' and args.sensitive and args.ref then
        return nil, 'its args travelled as a reference (it touched a sensitive file): the bytes stayed on the machine that made it'
    end
    local id = require('cartograph.approvals').world_id(root)
    local bad
    local function rw(v)
        if type(v) == 'string' then
            -- a portable path is `@<world id>` or `@<world id>/rel`, the id being `host/path:prefix` (so it holds `/`
            -- and `:` itself — matched as a PREFIX, never split)
            local mine = id and ('@' .. id) or nil
            if mine and v == mine then return root end
            if mine and v:sub(1, #mine + 1) == mine .. '/' then return root .. '/' .. v:sub(#mine + 2) end
            if v == '@root' or v:sub(1, 6) == '@root/' or v:match('^@[%w%.%-]+/[^%s:]*:') then
                bad = bad or ('it names the world %s, and this one is %s'):format(v:match('^@([^:]*:?)') or v, tostring(id or 'unnamed'))
            end
            return v
        elseif type(v) == 'table' then
            local o = {}
            for k, x in pairs(v) do o[k] = rw(x) end
            return o
        end
        return v
    end
    local out = rw(args or {})
    if bad then return nil, bad end
    return out
end

--- replay `items` (from_notes rows, or { { invocation = { verb, args, touched? } } }) on the loaded world.
--- opts: { apply = bool, verbs?, approvals?, ns?, stop_at_first = bool } -> { status = 'done' | 'conflict' | 'frontier' |
---   'stopped' | 'failed' | 'previewed', steps = { { id, verb, outcome = 'done'|'applied'|'conflict'|'frontier'|<class>|
---   'not reached', why } }, applied, done, stops = { ids }, why?, at? }
--- ★ PAST A STOP (CART-1191 leaf 3): a later step runs when it shares NO touched file with any stopped step — MEASURED on
--- this repo's history, 6 of 105 step pairs were dependent (5.7%), a conflict left 92.3% of the later steps independent,
--- and touched-file overlap missed none of the 6. A step whose files are UNKNOWN (an old entry, a sensitive or
--- cross-world one) is assumed to touch everything — it neither runs past a stop nor lets one pass it; a step held back
--- blocks its own files in turn (a later step may depend on it). `stop_at_first` restores stopping at the first stop.
function M.run(store, items, opts)
    opts = opts or {}
    local tactic = require 'cartograph.tactic'
    local root = store.data and store.data.root
    local report = { steps = {}, applied = 0, done = 0, stops = {} }
    local first
    local blocked, blocked_all = {}, false
    local function touched_of(inv) return type(inv) == 'table' and type(inv.touched) == 'table' and inv.touched or nil end
    local function hold(t) if not t then blocked_all = true else for _, f in ipairs(t) do blocked[f] = true end end end
    local function stop(row, t)
        first = first or row
        report.stops[#report.stops + 1] = row.id
        hold(t)
    end
    for _, it in ipairs(items or {}) do
        local inv = it.invocation
        local t = touched_of(inv)
        local row = { id = it.id, commit = it.commit, verb = inv and inv.verb or it.verb }
        report.steps[#report.steps + 1] = row
        local shares
        if first then
            if opts.stop_at_first or blocked_all or not t then shares = true
            else for _, f in ipairs(t) do if blocked[f] then shares = f; break end end end
        end
        if shares then
            row.outcome = 'not reached'
            row.why = type(shares) == 'string' and ('it touches %s, which a stopped step touched'):format(shares)
                or 'an earlier step stopped the replay, and nothing shows this one is independent of it'
            hold(t)
        elseif type(inv) ~= 'table' then
            -- an entry made by a DIRECT apply (no tactic step) has no invocation: nothing records what was asked
            row.outcome, row.why = 'frontier', 'the entry recorded no invocation (a direct apply): it can only be merged as bytes'
            stop(row, nil)
        else
            local args, why = M.localize(inv.args, root)
            if not args then
                row.outcome, row.why = 'frontier', why
                stop(row, t)
            else
                local r = tactic.run(store, tactic.T.step(inv.verb, args), { apply = opts.apply, verbs = opts.verbs,
                    approvals = opts.approvals, ns = opts.ns })
                local tr = r.trace and r.trace[1] or {}
                if r.status == 'done' or r.status == 'previewed' then
                    if tr.empty then row.outcome = 'done'; report.done = report.done + 1
                    else row.outcome = 'applied'; report.applied = report.applied + 1 end
                elseif tr.class == 'stale' and tr.phase == 'plan' then
                    row.outcome, row.why, row.class = 'conflict', r.why, 'decision'
                    row.options = { { kind = 'keep-mine', text = 'keep this world\'s version of the site; drop the step' },
                        { kind = 'take-theirs', text = 'take the step: re-plan it against this world by hand, or answer the verb\'s own decision' } }
                    stop(row, t)
                else
                    row.outcome, row.why, row.class, row.options = r.class or r.status, r.why, r.class, r.options
                    stop(row, t)
                end
            end
        end
    end
    if not first then
        report.status = opts.apply and 'done' or 'previewed'
    else
        report.status = first.outcome == 'conflict' and 'conflict' or first.outcome == 'frontier' and 'frontier'
            or (first.class == 'decision' and 'stopped' or 'failed')
        report.why, report.at = first.why, first.id
    end
    return report
end

return M
