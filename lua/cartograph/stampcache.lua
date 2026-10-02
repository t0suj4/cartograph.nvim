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

local filehash, trees = {}, {}
--- the content hash of a file (memoized per path for this process: a run reads a header once) | nil when unreadable
function M.file(path)
    local h = filehash[path]
    if h == nil then
        local fd = io.open(path, 'rb')
        if not fd then filehash[path] = false; return nil end
        local s = fd:read('a'); fd:close()
        h = vim.fn.sha256(s)
        filehash[path] = h
    end
    return h or nil
end
function M._forget() filehash = {}; trees = {} end

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
        vim.fn.mkdir(dir, 'p')
        local fd = io.open(path, 'a')
        if fd then fd:write(vim.json.encode({ q, v }), '\n'); fd:close() end
    end
    return L
end

--- the CONTENT stamp of a directory: every regular file's path and bytes, every symlink's target, in path order
--- (memoized per process: a run stamps its tree once) -> hash, { files, bytes, ms }
function M.tree(dir)
    local t = trees[dir]
    if t then return t.h, t end
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
            local fd = io.open(dir .. '/' .. r, 'rb')
            local s = fd and fd:read('a') or '\0unreadable'
            if fd then fd:close() end
            bytes = bytes + #s
            h = vim.fn.sha256(s)
        end
        rows[i] = #r .. ':' .. r .. '=' .. h
    end
    t = { h = vim.fn.sha256(table.concat(rows, '\n')), files = #files, bytes = bytes, ms = (vim.uv.hrtime() - t0) / 1e6 }
    trees[dir] = t
    return t.h, t
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
        vim.fn.mkdir(vim.fn.fnamemodify(p, ':h'), 'p')
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
