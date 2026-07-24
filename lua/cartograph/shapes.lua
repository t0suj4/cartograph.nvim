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
        config = {
            entrypoints = {
                'control%.lua$', 'data%.lua$', 'settings%.lua$',
                'data%-updates%.lua$', 'data%-final%-fixes%.lua$',
                'settings%-updates%.lua$', 'settings%-final%-fixes%.lua$',
            },
            -- the L2 environment profile this shape implies ([[cartograph-
            -- stdlib-profile]]): a factorio-mod root runs Factorio's Lua, so its
            -- stdlib/global calls classify to the `stdlib` disposition. Read by
            -- the extractor (active_profile_for); apply()'s inert-preset
            -- allowlist (entrypoints/exclude only) ignores it in the setup path.
            profile = 'lua-factorio',
        },
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
        config = {
            entrypoints = {
                '^config%.ru$', 'config/application%.rb$', '^Rakefile$',
            },
            -- the L2 environment profile a Rails root implies ([[cartograph-
            -- stdlib-profile]]): app code runs on Ruby core + ActiveSupport +
            -- ActiveRecord/ActionController, so its framework method calls
            -- classify to the `stdlib` disposition. Read by active_profile_for
            -- in the extractor; apply()'s inert allowlist ignores it.
            profile = 'ruby-rails',
            -- S2 ([[cartograph-repo-shapes]]): the overlay PACK a Rails app
            -- implies — ActiveRecord assoc/delegate def-emitters + the ORM-finder
            -- receiver typing. Defaulted from this shape (UP-walk, packs_for) when
            -- no explicit packs are given, so opening a Rails app (or a sub-dir of
            -- one) auto-activates the pack alongside the profile. The
            -- `config/application.rb` MARKER is APP-shaped evidence → a framework-
            -- SOURCE repo (rails/activesupport, no such marker) never activates it.
            packs = { 'rails' },
        },
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
        -- a Rust crate / workspace (Cargo.toml). Excludes target/ (build
        -- output — huge, NOT globally excluded). Entry points are crate
        -- roots, bins, build scripts, benches/examples (unanchored so
        -- workspace members like crates/foo/src/main.rs match too).
        name = 'rust',
        detect = function (root)
            if has(root, 'Cargo.toml') then return 'Cargo.toml' end
        end,
        -- crate roots matched unanchored: workspace members AND non-standard
        -- path overrides (ripgrep's crates/core/main.rs isn't under src/)
        config = {
            entrypoints = { 'main%.rs$', 'lib%.rs$', 'src/bin/.*%.rs$',
                '^build%.rs$', 'benches/.*%.rs$', 'examples/.*%.rs$' },
            exclude = { 'target' },
        },
    },
    {
        -- a Go module (go.mod). vendor/ is already excluded; the value here
        -- is the entry points — package-main files (main.go, cmd/*/main.go).
        name = 'go',
        detect = function (root)
            if has(root, 'go.mod') then return 'go.mod' end
        end,
        config = { entrypoints = { 'main%.go$' } },
    },
    {
        -- a JVM build (Maven pom.xml / Gradle build.gradle[.kts]). Maven's
        -- target/ is not globally excluded (Gradle's build/ and .gradle
        -- already are). Java entry classes are conventionally *Application
        -- or *Main; the entry is a method, so filename is only a heuristic.
        name = 'jvm',
        detect = function (root)
            if has(root, 'pom.xml') then return 'pom.xml (Maven)' end
            if has(root, 'build.gradle') or has(root, 'build.gradle.kts') then
                return 'build.gradle (Gradle)'
            end
        end,
        config = {
            entrypoints = { 'Application%.java$', 'Main%.java$' },
            exclude = { 'target' },
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

-- The bounded ancestor chain to probe for an UP-direction claim: root first,
-- then parents, stopping AFTER the repo boundary (a dir carrying `.git`) or at a
-- small level cap — so a claim never wanders past the project into an unrelated
-- parent (a framework-SOURCE repo like rails/activesupport carries no app
-- `config/application.rb`, so it correctly contributes nothing). Shared by
-- profile_for (NEAREST wins) and packs_for (UNION). ([[cartograph-repo-shapes]] UP)
local function ancestor_dirs(root)
    local out, dir, levels = {}, root, 0
    while dir and dir ~= '' and levels <= 5 do
        out[#out + 1] = dir
        if has(dir, '.git') then break end -- probe the repo root, then halt
        local parent = dir:match('^(.*)/[^/]+$')
        if not parent or parent == dir then break end
        dir, levels = parent, levels + 1
    end
    return out
end

local function shapes_disabled()
    local ok, cfg = pcall(require, 'cartograph.config')
    return ok and cfg and cfg.shapes == false
end

--- The L2 environment profile a root implies, searched UP the ancestor chain
--- ([[cartograph-repo-shapes]] UP direction). An extraction root INSIDE a shaped
--- repo — e.g. `discourse/app/models` under a Rails app whose `config/
--- application.rb` marker is two levels up — inherits the shape's profile: root-
--- only probing cannot see the marker even in principle. NEAREST match wins.
--- Returns { profile, dir, name, evidence, inherited } or nil. DISPOSITION-tier:
--- a profile only affects files of its own language, so a cross-language ancestor
--- match is inert (eff_spec wraps it per-lang).
function M.profile_for(root)
    if type(root) ~= 'string' or shapes_disabled() then return nil end
    for _, dir in ipairs(ancestor_dirs(root)) do
        for _, p in ipairs(M.probe(dir)) do
            if p.evidence and p.config and p.config.profile then
                return { profile = p.config.profile, dir = dir, name = p.name,
                    evidence = p.evidence, inherited = dir ~= root }
            end
        end
    end
    return nil
end

--- The overlay PACKS a root implies, from shape evidence, searched UP the same
--- bounded ancestor chain (S2 shape-activated packs, [[cartograph-repo-shapes]]).
--- UNION across matched shapes (compose_spec is additive). Activation is gated on
--- APP-shaped evidence (the rails shape's `config/application.rb` marker), so a
--- framework-SOURCE repo (no app marker) contributes nothing — the design's
--- false-positive fence. Returns a list (possibly empty). EXTRACTION-tier: a pack
--- changes the graph (synth defs), so this only DEFAULTS when no explicit packs
--- were given; explicit opts.packs (incl. {}) DISPOSES (the doctrine).
function M.packs_for(root)
    if type(root) ~= 'string' or shapes_disabled() then return {} end
    local seen, out = {}, {}
    for _, dir in ipairs(ancestor_dirs(root)) do
        for _, p in ipairs(M.probe(dir)) do
            if p.evidence and p.config and p.config.packs then
                for _, pk in ipairs(p.config.packs) do
                    if not seen[pk] then seen[pk] = true; out[#out + 1] = pk end
                end
            end
        end
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
                -- list values (entrypoints/exclude) join; scalars (profile) print as-is
                local shown = type(val) == 'table' and table.concat(val, '  ')
                    or tostring(val)
                lines[#lines + 1] = ('      %s%s: %s'):format(
                    cfg.user_set[key] and '(user setup{} wins) ' or '', key, shown)
            end
        else
            lines[#lines + 1] = ('  · %-14s no marker'):format(p.name)
        end
    end
    -- UP-direction ([[cartograph-repo-shapes]]): a profile inherited from an
    -- ancestor shape (the extraction root is INSIDE a shaped repo) — root-only
    -- probing above cannot show it, so name it explicitly.
    local pf = M.profile_for(root)
    if pf and pf.inherited then
        lines[#lines + 1] = ''
        lines[#lines + 1] = ('  ↑ profile %s inherited from %s @ %s')
            :format(pf.profile, pf.name, pf.dir)
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'presets are inert hints (entry points, excludes) —'
        .. ' runtime wiring stays in setup{} (see examples/)'
    return lines
end

return M
