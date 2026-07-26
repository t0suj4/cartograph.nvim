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
local IDENT = (function ()
    local eco = require('cartograph.spec.ecosystem').load('lua-factorio')
    return eco and eco.identity or nil
end)()

local FMODS = {}
local function factorio_mods(root, files)
    local map = FMODS[root]
    if map then return map end
    map = {}
    if not IDENT then return map end -- no spec, no claim (never a guessed rule)
    local segs = { [''] = true }
    for f in pairs(files) do
        local seg = f:match('^([^/]+)/')
        if seg then segs[seg] = true end
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
    FMODS[root] = map
    return map
end

-- nvim-plugin REPO SHAPE (a 3rd per-root detector, still EMBEDDED INLINE beside
-- factorio_mods/toc_scope — the scattered cluster the resolution-health
-- analyzer's rule 3 [scattered-special-case finder] should detect as one
-- missing-abstraction; see [[cartograph-cross-project]] repo shapes).
-- STATUS: the abstraction now EXISTS — spec/ecosystem/ is that axis, and
-- factorio's half of the cluster has moved into it (identity + manifest name are
-- declared there, no longer restated here). These two are the remaining collapse:
-- a wow-addon ecosystem (manifest = <Addon>/<Addon>.toc) and an nvim-plugin one
-- (package root = lua/). Deliberately NOT moved in the same change — both feed
-- resolution BOUNDARIES that the wow and self corpora exercise, so they want
-- their own gate run. An nvim
-- plugin puts its package under `lua/` (`require 'foo.bar'` → lua/foo/bar.lua), so
-- `lua/` is the package root. MARKER-GATED (fires only when a lua/ layout is
-- present), NOT the reverted blind dir-relative guess. Memoized per root.
local NLROOT = {}
local function nvim_lua_root(root, files)
    local v = NLROOT[root]
    if v ~= nil then return v end
    v = false
    for f in pairs(files) do
        if f:match('^lua/.+%.lua$') then v = true; break end
    end
    NLROOT[root] = v
    return v
end

-- WoW-addon boundary detection, memoized per (root, top segment): an
-- addon tree is <root>/<Addon>/<Addon>.toc (or any *.toc in the dir).
local TOC_DIR = {}
local function toc_scope(file, _, root)
    local seg = file:match('^([^/]+)/')
    -- multi-root corpora (self://) pass a table root: never an addon tree
    if not seg or type(root) ~= 'string' then return '' end
    local key = root .. '\31' .. seg
    local hit = TOC_DIR[key]
    if hit == nil then
        local dir = root .. '/' .. seg
        hit = vim.uv.fs_stat(dir .. '/' .. seg .. '.toc') ~= nil
            -- factorio mods folder: the package MANIFEST is the marker. The
            -- name comes from the ecosystem spec, not a second literal — this was
            -- the duplicate copy of the fact that made the cluster below a
            -- scattering rather than three unrelated detectors.
            or (IDENT ~= nil
                and vim.uv.fs_stat(dir .. '/' .. IDENT.manifest) ~= nil)
        if not hit then
            local it = vim.uv.fs_scandir(dir)
            while it do
                local name = vim.uv.fs_scandir_next(it)
                if not name then break end
                if name:sub(-4) == '.toc' then hit = true break end
            end
        end
        TOC_DIR[key] = hit
    end
    return hit and seg or ''
end

return {
    exts = { 'lua' },
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
        if type(root) == 'string' and nvim_lua_root(root, files) then
            for _, cand in ipairs({ 'lua/' .. slashed .. '.lua', 'lua/' .. slashed .. '/init.lua' }) do
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
        -- The target dir comes from info.json identity; __base__/
        -- __core__ (engine data, not in corpus) stay unresolved, honest.
        local mn, rest = mod:match('^__([%w%-_]+)__[./](.+)$')
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
