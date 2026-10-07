-- cartograph.stampcache — a CONTENT-STAMPED store for answers that are expensive to derive and depend only on their
-- inputs' TEXT (CART-1303, CART-1299). A key is the sha256 of the inputs themselves — file CONTENTS, flags, a tool's
-- identity — never an mtime: CART-1301 measured what an mtime key does when two trees share one cache (a mutation-check
-- scratch copy served its mutant to the real tree). Two trees with the same inputs share entries; different inputs
-- can never collide into a stale hit.
-- Three primitives: KEYS (M.key of parts, M.file of a file's bytes, M.tree of a whole directory, M.value of a plain
-- Lua value — canonical, table order is not part of it), and two stores under stdpath('cache')/cartograph/stamped/<name>:
--   M.log   — many small answers per scope key (cinterp's layouts: one gcc probe each), appended as they are found;
--   M.blob  — one whole value per key (cinterp's facts, CART-1299), string.buffer bytes written to a temp file and
--             renamed; a value that would not come back equal is refused by name.
-- A LOG holds one JSON array `[qkey, value]` per line, read back once per scope. Appending is atomic enough for one
-- writer per scope; a torn last line is skipped on read.
-- ⚠ THE KEY IS JSON-ENCODED, never written raw: LuaJIT's io.lines() MANGLES a line holding a NUL and glues it onto the
-- NEXT line (measured: 'A\0b\t…' + 'plain\t…' read back as one line 'Aplain\t…'), and a layouts key is `T \0 path` —
-- every such answer missed, every run, while the log grew by the same answers.
-- ⚠ NOTHING IS EVICTED: a changed input writes new entries beside the old ones (cpython's facts + layouts: ~5 MB a key
-- set). Clearing the directory is always safe — it only costs a cold run.
local M = {}

-- (CARTOGRAPH_STAMPCACHE_DIR: a store elsewhere — the test suite's, thrown away with its state home)
local function root_dir()
    local d = vim.env.CARTOGRAPH_STAMPCACHE_DIR
    if d and d ~= '' then return d end
    return vim.fn.stdpath('cache') .. '/cartograph/stamped'
end
M.root_dir = root_dir

--- the content hash of a list of strings (inputs in order, each length-prefixed: no two lists hash alike by concatenation)
function M.key(parts)
    local buf = {}
    for i, p in ipairs(parts) do buf[i] = #tostring(p) .. ':' .. tostring(p) end
    return vim.fn.sha256(table.concat(buf, '\0'))
end

-- ★ A PATH'S STAMP IS A POINTER, NOT CONTENT (CART-1431; CART-1430's first principle: content never changes, only
-- pointers go stale). The memo used to keep a path's hash for the whole PROCESS, so in a long-lived one (the nvim
-- session, mcpserve) an edited file kept its old stamp and every entry keyed on it was served from the old file. Now the
-- memo keeps the hash beside the file's STAT SIGNATURE (inode, size, mtime and ctime to the nanosecond) and re-reads the
-- bytes only when the signature moved. The signature is the TRIGGER to rehash, never the key (CART-1301): the key stays
-- the bytes' hash. ⚠ A rewrite inside one timestamp tick that keeps the size and the inode is not seen — the price of
-- not hashing every file on every ask.
-- ★ CODE THIS PROCESS RUNS is the other kind of fact: a module's text is what was LOADED, and an edit on disk does not
-- change the running code. A stamp of loaded code must not follow the disk (a matcher compiled by the old code would be
-- filed under the new code's key), so M.loaded / M.loaded_tree PIN the stamp at the first ask in this process.
local filehash, pinned = {}, {}
local function sig(st)
    return st.ino .. ':' .. st.size .. ':' .. st.mtime.sec .. '.' .. st.mtime.nsec .. ':' .. st.ctime.sec .. '.' .. st.ctime.nsec
end
--- a path's STAT SIGNATURE (inode, size, mtime + ctime to the ns) | nil when it does not exist — for any memo of a file's
--- bytes: the TRIGGER to re-read, never a key (CART-1301, CART-1432)
function M.signature(path) local st = vim.uv.fs_stat(path); return st and sig(st) or nil end
--- the content hash of a file, re-read only when its stat signature moved | nil when unreadable
function M.file(path)
    local st = vim.uv.fs_stat(path)
    if not st then filehash[path] = nil; return nil end
    local s, e = sig(st), filehash[path]
    if e and e.sig == s then return e.h end
    local fd = io.open(path, 'rb')
    if not fd then filehash[path] = nil; return nil end
    local bytes = fd:read('a'); fd:close()
    if bytes == nil then filehash[path] = nil; return nil end
    local h = vim.fn.sha256(bytes)
    filehash[path] = { sig = s, h = h, bytes = #bytes }
    return h
end
--- the content hash of LOADED code (see above): pinned at the first ask in this process | nil when unreadable
function M.loaded(path)
    local k = 'f:' .. path
    if pinned[k] == nil then pinned[k] = M.file(path) or false end
    return pinned[k] or nil
end
function M._forget() filehash = {}; pinned = {} end

--- a LOG of answers under (store name, scope key) -> { get(q) -> value | nil, found, put(q, value) }. `false` is a valid
--- stored answer (the derivation said "none"); `found` tells it from a miss.
function M.log(name, scope)
    -- (CARTOGRAPH_STAMPCACHE=0: a log that remembers nothing — the A/B that proves a cache changes no answer)
    if vim.env.CARTOGRAPH_STAMPCACHE == '0' then
        return { get = function () return nil, false end, put = function () end }
    end
    local dir = root_dir() .. '/' .. name .. '/' .. scope:sub(1, 2)
    local path = dir .. '/' .. scope
    local map
    local function load()
        if map then return end
        map = {}
        local fd = io.open(path, 'r')
        if not fd then return end
        for line in fd:lines() do
            local ok, e = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
            if ok and type(e) == 'table' and type(e[1]) == 'string' then map[e[1]] = { v = e[2] } end -- (a torn line: skipped)
        end
        fd:close()
    end
    local L = {}
    function L.get(q)
        load()
        local e = map[q]
        if e then return e.v, true end
        return nil, false
    end
    function L.put(q, v)
        load()
        map[q] = { v = v }
        M.mkdir(dir)
        local fd = io.open(path, 'a')
        if fd then fd:write(vim.json.encode({ q, v }), '\n'); fd:close() end
    end
    return L
end

--- the CONTENT stamp of a directory: every regular file's path and bytes, every symlink's target, in path order
--- (memoized per process: a run stamps its tree once) -> hash, { files, bytes, ms }
function M.tree(dir)
    -- (walked on every ask — a new, removed or retargeted entry is a change too; each file's bytes are re-read only when
    -- its stat signature moved, through M.file's memo)
    local t0 = vim.uv.hrtime()
    local files, links = {}, {}
    local function walk(d, rel)
        for name, ty in vim.fs.dir(d) do
            local r = rel == '' and name or (rel .. '/' .. name)
            if ty == 'directory' then walk(d .. '/' .. name, r)
            elseif ty == 'file' then files[#files + 1] = r
            elseif ty == 'link' then files[#files + 1] = r; links[r] = true end
        end
    end
    walk(dir, '')
    table.sort(files)
    local rows, bytes = {}, 0
    for i, r in ipairs(files) do
        local h
        if links[r] then h = 'link:' .. tostring(vim.uv.fs_readlink(dir .. '/' .. r))
        else
            h = M.file(dir .. '/' .. r) or vim.fn.sha256('\0unreadable')
            local e = filehash[dir .. '/' .. r]
            bytes = bytes + (e and e.bytes or 0)
        end
        rows[i] = #r .. ':' .. r .. '=' .. h
    end
    local t = { h = vim.fn.sha256(table.concat(rows, '\n')), files = #files, bytes = bytes, ms = (vim.uv.hrtime() - t0) / 1e6 }
    return t.h, t
end
--- a directory of LOADED code, pinned like M.loaded
function M.loaded_tree(dir)
    local k = 't:' .. dir
    if pinned[k] == nil then pinned[k] = { M.tree(dir) } end
    return pinned[k][1], pinned[k][2]
end

-- the CANONICAL bytes of a value: a type tag and a length before every scalar, a table's keys in a total order — two
-- equal values give the same bytes whatever order their tables were built in (pairs() order is not part of a value)
local ffi = require 'ffi'
local function canon(v, buf, stack)
    local t = type(v)
    if t == 'string' then buf[#buf + 1] = 's' .. #v .. ':'; buf[#buf + 1] = v
    elseif t == 'number' then buf[#buf + 1] = ('n%.17g;'):format(v)
    elseif t == 'boolean' then buf[#buf + 1] = v and 'T' or 'F'
    elseif t == 'nil' then buf[#buf + 1] = 'N'
    elseif t == 'cdata' then
        if ffi.istype('uint64_t', v) then buf[#buf + 1] = 'U' .. tostring(v) .. ';'
        elseif ffi.istype('int64_t', v) then buf[#buf + 1] = 'I' .. tostring(v) .. ';'
        else return nil, 'a cdata that is no 64-bit integer' end
    elseif t == 'table' then
        if getmetatable(v) then return nil, 'a table with a metatable' end
        if stack[v] then return nil, 'a cycle' end
        stack[v] = true
        local ks = {}
        for k in pairs(v) do
            local kt = type(k)
            if kt ~= 'string' and kt ~= 'number' and kt ~= 'boolean' then stack[v] = nil; return nil, 'a ' .. kt .. ' key' end
            ks[#ks + 1] = k
        end
        table.sort(ks, function (a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta < tb end
            if ta == 'boolean' then return (not a) and b end
            return a < b
        end)
        buf[#buf + 1] = '{' .. #ks .. ';'
        for _, k in ipairs(ks) do
            local ok, why = canon(k, buf, stack)
            if ok then ok, why = canon(v[k], buf, stack) end
            if not ok then stack[v] = nil; return nil, why end
        end
        buf[#buf + 1] = '}'
        stack[v] = nil
    else return nil, 'a ' .. t end
    return true
end
--- the content hash of a VALUE (canonical: table order does not matter) | nil, why it has none (a function, userdata,
--- a metatable, a cycle — a value that is more than its data)
--- mkdir -p that survives a RACE (CART-1410): two processes creating one directory at once — the parallel suite's workers
--- share a state dir — make the loser's vim.fn.mkdir raise E739 although the directory now exists; only a directory that
--- is still missing afterwards is an error
--- ⚠ The race can be on an INTERMEDIATE directory: the loser's mkdir -p raises there and never makes the leaf, so a
--- failure is retried — the intermediate now exists — before it is an error (CART-1529)
function M.mkdir(dir)
    local err
    for _ = 1, 4 do
        local ok, e = pcall(vim.fn.mkdir, dir, 'p')
        if ok or vim.fn.isdirectory(dir) == 1 then return end
        err = e
    end
    error(err, 0)
end

function M.value(v)
    local buf = {}
    local ok, why = canon(v, buf, {})
    if not ok then return nil, why end
    return vim.fn.sha256(table.concat(buf))
end

--- a BLOB store under a name: one file per key, a whole value each (LuaJIT string.buffer), written to a temp file and
--- renamed (a reader never sees half a blob; one that does not decode is a miss) -> { get(key) -> v, found;
--- put(key, v) -> bytes | nil, why }. put REFUSES a value that would not come back equal (M.value of the decoded copy
--- must be the original's: string.buffer drops metatables silently) — a refusal is named, never stored
function M.blob(name)
    local B = require 'string.buffer'
    local off = vim.env.CARTOGRAPH_STAMPCACHE == '0'
    local function path(key) return root_dir() .. '/' .. name .. '/' .. key:sub(1, 2) .. '/' .. key end
    local S = {}
    function S.get(key)
        if off then return nil, false end
        local fd = io.open(path(key), 'rb')
        if not fd then return nil, false end
        local s = fd:read('a'); fd:close()
        local ok, v = pcall(B.decode, s)
        if not ok then return nil, false end
        return v, true
    end
    function S.put(key, v)
        if off then return nil, 'the stamp cache is off' end
        local h, why = M.value(v)
        if not h then return nil, why end
        local ok, s = pcall(B.encode, v)
        if not ok then return nil, tostring(s) end
        local okd, back = pcall(B.decode, s)
        if not okd or M.value(back) ~= h then return nil, 'it does not round-trip' end
        local p = path(key)
        M.mkdir(vim.fn.fnamemodify(p, ':h'))
        local tmp = p .. '.' .. vim.uv.os_getpid() .. '.tmp'
        local fd = io.open(tmp, 'wb')
        if not fd then return nil, 'cannot write ' .. tmp end
        fd:write(s); fd:close()
        local okr, err = os.rename(tmp, p)
        if not okr then os.remove(tmp); return nil, tostring(err) end
        return #s
    end
    return S
end

return M
