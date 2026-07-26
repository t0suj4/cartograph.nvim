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

-- ── the ROSTER: a package directory as a multi-root corpus ───────────────────
-- The consumer everything else was for. A mods directory holds packages in two
-- FORMS (unpacked directory, zip archive) at a declared PRECEDENCE, each with its
-- own manifest identity; this turns that into the shape extraction already
-- understands — the `roots` label map providers/self.lua established for a
-- multi-root corpus, where a label's base may now be a CONTAINER rather than a
-- directory (transport.join composes either).
--
-- WHY NO NEW PATH CONVENTION: a package is a LABEL, so a file key stays
-- `Name/control.lua` — the shape the graph already parses (first segment = scope,
-- extension = language). The `archive::entry` composite exists only between abs()
-- and a transport. That was the whole point of keeping it out of n.file.

--- Recursively collect a package's source files, relative to its base, through
--- whatever transport serves it. Uniform across forms: a directory and an archive
--- are both enumerated with dir(), so the caller writes one loop.
local function collect(stack, base, exts, out, prefix, depth)
    if depth > 24 then return end -- a container cannot nest forever
    local key = stack.join and stack.join(base, prefix == '' and '.' or prefix) or nil
    -- join needs a rest; for enumeration ask for the base itself
    local at
    if type(base) == 'table' then
        at = base.container .. '::' .. (base.prefix
            and (base.prefix .. (prefix == '' and '' or '/' .. prefix))
            or prefix)
    else
        at = prefix == '' and base or (base .. '/' .. prefix)
    end
    for name, ty in stack.dir(at) do
        if name:sub(1, 1) ~= '.' then
            local rel = prefix == '' and name or (prefix .. '/' .. name)
            if ty == 'directory' then
                collect(stack, base, exts, out, rel, depth + 1)
            else
                local e = name:match('%.([%w]+)$')
                if e and exts[e:lower()] then out[#out + 1] = rel end
            end
        end
    end
end

--- The packages in a directory, and the corpus shape to extract them as.
--- opts = { dir, user, transport, enabled_only }
--- Returns (roster, nil) or (nil, why). roster =
---   { root, roots, files, transport, packages = { {name, version, target, form,
---     base, enabled} } }
function M.roster(name, opts)
    opts = opts or {}
    local eco = M.load(name)
    if not eco then return nil, 'no ecosystem spec ' .. tostring(name) end
    local ident = eco.identity or {}
    local transport = require 'cartograph.transport'

    local dir = opts.dir
    if not dir then
        local user, how = M.root(eco, 'user', opts.user)
        if not user then
            return nil, 'no package directory: user root ' .. tostring(how)
        end
        dir = user .. '/' .. ((eco.roots.user or {}).mods or 'mods')
    end
    dir = (vim.fn.expand(dir):gsub('/+$', ''))
    if vim.fn.isdirectory(dir) ~= 1 then return nil, 'not a directory: ' .. dir end

    local stack = opts.transport
    if not stack then stack = transport.build(M.stack_spec(eco).spec)
    elseif not stack.read then stack = transport.build(stack) end

    -- ENABLEMENT is an honesty input, never a resolution one: a disabled package is
    -- still present and still readable, so it stays in the roster and carries the
    -- fact instead of vanishing from it.
    local enabled = {}
    local mlpath = (eco.roots.user or {}).mod_list
    if mlpath then
        local base = opts.dir and dir:gsub('/[^/]+$', '') or nil
        local at = base and (base .. '/' .. mlpath)
            or (dir:gsub('/[^/]+$', '') .. '/' .. mlpath)
        local txt = stack.read(at)
        local okj, ml = pcall(vim.json.decode, txt or '')
        if okj and type(ml) == 'table' then
            local ek = eco.enablement or {}
            for _, e in ipairs(ml[ek.list_key or 'mods'] or {}) do
                if type(e) == 'table' and e[ek.name_key or 'name'] ~= nil then
                    enabled[e[ek.name_key or 'name']] = e[ek.enabled_key or 'enabled']
                        and true or false
                end
            end
        end
    end

    local exts = {}
    for _, e in ipairs(eco.source_exts or { eco.lang }) do exts[e:lower()] = true end

    -- FORMS IN PRECEDENCE ORDER: the first form to claim a package name wins, which
    -- is how an unpacked directory shadows an archive of the same package (the
    -- normal state while editing one).
    local claimed, packages = {}, {}
    local function manifest_at(base, inner)
        local at = type(base) == 'table'
            and (base.container .. '::' .. (base.prefix and (base.prefix .. '/') or '')
                .. inner)
            or (base .. '/' .. inner)
        local txt = stack.read(at)
        if not txt then return nil end
        local okj, m = pcall(vim.json.decode, txt)
        if okj and type(m) == 'table' and type(m[ident.name_key]) == 'string' then
            return m
        end
    end

    local entries = {}
    for ename, ty in stack.dir(dir) do entries[#entries + 1] = { ename, ty } end
    table.sort(entries, function (a, b) return a[1] < b[1] end)

    for _, form in ipairs(eco.forms or {}) do
        for _, ent in ipairs(entries) do
            local ename, ty = ent[1], ent[2]
            local base, m
            if form.form == 'directory' and ty == 'directory' then
                base = dir .. '/' .. ename
                m = manifest_at(base, ident.manifest)
            elseif form.form == 'archive' and ty ~= 'directory'
                and form.ext and ename:sub(-#form.ext) == form.ext then
                local archive = dir .. '/' .. ename
                -- the manifest sits under ONE top directory whose name may differ
                -- from the package name (measured: 112 of 195 disagree), so it is
                -- FOUND, never derived from the filename
                for iname, ity in stack.dir(archive .. '::') do
                    if ity == 'directory' and not m then
                        local cand = { container = archive, prefix = iname }
                        m = manifest_at(cand, ident.manifest)
                        if m then base = cand end
                    end
                end
            end
            if m and base then
                local pname = m[ident.name_key]
                if not claimed[pname] then
                    claimed[pname] = true
                    packages[#packages + 1] = {
                        name = pname,
                        version = m[ident.version_key],
                        target = m[ident.target_key],
                        deps = m[ident.deps_key],
                        form = form.form, base = base,
                        enabled = enabled[pname],
                    }
                end
            end
        end
    end

    local roots, files = {}, {}
    for _, pkg in ipairs(packages) do
        if not (opts.enabled_only and pkg.enabled == false) then
            roots[pkg.name] = pkg.base
            local rels = {}
            collect(stack, pkg.base, exts, rels, '', 0)
            table.sort(rels)
            for _, rel in ipairs(rels) do files[#files + 1] = pkg.name .. '/' .. rel end
        end
    end
    table.sort(files)
    return {
        root = (eco.roster_scheme or 'pkg') .. '://' .. dir,
        roots = roots, files = files,
        transport = M.stack_spec(eco).spec, packages = packages, dir = dir,
        -- a LIVE convenience: `roots` is the serialisable truth (a worker rebuilds
        -- abs from it, as worker.lua already does), this saves an in-process caller
        -- repeating the join every extraction
        abs = function (file)
            local label, rest = file:match('^([^/]+)/(.*)$')
            local base = label and roots[label]
            if base then return transport.join(base, rest) end
            return dir .. '/' .. file
        end,
    }
end

return M
