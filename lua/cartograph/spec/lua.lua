-- The LUA language spec + its base helpers, extracted via the move-set flow
-- ([[cartograph-spec-layering]]). Contains the scope harvesters + LUA_SCOPES
-- (scope-model step 3), lua_is_write, LUA_GUARDS, and the three per-root
-- ECOSYSTEM detectors (factorio_mods / nvim_lua_root / toc_scope) that were
-- deliberately embedded inline beside the spec — they are lua-import-resolution
-- helpers, not composable packs, so they travel with the spec. The guard
-- substrate (chain_eq/optext_is/unparen) and node_text/inext are the shared
-- deps, required from spec/tsutil.lua. NOOP is a trivial engine idiom, copied
-- local. RB_ASSOC/ruby_rails_synth are the RAILS pack and stay in the engine.
-- Pure motion; behaviour-identical.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text
local inext = tsutil.inext
local chain_eq = tsutil.chain_eq
local optext_is = tsutil.optext_is
local unparen = tsutil.unparen

-- the identifier query behind escape_names (CART-0230), parsed once per session
local ESCQ

-- shared empty iterator: the `... or function () end` fallback used to avoid
-- allocating a fresh closure on every nil-children branch in hot loops
local function NOOP() end

local function lua_locals(node, src, out) -- chunk/block statement locals
    for _, stmt in inext, node, -1 do
        local t = stmt:type()
        if t == 'variable_declaration' then
            -- `local a, b = 1, 2` wraps an assignment_statement; a bare
            -- `local a` holds the variable_list directly
            local row = select(1, stmt:range())
            for _, a in inext, stmt, -1 do
                local vl = a:type() == 'variable_list' and a or nil
                if not vl and a:type() == 'assignment_statement' then
                    for _, c in inext, a, -1 do
                        if c:type() == 'variable_list' then vl = c break end
                    end
                end
                for _, v in (vl and inext or NOOP), vl, -1 do
                    if v:type() == 'identifier' then
                        out[node_text(v, src)] = { row = row }
                    end
                end
            end
        elseif t == 'function_declaration' then
            local islocal = false
            for _, c in inext, stmt, -1 do
                if c:type() == 'local' then islocal = true break end
            end
            if islocal then
                local nm = stmt:field('name')[1]
                if nm and nm:type() == 'identifier' then
                    out[node_text(nm, src)] = { row = select(1, stmt:range()) }
                end
            end
        end
    end
end
local function lua_params(node, src, out)
    local ps = node:field('parameters')[1]
    for _, c in (ps and inext or NOOP), ps, -1 do
        if c:type() == 'identifier' then out[node_text(c, src)] = {} end
    end
end
local function lua_forvars(node, src, out)
    local row = select(1, node:range())
    for _, cl in inext, node, -1 do
        local t = cl:type()
        if t == 'for_numeric_clause' then
            local v = cl:named_child(0) -- ONLY the loop var; bounds are exprs
            if v and v:type() == 'identifier' then
                out[node_text(v, src)] = { row = row }
            end
        elseif t == 'for_generic_clause' then
            for _, c in inext, cl, -1 do
                if c:type() == 'variable_list' then -- the vars, not the iterator
                    for _, v in inext, c, -1 do
                        if v:type() == 'identifier' then
                            out[node_text(v, src)] = { row = row }
                        end
                    end
                end
            end
        end
    end
end
local LUA_SCOPES = {
    chunk                = { kind = 'module', harvest = lua_locals },
    block                = { kind = 'local', harvest = lua_locals },
    function_declaration = { kind = 'param', harvest = lua_params },
    function_definition  = { kind = 'param', harvest = lua_params },
    for_statement        = { kind = 'local', harvest = lua_forvars },
}

-- WRITE-position classifier (the write axis, rung 1: syntactic). A mention is a
-- WRITE when it sits anywhere on an assignment-target chain. Called from the
-- engine's collect_mentions only when the parent type is in spec.write_gate.
local function lua_is_write(c, n)
    local cur, p = c, n
    while true do
        local pt = p:type()
        if pt == 'dot_index_expression' then
            -- both base and field ride the write path
        elseif pt == 'bracket_index_expression' then
            if p:named_child(0) ~= cur then return false end -- key = a read
        else
            break
        end
        cur = p
        p = p:parent()
        if not p then return false end
    end
    if p:type() ~= 'variable_list' then return false end
    local asg = p:parent()
    if not asg or asg:type() ~= 'assignment_statement' then return false end
    local wrap = asg:parent() -- `local x = v` BINDS a name, writes nothing
    return not (wrap and wrap:type() == 'variable_declaration')
end

local LUA_GUARDS = {
    cond = { if_statement = true, elseif_statement = true, while_statement = true },
    else_t = 'else_statement', elseif_t = 'elseif_statement',
    fn = { function_declaration = true, function_definition = true },
    binop = 'binary_expression', andops = { ['and'] = true },
    negop = 'unary_expression', negtok = 'not', pfield = 'parameters',
    pw_refsem = true, -- tables are reference-typed: param writes escape
    -- `not X` / `X == nil` / `nil == X`, X the written chain
    abs_test = function (n, src, chain)
        local t = n:type()
        if t == 'unary_expression' then
            local op = n:child(0)
            if op and not op:named() and op:type() == 'not' then
                local x = n:named_child(0)
                return x ~= nil and chain_eq(x, src, chain)
            end
        elseif t == 'binary_expression' and optext_is(n, src, { ['=='] = true }) then
            local a, b = n:named_child(0), n:named_child(1)
            if a and b then
                if a:type() == 'nil' then return chain_eq(b, src, chain) end
                if b:type() == 'nil' then return chain_eq(a, src, chain) end
            end
        end
        return false
    end,
    -- else arm of `if X then` / `if X ~= nil then`
    presence = function (cond, src, chain)
        cond = unparen(cond)
        if chain_eq(cond, src, chain) then return true end
        if cond:type() == 'binary_expression'
            and optext_is(cond, src, { ['~='] = true }) then
            local a, b = cond:named_child(0), cond:named_child(1)
            if a and b then
                if a:type() == 'nil' then return chain_eq(b, src, chain) end
                if b:type() == 'nil' then return chain_eq(a, src, chain) end
            end
        end
        return false
    end,
    -- `X = X or v` (the memoize idiom); positional in multi-assignment
    rhs_setonce = function (top, src, chain)
        local vl = top:parent()
        if not vl or vl:type() ~= 'variable_list' then return false end
        local pos, i = nil, 0
        for ch in vl:iter_children() do
            if ch:named() then
                i = i + 1
                if ch == top then pos = i break end
            end
        end
        local asg = vl:parent()
        local exprs = asg and asg:named_child(1)
        if not (pos and exprs) then return false end
        local rhs, j = nil, 0
        for ch in exprs:iter_children() do
            if ch:named() then
                j = j + 1
                if j == pos then rhs = ch break end
            end
        end
        if not rhs or rhs:type() ~= 'binary_expression'
            or not optext_is(rhs, src, { ['or'] = true }) then return false end
        local l = rhs:named_child(0)
        return l ~= nil and chain_eq(l, src, chain())
    end,
}

-- factorio mod-name -> top dir, from each dir's manifest "name" (the mod's
-- IDENTITY — dir names carry versions and may not match: space-exploration-
-- postprocess lives in space-exploration_0.7.5; MEASURED, 112 of 195 local
-- archives disagree with their filename). The root's OWN manifest maps its name
-- to '' (self-references resolve in a single-mod extraction too). Memoized per
-- root.
--
-- The identity RULE is no longer restated here: it comes from the package-
-- ecosystem spec (spec/ecosystem/lua-factorio.lua), which is the abstraction the
-- comment below this one has been asking for. Reaching OUTSIDE the corpus — into
-- a mods dir of zip archives — then uses the SAME declared rule rather than a
-- second copy of it.
-- the package-IDENTITY rule, from the ecosystem spec — resolved ONCE so every
-- consumer in this file reads the same source instead of restating it
local validity = require 'cartograph.validity'

local ECO = require('cartograph.spec.ecosystem').load('lua-factorio')
local IDENT = ECO and ECO.identity or nil

-- the cross-package require FORM, from the same spec
local REQFORM = ECO and ECO.require_form or nil

-- EPOCH-keyed, not memoized forever. A stamp is not available cheaply here: to
-- know whether this map is stale you must scan the top-level directories and stat
-- every candidate manifest, which is exactly what computing it does. So it turns
-- over per EXTRACTION RUN instead — which was also the live bug, since adding a
-- package to a tree left the identity map stale for the rest of the session.
local factorio_mods = validity.memo { name = 'factorio-mods', epoch = 'extract',
    compute = function (root, files)
    local map = {}
    if not IDENT then return map end -- no spec, no claim (never a guessed rule)
    local segs = { [''] = true }
    for f in pairs(files) do
        local seg = f:match('^([^/]+)/')
        if seg then segs[seg] = true end
    end
    -- THIS ECOSYSTEM'S OWN ROSTER (root carries the declared roster_scheme, keys
    -- are `Package/rel`) has already done this work: the label IS the package
    -- identity, established from each manifest when the roster was built.
    -- Re-deriving it would mean reading a manifest at `<uri>/<seg>/info.json`,
    -- which is not a path at all — which is why a cross-package require into an
    -- ARCHIVE resolved to nothing until this branch existed.
    -- Gated on the DECLARED scheme, not on "root is a URI": self://loaded is a
    -- labelled corpus too, and a non-empty map here switches on Factorio's
    -- dir-relative require matching below — the over-reach self_spec catches.
    local scheme = ECO and ECO.roster_scheme
    if scheme and type(root) == 'string'
        and root:sub(1, #scheme + 3) == scheme .. '://' then
        for seg in pairs(segs) do
            if seg ~= '' then map[seg] = seg end
        end
        return map
    end
    for seg in pairs(segs) do
        local p = root .. (seg == '' and '' or '/' .. seg) .. '/' .. IDENT.manifest
        local txt = require('cartograph.transport').read(p)
        if txt then
            local okj, m = pcall(vim.json.decode, txt)
            if okj and type(m) == 'table' and type(m[IDENT.name_key]) == 'string' then
                map[m[IDENT.name_key]] = seg
            end
        end
    end
    return map
end }

-- CLUSTER RESOLVED. This was three per-root detectors inline here —
-- factorio_mods / toc_scope / nvim_lua_root — which the comment that used to live
-- at this spot called "one missing-abstraction" for the resolution-health
-- analyzer's scattered-special-case rule to find ([[cartograph-cross-project]]
-- repo shapes). All three are now DECLARED ecosystems under spec/ecosystem/, and
-- what remains here is the mechanism that consults them.
--
-- Reading the code is what showed they belonged together: toc_scope was never
-- WoW-specific — it tested `.toc` OR factorio's `info.json`, so it was already the
-- package-boundary question with both answers hardcoded. The functions below now
-- ask that question of whatever is declared, and a fourth ecosystem participates
-- by declaring a marker rather than by editing this file.
--
-- The three are genuinely different ANSWERS, which is the point of one axis:
--   factorio  a fixed manifest name, per-package boundary, __mod__/path requires
--   wow       a manifest named for its own directory, per-package boundary, no
--             require at all (load order via the .toc)
--   nvim      no manifest — a package ROOT (`lua/`) that dotted requires resolve
--             from, and NO per-package boundary (a tree of plugins is a multi-root
--             corpus instead)
-- the nvim-plugin PACKAGE ROOT, from its declared ecosystem rather than a literal
-- here: `require 'foo.bar'` reaches <package_root>/foo/bar.lua. MARKER-GATED — it
-- fires only when that layout is actually present, because stock Lua's require is
-- package.path-based and resolving relative to the requiring file is the guess that
-- was tried and reverted.
local PKGROOT, NVIMIDX = (function ()
    local e = require('cartograph.spec.ecosystem').load('lua-nvim')
    if not e then return nil, nil end
    return e.package_root, (e.require_form or {}).index
end)()

local nvim_lua_root = validity.memo { name = 'nvim-lua-root', epoch = 'extract',
    compute = function (root, files)
        if not PKGROOT then return false end
        local pat = '^' .. PKGROOT:gsub('%p', '%%%0') .. '/.+%.lua$'
        for f in pairs(files) do
            if f:match(pat) then return true end
        end
        return false
    end }

-- IS THIS TOP-LEVEL DIRECTORY A PACKAGE? — asked over every DECLARED ecosystem
-- that says its packages form a resolution boundary, instead of over two markers
-- inlined here. Reading the code this replaced is what showed the shape: it tested
-- `.toc` OR factorio's `info.json`, i.e. it was already this question with both
-- answers hardcoded. A new ecosystem now participates by declaring a marker.
--
-- THREE MARKER SHAPES, because packages really are identified three ways:
--   manifest                 a fixed filename        (factorio: info.json)
--   manifest_named_after_dir named for its own dir   (wow: Bagnon/Bagnon.toc)
--   manifest_ext             any file of that type   (wow: a variant .toc)
-- Memoized per (root, segment) on the extract epoch: one scandir per directory at
-- worst, which matters on a 353-addon / 2.27M-line tree.
local BOUNDED = (function ()
    local out = {}
    local ecomod = require 'cartograph.spec.ecosystem'
    for _, name in ipairs(ecomod.names()) do
        local e = ecomod.load(name)
        if e and e.lang == 'lua' and (e.boundary or {}).per_package
            and e.identity then
            out[#out + 1] = e.identity
        end
    end
    return out
end)()

local pkg_dir = validity.memo { name = 'package-dir', epoch = 'extract',
    compute = function (_, dir, seg)
        local need_scan = false
        for _, ident in ipairs(BOUNDED) do
            if ident.manifest
                and vim.uv.fs_stat(dir .. '/' .. ident.manifest) ~= nil then
                return true
            end
            if ident.manifest_named_after_dir and vim.uv.fs_stat(
                dir .. '/' .. seg .. ident.manifest_named_after_dir) ~= nil then
                return true
            end
            if ident.manifest_ext then need_scan = true end
        end
        -- the extension fallback costs a scandir, so it runs only if some declared
        -- ecosystem actually asks for one, and only after the cheap stats missed
        if need_scan then
            local it = vim.uv.fs_scandir(dir)
            while it do
                local name = vim.uv.fs_scandir_next(it)
                if not name then break end
                for _, ident in ipairs(BOUNDED) do
                    local ext = ident.manifest_ext
                    if ext and name:sub(-#ext) == ext then return true end
                end
            end
        end
        return false
    end }

local function toc_scope(file, _, root)
    local seg = file:match('^([^/]+)/')
    -- multi-root corpora (self://) pass a table root: never an addon tree
    if not seg or type(root) ~= 'string' then return '' end
    local hit = pkg_dir(root .. '\31' .. seg, root .. '/' .. seg, seg)
    return hit and seg or ''
end

return {
    exts = { 'lua' },
    -- BINDER NODES ([[cartograph-cross-project]]): node types that BIND names, so a
    -- loop variable is known to be local. Neither df's `def` nor the expression IR
    -- records them — `for _, g in pairs(t)` puts `g` in `use` and never in `def` —
    -- which made a loop-bound receiver look like an unknown global.
    -- `child` names a container holding the bound names; without it, the binder's
    -- own direct name children are the bindings.
    binders = {
        { node = 'for_generic_clause', child = 'variable_list' },
        { node = 'for_numeric_clause' },
    },
    -- RESOLUTION BOUNDARY (the .toc scoping adapter): in a WoW-addon
    -- tree every addon vendors the same libraries (353 Ace3 copies),
    -- and whole-tree name resolution drowns in the ambiguity — the
    -- hedge census measured 63.6% of wow's hedge mass as refused-
    -- with-candidates. Each addon dir (identified by its .toc
    -- manifest) becomes a scope: calls resolve against the addon's
    -- OWN files (incl. its vendored libs); cross-addon names stay
    -- honestly unresolved (runtime cross-addon calls go through
    -- globals — name-matching them would be a guess). A lua tree
    -- with no .toc dirs partitions to ONE scope: behavior unchanged.
    scope = toc_scope,
    -- qualified/method names resolve within the addon boundary too:
    -- self:RegisterEvent means THIS addon's vendored AceEvent; a
    -- cross-addon unique-name match is a guess, not a fact
    qualified_scope_local = true,
    write_gate = { variable_list = true, dot_index_expression = true,
        bracket_index_expression = true },
    is_write = lua_is_write,
    -- a lua def name is FULLY SELF-CONTAINED (`function X.prototype:m` carries its
    -- own qualifier — no enclosing class block to truncate, unlike php/c). So tear
    -- only defs whose OWN subtree holds the error, not everything after the first
    -- error row: one invalid-escape string (`"[^\.]+"` at Waterfall-1.0.lua:370)
    -- otherwise torns ~2000 downstream defs — measured 481 clean defs corpus-wide
    -- torned to protect just 2 genuinely-in-error. Same rationale as bash.
    torn_by_node = true,
    guards = LUA_GUARDS,
    scopes = LUA_SCOPES, -- lexical-first id pass (scope-model step 3)
    functions = [[
        (function_declaration name: (_) @name) @def
        (assignment_statement
            (variable_list name: (_) @name)
            (expression_list value: (function_definition) @def))
        (field name: (identifier) @name value: (function_definition) @def)
    ]],
    -- a function VALUE in a table field is registry-style: invoked
    -- through the table, invisible to a name graph
    field_fn_cbarg = true,
    calls = [[ (function_call name: (_) @name) @call ]],
    -- OO inheritance/instancing via metatables: `setmetatable(X, {__index =
    -- P})` makes X's `:method` dispatch fall through to P (and P's own
    -- __index chain). The __index relation is what matters for method
    -- resolution — X may be a subclass OR an instance, both sound (X's
    -- methods come from P either way). Emitted as an extends edge X->P
    -- (data.extends), consumed by resolve_super for `X:m()`/`X.m()` calls
    -- (V0, [[cartograph-linker]] receiver-typing foundation). Two forms of the
    -- explicit `{__index = <id>}` inheritance (both unambiguous): PATTERN A
    -- `setmetatable(X, {__index=P})` (named first arg) and PATTERN B
    -- `local X = setmetatable(_, {__index=P})` (the LHS local is the child, so
    -- the common `local Sub = setmetatable({}, {__index=Base})` subclass form is
    -- captured — needed for a complete inheritance graph). The bare-2nd-arg
    -- `setmetatable(X, P)` heuristic stays deferred (soundness-first).
    super_query = [=[
        (function_call
            name: (identifier) @_smt (#eq? @_smt "setmetatable")
            arguments: (arguments
                (identifier) @child
                (table_constructor
                    (field name: (identifier) @_k (#eq? @_k "__index")
                           value: (identifier) @parent))))
        (variable_declaration
            (assignment_statement
                (variable_list name: (identifier) @child)
                (expression_list value: (function_call
                    name: (identifier) @_smt2 (#eq? @_smt2 "setmetatable")
                    arguments: (arguments (_)
                        (table_constructor
                            (field name: (identifier) @_k2 (#eq? @_k2 "__index")
                                   value: (identifier) @parent)))))))
    ]=],
    -- V2 constructor binds: `obj = C.new(...)` / `C:new(...)` (the callee is
    -- captured as text and filtered to the `.new`/`:new` convention in
    -- handle_ctor). Matches the inner assignment of `local obj = …` AND bare
    -- reassignments, so a rebind is counted (single-assignment gate).
    ctor_query = [=[
        (assignment_statement
            (variable_list name: (identifier) @cvar)
            (expression_list value: (function_call name: (_) @cctor)))
    ]=],
    -- V2 cut 2: any `setmetatable(_, {__index = C})` (first arg unconstrained,
    -- so the anonymous `setmetatable({}, …)` return form is caught) → C at its
    -- line; a fn whose body contains one has return-class C.
    smt_query = [=[
        (function_call
            name: (identifier) @_s (#eq? @_s "setmetatable")
            arguments: (arguments (_)
                (table_constructor
                    (field name: (identifier) @_ki (#eq? @_ki "__index")
                           value: (identifier) @smtclass))))
    ]=],
    vars = [[
        (variable_declaration
            (assignment_statement
                (variable_list name: (identifier) @vname)
                (expression_list value: (_) @value))) @vdef
        (chunk
            (assignment_statement
                (variable_list name: (identifier) @vname)
                (expression_list value: (_) @value)) @vdef)
    ]],
    params_field = 'parameters',
    body_field = 'body',
    is_method = function (name) return name:find(':') ~= nil end,
    -- VISIBILITY (CART-0231). Lua's is purely syntactic — a `local` binding is
    -- invisible outside its file BY NAME, everything else is reachable (a dotted
    -- name through its table, a bare `function g()` through _G). Until this existed
    -- every lua node carried `exported = nil`, and consumers that read the field as
    -- a boolean read ABSENCE AS FALSENESS: lsp hover labelled `function M.abs`
    -- `_local_`, for the whole language we dogfood on.
    --
    -- THE THREE SHAPES ARE THE THREE the `functions` query captures, no more:
    --   (1) function_declaration  — `function g/M.f/M:m` AND `local function l`;
    --       the only difference is a leading anonymous `local` token.
    --   (2) function_definition under assignment_statement — `M.h = function()`,
    --       `g = function()`. `local a = function()` reaches the same capture but
    --       carries a `variable_declaration` ancestor, which is its `local`.
    --   (3) function_definition under a table `field` — `{ k = function() end }`.
    --
    -- BIASED TOWARD `true` ON PURPOSE. A wrong `false` is the harmful direction:
    -- it lets a consumer refuse a live edge (CART-0230) or call a reachable
    -- function dead. So only syntax that PROVES a local binding returns false, and
    -- case (3) returns true — whether the containing table escapes is a different
    -- question, and answering it wrong here would be answering it in the harmful
    -- direction.
    exported_def = function (defn, src)
        if defn:type() == 'function_declaration' then
            local first = defn:child(0)
            return not (first and not first:named() and first:type() == 'local')
        end
        -- an anonymous function VALUE: the `local` lives on the enclosing STATEMENT,
        -- not on the value, so walk up to find the statement that BINDS it.
        local a, asn = defn:parent(), nil
        while a do
            local t = a:type()
            -- case (3) first: inside a table constructor the fn is a MEMBER, not a
            -- name binding, and the enclosing statement's `local` belongs to the
            -- table rather than to this function.
            if t == 'table_constructor' then return true end
            if t == 'variable_declaration' then return false end -- `local x = function()`
            if t == 'assignment_statement' then asn = a end
            if t == 'chunk' or t == 'return_statement' or t == 'block' then break end
            a = a:parent()
        end
        if not asn then return true end
        -- `NAME = function()`. A dotted/bracketed target is a table member, so
        -- reachable. A PLAIN IDENTIFIER is a local iff some enclosing scope declares
        -- it — the DEFERRED-ASSIGNMENT idiom, `local abs` … `abs = function()`, which
        -- is how worker.lua's `abs`, gen.lua's `body` and the factorio profiles'
        -- `mint_path` are written. Reading only the assignment calls all five of those
        -- exported, so the declaration has to be looked for.
        local vlist = asn:child(0)
        local target = vlist and vlist:type() == 'variable_list' and vlist:child(0)
        if not (target and target:type() == 'identifier') then return true end
        local name = node_text(target, src)
        local scope = asn:parent()
        while scope do
            local st = scope:type()
            if st == 'block' or st == 'chunk' then
                for c in scope:iter_children() do
                    if c:type() == 'variable_declaration' then
                        -- child(0) is the UNNAMED `local` token, not the binding list.
                        -- (A dump filtered to named children hides that and makes
                        -- `c:child(0)` look like the variable_list.) The list is a
                        -- named child: a variable_list directly for `local x`, or one
                        -- nested under an assignment_statement for `local x = v`.
                        local l
                        for k in c:iter_children() do
                            local kt = k:type()
                            if kt == 'variable_list' then l = k break end
                            if kt == 'assignment_statement' then
                                for k2 in k:iter_children() do
                                    if k2:type() == 'variable_list' then l = k2 break end
                                end
                                break
                            end
                        end
                        for id in (l and l:iter_children() or function () end) do
                            if id:type() == 'identifier'
                                and node_text(id, src) == name then return false end
                        end
                    end
                end
            end
            scope = scope:parent()
        end
        return true
    end,
    -- BINDING MODIFIERS (CART-0234): node types that decorate a DECLARATION and carry
    -- neither a value nor a name read. Lua 5.4's `local x <const>` / `<close>` parse as
    -- `attribute` — which is ALSO python's name for `a.b`, so the shared node-type maps in
    -- expr.lua and flow.lua cannot tell them apart without asking the language. Both sides
    -- fabricated a read of a variable called `const` from this, and the expr self-gate
    -- reported AGREEMENT because they fabricated it identically.
    binding_modifiers = { attribute = true },
    -- CONFINEMENT (CART-0230), the other half of exported_def. `exported = false`
    -- says a name is invisible OUTSIDE its file; it does not say the VALUE cannot
    -- leave, and in lua it routinely does — commands.lua's `local function cmd` is
    -- put in a handoff table the commands/* submodules destructure, and calls to it
    -- from those files are real.
    --
    -- The distinguishing fact is whether the name is ever mentioned in its own file
    -- somewhere OTHER than as the callee of a call: `t.f = NAME`, `return NAME`,
    -- `g(NAME)`, `{ NAME }`, `NAME.x`. If it never is, the value never left, and a
    -- cross-file call the name matcher wants to point here is not reaching it.
    --
    -- Returns the set of names this file mentions in a VALUE position. Deliberately
    -- OVER-inclusive: a same-named parameter used as a value in some unrelated
    -- function of this file lands in the set too, which only ever means "we do not
    -- refuse". Under-inclusiveness is what would cost a live edge.
    --
    -- ONE query, parsed once per session and iterated in C. The first cut walked
    -- every named node from lua and cost +26% of the whole extract on desynced
    -- (6.6s -> 8.9s) — a per-file whole-tree walk in interpreted lua, for a fact
    -- that changes a few hundred resolutions. Same answers, a fraction of the cost.
    escape_names = function (root, src)
        local set = {}
        ESCQ = ESCQ or vim.treesitter.query.parse('lua', '(identifier) @id')
        for _, n in ESCQ:iter_captures(root, src) do
            local p = n:parent()
            local pt = p and p:type()
            local mention = true
            if pt == 'function_call' then
                -- the callee: `NAME(...)` is a use of the binding but not an
                -- escape of the value
                local nm = p:field('name')[1]
                mention = not (nm and nm:id() == n:id())
            elseif pt == 'function_declaration' then
                mention = false -- the def's own name
            elseif pt == 'dot_index_expression' or pt == 'method_index_expression' then
                -- only the KEY is a non-mention. The OBJECT is a value read:
                -- `NAME.x` reads NAME. (Excluding both children instead would
                -- call such a file confined — wrong in the one direction that
                -- costs a live edge.)
                for _, f in ipairs { 'field', 'method' } do
                    local k = p:field(f)[1]
                    if k and k:id() == n:id() then mention = false end
                end
            end
            if mention then set[node_text(n, src)] = true end
        end
        return set
    end,
    -- FIELD ALIAS (CART-0237): `local f = mod.field`, the sibling of import_bind. The
    -- import binds a MODULE to a local; this binds one of its MEMBERS, and a later bare
    -- `f()` is then a call into that module — evidence from the caller's own file, which
    -- beats any corpus-wide name match. Returns (recv, member) or nil.
    -- Single-segment base only: `a.b.c` is a chain whose root type we do not know here,
    -- and the require-alias map is keyed on one name.
    field_alias = function (valn, src)
        if valn:type() ~= 'dot_index_expression' then return nil end
        local b, f = valn:named_child(0), valn:named_child(1)
        if not (b and f and b:type() == 'identifier' and f:type() == 'identifier') then
            return nil
        end
        return node_text(b, src), node_text(f, src)
    end,
    -- `require "x"` / `local x = require "x"`: module -> file
    import_call = 'require',
    resolve_import = function (mod, files, from, root)
        local slashed = mod:gsub('%.', '/')
        for _, cand in ipairs({ slashed .. '.lua', slashed .. '/init.lua', mod .. '.lua' }) do
            if files[cand] then return cand end
        end
        -- nvim-plugin repo shape: the package lives under lua/ (require
        -- 'foo.bar' → lua/foo/bar.lua) — marker-gated, so a non-nvim corpus
        -- without a lua/ layout is unaffected
        if type(root) == 'string' and PKGROOT and nvim_lua_root(root, files) then
            -- the ROOT and the index filename both come from the declaration; the
            -- literal 'lua/' used to sit here as a second copy of package_root,
            -- which the rule-consumption audit cannot catch (the field IS read —
            -- just somewhere else)
            local pre = PKGROOT .. '/'
            for _, cand in ipairs({ pre .. slashed .. '.lua',
                pre .. slashed .. '/' .. (NVIMIDX or 'init.lua') }) do
                if files[cand] then return cand end
            end
        end
        -- FACTORIO-ONLY semantics (stock lua require is package.path
        -- based — dir-relative matching elsewhere would be a GUESS,
        -- exactly what the self oracle exists to confirm instead; the
        -- self_spec caught the over-reach): factorio resolves requires
        -- relative to the CURRENT FILE's directory (bnw's
        -- migrations/lib/ is the proof), and in a multi-project root
        -- the project dir prefixes mod-root-relative requires (SE's
        -- require("scripts.zone") = space-exploration/scripts/zone.lua)
        if from and type(root) == 'string'
            and next(factorio_mods(root, files)) then
            local dir = from:match('^(.*)/[^/]*$')
            local pre = from:match('^([^/]+)/')
            local tries = {}
            if dir then
                tries[#tries + 1] = dir .. '/' .. slashed .. '.lua'
                tries[#tries + 1] = dir .. '/' .. slashed .. '/init.lua'
            end
            if pre and pre ~= dir then
                tries[#tries + 1] = pre .. '/' .. slashed .. '.lua'
                tries[#tries + 1] = pre .. '/' .. slashed .. '/init.lua'
            end
            for _, cand in ipairs(tries) do
                if files[cand] then return cand end
            end
        end
        -- factorio cross-mod require: __name__/path or __name__.dotted
        -- — the DECLARED cross-project import (cross-project layer 1).
        -- The FORM comes from the ecosystem spec, not a second copy of it: this
        -- line held an inline duplicate of require_form.pattern, which
        -- tools/specaudit.lua flagged as a declared rule nothing reads. The
        -- target dir comes from manifest identity; __base__/__core__ (engine
        -- data, not in corpus) stay unresolved, honest.
        -- NB `local a, b = cond and f()` truncates f() to ONE value, so the
        -- guard cannot live in the expression — `rest` would always be nil
        local mn, rest
        if REQFORM then mn, rest = mod:match(REQFORM.pattern) end
        if mn and type(root) == 'string' then
            local dir = factorio_mods(root, files)[mn]
            if dir then
                local pre = dir == '' and '' or dir .. '/'
                local rs = rest:gsub('%.', '/')
                for _, cand in ipairs({ pre .. rest, pre .. rs .. '.lua',
                    pre .. rs .. '/init.lua' }) do
                    if files[cand] then return cand end
                end
            end
        end
    end,
    -- which LOCAL names this import: `local util = require 'x'`
    -- binds util (positional in multi-assignments; nil when unclear)
    import_bind = function (calln, src)
        local el = calln:parent()
        if not el or el:type() ~= 'expression_list' then return nil end
        local as = el:parent()
        if not as or as:type() ~= 'assignment_statement' then return nil end
        local vl
        for _, c in inext, as, -1 do
            if c:type() == 'variable_list' then vl = c break end
        end
        if not vl then return nil end
        local vi, i = 0, 0
        for _, c in inext, el, -1 do
            if c:named() then
                i = i + 1
                if c:equal(calln) then vi = i end
            end
        end
        i = 0
        for _, c in inext, vl, -1 do
            if c:named() then
                i = i + 1
                if i == vi then
                    local n = node_text(c, src)
                    return n:match('^[%w_]+$') and n or nil
                end
            end
        end
    end,
    -- what a NEW import of `dest` looks like here, and the alias it
    -- introduces — the write side of the wiring the verbs disclose
    import_line = function (dest)
        local mod = dest:gsub('%.lua$', ''):gsub('/init$', ''):gsub('/', '.')
        local alias = dest:match('([%w_]+)%.lua$')
        if alias == 'init' then alias = dest:match('([%w_]+)/init%.lua$') end
        if not alias then return nil end
        return ('local %s = require \'%s\''):format(alias, mod), alias
    end,
    -- lines that ARE imports (placement: a new one goes after the last)
    import_pats = { '^local%s+[%w_,%s]-=%s*require%f[%W]', '^require%f[%W]' },
    litdata_types = { table_constructor = true },
    -- stdlib receivers must not tail-match a project def: string.format
    -- would otherwise link to the one module that defines M.format
    stdlib_prefixes = { 'string.', 'table.', 'math.', 'os.', 'io.',
        'coroutine.', 'debug.', 'bit.', 'jit.', 'ffi.', 'vim.' },
    -- load-time side effects (ported from the retired lua-ls --graph
    -- CLI): assigning a global, mutating a global-rooted table
    -- (function table.x() included), or a bare call at the top
    -- level. Feeds sideeffect-vs-deadimport classification and the
    -- move verbs' load-order hazard.
    module_effects = function (root, src)
        local locals = {}
        local function collect_names(vl)
            for _, v in inext, vl, -1 do
                if v:named() then
                    local n = node_text(v, src)
                    locals[n:match('^[%w_]+') or n] = true
                end
            end
        end
        for _, stmt in inext, root, -1 do
            local t = stmt:type()
            if t == 'variable_declaration' then
                for _, c in inext, stmt, -1 do
                    if c:type() == 'assignment_statement' then
                        for _, vl in inext, c, -1 do
                            if vl:type() == 'variable_list' then
                                collect_names(vl)
                            end
                        end
                    end
                end
            elseif t == 'function_declaration' then
                local islocal = false
                for _, c in inext, stmt, -1 do
                    if c:type() == 'local' then islocal = true end
                end
                if islocal then
                    local nm = stmt:field('name')[1]
                    if nm then
                        locals[node_text(nm, src)] = true
                    end
                end
            end
        end
        for _, stmt in inext, root, -1 do
            local t = stmt:type()
            if t == 'function_call' then
                return true -- a bare call runs at load time
            elseif t == 'assignment_statement' then
                for _, vl in inext, stmt, -1 do
                    if vl:type() == 'variable_list' then
                        for _, v in inext, vl, -1 do
                            if v:named() then
                                local rootname = node_text(v, src):match('^[%w_]+')
                                if rootname and not locals[rootname] then
                                    return true -- global(-rooted) write
                                end
                            end
                        end
                    end
                end
            elseif t == 'function_declaration' then
                local islocal = false
                for _, c in inext, stmt, -1 do
                    if c:type() == 'local' then islocal = true end
                end
                if not islocal then
                    local nm = stmt:field('name')[1]
                    local rootname = nm and node_text(nm, src):match('^[%w_]+')
                    if rootname and not locals[rootname] then
                        return true -- global fn / global-rooted method
                    end
                end
            end
        end
    end,
}
