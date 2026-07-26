-- Shared transaction substrate: the refusal ladder and the journaled
-- write loop that every apply verb rides (clone-merge, move today;
-- extract-module and remote edits later). A verb brings a PLAN — refs,
-- stamps, the generation, its edits — and this module keeps the
-- contract: verify late-bound, refuse loudly with the reason, journal
-- before any byte moves, splice the touched files back after.

local M = {}
local atr = require 'cartograph.at'
local transport = require 'cartograph.transport' -- single owner of the validity key (stamp)

function M.read_file(root, rel)
    local fd = io.open(root .. '/' .. rel, 'r')
    if not fd then return nil end
    local text = fd:read('a')
    fd:close()
    return text
end

function M.disk_stamp(root, rel)
    return transport.stamp(root .. '/' .. rel)
end

--- Comment adhesion: walk UP from a def's first line over lines that
--- belong to it (comments, decorators, attributes — per-language
--- patterns from the provider); blank lines and code stop the walk.
--- A block that reaches the TOP of the file belongs to the FILE, not
--- the def (license notices, file docblocks) — adhesion declines and
--- says so. `s` and the returned index are 0-based; the second return
--- is true when a top-of-file block was left behind.
function M.attach_above(lines, s, pats)
    local orig = s
    while s > 0 do
        local l = lines[s] or ''
        local hit
        for _, p in ipairs(pats) do
            if l:match(p) then hit = true break end
        end
        if not hit then break end
        s = s - 1
    end
    if s == 0 and orig > 0 then
        return orig, true -- the block touches line 1: a file header
    end
    return s, false
end

--- Apply deletions, token replacements and line insertions to one
--- file's text, bottom-up so earlier line numbers stay valid.
--- dels = {{s, e}} (0-based inclusive; one trailing blank swallowed),
--- reps = {{at, to}} (at = token range), ins = {{after, lines}}
--- (0-based; after = -1 inserts at the very top).
function M.edit_file(text, dels, reps, ins)
    local lines = vim.split(text, '\n', { plain = true })
    local edits = {}
    for _, r in ipairs(reps or {}) do
        edits[#edits + 1] = { line = atr.sl(r.at), ord = 2, rep = r }
    end
    for _, d in ipairs(dels or {}) do
        edits[#edits + 1] = { line = d.s, ord = 1, del = d }
    end
    for _, i in ipairs(ins or {}) do
        edits[#edits + 1] = { line = i.after, ord = 3, ins = i }
    end
    table.sort(edits, function (a, b)
        if a.line ~= b.line then return a.line > b.line end
        if a.ord ~= b.ord then return a.ord > b.ord end
        -- two replacements on the SAME line: apply the RIGHTMOST first, so each
        -- in-place splice leaves the earlier columns valid (else the first shifts
        -- them and the second corrupts — a latent bug for any multi-rep-per-line verb)
        if a.rep and b.rep then return atr.sc(a.rep.at) > atr.sc(b.rep.at) end
        return false
    end)
    for _, e in ipairs(edits) do
        if e.rep then
            local l = lines[e.line + 1]
            lines[e.line + 1] = l:sub(1, atr.sc(e.rep.at))
                .. e.rep.to .. l:sub(atr.ec(e.rep.at) + 1)
        elseif e.ins then
            for i = #e.ins.lines, 1, -1 do
                table.insert(lines, e.ins.after + 2, e.ins.lines[i])
            end
        else
            local last = e.del.e
            -- swallow one trailing blank line, so deletions don't
            -- leave double blanks behind
            if lines[last + 2] == '' then last = last + 1 end
            for _ = e.del.s, last do
                table.remove(lines, e.del.s + 1)
            end
        end
    end
    return table.concat(lines, '\n')
end

--- Dry-run a plan: the same before-content read and edit callback the
--- apply uses, but nothing written. Returns (before_map, after_map).
function M.dryrun(store, plan, edit_of)
    local root = store.data.root
    local before = {}
    for _, rel in ipairs(plan.touched) do
        local t = M.read_file(root, rel)
        if not t then
            if not (plan.creates and plan.creates[rel]) then
                return nil, nil, 'cannot read ' .. rel
            end
            t = false
        end
        before[rel] = t
    end
    local after = {}
    for _, rel in ipairs(plan.touched) do
        after[rel] = edit_of(rel, before[rel], before)
    end
    return before, after
end

--- A unified diff over (before, after) maps — what :CartographApply
--- would write, shown before it writes.
function M.difftext(before, after, order)
    local out = {}
    for _, rel in ipairs(order) do
        local b = before[rel]
        local a = after[rel] or ''
        out[#out + 1] = '--- ' .. (b == false and '/dev/null' or 'a/' .. rel)
        out[#out + 1] = '+++ b/' .. rel
        local d = vim.diff(b == false and '' or b, a,
            { result_type = 'unified', ctxlen = 3 })
        for _, l in ipairs(vim.split(d or '', '\n', { plain = true })) do
            if l ~= '' then out[#out + 1] = l end
        end
    end
    return out
end

--- The refusal ladder's common rungs: a live graph, the same
--- generation the plan was computed against, every ref still resolving
--- to its id witness-clean, file stamps unmoved (CAS), no dirty
--- buffers. `refspecs` = { {id, name, ref, what} }. Returns nil on
--- pass, or the refusal reason.
function M.verify(store, plan, refspecs)
    if store.data.partial then return 'extraction in progress' end
    if store.generation ~= plan.generation then
        return ('the graph changed since planning (gen %d -> %d) — re-plan')
            :format(plan.generation, store.generation)
    end
    for _, spec in ipairs(refspecs or {}) do
        local rid, note = store.resolve_ref(spec.ref)
        if not rid or rid ~= spec.id or note then
            return ('%s %s: %s'):format(spec.what or 'symbol', spec.name,
                note or 'no longer resolves')
        end
    end
    local root = store.data.root
    for _, rel in ipairs(plan.touched) do
        if M.disk_stamp(root, rel) ~= plan.stamps[rel] then
            return rel .. ' changed on disk since planning — re-plan'
        end
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b)
                and vim.api.nvim_buf_get_name(b) == root .. '/' .. rel
                and vim.bo[b].modified then
                return rel .. ' has unsaved buffer changes — save or discard'
            end
        end
    end
end

--- Journal-first commit: read every touched file's before-content,
--- journal.begin, run edit_of(rel, before, all_before) -> after per
--- file, write, journal.commit, clear the staged txn and splice the
--- touched files back through refresh — the same machinery every save
--- uses. Returns the journal entry, or nil + why.
function M.execute(store, plan, desc, edit_of)
    local root = store.data.root
    local before = {}
    for _, rel in ipairs(plan.touched) do
        local t = M.read_file(root, rel)
        if not t then
            -- a file the plan CREATES has no before; anything else
            -- unreadable refuses (the stamp rung caught most of these)
            if not (plan.creates and plan.creates[rel]) then
                return nil, 'cannot read ' .. rel
            end
            t = false
        end
        before[rel] = t
    end
    local journal = require 'cartograph.journal'
    local entry, jerr = journal.begin(root, plan.verb, desc, before)
    if not entry then return nil, jerr end
    local after = {}
    for _, rel in ipairs(plan.touched) do
        after[rel] = edit_of(rel, before[rel], before)
        local dir = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(dir, 'p') end
        local fd = io.open(root .. '/' .. rel, 'w')
        if not fd then
            journal.abort(root, entry, 'cannot write ' .. rel)
            return nil, 'cannot write ' .. rel .. ' (journal has before-content)'
        end
        fd:write(after[rel])
        fd:close()
    end
    journal.commit(root, entry, after)
    store.set_txn(nil)
    local ok, why = require('cartograph.refresh').files(plan.touched)
    if not ok then
        -- the writes are committed (journal has them); only the graph is stale
        vim.notify('cartograph: applied, but the graph refresh refused — '
            .. (why or '?') .. ' (:CartographRefresh when clear)', vim.log.levels.WARN)
    end
    vim.cmd('silent! checktime')
    return entry
end

return M
