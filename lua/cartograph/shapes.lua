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

-- any file matching `*.<ext>` at the root (for variable-named markers like
-- <pkg>.cabal); returns the filename or nil
local function has_ext(root, ext)
    local it = vim.uv.fs_scandir(root)
    while it do
        local name, ty = vim.uv.fs_scandir_next(it)
        if not name then break end
        if ty ~= 'directory' and name:match('%.' .. ext .. '$') then return name end
    end
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
        name = 'ansible',
        detect = function (root)
            if has(root, 'ansible.cfg') then return 'ansible.cfg' end
            if has(root, 'tasks/main.yml') and has(root, 'meta/main.yml') then
                return 'tasks/main.yml + meta/main.yml (role layout)'
            end
            if has(root, 'site.yml') and has(root, 'tasks') then
                return 'site.yml + tasks/'
            end
        end,
        -- playbooks and role mains are the entry points (no importer);
        -- vendored galaxy roles live under collections/ (already excluded)
        config = { entrypoints = {
            '^site%.ya?ml$', 'tasks/main%.ya?ml$', 'playbook.*%.ya?ml$',
        } },
    },
    {
        -- an Ansible COLLECTION (galaxy.yml) — a different layout from a
        -- role: plugins/, roles/, playbooks/. The role at ~/git/*-CIS is a
        -- role; ~/git/community.general is a collection the role shape misses.
        name = 'ansible-collection',
        detect = function (root)
            if has(root, 'galaxy.yml') and (has(root, 'plugins')
                or has(root, 'roles')) then
                return 'galaxy.yml + plugins/roles'
            end
        end,
        -- playbooks, role task mains, and plugin modules are entry points
        -- (loaded by Ansible, no in-repo importer)
        config = { entrypoints = {
            '^playbooks/.*%.ya?ml$', 'tasks/main%.ya?ml$',
            '^plugins/modules/.*%.py$',
        } },
    },
    {
        -- a Python PACKAGE (pyproject.toml / setup.py) — the non-django
        -- python case. Excludes venv/__pycache__ (NOT dot-prefixed, so not
        -- auto-skipped); .venv/.tox already are.
        name = 'python-package',
        detect = function (root)
            if has(root, 'pyproject.toml') then return 'pyproject.toml' end
            if has(root, 'setup.py') then return 'setup.py' end
        end,
        config = {
            entrypoints = { '^setup%.py$', '__main__%.py$', 'conftest%.py$' },
            exclude = { 'venv', '__pycache__' },
        },
    },
    {
        -- a Haskell project (stack.yaml / cabal.project / <pkg>.cabal, or
        -- GHC's hadrian build). Excludes dist-newstyle and hadrian's _build
        -- (both non-dotted); .stack-work is already skipped.
        name = 'haskell',
        detect = function (root)
            if has(root, 'stack.yaml') then return 'stack.yaml' end
            if has(root, 'cabal.project') then return 'cabal.project' end
            if has(root, 'hadrian') then return 'hadrian/ (GHC build)' end
            local cabal = has_ext(root, 'cabal')
            if cabal then return cabal end
        end,
        config = {
            entrypoints = { 'Main%.hs$', '^Setup%.hs$' },
            exclude = { 'dist-newstyle', '_build' },
        },
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
