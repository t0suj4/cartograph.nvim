-- factoriodistill — distill Factorio's runtime-api.json into an L2 profile
-- artifact for the lua-factorio profile ([[cartograph-stdlib-profile]] input
-- adapter, the factorio analog of tools/rbsdistill.lua for ruby RBS). runtime-
-- api.json is Factorio's DECLARED API export (the free-answer-key shape): classes
-- with typed methods + the global_objects name->class map + global_functions. We
-- emit the 9 GLOBAL objects' classes (game/script/rendering/...) — the sound
-- OWNER-PRECISE mintable set: a `<global>.<method>` call resolves unambiguously to
-- one documented class (measured 0 over-claim on the factorio corpus). Receiver-
-- typed methods (`player.insert`) need receiver typing (measured-negative for
-- dynamic langs) and stay a frontier — NOT distilled here.
--
--   nvim --headless -u NONE -l tools/factoriodistill.lua [<runtime-api.json>]
-- No network, no graph mutation — pure metadata → a version-keyed .mpack artifact.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/factoriodistill%.lua$')
package.path = here .. '/../lua/?.lua;' .. here .. '/../lua/?/init.lua;' .. package.path

local API = (arg and arg[1]) or vim.fn.expand('~/git/Factorio-luacheckrc/.io/runtime-api.json')
-- VERSION-KEYED OUTPUT. arg[2] is a suffix, so one distiller produces the artifact
-- for each environment version and portability can DIFF them: an api absence is weak
-- evidence ("2.0 lacks this name"), while a status CHANGE between two versions is
-- strong ("1.1 had it, 2.0 does not"). Without a suffix the 2.0 artifact keeps its
-- historical name, so existing callers are untouched.
local SUFFIX = (arg and arg[2]) or ''
local RUNTIME = 'lua-factorio-api' .. (SUFFIX ~= '' and ('-' .. SUFFIX) or '')
if vim.fn.filereadable(API) ~= 1 then
    io.write('no runtime-api.json at ' .. API .. '\n'); os.exit(2)
end
local fd = assert(io.open(API, 'r'))
local api = vim.json.decode(fd:read('*a')); fd:close()

-- ── type + signature rendering ───────────────────────────────────────────────
-- a param/return TYPE is a plain string ("LocalisedString") or a complex_type
-- table (union/array/dictionary/...). Render a compact, readable native form.
local function render_type(t, depth)
    depth = depth or 0
    if type(t) == 'string' then return t end
    if type(t) ~= 'table' then return '?' end
    if depth > 4 then return '…' end
    local ct = t.complex_type
    if ct == 'union' then
        local os = {}
        for _, o in ipairs(t.options or {}) do os[#os + 1] = render_type(o, depth + 1) end
        return table.concat(os, ' | ')
    elseif ct == 'array' then return render_type(t.value, depth + 1) .. '[]'
    elseif ct == 'dictionary' or ct == 'LuaCustomTable' then
        return '{[' .. render_type(t.key, depth + 1) .. ']: ' .. render_type(t.value, depth + 1) .. '}'
    elseif ct == 'literal' then
        return type(t.value) == 'string' and ('"' .. t.value .. '"') or tostring(t.value)
    elseif ct == 'type' then return render_type(t.value, depth + 1)
    elseif ct == 'function' then
        local ps = {}
        for _, p in ipairs(t.parameters or {}) do ps[#ps + 1] = render_type(p, depth + 1) end
        return 'function(' .. table.concat(ps, ', ') .. ')'
    elseif ct == 'table' or ct == 'tuple' or ct == 'struct' or ct == 'LuaLazyLoadedValue' then
        return ct
    elseif ct == 'builtin' then return t.name or 'builtin'
    end
    return ct or '?'
end

local function method_sig(m)
    local ps = {}
    if m.takes_table then                        -- a single-table argument: {f1=T1, f2?=T2}
        local fields = {}
        for _, p in ipairs(m.parameters or {}) do
            fields[#fields + 1] = p.name .. (p.optional and '?' or '') .. '=' .. render_type(p.type)
        end
        ps[1] = '{' .. table.concat(fields, ', ') .. '}'
    else
        for _, p in ipairs(m.parameters or {}) do
            ps[#ps + 1] = p.name .. (p.optional and '?' or '') .. ': ' .. render_type(p.type)
        end
    end
    if m.variadic_parameter then
        ps[#ps + 1] = '...: ' .. render_type(m.variadic_parameter.type or 'any')
    end
    local rets = {}
    for _, r in ipairs(m.return_values or {}) do
        rets[#rets + 1] = render_type(r.type) .. (r.optional and '?' or '')
    end
    local sig = '(' .. table.concat(ps, ', ') .. ')'
    if #rets > 0 then sig = sig .. ' -> ' .. table.concat(rets, ', ') end
    return sig
end

-- ── distill the 9 global objects' classes + the free functions ───────────────
local class_by_name = {}
for _, c in ipairs(api.classes) do class_by_name[c.name] = c end

-- BOTH methods AND attributes. Emitting methods only made the member set useless
-- for adjudication: `game.tick`, `game.players`, `game.surfaces` are ATTRIBUTES, so
-- they looked absent, and a genuinely REMOVED name was indistinguishable from a
-- perfectly fine one — `game.entity_prototypes` (renamed to prototypes.entity in
-- 2.0, real porting work) versus `game.tick` (fine). With both kinds in, a miss on
-- a global's member is EVIDENCE, and `complete` below is what lets a consumer rely
-- on that instead of guessing.
local global2class, members, sigs, complete = {}, {}, {}, {}
local n_members, n_attrs = 0, 0
for _, g in ipairs(api.global_objects) do
    global2class[g.name] = g.type
    local c = class_by_name[g.type]
    if c then
        for _, m in ipairs(c.methods or {}) do
            local key = g.type .. '::' .. m.name
            if not members[key] then
                members[key] = true
                sigs[key] = { sig = method_sig(m) }
                n_members = n_members + 1
            end
        end
        for _, a in ipairs(c.attributes or {}) do
            local key = g.type .. '::' .. a.name
            if not members[key] then
                members[key] = true
                -- an attribute has a TYPE and access flags, not a call signature;
                -- rendering it as `: T [read-only]` keeps hover honest about which
                -- kind of member it is
                local acc = {}
                if a.read ~= false then acc[#acc + 1] = 'read' end
                if a.write then acc[#acc + 1] = 'write' end
                sigs[key] = { sig = (': %s [%s]'):format(render_type(a.type),
                    table.concat(acc, '/')), attribute = true }
                n_members = n_members + 1
                n_attrs = n_attrs + 1
            end
        end
        -- COMPLETENESS, declared rather than assumed: this class's documented member
        -- surface is now fully enumerated (methods + attributes), so a consumer may
        -- treat a miss as absence. Operators (`[]`, `#`) are deliberately excluded —
        -- they are not name-addressable, so they cannot make a NAME look absent.
        complete[g.type] = true
    end
end
-- ── REGISTRY TEMPLATES: the environment's own idioms, DERIVED (CART-0226) ────
-- greenspun guesses a registry from call sites (a verb called many times with a
-- string key and a callable). A declared export already KNOWS the shape from types,
-- so the same predicate over signatures yields the environment's idioms
-- authoritatively — and a template turns a suggestion into a lint
-- ([[greenspun-is-suggestive]]).
--
-- FOUR KINDS, measured on this export rather than assumed. Only the first is a shape
-- greenspun could ever have suggested; the rest a profile can supply and a call-site
-- heuristic cannot:
--   string-key  a STRING param + a CALLABLE param      commands.add_command
--   dict        one `{[string]: function()}` param      remote.add_interface
--   enum-key    a NAMED-CONCEPT key + a callable        script.on_event (LuaEventType)
--   hook        a callable and NO key at all            script.on_init / on_load
--
-- `order` IS THE CALL POSITION, NOT THE ARRAY INDEX, and this is not a nicety: for
-- add_command the array is [function, help, name] while the orders are 2, 1, 0 — the
-- real call is add_command(name, help, fn). Using the array index would have put the
-- key at arg 3 and the binding would have matched nothing, silently. xlang's `name`
-- field is 1-based, so it is order + 1.
local function looks_str(t)
    if t == 'string' then return true end
    if type(t) == 'table' then
        if t.complex_type == 'union' then
            for _, o in ipairs(t.options or {}) do if looks_str(o) then return true end end
        elseif t.complex_type == 'literal' then return type(t.value) == 'string'
        elseif t.complex_type == 'type' then return looks_str(t.value) end
    end
    return false
end
-- SYMMETRIC with looks_str: see through unions. `handler: function() | nil` is how an
-- optional callback is declared, and a non-union-aware test misses every one — which
-- is exactly what the first measurement did, reporting 0 where there were 5.
local function looks_fn(t)
    if type(t) ~= 'table' then return false end
    if t.complex_type == 'function' then return true end
    if t.complex_type == 'union' then
        for _, o in ipairs(t.options or {}) do if looks_fn(o) then return true end end
    elseif t.complex_type == 'type' then return looks_fn(t.value) end
    return false
end
local function str_fn_dict(t)
    if type(t) ~= 'table' then return false end
    if t.complex_type ~= 'dictionary' and t.complex_type ~= 'LuaCustomTable' then return false end
    return looks_str(t.key) and looks_fn(t.value)
end
local function concept_key(t)
    if type(t) == 'string' and t:match('^Lua') then return t end
    if type(t) == 'table' then
        if t.complex_type == 'union' then
            for _, o in ipairs(t.options or {}) do
                local n = concept_key(o); if n then return n end
            end
        elseif t.complex_type == 'array' or t.complex_type == 'type' then
            return concept_key(t.value)
        end
    end
    return nil
end

local templates, n_tpl = {}, 0
for _, g in ipairs(api.global_objects) do
    local c = class_by_name[g.type]
    for _, m in ipairs((c or {}).methods or {}) do
        local key_arg, fn_arg, dict_arg, key_type
        for _, p in ipairs(m.parameters or {}) do
            local pos = (p.order or 0) + 1
            if str_fn_dict(p.type) then dict_arg = pos
            elseif looks_fn(p.type) then fn_arg = fn_arg or pos
            elseif looks_str(p.type) then key_arg = key_arg or pos
            elseif not key_type then
                local ck = concept_key(p.type)
                if ck then key_arg, key_type = key_arg or pos, ck end
            end
        end
        local kind
        if dict_arg then kind = 'dict'
        elseif fn_arg and key_arg and key_type then kind = 'enum-key'
        elseif fn_arg and key_arg then kind = 'string-key'
        elseif fn_arg then kind = 'hook' end
        if kind then
            n_tpl = n_tpl + 1
            templates[#templates + 1] = {
                verb = g.name .. '.' .. m.name,       -- how mod code writes it
                member = g.type .. '::' .. m.name,    -- owner-precise identity
                via = g.name, kind = kind,
                key = key_arg or dict_arg, fn = fn_arg or dict_arg,
                key_type = key_type,
            }
        end
    end
end
table.sort(templates, function (x, y) return x.verb < y.verb end)

local free, free_sigs, n_free = {}, {}, 0
for _, fn in ipairs(api.global_functions or {}) do
    free[fn.name] = true
    free_sigs[fn.name] = { sig = method_sig(fn) }
    n_free = n_free + 1
end

local profile = {
    schema = 1, runtime = RUNTIME, lang = 'lua',
    version = api.application_version, api_version = api.api_version,
    stamp = { source = API, application_version = api.application_version,
        api_version = api.api_version, stage = api.stage },
    -- `members` / `complete` are THIS ARTIFACT'S names, and they are deliberate: the
    -- artifact is an INGREDIENT, not a portability target. spec/profile/lua-factorio-11
    -- reads `api.members` / `api.complete` and republishes them as the api_members /
    -- api_complete that portability.provides consults. Renaming them here to match the
    -- consumer looks tidier and silently cuts that bridge (measured: the hand profile's
    -- api_members went empty, so `game.entity_prototypes` degraded from "member of
    -- LuaGameScript" to "namespace game" and stopped being adjudicable as porting work).
    -- If these ever need renaming, move lua-factorio-11.lua in the same commit.
    global2class = global2class, members = members, sigs = sigs,
    complete = complete, -- classes whose member surface is fully enumerated
    -- the environment's REGISTRY IDIOMS, derived from the declared signatures. The
    -- hand profile republishes these; xlang composes them with its global defaults so
    -- a discovered registry that MATCHES one is correct platform usage rather than a
    -- finding, and an ad-hoc one that DUPLICATES one is a real finding.
    templates = templates,
    free = free, free_sigs = free_sigs,
}

local out = here .. '/../lua/cartograph/spec/profile/' .. RUNTIME .. '.mpack'
local tmp = out .. '.tmp.' .. vim.fn.getpid()
local wf = assert(io.open(tmp, 'wb'))
wf:write(vim.mpack.encode(profile)); wf:close()
assert(os.rename(tmp, out))

io.write('=== factoriodistill ===\n')
io.write(('  runtime-api %s (api v%s, %s) — %d classes, %d globals\n'):format(
    api.application_version, api.api_version, api.stage, #api.classes, #api.global_objects))
io.write(('  global objects: %d ; members: %d (%d attributes) ; free fns: %d\n')
    :format(#api.global_objects, n_members, n_attrs, n_free))
for _, g in ipairs(api.global_objects) do
    local c = class_by_name[g.type]
    io.write(('    %-12s -> %-22s %d methods + %d attributes%s\n'):format(g.name,
        g.type, c and #(c.methods or {}) or 0, c and #(c.attributes or {}) or 0,
        complete[g.type] and ' [complete]' or ''))
end
io.write(('  registry TEMPLATES derived: %d\n'):format(n_tpl))
for _, t in ipairs(templates) do
    io.write(('    %-34s %-11s key=%s fn=%s%s\n'):format(t.verb, t.kind,
        tostring(t.key), tostring(t.fn),
        t.key_type and (' <' .. t.key_type .. '>') or ''))
end
io.write('  sample: LuaGameScript::print = ' .. (sigs['LuaGameScript::print']
    and sigs['LuaGameScript::print'].sig or '?') .. '\n')
io.write('  wrote ' .. out .. '\n')
