-- Move-apply: the founding verb finally writes. The staged move-set
-- (dd cuts, p sets the destination) becomes a transaction: each
-- symbol's text leaves its file and lands in the destination —
-- journal-first, behind the same refusal ladder as clone-merge.
--
-- What this verb deliberately does NOT write: call-site
-- requalification and import wiring. Both are language-specific
-- guesses (which alias names the dest module here? what does an import
-- line look like?), and a transaction that guesses is a transaction
-- that lies. The ImpactEngine's findings — call sites naming the old
-- home, imports each side should gain — ride the plan as HAZARDS with
-- counts and file names: the human finishes what the tool can prove
-- but not spell.

local M = {}

-- where inserted code lands in dest: before a trailing `return M`-ish
-- line (the lua module idiom), else after the last nonblank line.
-- Returns a 0-based insert-before line index.
local function insert_point(lines)
    local last
    for i = #lines, 1, -1 do
        if lines[i]:match('%S') then last = i break end
    end
    if not last then return 0 end
    if lines[last]:match('^%s*return%s+[%w_%.]+%s*$') then
        return last - 1 -- 0-based index OF the return line
    end
    return last -- 0-based slot just after the last nonblank
end

--- Build the plan from the staged move-set + destination. Everything
--- the apply verifies rides along: refs, stamps, the generation, the
--- insertion point (pinned by the dest stamp).
function M.plan(store)
    local ids = store.staged_ids()
    if #ids == 0 then
        return nil, 'nothing staged — dd cuts a function into the move-set'
    end
    local dest = store.dest
    if not dest then
        return nil, 'no destination — p on a file row sets it'
    end
    local txn = require 'cartograph.txn'
    local root = store.data.root
    local plan = {
        verb = 'move', generation = store.generation, dest = dest,
        moves = {}, hazards = {}, stamps = {}, touched = {},
    }
    local touched = { [dest] = true }
    for _, id in ipairs(ids) do
        local n = store.node(id)
        if not n then return nil, 'staged symbol vanished: ' .. tostring(id) end
        if n.kind ~= 'function' and n.kind ~= 'method' then
            return nil, ('%s is a %s — only functions and methods move')
                :format(n.name, n.kind)
        end
        if n.file == dest then
            return nil, n.name .. ' already lives in ' .. dest
        end
        plan.moves[#plan.moves + 1] = { id = id, name = n.name, file = n.file,
            lines = { s = n.range.start.line, e = n.range['end'].line },
            ref = store.ref_of(id) }
        touched[n.file] = true
        if n.cbarg then
            plan.hazards[#plan.hazards + 1] = ('%s is referenced from data'
                .. ' (dispatch table / registry) — those references are NOT'
                .. ' rewritten'):format(n.name)
        end
    end
    -- the ImpactEngine's analysis becomes the disclosure list: what a
    -- correct move still needs that this transaction will not guess
    local imp = require('cartograph.impact').compute(store, ids, dest)
    for _, h in ipairs(imp.hazards) do
        if h.kind ~= 'noop' then
            plan.hazards[#plan.hazards + 1] = h.kind .. ': ' .. h.msg
        end
    end
    for _, r in ipairs(imp.rewrites) do
        plan.hazards[#plan.hazards + 1] = ('%d call site(s) in %s still'
            .. ' reference the old home — requalify them yourself')
            :format(r.total, r.file)
    end
    for _, f in ipairs(imp.requires_add) do
        plan.hazards[#plan.hazards + 1] = f .. ' should import ' .. dest
    end
    for _, f in ipairs(imp.dest_requires) do
        plan.hazards[#plan.hazards + 1] = dest .. ' should import ' .. f
    end
    local dtext = txn.read_file(root, dest)
    if not dtext then return nil, 'cannot read ' .. dest end
    plan.dest_at = insert_point(vim.split(dtext, '\n', { plain = true }))
    for f in pairs(touched) do
        plan.touched[#plan.touched + 1] = f
        plan.stamps[f] = txn.disk_stamp(root, f)
    end
    table.sort(plan.touched)
    return plan
end

--- Apply: the shared ladder plus one verb-specific rung — the LIVE
--- move-set must still be exactly the plan's moves. On success the
--- move-set is consumed (cleared before the splice, which a staged
--- set would freeze).
function M.apply(store, plan)
    local ids = store.staged_ids()
    local want = {}
    for _, m in ipairs(plan.moves) do want[m.id] = true end
    local same = #ids == #plan.moves
    if same then
        for _, id in ipairs(ids) do
            if not want[id] then same = false end
        end
    end
    if not same then
        return nil, 'the move-set changed since planning — re-run :CartographMove'
    end
    local txn = require 'cartograph.txn'
    local refspecs = {}
    for _, m in ipairs(plan.moves) do
        refspecs[#refspecs + 1] = { id = m.id, name = m.name,
            ref = m.ref, what = 'move' }
    end
    local bad = txn.verify(store, plan, refspecs)
    if bad then return nil, bad end
    -- consumed: the splice after the writes must not see a frozen graph
    store.clear_stage()
    return txn.execute(store, plan, {
        moves = vim.tbl_map(function (m) return m.ref end, plan.moves),
        dest = plan.dest,
    }, function (rel, before, all)
        local lines = vim.split(before, '\n', { plain = true })
        if rel == plan.dest then
            -- the moved blocks, lifted from each source's BEFORE content
            -- (the same bytes the journal holds)
            local ins = {}
            local at = plan.dest_at
            if at > 0 and (lines[at] or ''):match('%S') then
                ins[#ins + 1] = ''
            end
            for mi, m in ipairs(plan.moves) do
                if mi > 1 then ins[#ins + 1] = '' end
                local src = vim.split(all[m.file], '\n', { plain = true })
                for i = m.lines.s + 1, m.lines.e + 1 do
                    ins[#ins + 1] = src[i]
                end
            end
            if (lines[at + 1] or ''):match('%S') then
                ins[#ins + 1] = ''
            end
            for i = #ins, 1, -1 do
                table.insert(lines, at + 1, ins[i])
            end
        else
            -- a source file: delete bottom-up, swallowing one trailing
            -- blank so departures don't leave double blanks behind
            local dels = {}
            for _, m in ipairs(plan.moves) do
                if m.file == rel then dels[#dels + 1] = m.lines end
            end
            table.sort(dels, function (a, b) return a.s > b.s end)
            for _, d in ipairs(dels) do
                local last = d.e
                if lines[last + 2] == '' then last = last + 1 end
                for _ = d.s, last do
                    table.remove(lines, d.s + 1)
                end
            end
        end
        return table.concat(lines, '\n')
    end)
end

return M
