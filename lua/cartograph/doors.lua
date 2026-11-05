-- cartograph.doors — the host's DOORS, wrapped while one function runs (CART-1915; first written inside door-trap,
-- CART-1444). A door is anything a run can do besides compute: WRITE / DELETE / RENAME / MKDIR a file, start a
-- PROCESS, or run LUA that is not cartograph's own — a chunk compiled at runtime and then CALLED, or a file outside
-- cartograph's `lua/` and $VIMRUNTIME loaded and run. Compiling is not a door (a parse check compiles and never calls).
--
-- Two modes over one wrapper, so the gate and the measurement cannot drift apart:
--   'record'  every opening is let through and recorded { kind, what, at } — door-trap's measurement, the toolbelt
--             fence that pins each tactic's `executes` declaration
--   'trap'    the first opening RAISES, and is recorded all the same: a run that catches the error itself has still
--             tried, and the caller refuses on the record, not on the error — a read-only host's toolbelt_run
--
-- ★ EVERY ORIGINAL IS PUT BACK ON EVERY EXIT PATH. The MCP host is long-lived: a run that raised must not leave
-- `load` or `vim.uv.spawn` wrapped for every later call.
-- ⚠ What is NOT seen: a door opened by a child process, through FFI, or by C code calling libc directly; and Lua
-- code reached through a reference taken BEFORE the watch began (a module that cached `load` at require time).
local M = {}

-- cartograph's own lua/ — from THIS file's path, never the working directory: a host's cwd is not its install dir
local OWN = (debug.getinfo(1, 'S').source:sub(2):match('^(.*/)cartograph/doors%.lua$')) or ''

local function realdir(p)
    local r = p ~= '' and vim.uv.fs_realpath(p) or nil
    return r and (r:sub(-1) == '/' and r or r .. '/') or nil
end

local OWN_REAL = realdir(OWN)

-- every wrapper this module installs, by the watch that installed it, and which watches are still running: so a test
-- can ask whether a FINISHED watch left a wrapper in place, which nesting (an audit around door-trap) cannot tell
-- from the source file alone
local INSTALLED = setmetatable({}, { __mode = 'k' })
local ACTIVE, NEXT_ID = {}, 0

--- is `f` a wrapper left behind by a watch that has already returned?
function M.stale(f) local id = INSTALLED[f]; return id ~= nil and not ACTIVE[id] end

--- is `path` cartograph's own code or the editor's runtime? (then loading it is not a door)
function M.own(path)
    if type(path) ~= 'string' or path == '' then return false end
    local p = vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ':p')
    for _, base in ipairs({ OWN_REAL, realdir(vim.env.VIMRUNTIME or '') }) do
        if base and p:sub(1, #base) == base then return true end
    end
    return false
end

local function here(src)
    return src:find('/cartograph/doors%.lua$') ~= nil
end

-- the first frame that is neither this file nor the editor's runtime: who opened the door
local function at()
    local rt = vim.env.VIMRUNTIME or ''
    for lvl = 3, 40 do
        local i = debug.getinfo(lvl, 'Sl')
        if not i then break end
        local s = i.source or ''
        if s:sub(1, 1) == '@' then
            local f = s:sub(2)
            if not here(f) and not (rt ~= '' and f:sub(1, #rt) == rt) then
                return (f:gsub('^.*/lua/', '')) .. ':' .. tostring(i.currentline)
            end
        elseif s ~= '=[C]' then
            return tostring(i.short_src) .. ':' .. tostring(i.currentline)
        end
    end
    return '?'
end

local function writes_mode(m) return type(m) == 'string' and m:find('[wa+]') ~= nil end
local function writes_flags(f)
    if type(f) == 'string' then return f:find('[wa+]') ~= nil end
    if type(f) == 'number' then return f % 4 ~= 0 end -- (O_WRONLY / O_RDWR)
    return false
end
local function argv(a) return type(a) == 'table' and table.concat(vim.tbl_map(tostring, a), ' ') or a end

-- { table, key, kind, wrap(real, fire) -> fn, raw = vim.fn's lazily-served fields }
local function file_doors()
    local d = {
        { io, 'open', 'write', function (real, fire) return function (path, mode, ...) if writes_mode(mode) then fire(path) end return real(path, mode, ...) end end },
        { io, 'popen', 'process', function (real, fire) return function (cmd, ...) fire(cmd); return real(cmd, ...) end end },
        { os, 'remove', 'delete', function (real, fire) return function (path, ...) fire(path); return real(path, ...) end end },
        { os, 'rename', 'rename', function (real, fire) return function (a, b, ...) fire(tostring(a) .. ' -> ' .. tostring(b)); return real(a, b, ...) end end },
        { os, 'execute', 'process', function (real, fire) return function (cmd, ...) fire(cmd); return real(cmd, ...) end end },
        { vim.uv, 'spawn', 'process', function (real, fire) return function (cmd, ...) fire(cmd); return real(cmd, ...) end end },
        { vim.uv, 'fs_unlink', 'delete', function (real, fire) return function (path, ...) fire(path); return real(path, ...) end end },
        { vim.uv, 'fs_rename', 'rename', function (real, fire) return function (a, b, ...) fire(tostring(a) .. ' -> ' .. tostring(b)); return real(a, b, ...) end end },
        { vim.uv, 'fs_mkdir', 'mkdir', function (real, fire) return function (path, ...) fire(path); return real(path, ...) end end },
        { vim.uv, 'fs_open', 'write', function (real, fire) return function (path, flags, ...) if writes_flags(flags) then fire(path) end return real(path, flags, ...) end end },
    }
    for _, f in ipairs({ { 'system', 'process' }, { 'systemlist', 'process' }, { 'jobstart', 'process' }, { 'termopen', 'process' },
        { 'writefile', 'write' }, { 'delete', 'delete' }, { 'mkdir', 'mkdir' } }) do
        d[#d + 1] = { vim.fn, f[1], f[2], function (real, fire) return function (a, ...) fire(argv(a)); return real(a, ...) end end, raw = true }
    end
    return d
end

--- run fn(...) with the doors of `kinds` (a set: write / delete / rename / mkdir / process / lua) watched in `mode`
--- ('record' | 'trap'). `kinds.trusted` (a list of paths) adds files whose loading is not a door — the toolbelt audit
--- trusts the entry's own file, which the run under audit loads. -> ok, events, fn's results… (ok false: the error)
function M.watch(kinds, mode, fn, ...)
    local events = {}
    local trusted = {}
    for _, p in ipairs(kinds.trusted or {}) do trusted[vim.uv.fs_realpath(p) or p] = true end
    local function mine(p) return M.own(p) or (type(p) == 'string' and trusted[vim.uv.fs_realpath(p) or p]) or false end
    local function fire(kind, what)
        local ev = { kind = kind, what = tostring(what):sub(1, 160), at = at() }
        events[#events + 1] = ev
        if mode == 'trap' then
            error(('cartograph.doors: this run may open no %s door, and %s opened one (%s)'):format(kind, ev.at, ev.what), 0)
        end
    end
    NEXT_ID = NEXT_ID + 1
    local id = NEXT_ID
    ACTIVE[id] = true
    local saved = {}
    local function put(t, k, make, raw)
        local real = t[k]
        if type(real) ~= 'function' then return end
        -- (a vim.fn field is served lazily by __index: what is restored is the RAW slot, nil included — `raw and
        -- rawget(t, k) or real` would pin the function into vim.fn whenever that slot was empty)
        local v = real
        if raw then v = rawget(t, k) end
        saved[#saved + 1] = { t = t, k = k, v = v }
        local w = make(real)
        INSTALLED[w] = id
        rawset(t, k, w)
    end
    for _, d in ipairs(file_doors()) do
        local t, k, kind, wrap = d[1], d[2], d[3], d[4]
        if kinds[kind] then put(t, k, function (real) return wrap(real, function (what) fire(kind, what) end) end, d.raw) end
    end
    if kinds.lua then
        local chunks = setmetatable({}, { __mode = 'k' }) -- guard -> the chunk it stands for
        local function guard(f, what)
            if type(f) ~= 'function' then return f end
            local g = function (...) fire('lua', what); return f(...) end
            chunks[g] = f
            return g
        end
        local function compiled(src, name)
            return type(src) == 'string' and ('a chunk compiled from a string (%s)'):format(tostring(name or src:sub(1, 40)))
                or ('a chunk compiled from a reader (%s)'):format(tostring(name))
        end
        put(_G, 'load', function (real) return function (src, name, ...) local f, e = real(src, name, ...); return guard(f, compiled(src, name)), e end end)
        put(_G, 'loadstring', function (real) return function (src, name) local f, e = real(src, name); return guard(f, compiled(src, name)), e end end)
        put(_G, 'loadfile', function (real) return function (p, ...)
            local f, e = real(p, ...)
            if mine(p) then return f, e end
            return guard(f, 'the file ' .. tostring(p)), e
        end end)
        put(_G, 'dofile', function (real) return function (p)
            if not mine(p) then fire('lua', 'the file ' .. tostring(p)) end
            return real(p)
        end end)
        -- an environment set on a guard is set on its chunk (byexample, the algebra's core: setfenv(chunk, env));
        -- a numeric level counts one frame more, because this wrapper is itself a frame
        local function lvl(f) if f == nil then return 2 end if type(f) == 'number' and f > 0 then return f + 1 end return f end
        put(_G, 'setfenv', function (real) return function (f, env)
            if type(f) == 'function' and chunks[f] then real(chunks[f], env); return f end
            return real(lvl(f), env)
        end end)
        put(_G, 'getfenv', function (real) return function (f)
            if type(f) == 'function' and chunks[f] then return real(chunks[f]) end
            return real(lvl(f))
        end end)
    end
    local res = { pcall(fn, ...) }
    for i = #saved, 1, -1 do local s = saved[i]; rawset(s.t, s.k, s.v) end
    ACTIVE[id] = nil
    return res[1], events, unpack(res, 2, table.maxn(res))
end

--- the distinct kinds among `events`, as a sorted list
function M.kinds(events)
    local set, out = {}, {}
    for _, ev in ipairs(events or {}) do if not set[ev.kind] then set[ev.kind] = true; out[#out + 1] = ev.kind end end
    table.sort(out)
    return out
end

return M
