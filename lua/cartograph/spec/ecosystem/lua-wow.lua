-- PACKAGE-ECOSYSTEM spec: World of Warcraft addons.
--
-- The second half of the cluster spec/lua.lua:252 named as one missing
-- abstraction. Reading the code it replaces made the shape clear: `toc_scope` was
-- never WoW-specific — it tested the `.toc` marker OR Factorio's `info.json`, i.e.
-- it was already the package-boundary question asked over two ecosystems with both
-- answers inlined. This declares WoW's half; the test now loops over whatever is
-- declared.
--
-- WHY THE BOUNDARY IS THE POINT (measured, [[wow-addons-corpus]]): 353 addons /
-- 2.27M lines, and they VENDOR their libraries — 353 copies of Ace3. Without a
-- per-package resolution boundary a call to `AceGUI:Create` has 353 equally good
-- candidates and every one of them is wrong except the one in the calling addon.
-- The boundary is what makes that answerable rather than ambiguous.

return {
    schema = 1,
    ecosystem = 'lua-wow',
    lang = 'lua',
    source_exts = { 'lua' },

    -- ── package identity ─────────────────────────────────────────────────────
    -- A .toc is NAMED AFTER ITS OWN DIRECTORY (`Bagnon/Bagnon.toc`), which is a
    -- different rule from Factorio's fixed filename and the reason `identity`
    -- needs more than one shape. The extension alone is the fallback: an addon
    -- whose toc is named for a variant (`Bagnon_Config.toc`, `Bagnon-Mainline.toc`)
    -- still marks its directory.
    identity = {
        manifest_named_after_dir = '.toc',
        manifest_ext = '.toc',
        -- the addon NAME is its directory name; a .toc carries display metadata
        -- (## Title, ## Interface) but not a package id that differs from the dir,
        -- so unlike Factorio there is nothing to read out of it
        name_from = 'directory',
    },

    -- ── the resolution boundary ──────────────────────────────────────────────
    -- Each top-level package directory is its own resolution scope. This is the
    -- fact the whole spec exists for; see the measurement above.
    boundary = {
        per_package = true,
        notes = { why = '353 addons vendor their own copies of the same libraries,'
            .. ' so a name that is unique inside one addon is 353-way ambiguous'
            .. ' across the tree' },
    },

    -- ── HOOK FORMS: patching a table you did not define ──────────────────────
    -- CART-0618. A monkey-patch is "you modified a table you did not define", and
    -- HOW it is spelled is per-ecosystem. Plain Lua spells it as an assignment
    -- (`mod.member = f`) and needs no declaration. WoW spells it as a CALL, and a
    -- predicate that only knew assignments reported ZERO patches on a corpus that
    -- contains 249 of them — measured, and the reason this key exists.
    --
    -- DECLARED DATA, NOT CODE (the convergence rule): a hook form is a name plus
    -- which argument carries the table and which names the member. Hardcoding
    -- `hooksecurefunc` into an analyzer would have been the wrong-shaped fix and
    -- is exactly what an unmeasured version of this would have shipped.
    --
    -- MEASURED IN ~/work/wow_addons: hooksecurefunc 249 calls / 113 files;
    -- `require(` 0 occurrences in 2.27M lines, which is why the assignment form
    -- finds nothing here.
    hooks = {
        -- hooksecurefunc(table, "method", fn) — the 3-arg form. The 2-arg form
        -- hooksecurefunc("GlobalFn", fn) patches a GLOBAL rather than a member,
        -- so it carries no member argument and is declared separately rather than
        -- squeezed into the same shape.
        { call = 'hooksecurefunc', table_arg = 1, member_arg = 2, arity = 3,
            kind = 'post-hook',
            notes = { why = 'appends to the existing function; the original still runs,'
                .. ' so this is ADDITIVE and cannot silently replace behaviour' } },
        { call = 'hooksecurefunc', member_arg = 1, arity = 2,
            kind = 'post-hook-global',
            notes = { why = 'patches a global function by name, not a table member' } },
    },

    -- WoW addons have no require: files are listed in load order by the .toc and
    -- share one global table. Declaring the absence is not decoration — it is why
    -- no require_form appears here, and why load ORDER (banked) is the axis that
    -- would matter next. It is also why the ASSIGNMENT form of a monkey-patch is
    -- invisible in this ecosystem and the hook form above carries all of it.
    notes = {
        no_require = 'files are listed in .toc load order and share globals;'
            .. ' there is no import form to resolve',
    },
}
