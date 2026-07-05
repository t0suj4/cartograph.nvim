-- Shared transaction substrate: the refusal ladder and the journaled
-- write loop that every apply verb rides (clone-merge, move today;
-- extract-module and remote edits later). A verb brings a PLAN — refs,
-- stamps, the generation, its edits — and this module keeps the
-- contract: verify late-bound, refuse loudly with the reason, journal
-- before any byte moves, splice the touched files back after.

local M = {}

function M.read_file(root, rel)
    local fd = io.open(root .. '/' .. rel, 'r')
    if not fd then return nil end
    local text = fd:read('a')
    fd:close()
    return text
end

function M.disk_stamp(root, rel)
    local st = vim.uv.fs_stat(root .. '/' .. rel)
    return st and ('%d:%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
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
        if not t then return nil, 'cannot read ' .. rel end
        before[rel] = t
    end
    local journal = require 'cartograph.journal'
    local entry, jerr = journal.begin(root, plan.verb, desc, before)
    if not entry then return nil, jerr end
    local after = {}
    for _, rel in ipairs(plan.touched) do
        after[rel] = edit_of(rel, before[rel], before)
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
    require('cartograph.refresh').files(plan.touched)
    vim.cmd('silent! checktime')
    return entry
end

return M
