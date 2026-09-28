-- cartograph.deploy — A LOCAL DEPLOYMENT WORLD, the smallest honest one (CART-0154): the design's "immutability is a
-- property of VALUES, not of contexts", made runnable without a cluster.
--   a TARGET is a directory: releases/<id>/… (each release an immutable, CONTENT-ADDRESSED value) + CURRENT (the id
--   of the deployed release)
--   `release`  copies a source tree into releases/<sha256 of its files>/ — a CROSS-WORLD create (CART-1160 step 5:
--              the target must be granted by an accepted decision), journaled IN THE TARGET'S journal; the same source
--              is the same id, so a re-release is EMPTY
--   `switch`   points CURRENT at a release — COMPENSABLE, not journaled (a deployment's executor, not the journal,
--              moves it); its compensation is the invocation that switches back to the PREVIOUS release (CART-1186),
--              and it carries the `approve-deploy` DECISION: the manual review gate
-- A deployment PLAN is then a tactic: release -> switch -> a health PREMISE; a failed health check under
-- on_stop = 'rollback' compensates the switch (CURRENT back) and undoes the release (the target's journal).
local M = {}

local function readf(p) local fd = io.open(p, 'rb'); if not fd then return nil end; local s = fd:read('a'); fd:close(); return s end

--- the source tree's files -> { { rel, text } } (sorted), its content id
function M.content_id(src)
    local files = {}
    for name, ty in vim.fs.dir(src, { depth = 20 }) do
        if ty == 'file' then files[#files + 1] = { rel = name, text = readf(src .. '/' .. name) or '' } end
    end
    table.sort(files, function (a, b) return a.rel < b.rel end)
    local parts = {}
    for _, f in ipairs(files) do parts[#parts + 1] = f.rel .. '\0' .. vim.fn.sha256(f.text) end
    return files, vim.fn.sha256(table.concat(parts, '\n')):sub(1, 16)
end

function M.current(target) return (readf(target .. '/CURRENT') or ''):gsub('%s+$', '') end

function M.plan_release(store, args)
    local txn = require 'cartograph.txn'
    if type(args.from) ~= 'string' or type(args.target) ~= 'string' then return nil, 'release needs `from` and `target`', 'ill-posed' end
    local from = args.from:sub(1, 1) == '/' and args.from or (store.data.root .. '/' .. args.from)
    if vim.fn.isdirectory(from) == 0 then return nil, ('no source tree %s'):format(from), 'ill-posed' end
    local files, id = M.content_id(from)
    if #files == 0 then return nil, 'the source tree is empty: nothing to release', 'ill-posed' end
    local target = args.target:gsub('/+$', '')
    if vim.fn.isdirectory(target .. '/releases/' .. id) == 1 then return nil, ('release %s already exists (the same content)'):format(id), 'empty' end
    local touched, creates, stamps, edits = {}, {}, {}, {}
    for _, f in ipairs(files) do
        local rel = 'releases/' .. id .. '/' .. f.rel
        touched[#touched + 1] = rel; creates[rel] = true; stamps[rel] = txn.disk_stamp(target, rel); edits[rel] = f.text
    end
    local plan = {
        verb = 'release', guards = {}, generation = store.generation, touched = touched, creates = creates, stamps = stamps,
        refspecs = {}, edits = edits, release = id, preserves = 'all',
        preserves_why = 'a release CREATES a new immutable value; nothing that exists is changed',
        hazards = {}, desc = ('release %s (%d file(s)) into %s'):format(id, #files, target),
    }
    txn.target(plan, target, 'a release is written into the deployment world')
    return txn.protocol(plan, function (p) return function (rel, before) return p.edits[rel] or before end end)
end

function M.plan_switch(store, args)
    local txn, hazard = require 'cartograph.txn', require 'cartograph.hazard'
    if type(args.target) ~= 'string' or type(args.release) ~= 'string' then return nil, 'switch needs `target` and `release`', 'ill-posed' end
    local target = args.target:gsub('/+$', '')
    local id = args.release
    if id == 'LATEST' then
        -- the newest release by creation: what `release` just wrote (a deployment plan does not know the id in advance)
        local best, bt
        for name, ty in vim.fs.dir(target .. '/releases') do
            if ty == 'directory' then
                local st = vim.uv.fs_stat(target .. '/releases/' .. name)
                if st and (not bt or st.mtime.sec > bt or (st.mtime.sec == bt and st.mtime.nsec > (best and best.nsec or 0))) then
                    best, bt = { id = name, nsec = st.mtime.nsec }, st.mtime.sec
                end
            end
        end
        id = best and best.id
        if not id then return nil, 'no release to switch to', 'ill-posed' end
    end
    if vim.fn.isdirectory(target .. '/releases/' .. id) == 0 then return nil, ('no release %s in %s'):format(id, target), 'ill-posed' end
    local prev = M.current(target)
    if prev == id then return nil, ('%s is already deployed'):format(id), 'empty' end
    local plan = {
        verb = 'switch', guards = {}, generation = store.generation, touched = {}, stamps = {}, refspecs = {},
        target_dir = target, release = id, previous = prev ~= '' and prev or nil, preserves = 'none',
        preserves_why = 'a deploy changes what runs, on purpose',
        hazards = { hazard.new('approve-deploy', ('deploy %s to %s (currently %s) — the manual review gate'):format(id, target,
            prev ~= '' and prev or 'nothing'), nil, { target = target, release = id }, 'decision') },
        desc = ('switch %s: %s -> %s'):format(target, prev ~= '' and prev or '(none)', id),
    }
    -- staging needs a touched file to judge; the switch's effect is outside the journal, so it stages the pointer
    plan.touched = { 'CURRENT' }; plan.stamps = { CURRENT = txn.disk_stamp(target, 'CURRENT') }
    -- a FIRST deploy has no CURRENT yet: staging it is a create, not a read of a missing file
    if not readf(target .. '/CURRENT') then plan.creates = { CURRENT = true } end
    txn.target(plan, target, 'a deploy moves the deployment world')
    return txn.protocol(plan, function (p) return function (_, before) return p.release .. '\n' end end)
end

--- the switch's own executor (not the journal): write CURRENT -> an entry that knows how to go back
function M.apply_switch(store, plan)
    local fd = io.open(plan.target_dir .. '/CURRENT', 'w')
    if not fd then return nil, 'cannot write CURRENT in ' .. plan.target_dir, 'environment' end
    fd:write(plan.release .. '\n'); fd:close()
    return { id = 'switch-' .. plan.release, target = plan.target_dir, previous = plan.previous, release = plan.release }
end

--- a switch's inverse, as an INVOCATION: switch back to what was deployed before (or clear it)
function M.compensate_switch(args, entry)
    if entry.previous then return { verb = 'switch', args = { target = entry.target, release = entry.previous }, accept = { 'approve-deploy', 'target-write' } } end
    return { verb = 'undeploy', args = { target = entry.target }, accept = { 'target-write' } }
end

function M.plan_undeploy(store, args)
    local txn = require 'cartograph.txn'
    local target = tostring(args.target):gsub('/+$', '')
    if M.current(target) == '' then return nil, 'nothing is deployed', 'empty' end
    local plan = { verb = 'undeploy', guards = {}, generation = store.generation, touched = { 'CURRENT' },
        stamps = { CURRENT = txn.disk_stamp(target, 'CURRENT') }, refspecs = {}, target_dir = target, preserves = 'none',
        hazards = {}, desc = 'undeploy ' .. target }
    txn.target(plan, target, 'an undeploy moves the deployment world')
    return txn.protocol(plan, function () return function () return '' end end)
end

function M.apply_undeploy(_, plan)
    local fd = io.open(plan.target_dir .. '/CURRENT', 'w'); if fd then fd:write(''); fd:close() end
    return { id = 'undeploy', target = plan.target_dir }
end

return M