-- PACKAGE-ECOSYSTEM spec: Neovim plugins.
--
-- The third of the cluster spec/lua.lua:252 named. Unlike the other two this is
-- NOT a per-directory package layout: a plugin is ONE package whose modules live
-- under a root prefix, so it declares a package_root rather than a boundary.
-- Keeping all three on one axis is what shows they are different answers to the
-- same question — where do packages live, and how does a name reach one — rather
-- than three unrelated detectors.
--
-- MARKER-GATED, deliberately: it fires only when a `lua/` layout is actually
-- present. spec/lua.lua's comment records that a blind dir-relative guess was
-- tried here and REVERTED — stock Lua's require is package.path-based, so
-- resolving relative to the current file is a guess, and guessing is what the self
-- oracle exists to replace with confirmation.

return {
    schema = 1,
    ecosystem = 'lua-nvim',
    lang = 'lua',
    source_exts = { 'lua' },

    -- ── the package root ─────────────────────────────────────────────────────
    -- `require 'foo.bar'` reaches `lua/foo/bar.lua` (or `lua/foo/bar/init.lua`), so
    -- `lua/` is where module paths start. Everything outside it (plugin/, doc/,
    -- after/) is loaded by the host, not by a require.
    package_root = 'lua',

    -- NB no `dotted_ok`: that a '.' separates path segments is a property of LUA's
    -- require, true for every lua ecosystem here, so declaring it per-ecosystem put
    -- a language fact on the wrong axis. The rule-consumption audit is what surfaced
    -- it — it sat UNREAD because no consumer wanted an ecosystem to tell it.
    require_form = {
        exts = { '', '.lua' },
        index = 'init.lua',
        notes = { rooted = 'a module path is resolved from package_root, NOT'
            .. ' relative to the requiring file — the reverted guess' },
    },

    -- no per-package boundary: one plugin is one scope, and a tree of plugins is a
    -- MULTI-ROOT corpus instead (providers/self.lua's label map), which is a
    -- different mechanism and already exists
    boundary = { per_package = false },
}
