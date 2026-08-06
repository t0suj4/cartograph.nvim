-- The JAVA language spec + its helpers, extracted via the move-set flow
-- ([[cartograph-spec-layering]]) — the LAST inline spec, and the only one that
-- wasn't clean motion. Three wrinkles the tool disclosed:
--   1. java_var_type read the engine's ambient scope-model state (jvt_sm). The
--      generic scope-model cache (tree_model/jvt_sm) STAYS in the engine (it
--      drives df-binder tags for every scoped language); here java_var_type
--      takes the model as an explicit PARAM, and the engine threads it through
--      the qualify_call protocol (a backwards-compatible 4th arg other specs
--      ignore). No ambient coupling, no require cycle.
--   2. Three symbols are consumed by the ENGINE resolver, not the entry
--      (JAVA_JDK_TYPES also by the entry, JAVA_SERVICE_MARKERS + java_bean_name
--      only by it): exposed as `_`-prefixed fields on the returned table (the
--      capability contract skips `_` fields), and the engine reads them back
--      via require 'cartograph.spec.java'.
--   3. NOOP is the trivial engine empty-iterator idiom, copied local.
-- node_text/inext are the shared tsutil deps. Behaviour-identical.

-- @langs java — a spec IS one grammar's mapping, so every node type here is
-- java's by construction.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text
local inext = tsutil.inext

-- shared empty iterator (the `... or NOOP` nil-children fallback)
local function NOOP() end

-- Java receiver typing. Unlike php's `$var` (untyped), Java DECLARES the type
-- of every receiver lexically, so a call's receiver often resolves to a
-- concrete class by a bounded lexical lookup — no flow analysis, no server.
-- The base name of a type node: `List<Pet>` -> List, `a.b.Foo` -> Foo.
local function java_base_type(tnode, src)
    if not tnode then return nil end
    local t = tnode:type()
    if t == 'type_identifier' then
        return node_text(tnode, src)
    elseif t == 'generic_type' then
        local first = tnode:child(0) -- the erased base precedes type_arguments
        if first and first:type() == 'type_identifier' then
            return node_text(first, src)
        end
    elseif t == 'scoped_type_identifier' then
        return node_text(tnode, src):match('([%w_]+)%s*$')
    end
    return nil
end

-- JDK types whose methods are stdlib vocabulary, not project defs: a
-- receiver of this type must NOT be qualified (Optional::get would tail-match
-- a project get()). Best-effort — the common collection/util/lang surface.
local JAVA_JDK_TYPES = {}
for _, t in ipairs({ 'String', 'StringBuilder', 'StringBuffer', 'CharSequence',
    'Object', 'Class', 'Integer', 'Long', 'Double', 'Float', 'Boolean', 'Byte',
    'Short', 'Character', 'Number', 'Math', 'System', 'Thread', 'Optional',
    'List', 'ArrayList', 'LinkedList', 'Map', 'HashMap', 'TreeMap',
    'LinkedHashMap', 'Set', 'HashSet', 'TreeSet', 'LinkedHashSet', 'Collection',
    'Collections', 'Arrays', 'Iterator', 'Iterable', 'Stream', 'Queue',
    'Deque', 'Stack', 'File', 'Path', 'Paths', 'Files', 'Date', 'Calendar',
    'LocalDate', 'LocalDateTime', 'Instant', 'Duration', 'BigDecimal',
    'BigInteger', 'Pattern', 'Matcher', 'Objects', 'Comparator' }) do
    JAVA_JDK_TYPES[t] = true
end

-- the enclosing class/interface/enum/record: its name + declaration node
local function java_enclosing_class(node, src)
    local p = node:parent()
    while p do
        local t = p:type()
        if t == 'class_declaration' or t == 'interface_declaration'
            or t == 'enum_declaration' or t == 'record_declaration' then
            local cn = p:field('name')[1]
            return cn and node_text(cn, src) or nil, p
        end
        p = p:parent()
    end
end

-- Spring stereotype annotations: a class carrying one is a DI-managed BEAN.
-- Only beans count as interface→impl candidates in resolve_interface — an
-- unannotated implementor is never wired, so it must not inflate the candidate
-- set to a false ambiguity (the negative/spring-di `StorePlain` guard).
local JAVA_STEREOTYPES = {}
for _, a in ipairs({ 'Service', 'Component', 'Repository', 'Controller',
    'RestController', 'Configuration' }) do JAVA_STEREOTYPES[a] = true end
-- SERVICE-LOCATOR marker interfaces (metasfresh/adempiere `Services.get(
-- IFoo.class)` idiom): an interface transitively extending one of these is a
-- registry service — its receiver holds the single registered impl, so
-- resolve_interface resolves it to its unique implementer WITHOUT bean-gating
-- (the marker certifies a fat, single-impl service, so the no-lambda-impls
-- assumption holds). Absent in a codebase → the gate is simply inert. Framework
-- config; extend per-project later.
local JAVA_SERVICE_MARKERS = {}
for _, a in ipairs({ 'ISingletonService', 'IMultitonService', 'IService' }) do
    JAVA_SERVICE_MARKERS[a] = true
end
-- the first positional string argument of an annotation (@Service("x") → "x"),
-- or nil. Positional form only — the `@Service(value="x")` element-pair form is
-- rare and falls back to the default name (sound: a missed explicit name just
-- means the default-name path decides).
local function anno_str_arg(anno, src)
    local args = anno:field('arguments')[1]
    if not args then return nil end
    for _, a in inext, args, -1 do
        if a:type() == 'string_literal' then
            local s = node_text(a, src):gsub('^["\']', ''):gsub('["\']$', '')
            if s ~= '' then return s end
        end
    end
    return nil
end
-- a class's bean identity: its explicit @Service("name") arg, else `true` for a
-- default-named bean (name = decapitalized class name, computed at match time),
-- else nil if not a bean. Only beans are interface-impl candidates.
local function java_bean_name(decln, src)
    local mods = decln:child(0)
    if not (mods and mods:type() == 'modifiers') then return nil end
    for _, c in inext, mods, -1 do
        local t = c:type()
        if t == 'marker_annotation' or t == 'annotation' then
            local nm = c:field('name')[1]
            local name = nm and node_text(nm, src) or ''
            name = name:match('([%w_]+)%s*$') or name -- tail of a scoped name
            if JAVA_STEREOTYPES[name] then
                return (t == 'annotation' and anno_str_arg(c, src)) or true
            end
        end
    end
    return nil
end
-- the @Qualifier("bean") bean name on the field named `fieldname` in the class
-- enclosing `calln`, or nil. Bounded walk over the enclosing class's own field
-- declarations — the qualifier disambiguates which of an interface's several
-- impls this receiver holds (resolve_interface consumes it).
local function java_field_qualifier(calln, fieldname, src)
    local _, cnode = java_enclosing_class(calln, src)
    local body = cnode and cnode:field('body')[1]
    if not body then return nil end
    for _, fd in inext, body, -1 do
        if fd:type() == 'field_declaration' then
            local declares = false
            for _, ch in inext, fd, -1 do
                if ch:type() == 'variable_declarator' then
                    local dn = ch:field('name')[1]
                    if dn and node_text(dn, src) == fieldname then
                        declares = true; break
                    end
                end
            end
            if declares then
                local mods = fd:child(0)
                if mods and mods:type() == 'modifiers' then
                    for _, an in inext, mods, -1 do
                        if an:type() == 'annotation' then
                            local nm = an:field('name')[1]
                            if nm and node_text(nm, src):match('([%w_]+)%s*$') == 'Qualifier' then
                                return anno_str_arg(an, src)
                            end
                        end
                    end
                end
                return nil -- the field is here, but carries no qualifier
            end
        end
    end
    return nil
end

-- Java scope spec for the ScopeModel (cartograph.scope): which node types
-- open scopes and how to harvest their binders. This IS the old memoized
-- jvt_scope_sym, expressed as data + three harvesters; the model owns the
-- lazy per-scope memo (profiling: the per-call AST re-walk this replaces was
-- ~35% of extraction).
local function jvt_locals(node, src, out) -- name -> {ty, row} (position-checked)
    for _, c in inext, node, -1 do
        if c:type() == 'local_variable_declaration' then
            local ty, row = java_base_type(c:field('type')[1], src), select(1, c:range())
            if ty == 'var' then ty = nil end -- `var x = ...`: no declared name
            for _, d in inext, c, -1 do
                if d:type() == 'variable_declarator' then
                    local nm = d:field('name')[1]
                    if nm then
                        local b = { ty = ty, row = row }
                        if ty == nil then
                            -- typed only by the INITIALIZER: `new Foo()`
                            -- names the type right here; a call's return
                            -- type is knowable only after resolution, so
                            -- record the call site as INIT PROVENANCE for
                            -- the return-type rounds (graph-VM MVP)
                            local v = d:field('value')[1]
                            local vt = v and v:type()
                            if vt == 'object_creation_expression' then
                                b.ty = java_base_type(v:field('type')[1], src)
                            elseif vt == 'method_invocation' then
                                local vn = v:field('name')[1]
                                if vn then
                                    local r2, c2 = vn:range()
                                    b.init = { r = r2, c = c2 }
                                end
                            end
                        end
                        out[node_text(nm, src)] = b
                    end
                end
            end
        end
    end
end
local function jvt_params(node, src, out) -- name -> {ty}
    local ps = node:field('parameters')[1]
    for _, c in (ps and inext or NOOP), ps, -1 do
        if c:type() == 'formal_parameter' or c:type() == 'spread_parameter' then
            local nm = c:field('name')[1]
            if nm then out[node_text(nm, src)] = { ty = java_base_type(c:field('type')[1], src) } end
        end
    end
end
local function jvt_fields(node, src, out) -- name -> {ty}
    for _, c in inext, node, -1 do
        if c:type() == 'field_declaration' then
            local ty = java_base_type(c:field('type')[1], src)
            for _, d in inext, c, -1 do
                if d:type() == 'variable_declarator' then
                    local nm = d:field('name')[1]
                    if nm then out[node_text(nm, src)] = { ty = ty } end
                end
            end
        end
    end
end
local JAVA_SCOPES = {
    block                   = { kind = 'local', harvest = jvt_locals },
    constructor_body        = { kind = 'local', harvest = jvt_locals },
    method_declaration      = { kind = 'param', harvest = jvt_params },
    constructor_declaration = { kind = 'param', harvest = jvt_params },
    lambda_expression       = { kind = 'param', harvest = jvt_params },
    class_body              = { kind = 'field', harvest = jvt_fields },
    enum_body               = { kind = 'field', harvest = jvt_fields },
}

-- the declared type name of a simple variable `ident` visible at `from`, over
-- the scope model `sm` (threaded in from the engine via qualify_call — the
-- engine owns the per-tree model cache; see tree_model). Was a reader of the
-- engine's ambient jvt_sm; now the model is an explicit param, decoupling this
-- spec from engine state. MECHANISM: scope.resolve — every visible binder,
-- nearest first (inner shadows outer; block locals position-checked). POLICY:
--   * a param answers unconditionally, even untyped — matching a param ends
--     the question;
--   * an untyped local/field (scoped-generic base java_base_type can't name)
--     is TRANSPARENT — the shadowed outer binder answers, but the answer is
--     a GUESS (the real receiver is the nearer binder of an unnameable type),
--     so it returns a HEDGE alongside: resolve-but-mark, the edge keeps its
--     recall and gains `~` (scope-model step 2; pinned by shadowedSameFile).
-- `fields_only` restricts to class fields (a `this.field` receiver).
-- Returns ty, hedge, defer — hedge = { rule, row? } naming the walked-past
-- binder; defer = { r, c } = the INIT-PROVENANCE call site when the binder
-- is typed only by its initializer's return (the return-type rounds settle
-- it — precise beats the walk-out guess, so defer preempts the hedge).
local function java_var_type(sm, ident, from, fields_only)
    if not sm then return end
    local chain, k = sm.resolve(ident, from, fields_only and 'field' or nil)
    local skipped -- the nearest untyped binder walked past (the witness)
    for i = 1, k do
        local b = chain[i]
        if b.kind == 'param' or b.ty ~= nil then
            return b.ty, (skipped and b.ty ~= nil)
                and { rule = 'shadow-walkout', row = skipped.row } or nil
        end
        if b.init then return nil, nil, b.init end
        skipped = skipped or b
    end
end

return {
    exts = { 'java' },
    functions = [=[
        (method_declaration name: (identifier) @name) @def
        (constructor_declaration name: (identifier) @name) @def
    ]=],
    calls = [=[
        (method_invocation name: (identifier) @name) @call
        (object_creation_expression type: (type_identifier) @name) @call
    ]=],
    vars = [=[
        (field_declaration declarator: (variable_declarator
            name: (identifier) @vname value: (_) @value)) @vdef
    ]=],
    params_field = 'parameters',
    body_field = 'body',
    is_method = function () return true end,
    -- methods carry their class, `::` like php (and Java's own method-ref
    -- syntax): OwnerController::processFindForm
    qualify = function (name, defn, src)
        local cls = java_enclosing_class(defn, src)
        return cls and (cls .. '::' .. name) or name
    end,
    -- receiver-aware qualification: Java declares receiver types, so a
    -- call's target class is often recoverable lexically. this.m()/bare
    -- m() dispatch on the enclosing class; super.m() on its superclass;
    -- x.m()/this.f.m() on x's/the field's DECLARED type. Rewriting to
    -- Class::m turns the largest refusal bucket (getters/setters shared
    -- across many model classes) into exact or inheritance-walked links.
    scopes = JAVA_SCOPES, -- lexical-first id pass (scope-model step 3)
    -- declared return type = the per-method SUMMARY (graph-VM MVP). Second
    -- return = retclass: the 1-based value-parameter position of a
    -- `Class<T>` argument that BINDS the return type variable T. A generic
    -- `<T> T get(Class<T> c)` returns the type its class-literal argument
    -- names — the return-type rounds bind T from the call's `X.class` arg
    -- (the general form of the metasfresh Services.get(IFoo.class) idiom;
    -- sound because it reads the method's real signature, not a name).
    def_ret = function (defn, src)
        if defn:type() ~= 'method_declaration' then return nil end
        local ret = java_base_type(defn:field('type')[1], src)
        local tps = defn:field('type_parameters')[1]
        if not (ret and tps) then return ret end
        local tvars = {}
        for _, tp in inext, tps, -1 do
            if tp:type() == 'type_parameter' then
                local id = tp:named_child(0)
                if id and id:type() == 'type_identifier' then
                    tvars[node_text(id, src)] = true
                end
            end
        end
        if not tvars[ret] then return ret end -- return isn't a type variable
        -- find a Class<ret> parameter (Class<T> / Class<? extends T>)
        local function names_var(nd, depth)
            if nd:type() == 'type_identifier' and node_text(nd, src) == ret then
                return true
            end
            if depth < 3 then
                for i = 0, nd:named_child_count() - 1 do
                    if names_var(nd:named_child(i), depth + 1) then return true end
                end
            end
            return false
        end
        local params, k = defn:field('parameters')[1], 0
        for _, pn in (params and inext or NOOP), params, -1 do
            local pt = pn:type()
            if pt == 'formal_parameter' or pt == 'spread_parameter' then
                k = k + 1
                local ty = pn:field('type')[1]
                if ty and ty:type() == 'generic_type' then
                    local base = ty:named_child(0)
                    local targs = ty:named_child(1)
                    if base and node_text(base, src) == 'Class'
                        and targs and names_var(targs, 0) then
                        return ret, k -- return bound to this Class<T> arg
                    end
                end
            end
        end
        return ret
    end,
    qualify_call = function (calln, name, src, model)
        if calln:type() ~= 'method_invocation' then return nil end
        local obj = calln:field('object')[1]
        local cls, hedge, defer, qual
        if not obj then -- implicit this
            cls = java_enclosing_class(calln, src)
        else
            local ot = obj:type()
            if ot == 'this' then
                cls = java_enclosing_class(calln, src)
            elseif ot == 'super' then
                local _, cnode = java_enclosing_class(calln, src)
                local sup = cnode and cnode:field('superclass')[1]
                for _, c in (sup and inext or NOOP), sup, -1 do
                    if c:type() == 'type_identifier' then
                        cls = node_text(c, src)
                        break
                    end
                end
            elseif ot == 'identifier' then
                local objname = node_text(obj, src)
                cls, hedge, defer = java_var_type(model, objname, calln)
                -- a @Qualifier on the receiver field disambiguates which of
                -- an interface's several impls it holds (resolve_interface)
                if cls then qual = java_field_qualifier(calln, objname, src) end
                if not cls and not defer and objname:match('^%u') then
                    -- no binder and PascalCase: a STATIC call on the
                    -- class named right here (convention-sound; the
                    -- qualification just exact/tail-matches like any
                    -- other, so a miss costs nothing). This is what
                    -- lets `var f = Finder.of(...)` chains settle: the
                    -- determining static call resolves, its ret flows.
                    cls = objname
                end
            elseif ot == 'method_invocation' then
                -- CHAINED receiver f().g(): g's class is f's return type,
                -- knowable only after f resolves — defer to the return-type
                -- rounds, recording f's call site. A generic locator like
                -- `Services.get(IFoo.class)` is settled there too, from f's
                -- Class<T>-argument binding (resolve_returns).
                local vn = obj:field('name')[1]
                if vn then
                    local r2, c2 = vn:range()
                    defer = { r = r2, c = c2 }
                end
            elseif ot == 'object_creation_expression' then
                -- new Foo().m(): the type is right here
                cls = java_base_type(obj:field('type')[1], src)
            elseif ot == 'field_access' then
                local fo, ff = obj:field('object')[1], obj:field('field')[1]
                if fo and fo:type() == 'this' and ff then
                    cls, hedge = java_var_type(
                        model, node_text(ff, src), calln, true)
                end
            end
        end
        -- a JDK-typed receiver dispatches into the stdlib, not a project
        -- def: leave it bare for the stdlib_names/prefix gate to skip
        if cls and JAVA_JDK_TYPES[cls] then return nil end
        -- the hedge rides the qualification: a hedged qualification makes
        -- the resulting edge INFERRED even where resolution is confident.
        -- 4th value = the receiver field's @Qualifier bean name (or nil).
        return cls and (cls .. '::' .. name) or nil, cls and hedge or nil,
            (not cls) and defer or nil, cls and qual or nil
    end,
    -- single-inheritance chain (superclass ONLY here — a class implements
    -- MANY interfaces, which would collapse build_super's one-parent map to
    -- `false`; the implements relation is SET-valued and lives separately in
    -- iface_query → data.implements, consumed by resolve_interface). Feeds
    -- transitive super.m()/inherited this.m() resolution.
    super_query = [=[
        (class_declaration
            name: (identifier) @child
            superclass: (superclass (type_identifier) @parent))
    ]=],
    -- interface→impl (F1, [[cartograph-linker]]'s first Java kind): a class's
    -- `implements I, J` and an interface's `extends K` clauses. SET-valued
    -- (multiple @iface per decl), so it runs its own extraction pass (the
    -- shared defs loop's cap_node keeps only one). resolve_interface reads
    -- data.implements + data.beans to redirect an interface-stub call to its
    -- unique @stereotype impl.
    iface_query = [=[
        (class_declaration
            name: (identifier) @ichild
            (super_interfaces (type_list (type_identifier) @iface))) @idecl
        (interface_declaration
            name: (identifier) @ichild
            (extends_interfaces (type_list (type_identifier) @iface))) @idecl
    ]=],
    entry_names = { main = true },
    -- an ANNOTATION WITH ARGUMENTS passes the method into a framework
    -- (@RequestMapping("/x"), @Scheduled(...)): registered, not dead —
    -- marker annotations (@Override) wrap without registering
    cbarg_def = function (defn, _)
        local mods = defn:child(0)
        if mods and mods:type() == 'modifiers' then
            for _, c in inext, mods, -1 do
                if c:type() == 'annotation' then return true end
            end
        end
        return false
    end,
    exported_def = function (defn, src)
        local mods = defn:child(0)
        if mods and mods:type() == 'modifiers' then
            return node_text(mods, src)
                :find('public') ~= nil
        end
        return false
    end,
    -- the package (directory) scopes bare calls; qualified crosses
    scope = function (file, _)
        return file:match('^(.*)/[^/]*$') or ''
    end,
    id_fn_refs = false,
    stdlib_names = { get = true, set = true, add = true, size = true,
        isEmpty = true, toString = true, equals = true, hashCode = true,
        valueOf = true, of = true, build = true, builder = true,
        stream = true, collect = true, map = true, filter = true,
        forEach = true, format = true, println = true, append = true,
        put = true, remove = true, contains = true, length = true,
        charAt = true, substring = true, split = true, trim = true,
        parse = true, close = true, run = true, apply = true,
        accept = true, test = true, compare = true, next = true,
        iterator = true, getName = true, getId = true, getValue = true,
        setValue = true, orElse = true, orElseThrow = true },
    stdlib_prefixes = { 'System.', 'String.', 'Objects.', 'List.',
        'Map.', 'Set.', 'Collections.', 'Arrays.', 'Optional.',
        'Stream.', 'Integer.', 'Long.', 'Math.', 'Files.', 'Paths.' },
    import_query = [=[ (import_declaration (scoped_identifier) @path) ]=],
    resolve_import = function (path, files, _)
        -- com.example.pkg.Class -> the in-repo suffix .../pkg/Class.java
        local segs = {}
        for seg in path:gmatch('[%w_]+') do segs[#segs + 1] = seg end
        for i = 1, #segs do
            local cand = table.concat(segs, '/', i) .. '.java'
            if files[cand] then return cand end
            -- maven layout: the suffix sits under some src root the
            -- rel path includes; try the common prefix
            for _, pre in ipairs({ 'src/main/java/', 'src/test/java/' }) do
                if files[pre .. cand] then return pre .. cand end
            end
        end
        return nil
    end,
    -- engine-resolver-shared java knowledge (the resolution pipeline consults
    -- these outside qualify_call): JDK-type filter (also used by the entry),
    -- service-locator markers, and the bean-identity classifier. `_`-prefixed
    -- so the capability contract skips them; the engine reads them back via
    -- require 'cartograph.spec.java'.
    _jdk_types = JAVA_JDK_TYPES,
    _service_markers = JAVA_SERVICE_MARKERS,
    _bean_name = java_bean_name,
}
