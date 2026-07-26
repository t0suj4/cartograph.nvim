-- PACKAGE-ECOSYSTEM loader ([[cartograph-cross-project]] repo shapes). Mirrors
-- spec/profile/init.lua deliberately: same schema marker, same memoized load, same
-- stamp_of — and cache.lua composes that stamp into graph validity, so editing a
-- layout rule invalidates warm caches whose resolution used it. (The first version
-- of this file claimed that while nothing consumed stamp_of, which left every warm
-- cache confidently stale after a spec edit. The lesson kept: a stamp nobody
-- composes is not invalidation, it is a comment.)
--
-- An ecosystem answers "where do OTHER packages live, how are they identified,
-- which one wins" — the axis spec/lua.lua:216 flags as the missing abstraction
-- behind factorio_mods / toc_scope / nvim_lua_root. Only lua-factorio is
-- declared so far; the other two collapse in later.
--
-- The specs are DATA. Everything here is resolution over that data, so the facts
-- stay auditable (tools/specaudit.lua) and shippable to a worker process.

local M = {}

local DIR = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/init%.lua$')
local validity = require 'cartograph.validity'

--- Load an ecosystem spec by name (e.g. 'lua-factorio'). Memoized. nil when
--- absent or malformed — a half-loaded layout spec would be worse than none,
--- since callers would silently resolve against half the rules.
--- KEYED ON THE ARTIFACT STAMP (see profile/init.lua for why caching forever was
--- wrong: it returned a stale spec while the manifest recorded the fresh stamp).
M.load = validity.memo {
    name = 'ecosystem',
    stamp = function (name) return M.stamp_of(name) end,
    compute = function (name)
        -- evict Lua's module cache: see profile/init.lua — a moved stamp must
        -- actually re-read the artifact, and `require` would return the stale table
        local modname = 'cartograph.spec.ecosystem.' .. name
        package.loaded[modname] = nil
        local ok, mod = pcall(require, modname)
        if ok and type(mod) == 'table' and mod.schema == 1 then return mod end
        return nil
    end,
}

--- Graph-validity CONTRIBUTOR: package-layout rules (identity, manifest name,
--- precedence) shape resolution, so a cached graph must invalidate when they move.
--- Composed over EVERY declared spec, so one added later enters the key for free.
validity.contribute('ecosystem', function ()
    local parts = {}
    for _, n in ipairs(M.names()) do
        local st = M.stamp_of(n)
        if st then parts[#parts + 1] = n .. '=' .. st end
    end
    return #parts > 0 and table.concat(parts, ';') or nil
end)

--- Content-identity stamp of the backing artifact, for cache invalidation. Same
--- contract as profile.stamp_of: cheap (one fs_stat), nil for an unknown name.
function M.stamp_of(name)
    local st = vim.uv.fs_stat(DIR .. '/' .. name .. '.lua')
    return st and ('lua:%d:%d'):format(st.mtime.sec, st.size) or nil
end

--- The ecosystems that ship, derived from the directory rather than listed, so a
--- newly declared one needs no edit here.
function M.names()
    local out = {}
    local it = vim.uv.fs_scandir(DIR)
    while it do
        local n = vim.uv.fs_scandir_next(it)
        if not n then break end
        local base = n:match('^(.+)%.lua$')
        if base and base ~= 'init' then out[#out + 1] = base end
    end
    table.sort(out)
    return out
end

--- Resolve a declared root ('user' / 'install') to a real directory, or nil.
--- `override` (from user config) always wins — the install in particular is NOT
--- derivable (measured: absent from every standard location on a machine that
--- has the game's user dir), so autodetection alone would hand back a mods dir
--- and silently no base data.
--- Returns (path, how) where how = 'override' | 'candidate' — a caller that
--- reports its own state needs to say WHICH, not just the path.
function M.root(eco, which, override)
    if override and override ~= '' then
        local p = vim.fn.expand(override):gsub('/+$', '')
        if vim.fn.isdirectory(p) == 1 then return p, 'override' end
        return nil, 'override-missing'
    end
    local decl = ((eco or {}).roots or {})[which]
    for _, c in ipairs((decl or {}).candidates or {}) do
        if c.path then
            local p = vim.fn.expand(c.path):gsub('/+$', '')
            if vim.fn.isdirectory(p) == 1 then return p, 'candidate' end
        elseif c.glob then
            -- a WSL mount cannot know the Windows user name, hence globs
            for _, p in ipairs(vim.fn.glob(c.glob, false, true)) do
                if vim.fn.isdirectory(p) == 1 then
                    return (p:gsub('/+$', '')), 'candidate'
                end
            end
        end
    end
    return nil, 'not-found'
end

--- THE INTERFACE between this axis and the byte layer: declared package-form
--- PRECEDENCE becomes a transport stack spec (see the `forms` note in
--- lua-factorio.lua). The ecosystem knows Factorio and nothing about bytes;
--- transport knows bytes and nothing about Factorio.
---
--- Forms whose transport kind is not registered yet are REPORTED, not silently
--- dropped and not passed to transport.build — an unknown kind there is a hard
--- error by design, and a spec must not be able to turn that into a crash.
--- Returns { spec = <transport spec>, unsupported = { kind, … } }.
function M.stack_spec(eco, cfg)
    local transport = require 'cartograph.transport'
    local out, unsupported = {}, {}
    for _, f in ipairs((eco or {}).forms or {}) do
        local kind = f.transport
        if not kind then
            -- a form with no transport is a spec bug, not a runtime condition
        elseif transport.kinds[kind] then
            local e = { kind = kind }
            for k, v in pairs(cfg and cfg[kind] or {}) do e[k] = v end
            out[#out + 1] = e
        else
            unsupported[#unsupported + 1] = kind
        end
    end
    return { spec = out, unsupported = unsupported }
end

return M
