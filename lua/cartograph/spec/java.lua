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
-- ── IMPORTS PAST A MODULE SEGMENT (CART-0675) ────────────────────────────────
-- A class's file is `<source root>/<package path>/<Class>.java`, and in a multi-module tree the
-- source root carries a module prefix (`mod_core/src/main/java/`, hive's `serde/src/java/`, a
-- generated `src/gen/thrift/gen-javabean/`). The layout, not a list of conventional roots, is the
-- evidence: a candidate is any file whose path ENDS in `/<package path>/<Class>.java` at a
-- directory boundary — the WHOLE package path, never a tail of it (`com/other/core/Registry.java`
-- is not `com.example.core.Registry`).
-- ⚠ SEVERAL CANDIDATES ARE THE SAME FQN IN SEVERAL MODULES (shaded copies, per-module test
-- stubs, a copy under test resources). The importer's own source root sees its own class first;
-- otherwise which copy it compiles against is a CLASSPATH fact, and this refuses rather than pick.
-- ★ THE IMPORTER'S SOURCE ROOT IS ITS PATH MINUS ITS DECLARED PACKAGE (`import_context`), not a
-- path prefix: the index root `''` prefixes every path, so a prefix test made a class sitting at
-- the root "the importer's own" for every module (the rootcopy fixture). A file whose directory
-- does not spell its package has no source root, and its duplicates are refused.
-- basename -> {files}, memoized per fileset (weak keys: dies with the fileset).
local JAVA_BASENAMES = setmetatable({}, { __mode = 'k' })

local function java_basenames(files)
    local idx = JAVA_BASENAMES[files]
    if not idx then
        idx = {}
        for f in pairs(files) do
            local b = f:match('([^/]+%.java)$')
            if b then local l = idx[b] or {}; l[#l + 1] = f; idx[b] = l end
        end
        for _, l in pairs(idx) do table.sort(l) end
        JAVA_BASENAMES[files] = idx
    end
    return idx
end

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
-- REGISTERING MARKER annotations: argumentless annotations that nevertheless
-- hand the method to a framework, which then invokes it by reflection. The
-- structural premise cbarg_def used to rest on — an annotation WITH ARGUMENTS
-- passes the method into something — is sound but draws the wrong set, because
-- IN JAVA THE REGISTERING MARKER IS THE COMMON CASE: `@Test` parses as
-- tree-sitter's `marker_annotation`, `@Scheduled(fixedRate = 1000)` as
-- `annotation`, and only the second was accepted. 416 of 8,108-file cross's
-- 6,276 `dead-function` findings sat on a member some framework calls through
-- one of the names below (309 `@Test`, 35 `@BeforeEach`, 25 `@PostConstruct`,
-- 15 `@BeforeAll`, 10 `@Bean`), and no call-graph work can EVER reach them —
-- the caller is outside the source. [[cartograph-design-home]] CART-0701.
--
-- THE PREMISE IS SUPPLIED, NOT PROVEN, and no syntactic fact could replace it.
-- `@Retention(SOURCE)` proves an annotation cannot dispatch at runtime, so it
-- cleanly EXCLUDES `@Override`/`@SuppressWarnings` — but `@Deprecated` and
-- `@FunctionalInterface` are RUNTIME and register nothing, so retention is a
-- sound exclusion and never an inclusion. A human asserted this list; that it
-- says so, and that a project can extend it, are CART-0702.
--
-- THE INCLUSION RULE, because both directions of error are unsound (a wrong
-- name mints a false alibi and hides real dead code; a missing one hands out a
-- false deletion licence): a name belongs here only if the framework INVOKES
-- the member. Annotations that merely WRAP an invocation made from the source
-- — `@Override`, `@Transactional`, `@Deprecated`, `@SafeVarargs` — do not
-- qualify, which is the distinction the original comment was reaching for.
-- Nor does `@Disabled`, which de-registers and rides beside a `@Test`.
--
-- THE SET GATES BOTH ANNOTATION NODE TYPES, and that is CART-0720. The set used
-- to gate `marker_annotation` only; `annotation` (the has-ARGUMENTS form) was
-- accepted by node type alone, which is NAME-BLIND and mints a false alibi for
-- every inert annotation that happens to take an argument. Two measured arms:
-- `@SuppressWarnings("unchecked")` (569 defs on elasticsearch/server) registers
-- nothing, and `@Deprecated(since = "8.0")` inverts the very guard the
-- java-marker-annotation fixture rests on — the same annotation, the same
-- semantics, the opposite verdict, decided by whether the author typed
-- parentheses. Arguments are not evidence of registration; the NAME is the only
-- premise either form has, so both forms ask the same question of it.
local JAVA_REGISTERING_ANNOS = {}
for _, a in ipairs({
    -- JUnit 4/5 + TestNG: the engine discovers and runs these
    'Test', 'ParameterizedTest', 'RepeatedTest', 'TestFactory', 'TestTemplate',
    'BeforeEach', 'AfterEach', 'BeforeAll', 'AfterAll',
    'Before', 'After', 'BeforeClass', 'AfterClass',
    'BeforeMethod', 'AfterMethod', 'BeforeSuite', 'AfterSuite',
    -- @Parameters names the static factory the parameterized runner calls
    'Parameters',
    -- Spring: the container calls the factory method, the injection point,
    -- the scheduled task, the event handler. NOT @Async or @Transactional —
    -- those proxy a call the SOURCE makes, so an uncalled one is really dead.
    'Bean', 'Autowired', 'Scheduled', 'EventListener',
    -- JSR-250 / CDI lifecycle + injection
    'PostConstruct', 'PreDestroy', 'Inject', 'Produces',
    -- JPA entity lifecycle callbacks
    'PrePersist', 'PostPersist', 'PreUpdate', 'PostUpdate',
    'PreRemove', 'PostRemove', 'PostLoad',
    -- Jackson: the serializer invokes these during (de)serialization
    'JsonCreator', 'JsonValue', 'JsonProperty', 'JsonAnySetter', 'JsonAnyGetter',
    -- JAX-RS verbs are BARE markers; @Path carries arguments and, on a METHOD,
    -- names a sub-resource locator the runtime calls
    'GET', 'POST', 'PUT', 'DELETE', 'HEAD', 'OPTIONS', 'PATCH', 'Path',
    -- ── the names below CARRY ARGUMENTS. Before CART-0720 they were admitted
    -- by node type without being named, so listing them changes nothing for
    -- them; they are written down so the set states its own coverage, and so
    -- that removing the node-type shortcut does not silently drop a framework.
    -- Measured at ZERO occurrences on every pinned java corpus (server, libs,
    -- synjava), so they are regression insurance for repos we do not gate on,
    -- not a claim about ours.
    -- Spring MVC / WebFlux: the dispatcher invokes the handler it routed to
    'RequestMapping', 'GetMapping', 'PostMapping', 'PutMapping',
    'DeleteMapping', 'PatchMapping',
    'ExceptionHandler', 'InitBinder', 'ModelAttribute',
    -- Spring messaging: the listener container invokes on delivery
    'MessageMapping', 'KafkaListener', 'JmsListener', 'RabbitListener',
    -- Spring setter injection: @Value("${x}") on a setter is called by the container
    'Value',
    -- Guice: the injector calls a @Provides factory method
    'Provides',
    -- JUnit 4 rules + carrotsearch randomizedtesting: the runner calls these
    'Rule', 'ClassRule', 'ParametersFactory',
    -- JPA PROPERTY access: with accessor-based mapping Hibernate calls the
    -- getter/setter itself. Only the argument-carrying mapping annotations are
    -- listed — the marker twins (@Id, @Version, @Lob) would be an EXPANSION of
    -- the population rather than preservation of it, and belong with F1.
    -- @Transient is deliberately absent: it marks the accessor the ORM will NOT
    -- invoke, so listing it would be the inclusion rule inverted.
    'Column', 'JoinColumn', 'Enumerated', 'Temporal', 'Embedded',
    'OneToOne', 'OneToMany', 'ManyToOne', 'ManyToMany',
}) do JAVA_REGISTERING_ANNOS[a] = true end
-- ── THE OBSERVED HALF (CART-0722) ─────────────────────────────────────────
-- The list above is SUPPLIED: a human asserted it, and a private framework's
-- annotation can never be on it. `@EntitlementTest` is elasticsearch's, it is
-- read by reflection inside elasticsearch, and it genuinely invokes 456
-- members. No amount of curating a shared list reaches it — that is the whole
-- of CART-0720's fork.
--
-- So ask the CORPUS instead. Two facts, both read off the tree:
--   reg_read_query    a reflective annotation read naming a class literal
--                     (`method.getAnnotation(EntitlementTest.class)`)
--   reg_invoke_query  a reflective INVOCATION (`.invoke(`, `.newInstance(`)
-- A file holding both observes-registers the names it reads. The join lives in
-- store.ingest, not here: the reader and the annotated member are in different
-- files, so no per-file hook can see both ends.
--
-- ★ THE SECOND CONJUNCT IS NOT DECORATION, IT IS THE WHOLE SOUNDNESS ARGUMENT.
-- "read reflectively" ALONE is measured-WRONG: server's PluginIntrospector
-- reads `isAnnotationPresent(Deprecated.class)` twice purely to REPORT
-- deprecation, and contains no reflective invoke at all. Without the invoke
-- conjunct this route would mint an alibi for every `@Deprecated` member on
-- server — re-creating the exact false alibi CART-0720 exists to remove, and
-- defeating the guard examples/java-marker-annotation/ rests on.
--
-- GRANULARITY IS FILE, AND THAT IS MEASURED TOO, not a convenience. Function
-- level FAILS the positive arm: RestEntitlementsCheckAction reads the
-- annotation at :100 in `getTestEntries` and invokes at :184/:187 in
-- `createFunctionForMethod`, which takes the Method as a parameter and returns
-- a lambda closing over it. Read and invoke are one hop apart through a
-- closure. File level passes both arms on all 14 reflectively-read annotation
-- names on elasticsearch server+libs (5 in, 9 out), hand-adjudicated.
--
-- ERROR DIRECTION, and it is why a file-level heuristic is admissible here at
-- all: `registered` SUPPRESSES a dead-code finding. Over-claiming declines to
-- assert death; under-claiming hands out a false deletion licence. This route
-- can only ever over-claim, which is the sound-first direction.
local JAVA_REFLECT_READS = {
    'getAnnotation', 'isAnnotationPresent',
    'getAnnotationsByType', 'getDeclaredAnnotation',
}
local JAVA_REFLECT_INVOKES = { 'invoke', 'newInstance' }
-- ANNOTATIONS THE JDK DECLARES @Retention(SOURCE). They are erased before a
-- class file exists, so NO getAnnotation() can ever see one — a PROOF, not a
-- preference, and the same lever the ticket's layer 1 names. Their only job
-- here is to keep `annos` from carrying `@Override` on 37,992 of
-- elasticsearch's 43,926 annotated members (86.5%) for a join that could not
-- fire. @Deprecated is deliberately ABSENT: it is RUNTIME, so excluding it
-- would be a preference wearing a proof's hat, and it is the negative arm the
-- fixture tests.
local JAVA_SOURCE_RETAINED = { Override = true, SuppressWarnings = true }
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
-- ★ THE BINDERS A BLOCK DOES NOT DECLARE (CART-1077): `for (T x : xs)`, `catch (T e)` and try-with-resources
-- `(T r = ...)` bind a TYPED name outside any local_variable_declaration, so none of them had a type and every call
-- on them (`field.getFieldName()` over a thrift `_Fields` loop) fell to the repo-wide name join. A multi-catch
-- `catch (A | B e)` has no single declared type: it binds e UNTYPED (a param answers anyway, ending the walk).
local function jvt_binders(node, src, out) -- name -> {ty}
    local t = node:type()
    local function put(nm, ty)
        if nm then
            local base = ty and java_base_type(ty, src) or nil
            out[node_text(nm, src)] = { ty = base ~= 'var' and base or nil }
        end
    end
    if t == 'enhanced_for_statement' then
        put(node:field('name')[1], node:field('type')[1])
    elseif t == 'catch_clause' then
        for _, c in inext, node, -1 do
            if c:type() == 'catch_formal_parameter' then
                local ty
                for _, cc in inext, c, -1 do
                    if cc:type() == 'catch_type' and cc:named_child_count() == 1 then ty = cc:named_child(0) end
                end
                put(c:field('name')[1], ty)
            end
        end
    elseif t == 'try_with_resources_statement' then
        local rs = node:field('resources')[1]
        for _, r in (rs and inext or NOOP), rs, -1 do
            if r:type() == 'resource' then put(r:field('name')[1], r:field('type')[1]) end
        end
    end
end
-- simple name -> fully qualified name, from a file's explicit single-type imports (`import a.b.C;`; static and
-- on-demand imports are not bindings of a type name). Memoized for the LAST file only: calls are qualified file by file.
local imports_src, imports_map
local function java_imports(src)
    if src == imports_src then return imports_map end
    local m = {}
    for fq in src:gmatch('\n%s*import%s+([%w_%.]+)%s*;') do
        local simple = fq:match('([%w_]+)$')
        if simple and simple:match('^%u') then m[simple] = fq end
    end
    imports_src, imports_map = src, m
    return m
end
-- ★ RETURN FLOW (CART-1077): a method whose declared return is its OWN type variable (`<S extends IScheme> S scheme(p)`)
-- erases to its bound, and the bound is often a library interface the project reaches only through library classes, so
-- the declared type can settle nothing. Its RETURN EXPRESSIONS can: thrift's generated
--   return (StandardScheme.class.equals(p.getScheme()) ? STANDARD_SCHEME_FACTORY : TUPLE_SCHEME_FACTORY).getScheme();
-- names two `private static final ... = new XStandardSchemeFactory()` fields, and each factory's getScheme() declares a
-- project class as its return. This summarises those expressions as TERMS for the return-type rounds to evaluate once
-- every file is in: `=C` is exactly class C (a `new C()`), `C` is C or any project subclass (a declared type), and each
-- `>m` step replaces the set by m's declared returns. Terms are joined with `|`. All or nothing: one return expression
-- this cannot read and there is no summary. Measured on hive's metastore: 1,814 of 1,836 type-variable chain calls,
-- 8.8M candidate scans -> 3.7k. What it READS is syntax in this file; what the terms MEAN is decided against the graph.
local JAVA_JDK_PREFIX = { 'java.', 'javax.', 'jdk.', 'sun.', 'com.sun.' }
local function java_jdk_import(fq)
    if not fq then return false end
    for _, p in ipairs(JAVA_JDK_PREFIX) do if fq:sub(1, #p) == p then return true end end
    return false
end
-- a class body's fields: name -> { ty = type node, init = value node, final = bool }, memoized per body for the last file
local flowfields_src, flowfields = nil, {}
local function java_body_fields(body, src)
    if src ~= flowfields_src then flowfields_src, flowfields = src, {} end
    local key = body:id()
    local out = flowfields[key]
    if out then return out end
    out = {}
    for c in body:iter_children() do
        if c:type() == 'field_declaration' then
            local ty = c:field('type')[1]
            local fin = false
            for m in c:iter_children() do
                if m:type() == 'modifiers' then fin = node_text(m, src):match('%f[%w]final%f[%W]') ~= nil end
            end
            for d in c:iter_children() do
                if d:type() == 'variable_declarator' then
                    local nm = d:field('name')[1]
                    if nm then out[node_text(nm, src)] = { ty = ty, init = d:field('value')[1], final = fin } end
                end
            end
        end
    end
    flowfields[key] = out
    return out
end
local function java_ret_flow(defn, src, tvars)
    local _, cnode = java_enclosing_class(defn, src)
    local cname = cnode and cnode:field('name')[1]
    local body = cnode and cnode:field('body')[1]
    if not (cname and body) then return nil end
    local fields = java_body_fields(body, src)
    local imports = java_imports(src)
    -- names bound in the method (params, locals): an identifier that is one of them is not the field of that name
    local bound = {}
    local function bind(n)
        local t = n:type()
        if t == 'formal_parameter' or t == 'spread_parameter' or t == 'variable_declarator'
            or t == 'catch_formal_parameter' or t == 'resource' then
            local nm = n:field('name')[1]
            if nm then bound[node_text(nm, src)] = true end
        end
        for c in n:iter_children() do if c:named() then bind(c) end end
    end
    bind(defn)
    -- a type NAME the project may define: a plain identifier, not a type variable, not the JDK's
    local function tname(tnode)
        local t = tnode and tnode:type()
        local base = t == 'type_identifier' and tnode or (t == 'generic_type' and tnode:child(0)) or nil
        if not (base and base:type() == 'type_identifier') then return nil end
        local s = node_text(base, src)
        if tvars[s] or JAVA_JDK_TYPES[s] or java_jdk_import(imports[s]) then return nil end
        return s
    end
    local terms
    local function field_terms(name, depth)
        if bound[name] then return nil end
        local f = fields[name]
        if not f then return nil end
        if f.final and f.init then return terms(f.init, depth + 1) end
        local s = tname(f.ty)
        return s and { s } or nil
    end
    terms = function(e, depth)
        if not e or depth > 8 then return nil end
        local t = e:type()
        if t == 'parenthesized_expression' then return terms(e:named_child(0), depth + 1)
        elseif t == 'null_literal' then return {}
        elseif t == 'ternary_expression' then
            local a = terms(e:field('consequence')[1], depth + 1)
            local b = a and terms(e:field('alternative')[1], depth + 1)
            if not b then return nil end
            for _, x in ipairs(b) do a[#a + 1] = x end
            return a
        elseif t == 'object_creation_expression' then
            if e:field('body')[1] then return nil end -- an anonymous class has no name to look a method up on
            local s = tname(e:field('type')[1])
            return s and { '=' .. s } or nil
        elseif t == 'cast_expression' then
            local s = tname(e:field('type')[1])
            return s and { s } or nil
        elseif t == 'identifier' then
            return field_terms(node_text(e, src), depth)
        elseif t == 'field_access' then
            local o, f = e:field('object')[1], e:field('field')[1]
            if o and o:type() == 'this' and f then return field_terms(node_text(f, src), depth) end
            return nil
        elseif t == 'method_invocation' then
            local o, nm = e:field('object')[1], e:field('name')[1]
            if not nm then return nil end
            local base
            if not o or o:type() == 'this' then base = { node_text(cname, src) }
            else base = terms(o, depth + 1) end
            if not base then return nil end
            local m = node_text(nm, src)
            for i, x in ipairs(base) do base[i] = x .. '>' .. m end
            return base
        end
        return nil
    end
    local all, seen = {}, {}
    local ok = true
    local function walk(n)
        if not ok then return end
        local t = n:type()
        if t == 'lambda_expression' or t == 'class_body' then return end
        if t == 'return_statement' then
            local ts_ = terms(n:named_child(0), 0)
            if not ts_ then ok = false; return end
            for _, x in ipairs(ts_) do if not seen[x] then seen[x] = true; all[#all + 1] = x end end
        end
        for c in n:iter_children() do if c:named() then walk(c) end end
    end
    local b = defn:field('body')[1]
    if b then walk(b) end
    if not ok or #all == 0 then return nil end
    return table.concat(all, '|')
end
-- the type variables a method declares (`<S extends X, T>` -> { S = true, T = true })
local function java_tvars(defn, src)
    local tps = defn:field('type_parameters')[1]
    if not tps then return nil end
    local tvars = {}
    for _, tp in inext, tps, -1 do
        if tp:type() == 'type_parameter' then
            local id = tp:named_child(0)
            if id and id:type() == 'type_identifier' then tvars[node_text(id, src)] = true end
        end
    end
    return tvars
end
-- ★ WHICH CHAINS THE FIRST PASS MAY SKIP: a chained call `m(..).g()` whose head `m` is declared exactly once in the
-- calling class, returns its own type variable and has a return flow. The rounds settle it from the flow; the name
-- join the first pass would have paid runs afterwards only if they cannot (the same fallback field deferrals use).
-- Memoized per class body for the last file.
local tvheads_src, tvheads = nil, {}
local function java_tvflow_heads(body, src)
    if src ~= tvheads_src then tvheads_src, tvheads = src, {} end
    local key = body:id()
    local out = tvheads[key]
    if out then return out end
    out = {}
    local count = {}
    for c in body:iter_children() do
        if c:type() == 'method_declaration' then
            local nm = c:field('name')[1]
            local s = nm and node_text(nm, src)
            if s then
                count[s] = (count[s] or 0) + 1
                local tvars = java_tvars(c, src)
                local ret = tvars and java_base_type(c:field('type')[1], src)
                if ret and tvars[ret] and java_ret_flow(c, src, tvars) then out[s] = true end
            end
        end
    end
    for s in pairs(out) do if count[s] > 1 then out[s] = nil end end
    tvheads[key] = out
    return out
end
-- ★ A PROJECT-WIDE FIELD-TYPE TABLE (CART-1077): every field of every class, `Owner.field -> declared type`, for
-- data.fieldtypes (the side table zig already fills, cached per file and merged across workers). It types `var.f.m()`:
-- var's class is known, and f's declared type there is the receiver's type. That shape was 57% of what still paid the
-- repo-wide name join on hive (`struct.environmentContext.read(iprot)`). An explicitly imported JDK type is recorded by
-- its FULL name, so it can never be mistaken for a project class of the same simple name.
local JAVA_TYPE_DECLS = { class_declaration = true, enum_declaration = true, interface_declaration = true,
    record_declaration = true }
local function java_scan_fields(tsroot, src)
    local rows, imports = {}, java_imports(src)
    local function field_rows(owner, fd)
        local ty = java_base_type(fd:field('type')[1], src)
        if not ty or ty == 'var' then return end
        local fq = imports[ty]
        if fq and (fq:match('^java%.') or fq:match('^javax%.') or fq:match('^jdk%.')) then ty = fq end
        for _, d in inext, fd, -1 do
            if d:type() == 'variable_declarator' then
                local dn = d:field('name')[1]
                if dn then rows[#rows + 1] = { typename = owner, field = node_text(dn, src), ftype = ty } end
            end
        end
    end
    -- ONLY TYPE DECLARATIONS AND THEIR BODIES are walked, never a method body: a whole-tree walk of the 12 MB thrift
    -- file was part of a measured +9 s. (A class declared INSIDE a method, anonymous or local, is not indexed.)
    local function decl(n)
        local nm, body = n:field('name')[1], n:field('body')[1]
        local owner = nm and node_text(nm, src)
        local function members(b)
            for _, c in (b and inext or NOOP), b, -1 do
                local t = c:type()
                if t == 'field_declaration' then if owner then field_rows(owner, c) end
                elseif t == 'enum_body_declarations' then members(c) -- an enum's fields sit one level down
                elseif JAVA_TYPE_DECLS[t] then decl(c) end -- nested types own their fields
            end
        end
        members(body)
    end
    for _, c in inext, tsroot, -1 do
        if JAVA_TYPE_DECLS[c:type()] then decl(c) end
    end
    return rows
end
local JAVA_SCOPES = {
    enhanced_for_statement  = { kind = 'param', harvest = jvt_binders },
    catch_clause            = { kind = 'param', harvest = jvt_binders },
    try_with_resources_statement = { kind = 'param', harvest = jvt_binders },
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

-- IS THIS MENTION A WRITE? (CART-0532) The fifth language to answer, and the
-- largest population left: 3467 use edges on `libs` alone.
--
-- DECLARED AS A PAIR with write_gate below — v147 shipped python's classifier
-- WITHOUT its gate, the classifier was therefore never called, and because
-- `wmode` is `spec.is_write ~= nil` the axis still switched on and reported every
-- mention as a READ. atlas then minted `const` over a write pass that had not
-- run. tests/pywrite_spec fences the pair now; this comment is the other half.
local function java_is_write(c, n)
    local cur, p = c, n
    while p do
        local pt = p:type()
        if pt == 'field_access' then
            -- `this.f = v` · `o.f = v` · `K.g = v`: object and field both ride,
            -- as in lua's dot_index_expression and go's selector_expression
            cur, p = p, p:parent()
        elseif pt == 'array_access' then
            -- `a[i] = v` writes a; the INDEX is a read
            if p:named_child(0) ~= cur then return false end
            cur, p = p, p:parent()
        else
            break
        end
    end
    if not p then return false end
    local pt = p:type()
    if pt == 'assignment_expression' then
        return p:named_child(0) == cur -- child 0 is the target, `+=` included
    elseif pt == 'update_expression' then
        return true -- g++ / --g, both spelled the same node
    end
    -- variable_declarator (a local OR a field declaration) BINDS a name and
    -- writes nothing, which is what keeps `set-once` reachable; everything else
    -- is a read.
    return false
end

return {
    -- INDEX POSITIONS (CART-0533): parent node type -> the child holding the
    -- OBJECT of a BRACKET-style access. Separate from `member_positions` because
    -- the two answer different questions: a member name is a NAME (and must not
    -- be matched against the bare-name function index), while a bracket key is an
    -- EXPRESSION and the mention inside it is a genuine value read.
    -- ★ TEN LANGUAGES SPELL ONE CONCEPT SIX WAYS — array / operand / object /
    -- value / argument / bare child 0 — which is why this is declared and not
    -- hardcoded. It was hardcoded, and java's `array_access` was absent, so
    -- `atanTab[i] = v` against `private static final double[] atanTab` recorded a
    -- WHOLE-VAR write: a claimed REBIND of a `final` field, which is a compile
    -- error. 47 of those in libs alone.
    index_positions = {
        array_access = 'array', -- a[i]
    },
    is_write = java_is_write,
    -- the PREFILTER: every immediate parent type a java write mention can have.
    -- Without it the classifier above is never invoked (see the note on it).
    write_gate = { assignment_expression = true, field_access = true,
        array_access = true, update_expression = true },
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
        field_access = 'field', -- o.NAME
    },
    -- CALL POSITIONS (CART-0499): parent node type -> which child holds the
    -- CALLEE NAME, as a field name or a named-child index. Replaces a
    -- hardcoded four-name or-chain inline in the provider that php, java,
    -- bash, rust macros, ruby and haskell were all missing from -- so a call
    -- to a corpus-unique function became a fn REFERENCE and minted a `reg`
    -- edge ("kept alive by top-level DATA"), a different fact. 96.6% of
    -- mantisbt's reg occurrences were mislabelled calls.
    call_positions = {
        method_invocation = 'name', -- g(1) / this.h(2) / K.s(3) all name it here
    },
    exts = { 'java' },
    -- ★ A LAMBDA IS A FUNCTION AND IT HAD NO NODE, so its body had NO ROWS ANYWHERE
    -- (CART-0406). `flow_stop('java')` contains `lambda_expression`, and treesitter.lua
    -- documents what that means: "the nested-fn STOP, not the enclosure set: ONLY WHERE A
    -- NODE IS MINTED TO HOLD THE ROWS". An anonymous CLASS keeps that promise — its `run`
    -- appears in the graph — and a lambda broke it: du stopped there and nothing picked the
    -- body up. The rows were not relocated, they were ABSENT.
    -- MEASURED on elasticsearch/libs: 1670 lambdas, 94 of them holding a control form.
    -- ★ THE POSITIONS AND THEIR NAMES ARE JS'S, because js already solved this for arrow
    -- functions and a second convention would BE the drift:
    --   a NAMED binding  `Runnable r = () -> {…}`  -> the declarator's name (also covers a
    --                                                 FIELD initialiser: same node shape)
    --   an ARGUMENT      `xs.forEach(x -> {…})`     -> `<callee>#cb`, via @adef
    -- Deliberately NOT captured: a lambda in RETURN position. It has no name and no enclosing
    -- call, so @adef would mint `fn#cb` — and in a graph keyed by name, a name carrying no
    -- information is worse than an honest absence.
    functions = [=[
        (method_declaration name: (identifier) @name) @def
        (constructor_declaration name: (identifier) @name) @def
        (variable_declarator name: (identifier) @name value: (lambda_expression) @def)
        (argument_list (lambda_expression) @adef)
    ]=],
    calls = [=[
        (method_invocation name: (identifier) @name) @call
        (object_creation_expression type: (type_identifier) @name) @call
    ]=],
    -- ★ TWO PATTERNS, because 42.5% of java's fields have NO INITIALIZER (1130 of
    -- 2656 declarators on libs) and the single value-requiring pattern made every
    -- one of them invisible as a var (CART-0537). `!value` is the negated-field
    -- assertion, so the second pattern matches exactly the complement — no overlap
    -- to dedup. A `@vdecl` var carries `decl`, the field a C prototype already uses
    -- for "declared, not defined".
    -- WHY IT MATTERS MORE THAN THE PERCENTAGE SUGGESTS: `private final byte[]
    -- idPage;` is assigned in a CONSTRUCTOR, so the invisible population is
    -- enriched in the SET-ONCE cases — the rung with the most to say.
    vars = [=[
        (field_declaration declarator: (variable_declarator
            name: (identifier) @vname value: (_) @value)) @vdef
        (field_declaration declarator: (variable_declarator
            name: (identifier) @vname !value)) @vdecl
    ]=],
    params_field = 'parameters',
    body_field = 'body',
    -- a CONSTRUCTOR is a function the shared table never named: it is 12.5% of
    -- java's sampled def population and every one of them was invisible to
    -- `expr.of` while the set was hardcoded elsewhere (CART-0306).
    fn_types = { method_declaration = true, constructor_declaration = true,
        lambda_expression = true },
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
        -- no Class<T> binds it: the return EXPRESSIONS may still say which classes come back (see java_ret_flow)
        return ret, nil, java_ret_flow(defn, src, tvars)
    end,
    scan_fields = java_scan_fields,
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
                -- (a class name may lead with underscores: thrift nests `_Fields` in every struct, CART-1077)
                if not cls and not defer and objname:match('^_*%u') then
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
                    -- a head declared in this class with a return flow: the rounds settle it, so the first pass
                    -- skips the name join (tv = type-variable head; see java_tvflow_heads)
                    local ho = obj:field('object')[1]
                    if not ho or ho:type() == 'this' then
                        local _, cnode = java_enclosing_class(calln, src)
                        local body = cnode and cnode:field('body')[1]
                        if body and java_tvflow_heads(body, src)[node_text(vn, src)] then defer.tv = true end
                    end
                end
            elseif ot == 'object_creation_expression' then
                -- new Foo().m(): the type is right here
                cls = java_base_type(obj:field('type')[1], src)
            elseif ot == 'field_access' then
                local fo, ff = obj:field('object')[1], obj:field('field')[1]
                if fo and fo:type() == 'this' and ff then
                    cls, hedge = java_var_type(
                        model, node_text(ff, src), calln, true)
                elseif ff and fo and fo:type() == 'identifier' and not node_text(ff, src):match('^_*%u') then
                    -- ★ `var.f.m()` with var's type KNOWN (CART-1077): f's declared type in var's class types the
                    -- receiver. That class may be in a file not parsed yet, so the call is DEFERRED to the
                    -- return-type rounds, which read data.fieldtypes once every file is in. ONE scope lookup: this
                    -- branch runs for every `x.f.m()`, and the lookup is the cost (measured: a doubled call was part of
                    -- a +9 s extract_calls on hive's metastore).
                    local vt = java_var_type(model, node_text(fo, src), calln)
                    if vt and not JAVA_JDK_TYPES[vt] then defer = { owner = vt, fld = node_text(ff, src) } end
                elseif ff and fo and node_text(ff, src):match('^_*%u') and node_text(ff, src):find('%l') then
                    -- (a CLASS name has lower case: `Version.CURRENT.m()` names a static FIELD, all caps, and its
                    -- type is Version's to declare, not `CURRENT` — found by the server gate's removed-edge witness)
                    -- a QUALIFIED CLASS receiver, `org.apache.thrift.TBaseHelper.compareTo(..)` or `Outer.Inner.m()`
                    -- (CART-1077): a chain of plain identifiers whose last segment is a class name and whose head is
                    -- NOT a variable in scope is a static call on that class. A variable head (`cfg.Inner.m()`) is
                    -- left alone: that is field access through a value.
                    local head, ok = fo, true
                    while head and head:type() == 'field_access' do head = head:field('object')[1] end
                    if not (head and head:type() == 'identifier') then ok = false end
                    local cur = fo
                    while ok and cur and cur:type() == 'field_access' do
                        local f2 = cur:field('field')[1]
                        if not (f2 and f2:type() == 'identifier') then ok = false end
                        cur = cur:field('object')[1]
                    end
                    if ok then
                        local ht = node_text(head, src)
                        local vt, _, vd = java_var_type(model, ht, calln)
                        if vt == nil and vd == nil then cls = node_text(ff, src) end
                    end
                end
            end
        end
        -- a JDK-typed receiver dispatches into the stdlib, not a project
        -- def: leave it bare for the stdlib_names/prefix gate to skip
        if cls and JAVA_JDK_TYPES[cls] then return nil end
        -- ★ AN EXPLICITLY IMPORTED JDK CLASS IS NOT THE PROJECT'S CLASS OF THE SAME SIMPLE NAME (CART-1077): Version.java
        -- imports java.lang.reflect.Field, and elasticsearch has its own script.field.Field, so `field.getName()` was
        -- typed to the project's Field by simple name. Qualify with the FULL name instead: it can match no project def,
        -- and the resolver's typed-receiver rule reads it as external. (Found by the server gate's added-edge witness.)
        if cls then
            local fq = java_imports(src)[cls]
            if fq and (fq:match('^java%.') or fq:match('^javax%.') or fq:match('^jdk%.')
                or fq:match('^sun%.') or fq:match('^com%.sun%.')) then
                return fq .. '::' .. name, hedge, nil, qual
            end
        end
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
    -- ⚠ THE PARAMETERIZED FORM IS A DIFFERENT NODE, NOT A DECORATED ONE
    -- (CART-0672). `extends Base` parses `superclass → type_identifier`;
    -- `extends Base<T, C>` parses `superclass → generic_type → type_identifier`,
    -- so a query naming only the first shape gives a generic class NO PARENT.
    -- Measured on an 8k-file Spring monorepo: 1,030 of 3,304 `extends` clauses
    -- (31%) and 801 of 2,088 `implements` (38%) were invisible, and the second
    -- number is a ~38% under-coverage of the F1 bean redirect.
    --
    -- IT HID BECAUSE A LOST SUPER CHAIN DEGRADES TO NAME MATCHING, which succeeds
    -- while the method name is unique. It becomes a lost EDGE only where the name
    -- is ALSO ambiguous — a conjunction, which is why a 1-D bestiary never emitted
    -- it ([[cartograph-combinatorial-grid]]).
    --
    -- ERASURE IS CORRECT HERE and is the reason the alternation is legal rather
    -- than a shortcut: `Base<T, C>` and `Base` are THE SAME DECLARATION, and the
    -- chain being walked is the declaration chain. The type arguments are a
    -- sibling `type_arguments` node, so capturing the direct `type_identifier`
    -- child cannot pick one of them up by accident.
    super_query = [=[
        (class_declaration
            name: (identifier) @child
            superclass: (superclass [ (type_identifier) @parent
                                      (generic_type (type_identifier) @parent) ]))
    ]=],
    -- interface→impl (F1, [[cartograph-linker]]'s first Java kind): a class's
    -- `implements I, J` and an interface's `extends K` clauses. SET-valued
    -- (multiple @iface per decl), so it runs its own extraction pass (the
    -- shared defs loop's cap_node keeps only one). resolve_interface reads
    -- data.implements + data.beans to redirect an interface-stub call to its
    -- unique @stereotype impl.
    -- Same two shapes as super_query, in both clauses — `implements Foo` and
    -- `implements Foo<T>`, `interface J extends K` and `interface J<T> extends K<T>`.
    iface_query = [=[
        (class_declaration
            name: (identifier) @ichild
            (super_interfaces (type_list [ (type_identifier) @iface
                                           (generic_type (type_identifier) @iface) ]))) @idecl
        (interface_declaration
            name: (identifier) @ichild
            (extends_interfaces (type_list [ (type_identifier) @iface
                                             (generic_type (type_identifier) @iface) ]))) @idecl
    ]=],
    entry_names = { main = true },
    -- An annotation registers the member iff its NAME says so — see
    -- JAVA_REGISTERING_ANNOS for the inclusion rule and why the name is the
    -- only available premise. tree-sitter splits the two spellings into
    -- `marker_annotation` (@Test) and `annotation` (@Scheduled(...)); that
    -- split is a grammar fact about parentheses and carries no semantics, so
    -- both forms are asked the same question (CART-0720). The name may be
    -- qualified (@org.junit.Test), so match the last segment.
    --
    -- SECOND RETURN (CART-0722): the annotation names this SUPPLIED list does
    -- not recognise and the JDK does not erase — the only ones an OBSERVED
    -- registrar could ever speak for. Collected here rather than in a hook of
    -- its own because the modifiers walk, the qualified-name tail and the
    -- inclusion set all already live in this function; a second walk would be
    -- a second place for them to drift.
    --
    -- ★ THE TWO HALVES ARE ONE MECHANISM AND THAT IS THE POINT. Name-gating
    -- the has-arguments form (this ticket) is what STOPS `@EntitlementTest`
    -- registering by accident; the observed route (CART-0722) is what puts it
    -- back, on evidence, for the 456 members it really does invoke. Landing
    -- either alone is wrong in a measurable direction: 0722 alone changes
    -- nothing at all, this alone mints 456 false deletion licences on libs.
    cbarg_def = function (defn, src)
        local mods = defn:child(0)
        if not (mods and mods:type() == 'modifiers') then return false end
        local reg, annos, seen = false, nil, nil
        for _, c in inext, mods, -1 do
            local t = c:type()
            if t == 'annotation' or t == 'marker_annotation' then
                local nm = c:field('name')[1]
                local tail = nm and node_text(nm, src):match('([%w_]+)%s*$')
                if tail and JAVA_REGISTERING_ANNOS[tail] then reg = true end
                if tail and not JAVA_REGISTERING_ANNOS[tail]
                    and not JAVA_SOURCE_RETAINED[tail] then
                    seen = seen or {}
                    if not seen[tail] then
                        seen[tail] = true
                        annos = annos or {}
                        annos[#annos + 1] = tail
                    end
                end
            end
        end
        return reg, annos
    end,
    -- the reflective REGISTRAR pair, see JAVA_REFLECT_READS above. Split into
    -- two queries on purpose: the read is rare and cheap to look for, the
    -- invoke pattern matches every method call in the file, so the provider
    -- runs the second ONLY where the first hit.
    reg_read_query = ([=[
        (method_invocation
            name: (identifier) @rmeth (#any-of? @rmeth %s)
            arguments: (argument_list (class_literal) @rcls))
    ]=]):format('"' .. table.concat(JAVA_REFLECT_READS, '" "') .. '"'),
    reg_invoke_query = ([=[
        (method_invocation name: (identifier) @imeth (#any-of? @imeth %s))
    ]=]):format('"' .. table.concat(JAVA_REFLECT_INVOKES, '" "') .. '"'),
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
    -- the importer's source root, from its own `package` declaration (see JAVA_BASENAMES)
    import_context = function (tsroot, src, file)
        local pkg = ''
        for child in tsroot:iter_children() do
            if child:type() == 'package_declaration' then
                for n in child:iter_children() do
                    local t = n:type()
                    if t == 'scoped_identifier' or t == 'identifier' then pkg = node_text(n, src) end
                end
                break
            end
        end
        local tail = (pkg ~= '' and pkg:gsub('%s', ''):gsub('%.', '/') .. '/' or '') .. file:match('[^/]*$')
        if file == tail then return { srcroot = '' } end
        if file:sub(-#tail - 1) == '/' .. tail then return { srcroot = file:sub(1, #file - #tail) } end
        return {}
    end,
    resolve_import = function (path, files, _, _, ctx)
        -- com.example.pkg.Class -> <source root>/com/example/pkg/Class.java, the root being the
        -- index root, `src/main/java/`, or any module's (see JAVA_BASENAMES): ONE candidate rule,
        -- so a class at the root and a copy in a module are two candidates, not a silent preference
        local segs = {}
        for seg in path:gmatch('[%w_]+') do segs[#segs + 1] = seg end
        if #segs == 0 then return nil end
        local full = table.concat(segs, '/') .. '.java'
        local tail, cands = '/' .. full, {}
        for _, f in ipairs(java_basenames(files)[segs[#segs] .. '.java'] or {}) do
            if f == full or f:sub(-#tail) == tail then cands[#cands + 1] = f end
        end
        if #cands == 1 then return cands[1] end
        if #cands > 1 then
            local own = ctx and ctx.srcroot
            if own then
                for _, c in ipairs(cands) do
                    if c:sub(1, #c - #full) == own then return c end
                end
            end
            return nil
        end
        -- no file spells the whole package: the index root may sit INSIDE a source root
        -- (`src/main/java/com/example` indexed alone holds com.example.core.Registry as
        -- `core/Registry.java`), so try the shorter suffixes
        for i = 2, #segs do
            local cand = table.concat(segs, '/', i) .. '.java'
            if files[cand] then return cand end
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
