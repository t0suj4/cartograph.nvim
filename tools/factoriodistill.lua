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

local global2class, members, sigs = {}, {}, {}
local n_members = 0
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
    end
end
local free, free_sigs, n_free = {}, {}, 0
for _, fn in ipairs(api.global_functions or {}) do
    free[fn.name] = true
    free_sigs[fn.name] = { sig = method_sig(fn) }
    n_free = n_free + 1
end

local profile = {
    schema = 1, runtime = 'lua-factorio-api', lang = 'lua',
    version = api.application_version, api_version = api.api_version,
    stamp = { source = API, application_version = api.application_version,
        api_version = api.api_version, stage = api.stage },
    global2class = global2class, members = members, sigs = sigs,
    free = free, free_sigs = free_sigs,
}

local out = here .. '/../lua/cartograph/spec/profile/lua-factorio-api.mpack'
local tmp = out .. '.tmp.' .. vim.fn.getpid()
local wf = assert(io.open(tmp, 'wb'))
wf:write(vim.mpack.encode(profile)); wf:close()
assert(os.rename(tmp, out))

io.write('=== factoriodistill ===\n')
io.write(('  runtime-api %s (api v%s, %s) — %d classes, %d globals\n'):format(
    api.application_version, api.api_version, api.stage, #api.classes, #api.global_objects))
io.write(('  global objects: %d ; owner-precise methods: %d ; free fns: %d\n'):format(
    #api.global_objects, n_members, n_free))
for _, g in ipairs(api.global_objects) do
    local c = class_by_name[g.type]
    io.write(('    %-12s -> %-22s %d methods\n'):format(g.name, g.type, c and #(c.methods or {}) or 0))
end
io.write('  sample: LuaGameScript::print = ' .. (sigs['LuaGameScript::print']
    and sigs['LuaGameScript::print'].sig or '?') .. '\n')
io.write('  wrote ' .. out .. '\n')
