-- Clone-merge: the first transaction. Merge a function's clones into it
-- — the twins found by the same WITNESS the reference layer trusts (df
-- shape + params + callee set) — by deleting the copies and rewriting
-- their call sites to the survivor's name.
--
-- The transaction contract, door by door:
--   plan   = REFS + witnesses + file stamps + the graph generation,
--            computed now, shown in the plan bar, applied LATE-BOUND;
--   apply  = refuses on ANY drift: generation changed, refs unresolved,
--            witness drifted, file stamps moved, buffers dirty — a
--            refusal names its reason and costs a re-plan, never a
--            corrupted write;
--   journal= before-content captured first (pending -> write ->
--            applied); :CartographUndo restores byte-exact, refusing if
--            files moved on since;
--   after  = the touched files splice back through refresh — the same
--            machinery every save uses.

local M = {}

local function read_file(root, rel)
    local fd = io.open(root .. '/' .. rel, 'r')
    if not fd then return nil end
    local text = fd:read('a')
    fd:close()
    return text
end

local function disk_stamp(root, rel)
    local st = vim.uv.fs_stat(root .. '/' .. rel)
    return st and ('%d:%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
end

--- Witness twins of `id`: same kind, equal behavior witness, elsewhere
--- in the graph. The clone detector's identity, reused as the merge's.
function M.twins(store, id)
    local refs = require 'cartograph.refs'
    local n = store.node(id)
    if not n then return {} end
    local function callees(x)
        local out = {}
        for _, c in ipairs(store.calls_by_fn[x.id] or {}) do
            out[#out + 1] = c.callee
        end
        return out
    end
    local w = refs.witness(n, callees(n))
    if not w then return {}, 'no data-flow witness (blocks/vars cannot merge)' end
    local out = {}
    for _, x in ipairs(store.data.nodes) do
        if x.id ~= id and x.kind == n.kind and not x.db and not x.sql
            and refs.witness(x, callees(x)) == w then
            out[#out + 1] = x
        end
    end
    return out
end

--- Build the plan: survivor = the focused function, removed = its
--- twins. Everything the apply needs to verify rides along.
function M.plan(store, id)
    local survivor = store.node(id)
    if not survivor then return nil, 'no function under focus' end
    local twins, why = M.twins(store, id)
    if #twins == 0 then
        return nil, why or ('no clones of %s found (witness has no twin)')
            :format(survivor.name)
    end
    local root = store.data.root
    local plan = {
        verb = 'clone-merge',
        generation = store.generation,
        survivor = { id = id, name = survivor.name, file = survivor.file,
            ref = store.ref_of(id) },
        removed = {}, rewrites = {}, hazards = {}, stamps = {},
        touched = {},
    }
    local touched = { [survivor.file] = true }
    local lines_cache = {}
    local function file_lines(rel)
        if lines_cache[rel] == nil then
            local t = read_file(root, rel)
            lines_cache[rel] = t and vim.split(t, '\n', { plain = true }) or false
        end
        return lines_cache[rel]
    end

    for _, t in ipairs(twins) do
        plan.removed[#plan.removed + 1] = {
            id = t.id, name = t.name, file = t.file,
            lines = { s = t.range.start.line, e = t.range['end'].line },
            ref = store.ref_of(t.id),
        }
        touched[t.file] = true
        if t.cbarg then
            plan.hazards[#plan.hazards + 1] = ('%s is referenced from data'
                .. ' (dispatch table / registry) — those references are NOT'
                .. ' rewritten'):format(t.name)
        end
        -- call sites into this twin: rewrite the callee token when it is
        -- exactly the twin's name; anything else is a hazard, not a write
        for _, c in ipairs(store.calls_to[t.id] or {}) do
            local at = c.at
            local ls = file_lines(c.file)
            local token = at and ls and at.start.line == at['end'].line
                and (ls[at.start.line + 1] or '')
                    :sub(at.start.char + 1, at['end'].char)
            if token == t.name then
                plan.rewrites[#plan.rewrites + 1] = { file = c.file,
                    at = at, from = t.name, to = survivor.name }
                touched[c.file] = true
            else
                plan.hazards[#plan.hazards + 1] = ('%s:%d calls %s in a form'
                    .. " that isn't its bare name (%s) — rewrite it yourself")
                    :format(c.file, c.line + 1, t.name, tostring(token or c.callee))
            end
        end
        -- non-call references (the id pass's dispatch-table finds): they
        -- would still NAME the removed twin — disclosed, never rewritten
        local nonrefs = 0
        for _, from in ipairs(store.usedby[t.id] or {}) do
            local calls = 0
            for _, c in ipairs(store.calls_to[t.id] or {}) do
                if c.fn == from then calls = calls + 1 end
            end
            local occs = #(store.occurrences(from, t.id) or {})
            if occs > calls then nonrefs = nonrefs + (occs - calls) end
        end
        if nonrefs > 0 then
            plan.hazards[#plan.hazards + 1] = ('%d non-call reference(s) to'
                .. ' %s (identifier mentions) keep the old name')
                :format(nonrefs, t.name)
        end
    end
    -- rewritten call sites OUTSIDE the survivor's file will reference it
    -- by name from there — visibility (imports, linkage) is the user's
    -- to verify; cartograph won't guess a language's import wiring
    local foreign = {}
    for _, r in ipairs(plan.rewrites) do
        if r.file ~= survivor.file and not foreign[r.file] then
            foreign[r.file] = true
            plan.hazards[#plan.hazards + 1] = ('callers in %s will reference'
                .. ' %s by name — verify it is visible there (imports)')
                :format(r.file, survivor.name)
        end
    end
    for f in pairs(touched) do
        plan.touched[#plan.touched + 1] = f
        plan.stamps[f] = disk_stamp(root, f)
    end
    table.sort(plan.touched)
    return plan
end

-- apply the edits of one file, bottom-up so line numbers stay valid
local function edit_file(text, dels, reps)
    local lines = vim.split(text, '\n', { plain = true })
    local edits = {}
    for _, r in ipairs(reps) do
        edits[#edits + 1] = { line = r.at.start.line, rep = r }
    end
    for _, d in ipairs(dels) do
        edits[#edits + 1] = { line = d.s, del = d }
    end
    table.sort(edits, function (a, b) return a.line > b.line end)
    for _, e in ipairs(edits) do
        if e.rep then
            local l = lines[e.line + 1]
            lines[e.line + 1] = l:sub(1, e.rep.at.start.char)
                .. e.rep.to .. l:sub(e.rep.at['end'].char + 1)
        else
            local last = e.del.e
            -- swallow one trailing blank line, so deletions don't leave
            -- double blanks behind
            if lines[last + 2] == '' then last = last + 1 end
            for _ = e.del.s, last do
                table.remove(lines, e.del.s + 1)
            end
        end
    end
    return table.concat(lines, '\n')
end

--- Apply a plan. Every verification failure REFUSES with its reason.
function M.apply(store, plan)
    local root = store.data.root
    -- 1. one transaction at a time; a live graph to splice back into
    if next(store.moveset or {}) then
        return nil, 'a move-set is staged — apply or clear it first'
    end
    if store.data.partial then
        return nil, 'extraction in progress'
    end
    -- 2. the graph must be the one the plan was computed against
    if store.generation ~= plan.generation then
        return nil, ('the graph changed since planning (gen %d -> %d) —'
            .. ' re-run :CartographMerge'):format(plan.generation, store.generation)
    end
    -- 3. late-bound refs: survivor and every twin must still resolve,
    --    witness-clean (a transaction never follows drift silently)
    local function must_resolve(spec, what)
        local rid, note = store.resolve_ref(spec.ref)
        if not rid or rid ~= spec.id or note then
            return ('%s %s: %s'):format(what, spec.name,
                note or 'no longer resolves')
        end
    end
    local bad = must_resolve(plan.survivor, 'survivor')
    if bad then return nil, bad end
    for _, r in ipairs(plan.removed) do
        bad = must_resolve(r, 'clone')
        if bad then return nil, bad end
    end
    -- 4. files: unchanged since planning (CAS), and no dirty buffers
    for _, rel in ipairs(plan.touched) do
        if disk_stamp(root, rel) ~= plan.stamps[rel] then
            return nil, rel .. ' changed on disk since planning — re-plan'
        end
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b)
                and vim.api.nvim_buf_get_name(b) == root .. '/' .. rel
                and vim.bo[b].modified then
                return nil, rel .. ' has unsaved buffer changes — save or discard'
            end
        end
    end
    -- 5. journal FIRST: before-content on record before any byte moves
    local before = {}
    for _, rel in ipairs(plan.touched) do
        local t = read_file(root, rel)
        if not t then return nil, 'cannot read ' .. rel end
        before[rel] = t
    end
    local journal = require 'cartograph.journal'
    local entry, jerr = journal.begin(root, plan.verb, {
        survivor = plan.survivor.ref, survivor_name = plan.survivor.name,
        removed = vim.tbl_map(function (r) return r.ref end, plan.removed),
        rewrites = #plan.rewrites,
    }, before)
    if not entry then return nil, jerr end
    -- 6. the writes
    local after = {}
    for _, rel in ipairs(plan.touched) do
        local dels, reps = {}, {}
        for _, r in ipairs(plan.removed) do
            if r.file == rel then dels[#dels + 1] = r.lines end
        end
        for _, r in ipairs(plan.rewrites) do
            if r.file == rel then reps[#reps + 1] = r end
        end
        after[rel] = edit_file(before[rel], dels, reps)
        local fd = io.open(root .. '/' .. rel, 'w')
        if not fd then
            journal.abort(root, entry, 'cannot write ' .. rel)
            return nil, 'cannot write ' .. rel .. ' (journal has before-content)'
        end
        fd:write(after[rel])
        fd:close()
    end
    journal.commit(root, entry, after)
    -- 7. the graph follows: clear the txn, splice the touched files
    store.set_txn(nil)
    require('cartograph.refresh').files(plan.touched)
    vim.cmd('silent! checktime')
    return entry
end

return M
