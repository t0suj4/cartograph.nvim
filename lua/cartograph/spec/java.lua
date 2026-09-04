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
local JAVA_REGISTERING_MARKERS = {}
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
    -- JAX-RS verbs are BARE markers; only @Path carries arguments
    'GET', 'POST', 'PUT', 'DELETE', 'HEAD', 'OPTIONS', 'PATCH',
}) do JAVA_REGISTERING_MARKERS[a] = true end
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
    -- an ANNOTATION WITH ARGUMENTS passes the method into a framework
    -- (@RequestMapping("/x"), @Scheduled(...)): registered, not dead. A bare
    -- MARKER annotation needs its name checked instead — most of them register
    -- too (@Test, @Bean, @PostConstruct) and only some wrap without
    -- registering (@Override, @Deprecated), and nothing in the syntax tells
    -- the two apart. See JAVA_REGISTERING_MARKERS for why the name is the only
    -- available premise. The name may be qualified (@org.junit.Test), so match
    -- the last segment.
    -- SECOND RETURN (CART-0722): the annotation names on this def that the
    -- SUPPLIED list above does not recognise and the JDK does not erase — the
    -- only ones an observed registrar could ever speak for. Collected here
    -- rather than in a hook of its own because the modifiers walk, the
    -- qualified-name tail and the inclusion set all already live in this
    -- function; a second walk would be a second place for them to drift.
    -- The verdict itself is UNCHANGED, deliberately: this commit adds a route,
    -- it does not re-decide the existing one (that is CART-0720, on its own
    -- branch, and keeping them separate is what made each measurable).
    cbarg_def = function (defn, src)
        local mods = defn:child(0)
        if not (mods and mods:type() == 'modifiers') then return false end
        local reg, annos, seen = false, nil, nil
        for _, c in inext, mods, -1 do
            local t = c:type()
            if t == 'annotation' or t == 'marker_annotation' then
                local nm = c:field('name')[1]
                local tail = nm and node_text(nm, src):match('([%w_]+)%s*$')
                -- an annotation WITH ARGUMENTS is accepted by node type, which
                -- is name-blind and is CART-0720's defect — preserved verbatim
                -- so this change is liveness-neutral on its own
                if t == 'annotation' then reg = true end
                if tail and JAVA_REGISTERING_MARKERS[tail] then reg = true end
                if tail and not JAVA_REGISTERING_MARKERS[tail]
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
