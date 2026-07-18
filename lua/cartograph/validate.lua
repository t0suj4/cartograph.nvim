-- The schema validator: the closed schema as an executable registry.
-- Every field a provider may put on a node/edge/call is enumerated HERE;
-- growing the schema means growing these tables in the same commit — the
-- gate turns red on silent drift (the tokens provider grew four fields
-- and capabilities.calls='aggregated' with nothing structural saying
-- "approved"; this is the structural thing). The allowlists were built
-- EMPIRICALLY from a 17-corpus field inventory (2026-07-10), not from
-- recollection — they double as the CSR fold's column inventory.

local M = {}

M.NODE_KINDS = { module = true, ['function'] = true, method = true,
    var = true, region = true }
M.EDGE_KINDS = { ref = true, import = true, use = true, reg = true }

M.NODE_FIELDS = {
    -- identity + location (required set checked separately)
    id = true, name = true, kind = true, file = true, range = true,
    order = true,
    -- extraction facts
    params = true, locals = true, arrow = true, torn = true, decl = true, macro = true, cbarg = true,
    unparsed = true, df = true, flow = true, data = true, ctype = true, ret = true,
    retclass = true, -- generic Class<T> return: arg index binding the return var
    entry = true, exported = true, effects = true, apertures = true,
    pw = true, -- param-write fact: sorted indexes of OWN params this fn
               -- writes through (lua/js reference semantics; ~ to own params)
    top = true, -- unconditional module-load def (lua): a load-order sibling for
                -- the reassignment-override resolver (resolve_reassign, v56)
    synth = true, -- a synthetic def emitted from a DSL call (ruby attr_*),
                  -- no `def` keyword in the source
    -- token provider (stack languages)
    effect = true, derived = true, echeck = true,
}
M.EDGE_FIELDS = {
    from = true, to = true, kind = true, at = true, atn = true,
    inferred = true, self = true,
    -- trust tiers: type-inferred (graph-VM), oracle proven/xlang,
    -- runtime-confirmed (session-live overlay, self://loaded / MCP)
    tinf = true, proven = true, xlang = true, conf = true,
    bind = true, -- import edges: the local name the import binds (v8);
                 -- absent from the 17-corpus inventory until SE exercised it
    sideeffect = true, -- import edges: required for effect, no binding
    rw = true, -- the write axis (use edges): 1 read / 2 write / 3 both
    gw = true, -- guard chain of the writes: 1 some-unguarded / 2 all-guarded
               -- / 3 all-set-once (absence-guarded: commutative)
    gp = true, -- param predicate: ALL writes fire only when param |gp| is
               -- truthy (gp>0) / falsy (gp<0) — dischargeable per call site
               -- against argv literals (skip direction only)
    flds = true, -- per-field facts: field -> packed rw + gw*4 ('' = whole-var)
}
M.CALL_FIELDS = {
    callee = true, full = true, file = true, line = true, at = true,
    fn = true, to = true, refused = true, inferred = true, args = true,
    argv = true, method = true, top = true, dynamic = true,
    indirect = true, traced = true, strarg = true, hedge = true,
    rt = true, n = true, tinf = true, -- type-inferred tier (graph-VM)
    rtfull = true, -- c.full was SYNTHESIZED by the return-type rounds (not
    -- lexical): the parallel audit nulls it with the resolution it rode

    registry = true, -- string-keyed registry (stage 3): the node id this
    -- retrieval (LibStub("X")/:GetModule("Y")) resolves to (the registered table)
    qualifier = true, -- @Qualifier bean name (interface→impl narrowing)
    escalated = true, -- escalation-on-hedge: oracle-tried, still ~ (anti-thrash)
    bare = true, -- a bare no-paren call surfaced by scan_bare_calls (ruby)
    superx = true, -- ruby `super`: {cls,member,sing} → ancestor's method (R4)
    conf = true, -- runtime-confirmed tier (session-live overlay)
    _av = true, _av0 = true, _avn = true, -- folded argv slice (post-ingest)
}

local SAMPLES = 5 -- violations kept per rule

--- Validate a neutral-schema data table. Returns a report:
---   { ok = bool, checked = {nodes=,edges=,calls=},
---     violations = { rule -> { n = count, sites = {msg,...} } } }
function M.check(data)
    local v = {}
    local function flag(rule, msg)
        local r = v[rule]
        if not r then r = { n = 0, sites = {} }; v[rule] = r end
        r.n = r.n + 1
        if #r.sites < SAMPLES then r.sites[#r.sites + 1] = msg end
    end
    local function ranged(r)
        return type(r) == 'table'
            and type(r.start) == 'table' and type(r['end']) == 'table'
            and type(r.start.line) == 'number'
            and type(r.start.char) == 'number'
            and type(r['end'].line) == 'number'
            and type(r['end'].char) == 'number'
            and r.start.line <= r['end'].line
    end

    local ids = {}
    for _, n in ipairs(data.nodes or {}) do
        if type(n.id) ~= 'string' or type(n.name) ~= 'string'
            or type(n.file) ~= 'string' or type(n.order) ~= 'number' then
            flag('node-required', tostring(n.id))
        elseif ids[n.id] then
            flag('node-dup-id', n.id)
        else
            ids[n.id] = true
        end
        if not M.NODE_KINDS[n.kind] then
            flag('node-kind', ('%s: %s'):format(tostring(n.id), tostring(n.kind)))
        end
        if not ranged(n.range) then
            flag('node-range', tostring(n.id))
        end
        for k in pairs(n) do
            if not M.NODE_FIELDS[k] then
                flag('node-field', ('%s on %s'):format(k, tostring(n.id)))
            end
        end
    end

    local function endpoint(id)
        -- a valid endpoint is a known node id; module ids ARE file paths,
        -- so file-shaped endpoints resolve through their module node
        return ids[id] ~= nil
    end
    for _, e in ipairs(data.edges or {}) do
        if not M.EDGE_KINDS[e.kind] then
            flag('edge-kind', tostring(e.kind))
        end
        if type(e.from) ~= 'string' or not endpoint(e.from) then
            flag('edge-dangling-from', ('%s -> %s'):format(
                tostring(e.from), tostring(e.to)))
        end
        if type(e.to) ~= 'string' or not endpoint(e.to) then
            flag('edge-dangling-to', ('%s -> %s'):format(
                tostring(e.from), tostring(e.to)))
        end
        if e.at ~= nil then
            for _, a in ipairs(e.at) do
                if not ranged(a) then
                    flag('edge-at', ('%s -> %s'):format(
                        tostring(e.from), tostring(e.to)))
                    break
                end
            end
            if e.atn and e.atn < #e.at then
                flag('edge-atn', ('%s -> %s: atn %d < #at %d'):format(
                    tostring(e.from), tostring(e.to), e.atn, #e.at))
            end
        end
        for k in pairs(e) do
            if not M.EDGE_FIELDS[k] then
                flag('edge-field', ('%s on %s -> %s'):format(
                    k, tostring(e.from), tostring(e.to)))
            end
        end
    end

    for _, c in ipairs(data.calls or {}) do
        if type(c.callee) ~= 'string' and type(c.full) ~= 'string' then
            flag('call-callee', ('%s:%s'):format(
                tostring(c.file), tostring(c.line)))
        end
        if type(c.file) ~= 'string' or type(c.line) ~= 'number' then
            flag('call-site', tostring(c.callee))
        end
        if c.refused ~= nil and type(c.refused.rule) ~= 'string' then
            flag('call-refusal-rule', ('%s @ %s:%s'):format(
                tostring(c.callee), tostring(c.file), tostring(c.line)))
        end
        if c.to ~= nil and not ids[c.to] then
            flag('call-dangling-to', ('%s -> %s'):format(
                tostring(c.callee), tostring(c.to)))
        end
        for k in pairs(c) do
            if not M.CALL_FIELDS[k] then
                flag('call-field', ('%s on %s'):format(k, tostring(c.callee)))
            end
        end
    end

    local ok = next(v) == nil
    return { ok = ok, violations = v,
        checked = { nodes = #(data.nodes or {}),
            edges = #(data.edges or {}), calls = #(data.calls or {}) } }
end

--- Render a report for the gate: one line when clean, samples when not.
function M.report(r)
    if r.ok then
        return ('schema: OK (%d nodes, %d edges, %d calls validated)')
            :format(r.checked.nodes, r.checked.edges, r.checked.calls)
    end
    local out = { 'schema: VIOLATIONS' }
    local rules = {}
    for rule in pairs(r.violations) do rules[#rules + 1] = rule end
    table.sort(rules)
    for _, rule in ipairs(rules) do
        local rec = r.violations[rule]
        out[#out + 1] = ('  %s ×%d'):format(rule, rec.n)
        for _, s in ipairs(rec.sites) do
            out[#out + 1] = '    ' .. s
        end
    end
    return table.concat(out, '\n')
end

return M
