-- cartograph.stampcache — a CONTENT-STAMPED store for answers that are expensive to derive and depend only on their
-- inputs' TEXT (CART-1303, CART-1299). A key is the sha256 of the inputs themselves — file CONTENTS, flags, a tool's
-- identity — never an mtime: CART-1301 measured what an mtime key does when two trees share one cache (a mutation-check
-- scratch copy served its mutant to the real tree). Two trees with the same inputs share entries; different inputs
-- can never collide into a stale hit.
-- An entry is a LOG (one per scope key): one JSON array `[qkey, value]` per line, appended as answers are found, read
-- back once per scope. Appending is atomic enough for one writer per scope; a torn last line is skipped on read.
-- ⚠ THE KEY IS JSON-ENCODED, never written raw: LuaJIT's io.lines() MANGLES a line holding a NUL and glues it onto the
-- NEXT line (measured: 'A\0b\t…' + 'plain\t…' read back as one line 'Aplain\t…'), and a layouts key is `T \0 path` —
-- every such answer missed, every run, while the log grew by the same answers.
local M = {}

local function root_dir() return vim.fn.stdpath('cache') .. '/cartograph/stamped' end
M.root_dir = root_dir

--- the content hash of a list of strings (inputs in order, each length-prefixed: no two lists hash alike by concatenation)
function M.key(parts)
    local buf = {}
    for i, p in ipairs(parts) do buf[i] = #tostring(p) .. ':' .. tostring(p) end
    return vim.fn.sha256(table.concat(buf, '\0'))
end

local filehash = {}
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
function M._forget() filehash = {} end

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

return M
