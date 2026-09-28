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

--- the invocations the ledger notes of `range` (in `repo`) carry, in replay order -> { { commit, id, invocation } }
function M.from_notes(repo, range)
    local P = require 'cartograph.provenance'
    local out, seen = {}, {}
    for sha in (git(repo, { 'rev-list', '--reverse', range }) or ''):gmatch('%x+') do
        local row = P.read_note(repo, sha)
        local entries = {}
        -- ⚠ ONE ENTRY, ONE STEP: the line-level attribution can credit an entry to SEVERAL commits (MEASURED: 22 of 135
        -- entries over the last 8 notes of this repo — an old entry "explains" identical lines of a later commit), so
        -- an entry is replayed once, at the FIRST commit of the range that names it
        for _, e in ipairs(row and row.entries or {}) do
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

--- replay `items` (from_notes rows, or { { invocation = { verb, args } } }) on the loaded world.
--- opts: { apply = bool, verbs?, approvals?, ns? } -> { status = 'done' | 'conflict' | 'frontier' | 'stopped' | 'failed'
---   | 'previewed', steps = { { id, verb, outcome = 'done'|'applied'|'conflict'|'frontier'|<class>|'not reached', why } },
---   applied, done, why? }
function M.run(store, items, opts)
    opts = opts or {}
    local tactic = require 'cartograph.tactic'
    local root = store.data and store.data.root
    local report = { steps = {}, applied = 0, done = 0 }
    local stopped
    for _, it in ipairs(items or {}) do
        local inv = it.invocation
        local row = { id = it.id, commit = it.commit, verb = inv and inv.verb or it.verb }
        report.steps[#report.steps + 1] = row
        if stopped then
            row.outcome, row.why = 'not reached', 'an earlier step stopped the replay'
        elseif type(inv) ~= 'table' then
            -- an entry made by a DIRECT apply (no tactic step) has no invocation: nothing records what was asked
            row.outcome, row.why = 'frontier', 'the entry recorded no invocation (a direct apply): it can only be merged as bytes'
            stopped = row
        else
            local args, why = M.localize(inv.args, root)
            if not args then
                row.outcome, row.why = 'frontier', why
                stopped = row
            else
                local r = tactic.run(store, tactic.T.step(inv.verb, args), { apply = opts.apply, verbs = opts.verbs,
                    approvals = opts.approvals, ns = opts.ns })
                local t = r.trace and r.trace[1] or {}
                if r.status == 'done' or r.status == 'previewed' then
                    if t.empty then row.outcome = 'done'; report.done = report.done + 1
                    else row.outcome = 'applied'; report.applied = report.applied + 1 end
                elseif t.class == 'stale' and t.phase == 'plan' then
                    row.outcome, row.why, row.class = 'conflict', r.why, 'decision'
                    row.options = { { kind = 'keep-mine', text = 'keep this world\'s version of the site; drop the step' },
                        { kind = 'take-theirs', text = 'take the step: re-plan it against this world by hand, or answer the verb\'s own decision' } }
                    stopped = row
                else
                    row.outcome, row.why, row.class, row.options = r.class or r.status, r.why, r.class, r.options
                    stopped = row
                end
            end
        end
    end
    if not stopped then
        report.status = opts.apply and 'done' or 'previewed'
    else
        report.status = stopped.outcome == 'conflict' and 'conflict' or stopped.outcome == 'frontier' and 'frontier'
            or (stopped.class == 'decision' and 'stopped' or 'failed')
        report.why, report.at = stopped.why, stopped.id
    end
    return report
end

return M
