-- The ODIN language spec + its package-context helper, extracted from the
-- engine ([[cartograph-spec-layering]] P1). Driven through the move-set flow:
-- close_moveset seeded on odin_context returned it as the whole cluster (no
-- private consts); node_text is the one shared dep (required below). Pure motion.

-- @langs odin — a spec IS one grammar's mapping, so every node type here is
-- odin's by construction.

local node_text = require('cartograph.spec.tsutil').node_text

-- Odin package-qualified resolution (R1). A .odin file declares `package P`; the
-- per-file context is its package name + import alias→package map. An import
-- `import "core:strings"` binds `strings` (the path's last segment = the package
-- name, Odin convention); `import s "core:strings"` binds the alias `s`→strings.
-- Computed per def/call — a scan of the source_file's TOP-LEVEL children only
-- (package_declaration + import_declarations), which is cheap (not a body walk).
-- Cached per FILE on src (deterministic: the source_file root — hence the
-- context — is the same for every node in a file). Takes ANY node and walks to
-- the source_file itself (robust), so a caller never poisons the cache with a
-- bad root. Cache is POSITIVE-ONLY (a package must be found) so a pathological
-- rootless node returns nil without evicting a good entry — the earlier
-- single-slot cache poisoned io.odin to 3/25 by caching a nil-root result; a
-- per-def recompute (no cache) was correct but O(defs×top-level) and too slow.
local odin_ctx_src, odin_ctx_val
local function odin_context(node, src)
    if src == odin_ctx_src and odin_ctx_val then return odin_ctx_val end
    local r = node
    while r:parent() do r = r:parent() end -- absolute tree root (robust: a
    -- premature `~= source_file` stop returned nil for some deep def nodes,
    -- leaving big files like fmt.odin/io.odin only partially package-keyed)
    local pkg, imports = nil, {}
    if r then
        for n in r:iter_children() do
            local t = n:type()
            if t == 'package_declaration' then
                for c in n:iter_children() do
                    if c:type() == 'identifier' then pkg = node_text(c, src); break end
                end
            elseif t == 'import_declaration' then
                local alias, path
                for c in n:iter_children() do
                    if c:type() == 'identifier' then alias = node_text(c, src)
                    elseif c:type() == 'string' then
                        for cc in c:iter_children() do
                            if cc:type() == 'string_content' then path = node_text(cc, src) end
                        end
                    end
                end
                if path then
                    local pk = path:gsub('["\']', ''):match('([%w_]+)$')
                    if pk then imports[alias or pk] = pk end
                end
            end
        end
    end
    local ctx = { package = pkg, imports = imports }
    if pkg then odin_ctx_src, odin_ctx_val = src, ctx end -- positive-only cache
    return ctx
end

return {
    -- MEMBER-NAME POSITIONS (CART-0529): parent node type -> the child holding a
    -- MEMBER NAME, i.e. a name that is reached THROUGH A RECEIVER. Same shape as
    -- `call_positions`, and read for the opposite purpose: a mention here must
    -- NOT be matched against the corpus-wide unique-function index, because a
    -- bare name match says nothing about which object the receiver holds.
    -- Measured on wow_addons: 724 of 2988 reg occurrences (24.2%) sat in member
    -- position, and the sample held outright cross-file fabrication
    -- (`db.ResetProfile = DBObjectLib.ResetProfile` pointing at an unrelated
    -- addon's local ResetProfile).
    -- ★ BRACKET FORMS ARE DELIBERATELY ABSENT (`t[k]`, `t["k"]`, subscript_*):
    -- their key is an EXPRESSION, so the mention inside is a genuine value read
    -- and vetoing it would lose a real reference. Only dot-style member NAMES
    -- belong here.
    member_positions = {
        member_expression = 1, -- o.NAME -- child 1, no field
    },
    -- CALL POSITIONS (CART-0499): parent node type -> which child holds the
    -- CALLEE NAME, as a field name or a named-child index. Replaces a
    -- hardcoded four-name or-chain inline in the provider that php, java,
    -- bash, rust macros, ruby and haskell were all missing from -- so a call
    -- to a corpus-unique function became a fn REFERENCE and minted a `reg`
    -- edge ("kept alive by top-level DATA"), a different fact. 96.6% of
    -- mantisbt's reg occurrences were mislabelled calls.
    call_positions = {
        call_expression = 'function', -- g(1)
    },
        exts = { 'odin' },
        -- ⚠ TWO PATTERNS, AND THE SECOND IS NOT OPTIONAL POLISH (CART-0630). Odin
        -- attaches ATTRIBUTES to a declaration — `@(require_results)`,
        -- `@(private="file")` — and the grammar makes `attributes` the FIRST NAMED
        -- CHILD. The `.` anchor then fails, so a proc carrying one matched NOTHING:
        -- not a def, not a node, no fn_range, and no enclosing function for anything
        -- inside it.
        --
        -- MEASURED on ~/git/odin/core: 40842 procedure_declaration, 8887 of them
        -- beginning with `attributes` — 21.8% OF THE STANDARD LIBRARY'S PROCEDURES
        -- WERE INVISIBLE. `os/temp_file.odin` has four procs and produced zero
        -- functions, which is how this surfaced: every call in it had a nil
        -- enclosing fn, so the callback-argument upgrade minted FILE-level `reg`
        -- edges instead of function refs.
        --
        -- ★ WRITTEN AS TWO ANCHORED PATTERNS rather than one with `(attributes)?`:
        -- an optional node between two anchors is exactly the construct whose
        -- meaning is easy to get wrong, and this file has already paid once for a
        -- pattern that read correctly and matched nothing.
        functions = [=[
            (procedure_declaration . (identifier) @name) @def
            (procedure_declaration . (attributes) . (identifier) @name) @def
        ]=],
        calls = [=[
            (call_expression function: (identifier) @name) @call
        ]=],
        -- Odin has no methods — every proc is free (UFCS is banked)
        is_method = function () return false end,
        -- ONLY the declaration, deliberately: the `procedure` wrapper below is
        -- also a named node, and including it would make an upward walk stop at
        -- the wrapper — whose body_of/params_of hooks expect the DECLARATION and
        -- would then find nothing. The narrower set is the correct one.
        fn_types = { procedure_declaration = true },
        -- ★ ODIN LABELS NEITHER THE BODY NOR THE PARAMETERS. A
        -- `procedure_declaration` holds a `procedure` WRAPPER, and that holds the
        -- `parameters` and the `block` as positional children — odin's whole field
        -- list has no `body` and no `params`. Both field-based readers therefore came
        -- back empty and odin got NO flow records at all: 31955 functions with zero
        -- fine flow, so optimize / untangle / narrow / expr.of / const-fold / exprlint
        -- and the shape roster were not degraded on odin, they were ABSENT — and
        -- silently, because a function with no flow record simply yields no findings
        -- (CART-0305, measured). These two hooks are the positional twins of
        -- body_field / params_field; flow.build prefers the field and falls back here.
        body_of = function (def)
            for c in def:iter_children() do
                if c:named() and c:type() == 'procedure' then
                    for g in c:iter_children() do
                        if g:named() and g:type() == 'block' then return g end
                    end
                end
            end
            return nil
        end,
        params_of = function (def)
            for c in def:iter_children() do
                if c:named() and c:type() == 'procedure' then
                    for g in c:iter_children() do
                        if g:named() and g:type() == 'parameters' then return g end
                    end
                end
            end
            return nil
        end,
        -- NODE-LOCAL tearing: a proc's key is `package.proc`, and the package
        -- comes from the file-top `package` decl (before any parse error), so a
        -- proc AFTER an error has lost no enclosing context. Tear only defs whose
        -- OWN subtree errors — the Odin grammar errors in big stdlib files
        -- (fmt.odin/io.odin ~L681) and the default (tear-everything-after) hid
        -- the most-used procs (fmt.aprintf, io.write_rune). Like bash.
        torn_by_node = true,
        -- R1 package-qualified DEF keying: a proc in `package P` gains a `P.proc`
        -- EXACT key (so a cross-package `P.proc()` call meets it) via alt_keys —
        -- NOT qualify. qualify would MOVE the def off its bare key onto tail[proc],
        -- and the tail path has no same-file priority, so same-package procs that
        -- repeat across a package's files (`try_set` per platform file in
        -- sys/info) went ambiguous → lost. alt_keys keeps the bare key intact
        -- (same-file/scope reach unchanged, 0 regression) and ADDS P.proc.
        alt_keys = function (name, defn, src)
            local ctx = odin_context(defn, src)
            return ctx.package and { ctx.package .. '.' .. name } or {}
        end,
        -- R1 CALL side: `op.proc()` parses as member_expression(op, call_expr(proc)).
        -- Key `<pkg>.proc` where op is an import alias/name (→ the import path's
        -- last segment) or the file's own package. A non-package operand (a local
        -- var, i.e. UFCS `x.foo()`) → nil (left bare; UFCS is banked).
        qualify_call = function (calln, name, src)
            if calln:type() ~= 'call_expression' then return nil end
            local me = calln:parent()
            if not me or me:type() ~= 'member_expression' then return nil end
            local op
            for c in me:iter_children() do
                if c:named() then op = c; break end -- operand = first named child
            end
            if not op or op:type() ~= 'identifier' then return nil end
            local opn = node_text(op, src)
            local ctx = odin_context(calln, src)
            local pk = ctx.imports[opn] or (opn == ctx.package and ctx.package or nil)
            if pk then return pk .. '.' .. name, { rule = 'pkg-qualified' } end
            return nil
        end,
        -- a package-qualified key (`strings.contains`) is exact-or-nothing: the
        -- package is explicit, so a miss is an honest frontier (external/nested/
        -- vendored), never a promiscuous bare-tail guess. Bare calls (no dot) still
        -- take the tail path (same-package reach).
        exact_only_key = function (name) return name:find('.', 1, true) ~= nil end,
        -- a package IS a directory (all .odin in a dir share a namespace); bare
        -- proc names resolve within it, like Go
        scope = function (file, _)
            return file:match('^(.*)/[^/]*$') or ''
        end,
        entry_names = { main = true },
        id_fn_refs = false,
        -- common core/builtin verbs — never absorbed by a project proc
        stdlib_names = { len = true, cap = true, append = true, make = true,
            new = true, delete = true, free = true, clone = true, copy = true,
            print = true, println = true, printf = true, tprintf = true,
            aprintf = true, format = true, panic = true, assert = true,
            init = true, destroy = true, reserve = true, resize = true,
            clear = true, contains = true, get = true, set = true,
            has_key = true, size_of = true, len_of = true, type_of = true,
            read = true, write = true, close = true, open = true, next = true,
            string = true, clone_string = true, to_string = true },
}
