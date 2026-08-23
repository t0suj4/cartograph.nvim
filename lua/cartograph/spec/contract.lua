-- THE SPEC CONTRACT ([[cartograph-spec-layering]] P1, step 1): the implicit
-- language-spec interface made EXPLICIT and CLOSED. A spec (M.spec.<lang>) is a
-- pile of fields the resolver reads; until now the contract was discovered by
-- reading the 8.9k-line provider, and the singleton tail grew one field per
-- language with no home (the 30-singleton drift). This registry names every
-- field, groups it by the CAPABILITY it unlocks (the capability ladder), and —
-- via M.audit + the contract_spec test — enforces that a spec may NOT introduce
-- an UNREGISTERED field: a new language either fills an existing slot with
-- cross-language semantics, or the field is added here (into a group, or QUIRKS
-- with a generalization note). This is the closed-schema principle applied to
-- the spec contract, and the basis for the CAPABILITY MATRIX (which groups a
-- language fills = which engine capabilities it has — the charter's checkable
-- "N cheap front-ends" metric). PURE DATA — zero behavior; the engine still
-- reads M.spec directly. Physical spec-module extraction (spec/<lang>.lua) is a
-- later step this registry defines the target of.

-- @langs any
-- The spec CAPABILITY CONTRACT: it names what a spec must provide, never a
-- particular grammar's nodes. (Declared `contract` at first, and the audit's own
-- malformed-declaration check rejected it — `contract` is not an installed grammar.)

local M = {}

-- The capability ladder: groups in dependency order, each with what filling it
-- unlocks. CORE is required; everything above CORE is optional capability.
M.GROUPS = {
    { name = 'CORE',      unlocks = 'defs / calls / bare-name resolution (the neutral schema)' },
    { name = 'SCOPE&KEY', unlocks = 'scoped + keyed resolution, receiver keying, the stdlib gate' },
    { name = 'IMPORTS',   unlocks = 'cross-file binding' },
    { name = 'TYPES',     unlocks = 'receiver / return / chain / field typing' },
    { name = 'EMITTERS',  unlocks = 'convention defs (accessors, ctors, ancestors, callbacks)' },
    { name = 'ANALYSIS',  unlocks = 'flow / df / effects / write-axis / taint' },
    { name = 'QUIRKS',    unlocks = 'nothing new — quarantined single-language shims (generalize or die)' },
}

-- field -> group. Grouped in source by capability; the comment IS the doc.
-- Adding a language field that isn't here MUST fail contract_spec — register
-- it (with a real cross-language slot) or quarantine it in QUIRKS with a note.
M.SLOTS = {
    -- CORE (required by every spec): the neutral-schema minimum
    exts = 'CORE', functions = 'CORE', calls = 'CORE', is_method = 'CORE',
    vars = 'CORE',                 -- variable-def capture
    mention_types = 'CORE',        -- node types that count as call mentions
    indirect_calls = 'CORE',       -- dispatch-through-value call forms
    -- L0 REPAIR: a length-preserving rewrite of the SOURCE BYTES, applied between the
    -- first parse and the real one, for a shape the grammar cannot parse at all. CORE
    -- because it is part of the grammar binding — it decides what tree every other
    -- slot in this contract is reading. Handed the TREE (not the text) so a repair is
    -- gated on the parse being demonstrably broken, and returns nil when there is
    -- nothing to fix. Length-preserving is the contract: every range in the graph is
    -- an offset into the repaired bytes and must still address the raw file.
    src_repair = 'CORE',

    -- SCOPE&KEY: how names scope, qualify, key; the stdlib tail gate (until L2)
    scope = 'SCOPE&KEY', scopes = 'SCOPE&KEY',
    qualify = 'SCOPE&KEY', qualify_call = 'SCOPE&KEY',
    alt_keys = 'SCOPE&KEY',        -- extra exact keys for one def (dual-key)
    exact_only_key = 'SCOPE&KEY',  -- receiver-evidence keys: exact-or-nothing
    exported_def = 'SCOPE&KEY',    -- visibility (pub/export) detection
    escape_names = 'SCOPE&KEY',    -- names mentioned in a VALUE position in a file:
                                   -- the other half of exported_def, since a
                                   -- file-local's VALUE can still leave (CART-0230).
                                   -- Only the index-only front-ends call it now
    member_positions = 'SCOPE&KEY', -- parent type -> the child holding a MEMBER
                                   -- NAME (a name reached through a receiver).
                                   -- OPTIONAL, unlike call_positions: a language
                                   -- may genuinely have no member form (bash,
                                   -- haskell, scheme) or spell it as a call node
                                   -- it already declares (ruby's `call`).
                                   -- CART-0529
    call_positions = 'SCOPE&KEY',  -- parent type -> the child holding a CALLEE
                                   -- NAME (field name or named-child index). Was
                                   -- an or-chain inline in the provider, which
                                   -- is worse than CART-0451's unauditable spec
                                   -- TABLE: there was nothing to audit at all,
                                   -- and six languages were silently missing
                                   -- (CART-0499)
    escape_nonvalue = 'SCOPE&KEY', -- the same rule as a parent-type veto table, so
                                   -- the mention walk answers it as a rider and no
                                   -- file is traversed twice (CART-0236)
    local_decls = 'SCOPE&KEY',     -- in-fn local bindings (local-shadow gate)
    id_fn_refs = 'SCOPE&KEY',      -- identifier arg = fn reference (callback)
    dot_calls_are_methods = 'SCOPE&KEY',
    hash_qualified = 'SCOPE&KEY',
    qualified_scope_local = 'SCOPE&KEY',
    literal_names = 'SCOPE&KEY',   -- literal-name langs (bash): no tail-match
    stdlib_names = 'SCOPE&KEY',    -- the stdlib vocab gate (L2 profile succeeds it)
    stdlib_prefixes = 'SCOPE&KEY', -- stdlib namespace-prefix gate

    -- IMPORTS: cross-file binding (the 3-overlapping-mechanism family — a
    -- consolidation candidate into one `imports` contract, spec-layering)
    resolve_import = 'IMPORTS', import_query = 'IMPORTS',
    import_call = 'IMPORTS', import_bind = 'IMPORTS', import_line = 'IMPORTS',
    import_pats = 'IMPORTS', import_call_like = 'IMPORTS', scan_imports = 'IMPORTS',
    -- WHAT KIND OF IMPORT THE SITE IS (CART-0510), keyed on the import
    -- expression's NODE TYPE: { once = <re-executes?>, soft = <failure is
    -- non-fatal?> }. Declared ONLY where the site's own syntax discriminates --
    -- php's four require/include forms, bash's `source`. NOT declared for a
    -- module system that is always-once (go, rust, js): `once = true` there
    -- would be a claim about the RUNTIME, not about the site, i.e. a promise
    -- fact minted from a blanket assertion -- the guarantee slot
    -- [[cartograph-stdlib-profile]] was refused. Absence means NOT ASKED.
    import_kinds = 'IMPORTS',
    field_alias = 'IMPORTS',        -- `local f = mod.field`: binds a MEMBER of an
                                    -- imported module to a local (CART-0237)
    std_aliases = 'IMPORTS',        -- per-file names bound to the stdlib (std-alias disposition)

    -- TYPES: receiver / return / chain / field typing (the D-measurement's
    -- local-inference rung lands here)
    chain_root = 'TYPES', chain_type = 'TYPES', scan_fields = 'TYPES',
    fields = 'TYPES', def_ret = 'TYPES', fn_types = 'TYPES',
    -- the subset of fn_types the extractor never MINTS as a node. It QUALIFIES
    -- fn_types, so it lives beside it rather than in ANALYSIS with its consumer:
    -- one fact, one tier. "Which function encloses this node" (fn_types) and
    -- "where does the flow walk stop" (fn_types minus this, plus the legacy set)
    -- are different questions, and a stop at an unminted type DELETES the rows
    -- rather than relocating them to a node that would hold them — measured, go
    -- 30 -> 1772 dfgate divergences when the two were conflated (CART-0308).
    fn_unminted = 'TYPES',
    annot_tag = 'TYPES',           -- how an annotation tag line is spelled here
                                   -- (LuaLS `---@x`, jsdoc `@x {T}`); the tag
                                   -- vocabulary itself is shared (CART-0240)
    recv_local = 'TYPES', recv_root = 'TYPES', recv_path = 'TYPES',
    litdata_types = 'TYPES',
    -- compound suffixes that reuse this language's extension but are a DIFFERENT
    -- language (`.blade.php`); claiming them fabricates structure (CART-0347)
    ext_disclaim = 'CORE',
    dynamic_callee_types = 'TYPES', smt_query = 'TYPES',
    -- the KEY child that takes a dynamic callee BACK to static: `t['name']()`
    -- names its member in the source. Cross-language by construction — every
    -- bracket/subscript grammar has literal keys (CART-0345)
    dynamic_callee_static_key = 'TYPES',
    -- local-type inference ([[cartograph-local-type-inference]]): local_ret
    -- captures a set-once local's determining call (→ c.rt), methodsep is the
    -- return-typed method-key separator (Ret<sep>m) the generic pass reads.
    local_ret = 'TYPES', methodsep = 'TYPES',

    -- EMITTERS: convention defs synthesized from the tree (the `scans` family —
    -- one named-fact-stream slot when touched, spec-layering)
    synth_defs = 'EMITTERS', cbarg_def = 'EMITTERS', cbarg_within = 'EMITTERS',
    field_fn_cbarg = 'EMITTERS', scan_ctors = 'EMITTERS',
    scan_ancestors = 'EMITTERS', scan_super = 'EMITTERS',
    scan_bare_calls = 'EMITTERS', ctor_query = 'EMITTERS',
    super_query = 'EMITTERS', iface_query = 'EMITTERS', interface = 'EMITTERS',
    aperture_query = 'EMITTERS',

    -- ANALYSIS: flow / df / effects semantics
    -- ACCESS BY STRING KEY (CART-0504): the table through which a variable is
    -- reachable BY NAME, and the operator that builds that name. Two facts, and
    -- deliberately only two: they are what keyaccess needs to DERIVE an
    -- accessor's transform from its own body (`$GLOBALS['g_' . $p_option]`)
    -- rather than be told the convention. A declared convention would be an
    -- authored guess, and a wrong one fabricates reads corpus-wide.
    global_table = 'ANALYSIS', concat_op = 'ANALYSIS',
    -- ...and whether a FILE-SCOPE var is unconditionally reachable through that
    -- table. php: yes, `$x = 1;` at file scope IS `$GLOBALS['x']`. lua: NO, and
    -- the difference is one keyword (`local x` is invisible to _G, bare `x = 1`
    -- is not) that no var node records -- `exported` is set by handle_fn only,
    -- so a var carries nil, which means "never asked" and must never be read as
    -- yes. Absent = a derived name is NOT resolved in this language.
    global_scope_vars = 'ANALYSIS',
    is_write = 'ANALYSIS', write_gate = 'ANALYSIS', guards = 'ANALYSIS',
    module_effects = 'ANALYSIS', dataflow = 'ANALYSIS', regime = 'ANALYSIS',
    -- EXTRA CONTROL NODES, per language (CART-0363). flow's CTRL/PRELOOP are one
    -- language's SPELLING; a control node absent from them is emitted as a plain row and
    -- its BODY GETS NO ROWS AT ALL. `ctrl` adds the statement, `preloop` says its test
    -- runs BEFORE the body (zero-trip feasible, back-edge to the head).
    ctrl = 'ANALYSIS', preloop = 'ANALYSIS',
    -- and the two REGION classes, needed the moment a language's containers are not
    -- `block`: ruby regions with `then`/`do` and sub-regions with `elsif`/`else`/`when`.
    body = 'ANALYSIS', clause = 'ANALYSIS',
    -- ATTACHED BLOCKS (part B): <block node type> -> <binder-list field>. Ruby's `do…end`
    -- and `{…}` hang off a call ANYWHERE in a statement, so du stops at them and hands
    -- them back to be emitted as rows of their own. `block` is in eight grammars, which
    -- is exactly why this is a spec key and not a base set.
    blocks = 'ANALYSIS',
    -- LOCAL DECLARATIONS, per language: which node type IS a declaration statement, for the
    -- expression harvest's name=value split. C spells it `declaration`, which is a node type
    -- in NINE grammars (several as a SUPERTYPE) — so it cannot be a base name (CART-0404).
    localdecl = 'ANALYSIS',
    df_ids = 'ANALYSIS', merge_equations = 'ANALYSIS',
    binding_modifiers = 'ANALYSIS', -- declaration decorations that read nothing: lua
                                    -- `<const>`/`<close>`, whose node name collides with
                                    -- python's field access (CART-0234)
    params_field = 'ANALYSIS', body_field = 'ANALYSIS',
    -- …and their POSITIONAL twins, for a grammar that does not LABEL either. Odin is
    -- the case: a `procedure_declaration` holds a `procedure` wrapper which holds the
    -- `parameters` and the `block`, none of them a named field, so both field-based
    -- readers came back empty and odin got NO flow records at all — 31955 functions
    -- dark, silently, because a function with no flow record simply yields no findings
    -- (CART-0305). A hook rather than a `body_type` string: the body can be nested
    -- arbitrarily deep, and a spec that must descend two levels should say how.
    body_of = 'ANALYSIS', params_of = 'ANALYSIS',
    -- node types that BIND names (loop variables). df records them as `use` and
    -- never as `def`, so without this a loop-bound receiver reads as a free name —
    -- which put a local into externals' "real porting work" group until declared.
    binders = 'ANALYSIS',
    -- DESTRUCTURING + IMPORT BINDERS (CART-0358): which children of a pattern-ish node
    -- are in DEF position. Distinct from `binders` above, which names whole node types
    -- whose contents bind; this is FIELD-PRECISE, because a pattern has children that
    -- genuinely READ — an object_assignment_pattern's `right` (`{dv = fallback}` reads
    -- fallback) and a computed_property_name key (`{[dyn]: computed}` reads dyn). A
    -- blanket "everything under a pattern binds" fabricates a def for each AND loses a
    -- real read, which is the wrong direction twice over.
    -- Value: `true` = every named child binds; an ORDERED FIELD LIST = the first field
    -- present binds (js `import_specifier` is {'alias','name'} — `N2 as N3` binds N3,
    -- while N2 names an export of the OTHER module and is no local name at all).
    -- An entry makes the node decide def-position for its children UNCONDITIONALLY, so
    -- ONE table serves both roles: an `import_statement` ORIGINATES def-position and an
    -- `object_pattern` PROPAGATES it. That is safe only because every node named here is
    -- binding-only BY GRAMMAR (the `_pattern` suffix and the import cluster) — a node
    -- that can also appear in a value position must never be listed.
    binder_fields = 'ANALYSIS',
    -- the node type that may WRAP a binding target in this language (js
    -- `parenthesized_expression`): `({body: b} = await x)` is the only way to destructure
    -- into EXISTING bindings, because a statement may not begin with `{`. A bare type test
    -- for it is a language assumption — the name exists in 14 grammars and not in haskell,
    -- ruby or scheme — so the language fence refuses one, correctly.
    binder_paren = 'ANALYSIS',
    string_sinks = 'ANALYSIS',

    -- QUIRKS (quarantine): single-language shims. Rule — each carries a comment
    -- naming its generalization candidate, or it shouldn't be here.
    torn_by_node = 'QUIRKS',     -- node-local tearing after a parse error
    toplevel_only = 'QUIRKS', toplevel_parent = 'QUIRKS', is_top = 'QUIRKS',
    block_container = 'QUIRKS',  -- grammar shape → coarse-region container
    block_skip = 'QUIRKS', call_skip = 'QUIRKS', call_skip_within = 'QUIRKS',
    skip_call = 'QUIRKS',        -- parse-level call filters (grammar noise)
    -- per-def veto: a captured def that must NOT become a name in the graph, when
    -- soundness depends on something a query cannot test (js: `X.y = function(){}`
    -- where X is a function-local object). Generalization candidate: the same
    -- question exists for lua `t.f = function() end` on a local table, so this
    -- belongs with a shared LOCALITY predicate once a second language needs it.
    skip_def = 'QUIRKS',
    entry_names = 'QUIRKS',      -- entry points → belongs in L4 project overlay
}

-- The audit: classify a spec table's fields against the registry. Returns
-- per-language { filled = {group -> true}, slots = {field -> true},
-- unknown = {fields not in the registry} } — unknown ~= {} is a CLOSED-CONTRACT
-- violation (a field the engine reads that this contract doesn't name).
function M.audit(spec)
    local out = {}
    for lang, s in pairs(spec) do
        local rec = { filled = {}, slots = {}, unknown = {} }
        for field in pairs(s) do
            -- skip `_`-prefixed keys: runtime memoization caches (e.g.
            -- spec._defs_query, lazily compiled at extract) — implementation
            -- detail, NOT authored contract claims. The closed contract governs
            -- authored fields only.
            if field:sub(1, 1) ~= '_' then
                local g = M.SLOTS[field]
                if g then
                    rec.slots[field] = true
                    rec.filled[g] = true
                else
                    rec.unknown[#rec.unknown + 1] = field
                end
            end
        end
        table.sort(rec.unknown)
        out[lang] = rec
    end
    return out
end

-- The CAPABILITY MATRIX as report lines: language × capability group, ● filled
-- / · empty. The measurable "N cheap front-ends" surface + a closed-contract
-- tripwire (any unknown field is flagged loudly).
function M.matrix_report(spec)
    local audit = M.audit(spec)
    local langs = {}
    for l in pairs(audit) do langs[#langs + 1] = l end
    table.sort(langs)
    local hdr = { ('%-12s'):format('language') }
    for _, g in ipairs(M.GROUPS) do hdr[#hdr + 1] = ('%-10s'):format(g.name) end
    local lines = { 'spec capability matrix — group filled (● / ·):', '',
        table.concat(hdr, ' ') }
    local anyunknown = {}
    for _, l in ipairs(langs) do
        local rec = audit[l]
        local row = { ('%-12s'):format(l) }
        for _, g in ipairs(M.GROUPS) do
            row[#row + 1] = ('%-10s'):format(rec.filled[g.name] and '●' or '·')
        end
        lines[#lines + 1] = table.concat(row, ' ')
        if #rec.unknown > 0 then
            anyunknown[#anyunknown + 1] = ('  %s: %s'):format(l,
                table.concat(rec.unknown, ', '))
        end
    end
    if #anyunknown > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'UNREGISTERED FIELDS (closed-contract violation — register or quarantine):'
        for _, l in ipairs(anyunknown) do lines[#lines + 1] = l end
    end
    return lines
end

return M
