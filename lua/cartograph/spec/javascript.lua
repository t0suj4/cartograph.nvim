-- The JAVASCRIPT language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs javascript typescript tsx
-- NOT just javascript, despite the filename: treesitter.lua derives the typescript
-- and tsx specs FROM this one (`M.spec.typescript = tbl_extend({}, M.spec.javascript)`),
-- so it deliberately names TS-only nodes such as `public_field_definition`. The audit
-- found that by flagging exactly that comparison against a javascript-only claim —
-- the file's real language set was wider than its name and nothing said so.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text

-- ONE owner for "what is a function scope here" — the spec field below and the
-- local-shadow walk inside `local_decls` both read this. They were two separate
-- literals that happened to agree; a set with two copies is a set that will
-- eventually disagree with itself (CART-0306). The generator forms are new:
-- omitting them made a node inside `function* g(){}` resolve to the OUTER
-- function, which is simply the wrong answer.
local FN_TYPES = {
    function_declaration = true, method_definition = true,
    arrow_function = true, function_expression = true,
    generator_function = true, generator_function_declaration = true,
}

return {
        exts = { 'js', 'mjs', 'cjs', 'jsx' }, -- the JS grammar handles JSX
        -- BINDER NODES: see spec/lua.lua. `for (const g of t)` binds g as a direct
        -- identifier child; a classic `for` binds inside its initializer.
        binders = {
            { node = 'for_in_statement' },
            { node = 'for_statement', child = 'lexical_declaration' },
        },
        -- MEMBER-TARGET FUNCTION LITERALS. MEASURED (tools/assigndef.lua):
        -- `X.y = function(){}` minted NOTHING, while the declarator form
        -- (`const f = function(){}`) and the prototype form both did — worth 6.4% of
        -- jquery's unresolved calls and 1.9% of ghost's (jQuery.extend,
        -- jQuery.Callbacks, opt.complete). Lua has always minted the same shape
        -- (`M.f = function() end`), so this closes a gap BETWEEN TWO FRONT ENDS rather
        -- than adding a new kind of claim, and it is no more aggressive than the
        -- object-literal `pair` patterns already here (`{ complete: () => {} }` mints
        -- a bare `complete`; the assignment form at least carries its receiver).
        -- ONE pattern now serves the prototype case too: the collapse
        -- (`X.prototype.m` -> `X.m`) lives in qualify and keys on the literal
        -- `.prototype.` in the name, so the old `#eq? @_pp "prototype"` gate is no
        -- longer what distinguishes the two forms.
        -- Note a CHAINED assignment (`a.b = c.d = function(){}`) still mints only the
        -- INNERMOST name: the outer right-hand side is an assignment_expression, not a
        -- function. jQuery's `jQuery.extend = jQuery.fn.extend = function(){}` is that
        -- shape, so `jQuery.fn.extend` is minted and `jQuery.extend` is not — one def
        -- per function NODE, which is the constraint that keeps a def a fact.
        functions = [=[
            (function_declaration name: (identifier) @name) @def
            (method_definition name: (property_identifier) @name) @def
            (variable_declarator name: (identifier) @name value: (arrow_function) @def)
            (variable_declarator name: (identifier) @name value: (function_expression) @def)
            (pair key: (property_identifier) @name value: (arrow_function) @def)
            (pair key: (property_identifier) @name value: (function_expression) @def)
            (arguments (arrow_function) @adef)
            (arguments (function_expression) @adef)
            ; ANY member target, not just X.prototype.m — see the note above the field
            (assignment_expression
                left: (member_expression) @name
                right: (function_expression) @def)
            (assignment_expression
                left: (member_expression) @name
                right: (arrow_function) @def)
        ]=],
        calls = [=[
            (call_expression function: (identifier) @name) @call
            (call_expression function: (member_expression) @name) @call
        ]=],
        vars = [=[
            (program (lexical_declaration
                (variable_declarator name: (identifier) @vname value: (_) @value) @vdef))
            (program (variable_declaration
                (variable_declarator name: (identifier) @vname value: (_) @value) @vdef))
        ]=],
        -- V2 ctor-typing: `const o = new C(...)` (ANYWHERE, incl. in-function)
        -- binds o to class C; resolve_local_ctor types o.member → C.member. The
        -- callee stored is the bare class C (not lua's `C.new` convention) → the
        -- JS cut in resolve_local_ctor keys on is_class[callee] directly.
        ctor_query = [=[
            (variable_declarator name: (identifier) @cvar
                value: (new_expression constructor: (identifier) @cctor))
            (assignment_expression left: (identifier) @cvar
                right: (new_expression constructor: (identifier) @cctor))
        ]=],
        -- THE LOCALITY VETO for the member-target pattern above. `X.y = function(){}`
        -- is a definition worth naming when X is a module namespace (`jQuery.param`,
        -- `module.exports.x`) and JUNK when X is a function-local object: MEASURED on
        -- jquery, `opt.complete = function(){}` inside jQuery.speed minted a def whose
        -- tail then answered every bare `complete()` callback call in the corpus —
        -- four confident wrong resolutions replacing four honest refusals.
        -- A query cannot ask this, so the spec does: is the receiver's ROOT bound as a
        -- parameter or a local declaration in an enclosing function?
        -- `this.x = …` is deliberately NOT vetoed — it is the pre-class instance-method
        -- form, and its receiver is not a local binding.
        skip_def = function (defn, _, src)
            local asg = defn:parent()
            if not (asg and asg:type() == 'assignment_expression') then return false end
            local lhs = asg:field('left')[1]
            if not (lhs and lhs:type() == 'member_expression') then return false end
            -- NEVER veto the prototype form. It minted before this veto existed, and a
            -- prototype assignment defines a CLASS method however its constructor
            -- variable is scoped (`var K = function(){}; K.prototype.m = …` inside a
            -- module closure is the normal pre-ES6 idiom). Without this the veto
            -- REMOVED 62 pre-existing defs on ghost and 4 on mootools — a change that
            -- is supposed to be purely additive.
            if node_text(lhs, src):find('%.prototype%.') then return false end
            -- the receiver ROOT: the leftmost identifier of the member chain
            local root = lhs
            while root and root:type() == 'member_expression' do
                root = root:field('object')[1]
            end
            -- `this.x = function(){}` is vetoed too. It IS the pre-class instance-method
            -- idiom, but the def name `this.x` names no owner — it is a key nothing can
            -- match on purpose, and its TAIL then answers unrelated calls. MEASURED on
            -- mootools: `this.$each = function(){}` has tail `each` (a `$` is not a word
            -- character), so it captured bare `each(…)` calls corpus-wide. Naming these
            -- properly needs the enclosing constructor's name — a separate piece of work.
            if root and root:type() == 'this' then return true end
            if not (root and root:type() == 'identifier') then return false end
            local want = node_text(root, src)
            local fn_types = FN_TYPES
            -- A POSITIONAL IDENTIFIER PARAMETER IS NOT TREATED AS LOCAL, which
            -- fn_locals already argues for the local-shadow gate: in the AMD/IIFE shape
            -- every pre-ES6 library uses, `define(["./core"], function (jQuery) { … })`
            -- passes the namespace itself as a positional parameter. Vetoing those
            -- removed 36 of jquery's 52 new defs — the whole `jQuery.*` surface, i.e.
            -- most of the measured value. A DESTRUCTURED param has no such reading and
            -- is vetoed below.
            local seen_fn = false
            local up = asg:parent()
            while up do
                if fn_types[up:type()] then
                    seen_fn = true
                    local ps = up:field('parameters')[1]
                    if ps then
                        for p in ps:iter_children() do
                            local pt = p:type()
                            if (pt == 'object_pattern' or pt == 'array_pattern')
                                and node_text(p, src):find(
                                    '%f[%w_]' .. want .. '%f[^%w_]') then
                                return true
                            end
                        end
                    end
                end
                up = up:parent()
            end
            if not seen_fn then return false end -- top level: not a local
            -- a local DECLARATION (`var opt = …` / `const o = {}`) anywhere in an
            -- enclosing function body. Scanning the enclosing function's TEXT for a
            -- declaration of that name is deliberately coarse in the SAFE direction:
            -- a false "local" only withholds a def, never invents one.
            -- a local DECLARATION in an enclosing function. STRUCTURAL, not a text
            -- scan: a scan for `var <name>` misses every declarator after the first in
            -- a comma-separated list, which is how jquery declares most of its locals
            -- (`var opts = …, hooks, oldfire`) — it let `hooks.empty.fire`,
            -- `elemData.handle` and `xhr.onreadystatechange` through on the first try.
            local function declares(fnnode)
                local body = fnnode:field('body')[1]
                if not body then return false end
                local found = false
                local function walk(n)
                    if found then return end
                    for c in n:iter_children() do
                        if found then return end
                        if c:named() then
                            local ct = c:type()
                            if fn_types[ct] then -- a nested fn: its own scope
                            elseif ct == 'variable_declaration'
                                or ct == 'lexical_declaration' then
                                for d in c:iter_children() do
                                    if d:type() == 'variable_declarator' then
                                        local nm = d:field('name')[1]
                                        -- destructuring binds several names; any
                                        -- identifier leaf counts
                                        if nm and node_text(nm, src):find(
                                            '%f[%w_]' .. want .. '%f[^%w_]') then
                                            found = true; return
                                        end
                                    end
                                end
                            else walk(c) end
                        end
                    end
                end
                walk(body)
                return found
            end
            up = asg:parent()
            while up do
                if fn_types[up:type()] and declares(up) then return true end
                up = up:parent()
            end
            return false
        end,
        params_field = 'parameters',
        body_field = 'body',
        fn_types = FN_TYPES,
        -- ── DYNAMIC DISPATCH: THE MEMBER IS RUNTIME STATE (CART-0345/0344) ──
        -- `obj[k]()` selects its callee at run time — the `dynamic` rung, "a call the
        -- graph KNOWS IT CANNOT SEE", which is a different fact from `frontier`
        -- ("we failed to resolve"). Undeclared here until now, so every such call
        -- landed in frontier and any measurement of dynamic dispatch on a javascript
        -- corpus would have reported it as absent.
        -- ★ A LITERAL KEY IS NOT DYNAMIC: `obj["lit"]()` names its member in
        -- the source, and claiming we cannot see it would be a false negative
        -- FACT. Node names verified by parsing a snippet per grammar, not guessed.
        dynamic_callee_types = { subscript_expression = true },
        dynamic_callee_static_key = { string = true, number = true },
        -- ★ "MINTED" HAS TO MEAN *ALWAYS* MINTED, NOT SOMETIMES. The generator
        -- forms are never captured by the `functions` query above. But
        -- `function_expression` is worse than never — it is CONDITIONAL: minted
        -- as a variable_declarator value, a pair value, an `arguments` child or
        -- an assignment_expression right, and NOT minted anywhere else. The
        -- position that matters is the IIFE, `(function(){ … })()`, which is
        -- what jquery and ghost are built out of. Treating it as a flow stop
        -- deleted every IIFE body's rows: dfgate ghost 6986 -> 28406.
        -- A conditionally-minted type must be listed here, because the cost of
        -- being wrong is DELETED rows and the cost of being conservative is only
        -- the pre-existing over-collection into the enclosing function (CART-0308).
        -- `method_definition` goes the same way, for the same reason one step
        -- down: the query names `name: (property_identifier)`, so a `#private`
        -- or `[computed]` method is not minted. Ghost kept +440 divergences over
        -- its baseline until this was listed; jquery and mootools are pre-ES6 and
        -- had already returned to their EXACT pinned counts, which is what showed
        -- the residual was method_definition and nothing else.
        --
        -- ★★ SO JAVASCRIPT GAINS NO STOP AT ALL, and that is the honest outcome
        -- rather than a failure: this query is POSITIONAL — it mints a function by
        -- where it SITS, not by what it IS — so no js scope type is unconditionally
        -- minted except `function_declaration`, which LEGACY already stops at. A
        -- language whose def query is positional cannot support scope stops until
        -- the query does (CART-0313). The measurable win here is ruby, rust and
        -- odin, whose `method`/`function_item`/`procedure_declaration` always are.
        fn_unminted = { generator_function = true,
            generator_function_declaration = true, function_expression = true,
            method_definition = true },
        is_method = function (_, def) return def:type() == 'method_definition' end,
        -- ES6 methods carry their class: `class C { m(){} }` -> `C.m` (the JS
        -- analog of lua `C:m` / php `C::m`). A method_definition is a class
        -- member IFF its DIRECT parent is class_body — object-literal methods
        -- (`{ m(){} }`, incl. ones nested inside a class method) parent an
        -- `object`, so they stay bare, never falsely borrowing an outer class.
        -- `.` separator: aligns the key with how methods are called (obj.m),
        -- so a `ClassName.m()` reference exact-matches, while the tail index
        -- ([%w_]+$ -> `m`) still catches the unqualified `x.m()` receiver calls.
        -- Anonymous class expressions borrow their binding variable's name
        -- (`const C = class {…}`); a truly nameless class leaves methods bare.
        qualify = function (name, defn, src)
            -- pre-ES6 prototype method (pivot B4): `X.prototype.m = function` is
            -- captured with @name = the whole LHS `X.prototype.m`; collapse to the
            -- class key `X.m` (the same shape B1 gives ES6 methods, so B3
            -- this-typing / resolve_super treat a prototype "class" identically).
            -- `A.B.prototype.m` → `A.B.m`. The query's #eq? "prototype" gate means
            -- only genuine prototype assignments reach here in this form.
            local powner, pmethod = name:match('^(.+)%.prototype%.([%w_]+)$')
            if powner then return powner .. '.' .. pmethod end
            local body = defn:parent()
            -- field-arrow (`class C { m = () => {} }`): the fn's parent is the
            -- field def, whose parent is class_body — unwrap so C.m keys like a method.
            if body and (body:type() == 'field_definition'
                or body:type() == 'public_field_definition') then
                body = body:parent()
            end
            if not (body and body:type() == 'class_body') then return name end
            local cls = body:parent()
            if not cls then return name end
            local nm = cls:field('name')[1]
            local owner = nm and node_text(nm, src)
            if not owner and cls:type() == 'class' then
                local par = cls:parent() -- `const C = class {…}`
                if par and par:type() == 'variable_declarator' then
                    local vn = par:field('name')[1]
                    owner = vn and node_text(vn, src)
                end
            end
            return owner and (owner .. '.' .. name) or name
        end,
        -- in-function local declarations, for fn_locals (the local-shadow gate);
        -- df doesn't track JS locals so the destructured `const [x,setX]=…` hook
        -- setters would name-match a global without this.
        local_decls = { lexical_declaration = true, variable_declaration = true },
        stdlib_prefixes = { 'console.', 'JSON.', 'Object.', 'Array.', 'Math.',
            'Promise.', 'window.', 'document.', 'chrome.' },
        -- the WORKSPACE PACKAGE (nearest package.json ancestor) scopes
        -- bare names: monorepo packages import across, never leak across
        scope = function (file, _, root)
            if not root then return '' end
            local dir = file:match('^(.*)/[^/]*$') or ''
            while dir ~= '' do
                if vim.uv.fs_stat(root .. '/' .. dir .. '/package.json') then
                    return dir
                end
                dir = dir:match('^(.*)/[^/]*$') or ''
            end
            return ''
        end,
        -- dom/framework vocabulary
        stdlib_names = { getAttribute = true, setAttribute = true,
            addEventListener = true, removeEventListener = true,
            querySelector = true, querySelectorAll = true,
            createElement = true, appendChild = true, dispatch = true,
            subscribe = true, push = true, pop = true, shift = true,
            slice = true, splice = true, join = true, split = true,
            filter = true, map = true, forEach = true, reduce = true,
            find = true, includes = true, indexOf = true, replace = true,
            trim = true, toString = true, concat = true, keys = true,
            values = true, entries = true, assign = true, freeze = true,
            stringify = true, parse = true, emit = true, on = true,
            off = true, once = true, get = true, set = true, has = true,
            add = true, delete = true, clear = true, next = true,
            startsWith = true, endsWith = true, some = true, every = true,
            sort = true, reverse = true, flat = true, substring = true,
            toLowerCase = true, toUpperCase = true, padStart = true,
            charAt = true,
            ['$emit'] = true, ['$on'] = true, ['$nextTick'] = true },
        litdata_types = { object = true, array = true },
        -- ESM imports + CommonJS require + dynamic import(). require/import
        -- match ONLY a lone string literal argument — computed paths stay
        -- unresolved (honest frontier, not a guess). Predicates demand
        -- iter_matches in the consumer (iter_captures ignores #eq?).
        -- @bind is the LOCAL NAME an import introduces, which is what lets a call
        -- through that name be attributed to the imported file (resolve_module_alias,
        -- and the `unread-file` disposition for a call into an opaque bundle). Only
        -- SINGLE-bind forms are captured: a default import, a namespace import, and
        -- CommonJS `const x = require(...)`. NAMED imports (`import {a, b}`) bind
        -- several names to one edge and the edge carries one `bind`, so they stay
        -- uncaptured rather than being represented wrongly — a deliberate gap, not
        -- an oversight.
        --
        -- Several patterns can match ONE import site (a namespace import matches the
        -- general form too, and a CJS require matches both the declaration and the
        -- bare-call form). The consumer dedupes on the @path NODE, so the edge set is
        -- exactly what it was before binds existed; only the bind is added.
        import_query = [=[
            (import_statement
                (import_clause [
                    (identifier) @bind
                    (namespace_import (identifier) @bind)
                ])?
                source: (string) @path)
            (lexical_declaration (variable_declarator
                name: (identifier) @bind
                value: (call_expression
                    function: (identifier) @_rq (#eq? @_rq "require")
                    arguments: (arguments . (string) @path .))))
            (call_expression
                function: (identifier) @_fn (#eq? @_fn "require")
                arguments: (arguments . (string) @path .))
            (call_expression
                function: (import)
                arguments: (arguments . (string) @path .))
        ]=],
        resolve_import = function (path, files, from)
            path = path:gsub('^["\']', ''):gsub('["\']$', '')
            local function norm(p) -- ./ and ../ segments
                local parts = {}
                for seg in p:gmatch('[^/]+') do
                    if seg == '..' then parts[#parts] = nil
                    elseif seg ~= '.' then parts[#parts + 1] = seg end
                end
                return table.concat(parts, '/')
            end
            local function try(cand)
                cand = norm(cand)
                for _, c in ipairs({ cand, cand .. '.js', cand .. '.ts',
                    (cand:gsub('%.js$', '.ts')),
                    cand .. '/index.js', cand .. '/index.ts' }) do
                    if files[c] then return c end
                end
            end
            local dir = from:match('^(.*)/[^/]*$')
            if path:match('^[@~]/') then
                -- bundler alias ('@/x', '~/x'): the package's src/ (vite)
                -- or the app root itself (nuxt). The package.json isn't in
                -- the fileset, so walk ancestors and let existence decide
                local x = path:sub(3)
                local anc = dir
                while anc do
                    local hit = try(anc .. '/src/' .. x) or try(anc .. '/' .. x)
                    if hit then return hit end
                    anc = anc:match('^(.*)/[^/]*$')
                end
                return try('src/' .. x) or try(x)
            end
            return try(dir and (dir .. '/' .. path) or path)
        end,
}
