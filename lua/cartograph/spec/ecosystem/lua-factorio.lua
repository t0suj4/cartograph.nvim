-- PACKAGE-ECOSYSTEM spec: Factorio ([[cartograph-cross-project]] repo shapes).
--
-- The THIRD axis. Two already had homes and this one did not, which is why its
-- facts were about to be scattered a fourth time:
--
--   language environment  what NAMES exist        spec/profile/lua-factorio.lua
--   repo shape            what THIS tree is       shapes.lua `factorio-mod`
--   package ecosystem     where OTHER packages    <- here
--                         live, how they are
--                         identified, which wins
--
-- spec/lua.lua:216 already names the debt: factorio_mods / toc_scope /
-- nvim_lua_root are "the scattered cluster … one missing-abstraction". They are
-- the same axis for three ecosystems (Factorio mods, WoW addons, nvim plugins).
-- This is that abstraction, opened with the one the zip transport needs; the
-- other two collapse into it later rather than growing a fourth.
--
-- DATA, NOT CODE, for three reasons that are all established patterns here:
--   · it must cross a process boundary — extraction runs in spawned workers that
--     receive JSON, the same constraint that made transport kinds declarative
--   · declared in-file, like shapes.registry and source.lua's providers
--   · it is the shape tools/specaudit.lua audits: discrete rules that either FIRE
--     or do not, so a rule that quietly stops applying can be reported SUSPECT.
--     NOT WIRED YET — specaudit enumerates ts.spec and ts.packs only, and covers
--     neither spec/profile/ nor this directory. So the auditability is a property
--     of the SHAPE, not a check that runs today; extending specaudit to walk both
--     is its own piece of work, and until then a dead rule here is as invisible as
--     one anywhere else.
--
-- THE DIVISION THIS PROTECTS: precedence here becomes transport STACK ORDER, so
-- the ecosystem knows Factorio and nothing about bytes, transport knows bytes and
-- nothing about Factorio, and the stack spec is the only interface. Without it
-- the zip transport's `claims` predicate ends up encoding mods-dir conventions
-- and Factorio is welded into the substrate layer forever.

return {
    schema = 1,
    ecosystem = 'lua-factorio',
    lang = 'lua',

    -- ── where packages live ──────────────────────────────────────────────────
    -- Candidates are ORDERED and expanded by the loader; `glob` entries need
    -- wildcard expansion (a WSL mount cannot know the Windows user name).
    --
    -- MEASURED 2026-07-26 on this machine: the USER dir autodetects, the INSTALL
    -- does NOT exist anywhere findable — Steam's only library holds no Factorio,
    -- and config.ini records just the unsubstituted `__PATH__system-read-data__`
    -- token. So autodetection alone would hand back a mods dir and silently no
    -- base/core data. The install must be specifiable, and its absence must be
    -- REPORTED rather than assumed.
    roots = {
        user = {
            what = 'the writable user directory: mods/, config/, saves/',
            candidates = {
                { path = '~/.factorio' },
                { path = '~/Library/Application Support/factorio' },
                { path = '$APPDATA/Factorio' },
                { glob = '/mnt/*/Users/*/AppData/Roaming/Factorio' }, -- WSL
            },
            mods = 'mods',
            mod_list = 'mods/mod-list.json',
            settings = 'mods/mod-settings.dat',
        },
        install = {
            what = 'the read-only install: data/base and data/core',
            derivable = false, -- see the measurement note above
            candidates = {
                { glob = '/mnt/*/Program Files/Factorio' },
                { glob = '/mnt/*/Program Files (x86)/Steam/steamapps/common/Factorio' },
                { glob = '/mnt/*/SteamLibrary/steamapps/common/Factorio' },
                { path = '~/.steam/steam/steamapps/common/Factorio' },
                { path = '/Applications/factorio.app/Contents' },
            },
            data = 'data',
            -- packages the install provides rather than the mods dir. `base` and
            -- `core` always; the rest ship with 2.0+ and are toggled like mods.
            builtin = { 'core', 'base', 'elevated-rails', 'quality', 'space-age' },
        },
    },

    -- ── package identity ─────────────────────────────────────────────────────
    -- NEVER the filename. MEASURED: 112 of 195 local archives have an internal
    -- directory name that differs from the manifest name, and spec/lua.lua:184
    -- already records the same rule for unpacked trees
    -- (space-exploration-postprocess lives in space-exploration_0.7.5). A
    -- filename-derived identity is wrong for well over half the corpus.
    identity = {
        manifest = 'info.json',
        name_key = 'name',
        version_key = 'version',
        -- the version of the ENVIRONMENT this package targets — the fact
        -- :CartographPortability needs and currently never reads, which is what
        -- turns "score against some profile" into "you are porting 1.1 -> 2.0"
        target_key = 'factorio_version',
        deps_key = 'dependencies',
        -- a HINT for finding the right archive without opening all of them (one
        -- info.json out of a zip costs ~22ms over /mnt/c, so a 199-archive scan
        -- is ~4.4s). The hint must always be CONFIRMED against the manifest.
        filename_hint = '^(.+)_%d[%w%.%-]*%.zip$',
        authoritative = 'manifest', -- never 'filename'
    },

    -- ── package forms, in PRECEDENCE order ───────────────────────────────────
    -- Earlier wins. Factorio prefers an UNPACKED mod directory over a zip of the
    -- same mod, which is the normal state while editing one. This list IS the
    -- transport stack order, and it is why fallthrough must distinguish ABSENT
    -- (ask the next form) from UNAVAILABLE (stop): falling through on the latter
    -- would let a transient failure be reported as a package that is not there.
    --
    -- NOT PRESENT on this machine today (checked: 2 unpacked, 195 zipped, zero
    -- overlap) — declared because it is a documented loader rule, not because a
    -- local case exercises it. specaudit will report it SUSPECT until one does,
    -- which is the honest state rather than a silent assumption.
    forms = {
        { form = 'directory', transport = 'disk',
            detect = 'a directory containing the manifest' },
        { form = 'archive', transport = 'zip', ext = '.zip',
            -- the manifest sits under ONE top-level directory inside the archive,
            -- whose name may differ from the package name (see identity)
            manifest_glob = '^[^/]+/info%.json$',
            detect = 'a .zip whose single top directory contains the manifest' },
    },

    -- ── the cross-package require form ───────────────────────────────────────
    -- `require("__mod__/path")` or `require("__mod__.dotted")`. Already
    -- implemented for IN-CORPUS mods (spec/lua.lua resolve_import); the rule
    -- lives here so reaching OUTSIDE the corpus does not restate it.
    require_form = {
        pattern = '^__([%w%-_]+)__[./](.+)$', -- 1 = package name, 2 = path
        dotted_ok = true,                     -- '.' separators mean '/'
        exts = { '', '.lua' },
        index = 'init.lua',
        -- a bare `require("x")` is package-LOCAL; only the __name__ form crosses
        crosses_packages = 'only via the pattern above',
    },

    -- ── enablement ───────────────────────────────────────────────────────────
    -- mod-list.json says which packages LOAD. This is an HONESTY input, not a
    -- resolution one: a disabled package is still present and its code is still
    -- readable, so a require into it resolves — but the resolution should carry
    -- that the target does not load in this configuration.
    enablement = {
        file = 'mods/mod-list.json',
        list_key = 'mods',
        name_key = 'name',
        enabled_key = 'enabled',
        affects = 'honesty', -- never 'resolution'
    },
}
