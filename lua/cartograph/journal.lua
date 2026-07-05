-- The transaction journal: what git gives local files for free — undo,
-- drift detection, a record — supplied by cartograph itself, so every
-- apply verb (clone-merge today; move, extract-module, remote edits
-- later) rides the same substrate. Design rules, from the session's
-- write-side taxonomy:
--
--   * entries hold REFS and full BEFORE-CONTENT per touched file: undo
--     is a byte-exact restore, never a re-derivation;
--   * the commit-point discipline: an entry is written as 'pending',
--     files are mutated, then the entry flips to 'applied' — a crash
--     mid-apply leaves evidence (pending + before-content = a manual
--     rollback), never mystery;
--   * rollback verifies the CURRENT content matches what the apply
--     wrote (after_hash) before restoring — files that drifted since
--     are refused, loudly, not clobbered;
--   * entries are human-inspectable JSON in the STATE dir (user record,
--     not derived cache).

local M = {}

local function dir_of(root)
    local dir = vim.fn.stdpath('state') .. '/cartograph/'
        .. root:gsub('/+$', ''):gsub('[/\\:]', '%%') .. '.journal'
    vim.fn.mkdir(dir, 'p')
    return dir
end

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return ('%08x'):format(h)
end
M.hash = hash

local function entry_path(root, id)
    return dir_of(root) .. '/' .. id .. '.json'
end

local function write_entry(root, e)
    local fd = io.open(entry_path(root, e.id), 'w')
    if not fd then return false end
    fd:write(vim.json.encode(e))
    fd:close()
    return true
end

--- Open a transaction: records the verb, the plan description (refs,
--- never ids) and each touched file's full before-content. A value of
--- `false` means the file did NOT exist before (a create) — its undo
--- is deletion, never an empty husk. Returns the entry (status
--- 'pending') or nil, why.
function M.begin(root, verb, plan, files)
    local e = {
        version = 1,
        id = ('%d-%s'):format(os.time(), verb),
        verb = verb, root = root, ts = os.time(),
        status = 'pending',
        plan = plan,
        files = {},
    }
    for rel, before in pairs(files) do
        if before == false then
            e.files[rel] = { absent = true }
        else
            e.files[rel] = { before = before, before_hash = hash(before) }
        end
    end
    if not write_entry(root, e) then
        return nil, 'cannot write journal entry'
    end
    return e
end

--- Flip an entry to 'applied', recording what each file became — the
--- full text, not just the hash, so an undone entry can be REDONE
--- (changing your mind is symmetric).
function M.commit(root, e, after)
    e.status = 'applied'
    for rel, text in pairs(after) do
        e.files[rel].after = text
        e.files[rel].after_hash = hash(text)
    end
    return write_entry(root, e)
end

--- Abort a pending entry (apply refused after begin): keep the record,
--- mark it so nobody rolls "back" to it.
function M.abort(root, e, why)
    e.status = 'aborted'
    e.abort_reason = why
    write_entry(root, e)
end

--- Entries for a root, newest first.
function M.list(root)
    local dir = dir_of(root)
    local out = {}
    local it = vim.uv.fs_scandir(dir)
    while it do
        local name = vim.uv.fs_scandir_next(it)
        if not name then break end
        local id = name:match('^(.*)%.json$')
        if id then
            local fd = io.open(dir .. '/' .. name, 'r')
            if fd then
                local ok, e = pcall(vim.json.decode, fd:read('a'))
                fd:close()
                if ok and type(e) == 'table' and e.id then
                    out[#out + 1] = e
                end
            end
        end
    end
    table.sort(out, function (a, b) return a.id > b.id end)
    return out
end

--- The newest 'applied' entry (the undo target).
function M.last(root)
    for _, e in ipairs(M.list(root)) do
        if e.status == 'applied' then return e end
    end
    return nil
end

--- Roll back the newest applied entry: every touched file must still
--- contain EXACTLY what the apply wrote (after_hash) — drifted files
--- refuse the whole rollback, listing them. On success files are
--- restored byte-exact and the entry flips to 'rolled_back'.
--- Returns (entry, nil) or (nil, why).
function M.rollback(root)
    local e = M.last(root)
    if not e then return nil, 'nothing applied to roll back' end
    local drifted = {}
    for rel, f in pairs(e.files) do
        local fd = io.open(root .. '/' .. rel, 'r')
        local now = fd and fd:read('a')
        if fd then fd:close() end
        -- a file the apply deleted entirely reads as nil: hash of '' set
        -- at commit covers it
        if hash(now or '') ~= f.after_hash then
            drifted[#drifted + 1] = rel
        end
    end
    if #drifted > 0 then
        return nil, ('refused: %s changed since the apply — rolling back'
            .. ' would clobber newer edits'):format(table.concat(drifted, ', '))
    end
    for rel, f in pairs(e.files) do
        if f.absent then
            -- the apply CREATED this file: undo removes it
            vim.fn.delete(root .. '/' .. rel)
        else
            local fd = io.open(root .. '/' .. rel, 'w')
            if not fd then
                return nil, 'cannot write ' .. rel
            end
            fd:write(f.before)
            fd:close()
        end
    end
    e.status = 'rolled_back'
    write_entry(root, e)
    return e
end

--- Redo the most recently undone entry. Undo/redo form a stack over
--- the id-ordered entries: applied entries are the prefix, rolled-back
--- the suffix — redo re-applies the LOWEST rolled-back entry above
--- every applied one. Every touched file must still contain exactly
--- the entry's before-content (or be absent, for creates); drift
--- refuses. Returns (entry, nil) or (nil, why).
function M.redo(root)
    local top_applied, cand
    for _, e in ipairs(M.list(root)) do -- newest first
        if e.status == 'applied' and not top_applied then top_applied = e end
        if e.status == 'rolled_back'
            and (not top_applied or e.id > top_applied.id) then
            cand = e -- keep walking: the OLDEST such entry wins
        end
    end
    if not cand then return nil, 'nothing rolled back to redo' end
    local drifted = {}
    for rel, f in pairs(cand.files) do
        local fd = io.open(root .. '/' .. rel, 'r')
        local now = fd and fd:read('a')
        if fd then fd:close() end
        local clean = f.absent and now == nil
            or (not f.absent and now ~= nil and hash(now) == f.before_hash)
        if not clean then drifted[#drifted + 1] = rel end
        if not f.after then
            return nil, cand.id .. ' predates redo support (no after-content)'
        end
    end
    if #drifted > 0 then
        return nil, ('refused: %s changed since the undo — redoing would'
            .. ' clobber newer edits'):format(table.concat(drifted, ', '))
    end
    for rel, f in pairs(cand.files) do
        local path = root .. '/' .. rel
        local dir = path:match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(dir, 'p') end
        local fd = io.open(path, 'w')
        if not fd then return nil, 'cannot write ' .. rel end
        fd:write(f.after)
        fd:close()
    end
    cand.status = 'applied'
    write_entry(root, cand)
    return cand
end

--- Remove a root's journal entirely (tests, spring cleaning).
function M.wipe(root)
    vim.fn.delete(dir_of(root), 'rf')
end

return M
