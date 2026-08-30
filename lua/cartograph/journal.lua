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

--- Allocate an entry id that is UNIQUE and still LEXICOGRAPHICALLY ORDERED,
--- and RESERVE its file atomically (CART-0582).
---
--- ★ THE BUG THIS REPLACES. The id was `os.time() .. '-' .. verb`, and
--- write_entry opens its path with 'w' — a plain truncate. Two applies of one
--- verb to one root inside a SINGLE SECOND produced the same filename, and the
--- second OVERWROTE the first. What is lost is not a log line: the entry holds
--- the BEFORE-CONTENT, so the first apply's UNDO went with it. Ordering broke
--- too, because M.list sorts by `a.id > b.id` and M.last picks the undo target
--- the same way, so two entries comparing EQUAL made the choice arbitrary.
---
--- ★ WHY IT SURVIVED THIS LONG: nothing in the code ever guaranteed uniqueness.
--- THE GUARANTEE WAS HUMAN TYPING SPEED — nobody drives two applies of the same
--- verb through the cockpit inside one second. Making the verb agent-drivable
--- (CART-0146) did not introduce the bug, it removed what was hiding it. Same
--- shape as CART-0577, where containment came from pressing `p` on a file row.
---
--- TWO CONSTRAINTS, and the second is the one that shapes the format:
---   1. UNIQUE. Microseconds alone are only *unlikely* to collide, so the file
---      is reserved with O_EXCL ('wx') and the stamp is bumped on EEXIST. That
---      is atomic across processes, which two mcpserve hosts on one root need.
---   2. STILL SORTABLE AGAINST ENTRIES ALREADY ON DISK. Real journals hold
---      `<epoch>-<verb>` ids and M.list compares them as STRINGS. `.` is 0x2E
---      and `-` is 0x2D, so `1787782381.000123-v` > `1787782381-v`: a new entry
---      sorts AFTER an old one from the same second, which is what "later"
---      means. The usec field is ZERO-PADDED to a fixed 6 because otherwise
---      `.9` would compare greater than `.10`.
--- @return string? id, string? why
local function alloc_id(root, verb)
    local sec, usec = vim.uv.gettimeofday()
    for _ = 1, 1000 do
        local id = ('%d.%06d-%s'):format(sec, usec, verb)
        -- 'wx' is O_CREAT|O_EXCL: the reservation IS the uniqueness check, so
        -- there is no exists-then-create window for a second host to slip into.
        local fd = vim.uv.fs_open(entry_path(root, id), 'wx', 420)
        if fd then
            vim.uv.fs_close(fd)
            return id
        end
        usec = usec + 1
        if usec > 999999 then
            sec, usec = sec + 1, 0
        end
    end
    return nil, 'cannot allocate a journal entry id (1000 collisions)'
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
    local id, why = alloc_id(root, verb)
    if not id then return nil, why end
    local e = {
        version = 1,
        id = id,
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
        -- the reservation is a real (empty) file; do not leave it behind. An
        -- empty file is inert to M.list (json decode fails, the entry is
        -- skipped) but it would still hold the id against a retry.
        vim.uv.fs_unlink(entry_path(root, e.id))
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

-- ── RETENTION (CART-0644) ───────────────────────────────────────────────────
-- Nothing pruned these, ever, and `wipe` was called from nowhere in the tree. The
-- entries are a USER RECORD by design — an apply's before-content is the only thing
-- between a bad edit and a lost file — so age is the wrong predicate and "clear the
-- cache" is the wrong instinct.
--
-- ★★ THERE IS A SOUND ONE AND IT NEEDS NO HEURISTIC: A JOURNAL WHOSE ROOT NO LONGER
-- EXISTS IS UNROLLBACKABLE BY CONSTRUCTION. `rollback` verifies the CURRENT content
-- of each file against after_hash before restoring; with the root gone there is no
-- current content, so the entry can never do its job again — today, or in a year.
-- Removing it destroys nothing that was still reachable.
--
-- Measured when this shipped: 27798 journal directories, 27794 of them for
-- `vim.fn.tempname()` roots from ~1949 test runs. 237 MB.

--- The parent of every per-root journal directory.
local function journals_root()
    return vim.fn.stdpath('state') .. '/cartograph'
end

--- The root a journal directory belongs to, read from an ENTRY rather than by
--- reversing the directory name.
--- ⚠ THE NAME IS NOT REVERSIBLE. `dir_of` maps `/`, `\` and `:` all to `%`, so the
--- escape is lossy and un-escaping would guess. Every entry records `root` verbatim,
--- so the authoritative answer is inside the file — read that, and treat a directory
--- with no decodable entry as having no root rather than inventing one.
--- Returns (root, n_entries) or (nil, 0).
local function root_of_dir(dir)
    local n, root = 0, nil
    local it = vim.uv.fs_scandir(dir)
    while it do
        local name = vim.uv.fs_scandir_next(it)
        if not name then break end
        if name:match('%.json$') then
            local fd = io.open(dir .. '/' .. name, 'r')
            if fd then
                local ok, e = pcall(vim.json.decode, fd:read('a'))
                fd:close()
                if ok and type(e) == 'table' and e.id then
                    n = n + 1
                    root = root or e.root
                end
            end
        end
    end
    return root, n
end

--- Every journal directory, classified. Never deletes.
--- Each row: { dir, root, entries, keep = bool, why }
---   keep   the root still exists — the entry can still be rolled back
---   'root-gone'  the root is gone; nothing here is reachable
---   'no-entries' the directory holds no decodable entry, so it protects nothing
---                (and its root cannot be read — see root_of_dir)
function M.survey()
    local base = journals_root()
    local out, it = {}, vim.uv.fs_scandir(base)
    while it do
        local name, ty = vim.uv.fs_scandir_next(it)
        if not name then break end
        if ty == 'directory' and name:match('%.journal$') then
            local dir = base .. '/' .. name
            local root, n = root_of_dir(dir)
            local row = { dir = dir, root = root, entries = n }
            if n == 0 then row.keep, row.why = false, 'no-entries'
            elseif root and vim.uv.fs_stat(root) then row.keep, row.why = true, 'root-exists'
            else row.keep, row.why = false, 'root-gone' end
            out[#out + 1] = row
        end
    end
    table.sort(out, function (a, b) return a.dir < b.dir end)
    return out
end

--- Remove the journals `survey` says are unreachable.
--- ⚠ DRY BY DEFAULT. `opts.apply` must be set explicitly; without it this reports
--- what it would remove and touches nothing. Deleting a user record is not a thing
--- to do as a side effect of asking about it.
--- Returns { removed, kept, entries_removed, rows }
function M.prune(opts)
    local apply = opts and opts.apply
    local rows = M.survey()
    local st = { removed = 0, kept = 0, entries_removed = 0, rows = rows }
    for _, r in ipairs(rows) do
        if r.keep then st.kept = st.kept + 1
        else
            st.removed = st.removed + 1
            st.entries_removed = st.entries_removed + r.entries
            if apply then vim.fn.delete(r.dir, 'rf') end
        end
    end
    st.applied = apply and true or false
    return st
end

return M
