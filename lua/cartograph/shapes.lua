-- Project SHAPES: recognizable project types, detected from marker
-- files at the root, presetting what the markers honestly imply. The
-- discovery doctrine applied to whole projects — and like every
-- auto-detect here, it ships with an explainer (:CartographShapes).
--
-- The preset surface is deliberately INERT: entry-point patterns and
-- extra excludes only — hints for the analysis, no behavior. A shape
-- never wires runtime dialing (mcp/live/db) and never overrides a key
-- the user set in setup{} (config.user_set): detection proposes,
-- explicit config disposes.

local M = {}

local function has(root, rel)
    return vim.uv.fs_stat(root .. '/' .. rel) ~= nil
end

-- Each entry: name, detect(root) -> evidence string | nil, and either
-- a static `config` or `configure(root)` for presets that read files.
M.registry = {
    {
        name = 'factorio-mod',
        detect = function (root)
            if has(root, 'info.json')
                and (has(root, 'control.lua') or has(root, 'data.lua')) then
                return 'info.json + control.lua/data.lua'
            end
            if has(root, 'control.lua') and has(root, 'data.lua') then
                return 'control.lua + data.lua at the root'
            end
        end,
        config = { entrypoints = {
            'control%.lua$', 'data%.lua$', 'settings%.lua$',
            'data%-updates%.lua$', 'data%-final%-fixes%.lua$',
            'settings%-updates%.lua$', 'settings%-final%-fixes%.lua$',
        } },
    },
    {
        name = 'nvim-plugin',
        detect = function (root)
            if has(root, 'plugin') and has(root, 'lua') then
                return 'plugin/ + lua/ directories'
            end
        end,
        config = { entrypoints = { '^plugin/[%w_%-]+%.lua$' } },
    },
    {
        name = 'nvim-config',
        detect = function (root)
            if has(root, 'init.lua') and has(root, 'lua')
                and not has(root, 'plugin') then
                return 'init.lua + lua/ directory'
            end
        end,
        config = { entrypoints = { '^init%.lua$' } },
    },
    {
        name = 'wordpress',
        detect = function (root)
            if has(root, 'wp-settings.php') then return 'wp-settings.php' end
        end,
        config = { entrypoints = {
            '^index%.php$', '^wp%-[%w%-]+%.php$',
        } },
    },
    {
        name = 'django',
        detect = function (root)
            if has(root, 'manage.py') then return 'manage.py' end
        end,
        config = { entrypoints = {
            'manage%.py$', 'wsgi%.py$', 'asgi%.py$',
        } },
    },
    {
        name = 'rails',
        detect = function (root)
            if has(root, 'config/application.rb') then
                return 'config/application.rb'
            end
        end,
        config = { entrypoints = {
            '^config%.ru$', 'config/application%.rb$', '^Rakefile$',
        } },
    },
    {
        name = 'symfony',
        detect = function (root)
            if has(root, 'bin/console') and has(root, 'composer.json') then
                return 'bin/console + composer.json'
            end
        end,
        config = { entrypoints = { '^public/index%.php$' } },
    },
    {
        name = 'node-package',
        detect = function (root)
            if has(root, 'package.json') then return 'package.json' end
        end,
        -- the manifest NAMES its entry points: read main/bin/module
        configure = function (root)
            local fd = io.open(root .. '/package.json', 'r')
            if not fd then return nil end
            local ok, pkg = pcall(vim.json.decode, fd:read('a'))
            fd:close()
            if not ok or type(pkg) ~= 'table' then return nil end
            local eps = {}
            local function add(p)
                if type(p) == 'string' and p ~= '' then
                    eps[#eps + 1] = '^' .. vim.pesc((p:gsub('^%./', ''))) .. '$'
                end
            end
            add(pkg.main)
            add(pkg.module)
            if type(pkg.bin) == 'string' then
                add(pkg.bin)
            elseif type(pkg.bin) == 'table' then
                for _, p in pairs(pkg.bin) do add(p) end
            end
            if #eps == 0 then return nil end
            return { entrypoints = eps }
        end,
    },
}

--- Every registry entry probed against `root`: { {name, evidence?,
--- config?}, ... } — evidence nil = did not match (the explainer
--- shows both).
function M.probe(root)
    local out = {}
    for _, s in ipairs(M.registry) do
        local ev = s.detect(root)
        local cfg
        if ev then
            cfg = s.configure and s.configure(root) or s.config
            if not cfg then ev = ev .. ' (no usable preset)' end
        end
        out[#out + 1] = { name = s.name, evidence = ev, config = cfg }
    end
    return out
end

-- what THIS module added to config (per key): stripped before the next
-- root's presets apply, so one project's shape never leaks into another
M._added = {}

--- Detect and apply shape presets for `root`. Matched shapes COMPOSE
--- (entry points and excludes union); a key the user set explicitly
--- is never touched; a previous root's presets are stripped first.
--- Returns the applied {name, evidence} list.
function M.apply(root)
    local cfg = require 'cartograph.config'
    -- strip the previous root's additions (never user entries)
    for key, added in pairs(M._added) do
        local keep, drop = {}, {}
        for _, x in ipairs(added) do drop[x] = true end
        for _, x in ipairs(cfg[key] or {}) do
            if not drop[x] then keep[#keep + 1] = x end
        end
        cfg[key] = keep
    end
    M._added = {}
    if cfg.shapes == false then return {} end
    local applied = {}
    for _, p in ipairs(M.probe(root)) do
        if p.evidence and p.config then
            for key, val in pairs(p.config) do
                if not cfg.user_set[key]
                    and (key == 'entrypoints' or key == 'exclude') then
                    -- anything else a shape might carry is ignored:
                    -- the preset surface stays inert
                    local seen = {}
                    for _, x in ipairs(cfg[key] or {}) do seen[x] = true end
                    for _, x in ipairs(val) do
                        if not seen[x] then
                            seen[x] = true
                            cfg[key] = cfg[key] or {}
                            table.insert(cfg[key], x)
                            M._added[key] = M._added[key] or {}
                            table.insert(M._added[key], x)
                        end
                    end
                end
            end
            applied[#applied + 1] = { name = p.name, evidence = p.evidence }
        end
    end
    return applied
end

--- The explainer: what was probed, what matched, what it changed.
function M.explain(root)
    local cfg = require 'cartograph.config'
    local lines = { 'project shapes @ ' .. root,
        cfg.shapes == false and '(disabled: setup{ shapes = false })' or '' }
    for _, p in ipairs(M.probe(root)) do
        if p.evidence then
            lines[#lines + 1] = ('  ✓ %-14s %s'):format(p.name, p.evidence)
            for key, val in pairs(p.config or {}) do
                lines[#lines + 1] = ('      %s%s: %s'):format(
                    cfg.user_set[key] and '(user setup{} wins) ' or '',
                    key, table.concat(val, '  '))
            end
        else
            lines[#lines + 1] = ('  · %-14s no marker'):format(p.name)
        end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'presets are inert hints (entry points, excludes) —'
        .. ' runtime wiring stays in setup{} (see examples/)'
    return lines
end

return M
