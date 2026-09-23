-- terraform.lua — THE DECLARED CLOUD LAYER: Terraform modules, their resources, and the
-- values that can be known WITHOUT running Terraform (CART-1042).
--
-- ★ WHY A READER WITH AN EVALUATOR, NOT A PATTERN. A DNS record never spells its host:
--     resource "azurerm_dns_a_record" "trusted_permanent_agent_2" {
--       name      = "agent-2"
--       zone_name = module.trusted_ci_jenkins_io_letsencrypt.zone_name
-- The host is `name` + `.` + the zone, and the zone is an OUTPUT of a local module whose
-- input is a literal three hops away. So this parses every block into a small expression
-- tree and evaluates it statically: literals, templates, locals, variable defaults, module
-- inputs bound PER INSTANCE, module outputs, data-source and resource ARGUMENTS, and the
-- functions the corpus actually uses (census: concat, split, lookup, format, replace, …).
--
-- ★★ WHAT CANNOT BE KNOWN IS SAID, NOT GUESSED. A computed attribute (an IP address, an id),
-- an index into a `count`/`for_each` resource, a remote module, a function this evaluator
-- does not implement — each evaluates to an UNKNOWN carrying its reason, and a template
-- touching one is unknown as a whole. A host is reported resolved only when every part is.
--
-- ── WHAT IT MINTS ─────────────────────────────────────────────────────────────
-- Each .tf file is a `module` node (the proto/k8s/helmfile convention; a `resource` kind is
-- CART-0140's schema change). A module call is a `use` edge from the calling file to each
-- file of the child module. The model rides on `data.terraform`: modules (one per directory),
-- instances (a root module, or a module call with its inputs bound), resources, and DNS
-- records with their evaluated hosts.

local M = {}

-- ── values ────────────────────────────────────────────────────────────────────
local function U(why, absent) return { unknown = why, absent = absent or nil } end
M.unknown = U
local function is_u(v) return type(v) == 'table' and v.unknown ~= nil end
M.is_unknown = is_u
local function list(items) return { list = items } end
local function map(o, keys) return { map = o, keys = keys } end

local function tostr(v)
    if type(v) == 'string' then return v end
    if type(v) == 'number' then
        if v == math.floor(v) then return tostring(math.floor(v)) end
        return tostring(v)
    end
    if type(v) == 'boolean' then return tostring(v) end
    return nil
end

-- ── parsing: the CST into a small expression tree ─────────────────────────────
local function txt(n, src) return vim.treesitter.get_node_text(n, src) end

local function unescape(s)
    return (s:gsub('\\(.)', { n = '\n', t = '\t', r = '\r', ['"'] = '"', ['\\'] = '\\' }))
end

local expr

local function named_kids(n)
    local out = {}
    for c in n:iter_children() do if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end end
    return out
end

-- a quoted/heredoc template: literal pieces and interpolations
local function template(n, src)
    local parts = {}
    for c in n:iter_children() do
        local t = c:type()
        if t == 'template_literal' then parts[#parts + 1] = unescape(txt(c, src))
        elseif t == 'template_interpolation' then
            local e
            for x in c:iter_children() do if x:type() == 'expression' then e = x end end
            parts[#parts + 1] = e and expr(e, src) or { t = 'unknown', text = txt(c, src) }
        elseif t == 'template_directive' then
            parts[#parts + 1] = { t = 'unknown', text = 'a %{ } template directive' }
        elseif c:named() and t ~= 'quoted_template_start' and t ~= 'quoted_template_end'
            and t ~= 'heredoc_start' and t ~= 'heredoc_identifier' then
            local sub = template(c, src)
            for _, p in ipairs(sub.parts) do parts[#parts + 1] = p end
        end
    end
    return { t = 'tmpl', parts = parts }
end

local function primary(n, src)
    local t = n:type()
    if t == 'literal_value' then
        local c = named_kids(n)[1]
        if not c then return { t = 'lit', v = nil } end
        local ct = c:type()
        if ct == 'string_lit' then
            local s = template(c, src)
            if #s.parts == 0 then return { t = 'lit', v = '' } end
            if #s.parts == 1 and type(s.parts[1]) == 'string' then return { t = 'lit', v = s.parts[1] } end
            return s
        end
        if ct == 'numeric_lit' then return { t = 'lit', v = tonumber(txt(c, src)) } end
        if ct == 'bool_lit' then return { t = 'lit', v = txt(c, src) == 'true' } end
        if ct == 'null_lit' then return { t = 'null' } end
        return { t = 'unknown', text = txt(c, src) }
    end
    if t == 'template_expr' then
        local c = named_kids(n)[1]
        return c and template(c, src) or { t = 'lit', v = '' }
    end
    if t == 'variable_expr' then return { t = 'ref', root = txt(named_kids(n)[1], src), steps = {} } end
    if t == 'function_call' then
        local kids = named_kids(n)
        local args = {}
        for _, c in ipairs(kids) do
            if c:type() == 'function_arguments' then
                for _, a in ipairs(named_kids(c)) do
                    if a:type() == 'expression' then args[#args + 1] = expr(a, src) end
                end
            end
        end
        return { t = 'call', name = txt(kids[1], src), args = args }
    end
    if t == 'collection_value' then
        local c = named_kids(n)[1]
        if c and c:type() == 'tuple' then
            local items = {}
            for _, x in ipairs(named_kids(c)) do if x:type() == 'expression' then items[#items + 1] = expr(x, src) end end
            return { t = 'tuple', items = items }
        end
        if c and c:type() == 'object' then
            local pairs_ = {}
            for _, el in ipairs(named_kids(c)) do
                if el:type() == 'object_elem' then
                    local ek = named_kids(el)
                    if #ek >= 2 then pairs_[#pairs_ + 1] = { k = expr(ek[1], src), v = expr(ek[2], src) } end
                end
            end
            return { t = 'object', pairs = pairs_ }
        end
    end
    if t == 'conditional' then
        local k = named_kids(n)
        return { t = 'cond', c = expr(k[1], src), a = expr(k[2], src), b = expr(k[3], src) }
    end
    if t == 'for_expr' then
        local c = named_kids(n)[1]
        if not c then return { t = 'unknown', text = txt(n, src) } end
        local f = { t = 'for', kind = c:type() == 'for_object_expr' and 'object' or 'tuple', vars = {}, bodies = {} }
        for x in c:iter_children() do
            local xt = x:type()
            if xt == 'for_intro' then
                for y in x:iter_children() do
                    if y:type() == 'identifier' then f.vars[#f.vars + 1] = txt(y, src)
                    elseif y:type() == 'expression' then f.coll = expr(y, src) end
                end
            elseif xt == 'expression' then f.bodies[#f.bodies + 1] = expr(x, src)
            elseif xt == 'for_cond' then
                for y in x:iter_children() do if y:type() == 'expression' then f.cond = expr(y, src) end end
            elseif xt == 'ellipsis' then f.group = true end
        end
        return f
    end
    if t == 'expression' then return expr(n, src) end
    if t == 'operation' then
        local c = named_kids(n)[1]
        if c then return primary(c, src) end
    end
    if t == 'unary_operation' or t == 'binary_operation' then
        -- ⚠ OPERANDS ARE FLAT SIBLINGS: a primary, then its get_attr/index steps, then the
        -- operator token, then the right operand. And the grammar attaches `.y` AFTER `!var`
        -- (`!var.y` parses as `(!var).y`), so a unary operator takes trailing steps inside.
        local groups, op, cur = {}, nil, {}
        for c in n:iter_children() do
            if not c:named() and c:type() ~= '(' and c:type() ~= ')' then
                if #cur > 0 or t == 'binary_operation' then groups[#groups + 1] = cur; cur = {} end
                op = c:type()
            elseif c:named() and c:type() ~= 'comment' then cur[#cur + 1] = c end
        end
        groups[#groups + 1] = cur
        local function seq(nodes)
            if #nodes == 0 then return { t = 'unknown', text = 'an empty operand' } end
            local e = primary(nodes[1], src)
            for i = 2, #nodes do
                local sn = nodes[i]
                local step
                if sn:type() == 'get_attr' then
                    local id = named_kids(sn)[1]
                    step = { attr = id and txt(id, src) or '?' }
                elseif sn:type() == 'index' then
                    local inner
                    for _, x in ipairs(named_kids(sn)) do
                        for _, y in ipairs(named_kids(x)) do if y:type() == 'expression' then inner = y end end
                        if x:type() == 'expression' then inner = x end
                    end
                    step = { index = inner and expr(inner, src) or { t = 'unknown', text = txt(sn, src) } }
                else return { t = 'unknown', text = txt(n, src):sub(1, 60) } end
                local target = e
                if e.t == 'op' and #e.args == 1 then target = e.args[1] end -- (!var).y means !(var.y)
                if target.t == 'ref' then target.steps[#target.steps + 1] = step
                elseif e.t == 'op' and #e.args == 1 then e.args[1] = { t = 'step', base = target, step = step }
                else e = { t = 'step', base = e, step = step } end
            end
            return e
        end
        if t == 'unary_operation' then return { t = 'op', op = op, args = { seq(groups[#groups]) } } end
        local nonempty = {}
        for _, g in ipairs(groups) do if #g > 0 then nonempty[#nonempty + 1] = g end end
        if #nonempty ~= 2 or not op then return { t = 'unknown', text = txt(n, src):sub(1, 60) } end
        return { t = 'op', op = op, args = { seq(nonempty[1]), seq(nonempty[2]) } }
    end
    return { t = 'unknown', text = txt(n, src):sub(1, 60) }
end

expr = function(n, src)
    local kids = named_kids(n)
    if #kids == 0 then return { t = 'unknown', text = txt(n, src) } end
    local e = primary(kids[1], src)
    for i = 2, #kids do
        local s = kids[i]
        local st = s:type()
        if st == 'get_attr' then
            local id = named_kids(s)[1]
            local step = { attr = id and txt(id, src) or '?' }
            if e.t == 'ref' then e.steps[#e.steps + 1] = step else e = { t = 'step', base = e, step = step } end
        elseif st == 'index' then
            local inner
            for _, x in ipairs(named_kids(s)) do
                for _, y in ipairs(named_kids(x)) do if y:type() == 'expression' then inner = y end end
                if x:type() == 'expression' then inner = x end
            end
            local step = { index = inner and expr(inner, src) or { t = 'unknown', text = txt(s, src) } }
            if e.t == 'ref' then e.steps[#e.steps + 1] = step else e = { t = 'step', base = e, step = step } end
        else
            e = { t = 'unknown', text = txt(n, src):sub(1, 60) } -- splat, operators on the tail
            break
        end
    end
    return e
end

--- Parse one file's text into its top-level blocks.
--- @return table|nil blocks, string|nil why
function M.parse(src, file)
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'terraform')
    if not okp then return nil, 'no terraform tree-sitter parser' end
    local tree = parser:parse()[1]
    if not tree then return nil, 'terraform parse failed' end
    local function block(n)
        local b = { labels = {}, attrs = {}, blocks = {}, file = file, line = (n:range()) }
        for c in n:iter_children() do
            local t = c:type()
            if t == 'identifier' and not b.kind then b.kind = txt(c, src)
            elseif t == 'string_lit' then
                local s = template(c, src)
                b.labels[#b.labels + 1] = (#s.parts == 1 and type(s.parts[1]) == 'string') and s.parts[1] or txt(c, src)
            elseif t == 'identifier' then b.labels[#b.labels + 1] = txt(c, src)
            elseif t == 'body' then
                for x in c:iter_children() do
                    if x:type() == 'attribute' then
                        local k = named_kids(x)
                        local id = k[1] and txt(k[1], src)
                        if id and k[2] then b.attrs[id] = expr(k[2], src) end
                    elseif x:type() == 'block' then
                        b.blocks[#b.blocks + 1] = block(x)
                    end
                end
            end
        end
        return b
    end
    local out = {}
    local root = tree:root()
    for c in root:iter_children() do
        if c:type() == 'body' then
            for x in c:iter_children() do if x:type() == 'block' then out[#out + 1] = block(x) end end
        end
    end
    return out, root:has_error() and 'the file has a parse error; blocks after it may be missing' or nil
end

-- ── modules: one per directory ────────────────────────────────────────────────
local function new_module(dir)
    return { dir = dir, files = {}, resources = {}, data = {}, locals = {}, vars = {}, outputs = {}, calls = {}, order = {} }
end

function M.add_blocks(mod, blocks)
    for _, b in ipairs(blocks) do
        if b.kind == 'resource' and #b.labels >= 2 then
            local key = b.labels[1] .. '.' .. b.labels[2]
            mod.resources[key] = b
            mod.order[#mod.order + 1] = key
        elseif b.kind == 'data' and #b.labels >= 2 then mod.data[b.labels[1] .. '.' .. b.labels[2]] = b
        elseif b.kind == 'locals' then for k, v in pairs(b.attrs) do mod.locals[k] = v end
        elseif b.kind == 'variable' and b.labels[1] then mod.vars[b.labels[1]] = b
        elseif b.kind == 'output' and b.labels[1] then mod.outputs[b.labels[1]] = b
        elseif b.kind == 'module' and b.labels[1] then mod.calls[b.labels[1]] = b end
    end
end

-- a root-relative path from a module-relative one, `..` resolved
local function join(dir, rel)
    local parts = {}
    for seg in ((dir ~= '' and (dir .. '/') or '') .. rel):gmatch('[^/]+') do
        if seg == '..' then if #parts == 0 then return nil end; table.remove(parts)
        elseif seg ~= '.' then parts[#parts + 1] = seg end
    end
    return table.concat(parts, '/')
end

-- ── evaluation ────────────────────────────────────────────────────────────────
local FUNCS = {}
local function need_str(v, fname)
    local s = tostr(v)
    if s == nil then return nil, U(fname .. ': a non-string argument') end
    return s
end
FUNCS.lower = function(a) local s, u = need_str(a[1], 'lower'); return u or s:lower() end
FUNCS.upper = function(a) local s, u = need_str(a[1], 'upper'); return u or s:upper() end
FUNCS.tostring = function(a) local s, u = need_str(a[1], 'tostring'); return u or s end
FUNCS.trimsuffix = function(a)
    local s, u = need_str(a[1], 'trimsuffix'); if u then return u end
    local x = tostr(a[2]) or ''
    if x ~= '' and s:sub(-#x) == x then return s:sub(1, -#x - 1) end
    return s
end
FUNCS.trimprefix = function(a)
    local s, u = need_str(a[1], 'trimprefix'); if u then return u end
    local x = tostr(a[2]) or ''
    if x ~= '' and s:sub(1, #x) == x then return s:sub(#x + 1) end
    return s
end
FUNCS.replace = function(a)
    local s, u = need_str(a[1], 'replace'); if u then return u end
    local from, to = tostr(a[2]), tostr(a[3])
    if not from or not to then return U('replace: non-string argument') end
    if from:match('^/.*/$') then return U('replace with a regular expression is not evaluated') end
    local out, i = {}, 1
    if from == '' then return s end
    while true do
        local j = s:find(from, i, true)
        if not j then out[#out + 1] = s:sub(i); break end
        out[#out + 1] = s:sub(i, j - 1); out[#out + 1] = to; i = j + #from
    end
    return table.concat(out)
end
FUNCS.format = function(a)
    local f, u = need_str(a[1], 'format'); if u then return u end
    local k = 1
    local bad
    local s = f:gsub('%%([%%sdv])', function (c)
        if c == '%' then return '%' end
        k = k + 1
        local v = tostr(a[k])
        if v == nil then bad = true; return '' end
        return v
    end)
    if bad then return U('format: an argument is not a string') end
    return s
end
FUNCS.join = function(a)
    local sep = tostr(a[1])
    if not sep or type(a[2]) ~= 'table' or not a[2].list then return U('join: not a list') end
    local parts = {}
    for _, x in ipairs(a[2].list) do
        local s = tostr(x); if not s then return U('join: a non-string element') end
        parts[#parts + 1] = s
    end
    return table.concat(parts, sep)
end
FUNCS.split = function(a)
    local sep, s = tostr(a[1]), tostr(a[2])
    if not sep or not s then return U('split: non-string argument') end
    local out, i = {}, 1
    while true do
        local j = sep ~= '' and s:find(sep, i, true)
        if not j then out[#out + 1] = s:sub(i); break end
        out[#out + 1] = s:sub(i, j - 1); i = j + #sep
    end
    return list(out)
end
FUNCS.concat = function(a)
    local out = {}
    for _, l in ipairs(a) do
        if type(l) ~= 'table' or not l.list then return U('concat: not a list') end
        for _, x in ipairs(l.list) do out[#out + 1] = x end
    end
    return list(out)
end
FUNCS.length = function(a)
    local v = a[1]
    if type(v) == 'string' then return #v end
    if type(v) == 'table' and v.list then return #v.list end
    if type(v) == 'table' and v.map then return #v.keys end
    return U('length: not a collection')
end
FUNCS.element = function(a)
    local l, i = a[1], a[2]
    if type(l) ~= 'table' or not l.list or type(i) ~= 'number' or #l.list == 0 then return U('element: bad arguments') end
    return l.list[(math.floor(i) % #l.list) + 1]
end
FUNCS.lookup = function(a)
    local m, k = a[1], tostr(a[2])
    if type(m) ~= 'table' or not m.map or not k then return U('lookup: not a map') end
    local v = m.map[k]
    if v == nil then return a[3] ~= nil and a[3] or U('lookup: key ' .. k .. ' absent') end
    return v
end
FUNCS.merge = function(a)
    local o, keys = {}, {}
    for _, m in ipairs(a) do
        if type(m) ~= 'table' or not m.map then return U('merge: not a map') end
        for _, k in ipairs(m.keys) do if o[k] == nil then keys[#keys + 1] = k end; o[k] = m.map[k] end
    end
    return map(o, keys)
end
FUNCS.coalesce = function(a)
    for _, v in ipairs(a) do if v ~= nil and v ~= '' then return v end end
    return U('coalesce: every argument empty')
end
for _, id in ipairs { 'tolist', 'tomap' } do FUNCS[id] = function(a) return a[1] end end
FUNCS.compact = function(a)
    if type(a[1]) ~= 'table' or not a[1].list then return U('compact: not a list') end
    local out = {}
    for _, x in ipairs(a[1].list) do if x ~= nil and x ~= '' then out[#out + 1] = x end end
    return list(out)
end
FUNCS.distinct = function(a)
    if type(a[1]) ~= 'table' or not a[1].list then return U('distinct: not a list') end
    local out, seen = {}, {}
    for _, x in ipairs(a[1].list) do local s = tostr(x) or tostring(x); if not seen[s] then seen[s] = true; out[#out + 1] = x end end
    return list(out)
end
FUNCS.sort = function(a)
    if type(a[1]) ~= 'table' or not a[1].list then return U('sort: not a list') end
    local out = {}
    for _, x in ipairs(a[1].list) do local s = tostr(x); if not s then return U('sort: a non-string element') end; out[#out + 1] = s end
    table.sort(out)
    return list(out)
end
FUNCS.flatten = function(a)
    local out = {}
    local function go(v)
        if type(v) == 'table' and v.list then for _, x in ipairs(v.list) do go(x) end
        else out[#out + 1] = v end
    end
    if type(a[1]) ~= 'table' or not a[1].list then return U('flatten: not a list') end
    go(a[1])
    return list(out)
end
FUNCS.keys = function(a)
    if type(a[1]) ~= 'table' or not a[1].map then return U('keys: not a map') end
    local ks = {}
    for _, k in ipairs(a[1].keys) do ks[#ks + 1] = k end
    table.sort(ks)
    return list(ks)
end
FUNCS.values = function(a)
    if type(a[1]) ~= 'table' or not a[1].map then return U('values: not a map') end
    local ks = {}
    for _, k in ipairs(a[1].keys) do ks[#ks + 1] = k end
    table.sort(ks)
    local out = {}
    for _, k in ipairs(ks) do out[#out + 1] = a[1].map[k] end
    return list(out)
end
FUNCS.contains = function(a)
    if type(a[1]) ~= 'table' or not a[1].list then return U('contains: not a list') end
    local want = tostr(a[2])
    if not want then return U('contains: a non-string value') end
    for _, x in ipairs(a[1].list) do if tostr(x) == want then return true end end
    return false
end
FUNCS.trimspace = function(a) local s, u = need_str(a[1], 'trimspace'); return u or (s:gsub('^%s+', ''):gsub('%s+$', '')) end
FUNCS.toset = function(a)
    if type(a[1]) ~= 'table' or not a[1].list then return a[1] end
    local out, seen = {}, {}
    for _, x in ipairs(a[1].list) do
        local k = tostr(x)
        if k == nil then out[#out + 1] = x elseif not seen[k] then seen[k] = true; out[#out + 1] = x end
    end
    return list(out)
end
FUNCS.setproduct = function(a)
    local acc = { {} }
    for _, l in ipairs(a) do
        if type(l) ~= 'table' or not l.list then return U('setproduct: not a list') end
        local nxt = {}
        for _, prefix in ipairs(acc) do
            for _, x in ipairs(l.list) do
                local row = {}
                for i2, y in ipairs(prefix) do row[i2] = y end
                row[#row + 1] = x
                nxt[#nxt + 1] = row
            end
        end
        acc = nxt
    end
    local out = {}
    for _, row in ipairs(acc) do out[#out + 1] = list(row) end
    return list(out)
end
--- yamldecode through cartograph's own YAML reader (scalars stay strings: the BaseLoader contract)
FUNCS.yamldecode = function(a)
    local src = tostr(a[1])
    if not src then return U('yamldecode of a non-string') end
    local v, why = require('cartograph.yamlvalue').read_one(src)
    if not v then return U('yamldecode: ' .. tostring(why)) end
    local function conv(x)
        if type(x) == 'table' and x.o then
            local o, keys = {}, {}
            for _, k in ipairs(x.keys) do o[k] = conv(x.o[k]); keys[#keys + 1] = k end
            return map(o, keys)
        end
        if type(x) == 'table' and x.a then
            local out = {}
            for i, y in ipairs(x.a) do out[i] = conv(y) end
            return list(out)
        end
        return x
    end
    return conv(v)
end
M.FUNCS = FUNCS

local META = { source = true, version = true, providers = true, count = true, for_each = true, depends_on = true }

-- ── SYMBOLIC VALUES (user, 2026-09-23: "manipulate the unknowns like opaque objects") ──
-- ★ AN UNKNOWN IS A NAMED HOLE, NOT A DEAD END. What only Terraform knows (a computed id, an
-- IP) is an OPAQUE value carrying its canonical ADDRESS — the innermost resource attribute,
-- reached through module outputs per instance — so two references to the same thing are EQUAL
-- without knowing it (cert.ci and assets.cert.ci point at ONE controller NIC). A template or a
-- string function touching an opaque keeps its structure as a RESIDUAL (a template with holes,
-- the algebra's own sense). UNKNOWN (`U`) is left for what cannot even be NAMED: an
-- unimplemented function, an undecidable condition, a cycle.
local function O(addr, ref) return { opaque = addr, ref = ref } end
M.opaque = O
local function is_sym(v) return type(v) == 'table' and (v.opaque ~= nil or v.tmpl ~= nil or v.call ~= nil) end
M.is_symbolic = is_sym

--- a symbolic value as text: holes as «address»
local function render(v)
    if type(v) ~= 'table' then return tostr(v) or tostring(v) end
    if v.opaque then return '«' .. v.opaque .. '»' end
    if v.tmpl then
        local out = {}
        for _, p in ipairs(v.tmpl) do out[#out + 1] = type(p) == 'string' and p or render(p) end
        return table.concat(out)
    end
    if v.call then
        local as = {}
        for _, x in ipairs(v.args) do as[#as + 1] = type(x) == 'string' and ('%q'):format(x) or render(x) end
        return v.call .. '(' .. table.concat(as, ', ') .. ')'
    end
    if v.unknown then return '?' end
    return tostring(v)
end
M.render = render

-- a residual template from pieces (strings, symbolic values), flattened; all-string -> a string
local function residual(pieces)
    local parts, all = {}, true
    for _, p in ipairs(pieces) do
        if type(p) == 'table' and p.tmpl then
            for _, q in ipairs(p.tmpl) do parts[#parts + 1] = q; if type(q) ~= 'string' then all = false end end
        elseif type(p) == 'string' then parts[#parts + 1] = p
        else parts[#parts + 1] = p; all = false end
    end
    if all then return table.concat(parts) end
    local merged = {}
    for _, p in ipairs(parts) do
        if type(p) == 'string' and type(merged[#merged]) == 'string' then merged[#merged] = merged[#merged] .. p
        elseif p ~= '' then merged[#merged + 1] = p end
    end
    return { tmpl = merged }
end

--- An INSTANCE: a module with its inputs bound (a root module has none).
local function instance(mod, inputs, key, parent)
    return { mod = mod, inputs = inputs or {}, key = key, parent = parent, memo = {}, busy = {}, scope = {},
        fsroot = parent and parent.fsroot }
end

local eval
local block_attr

-- an INSTANCE OBJECT: one element of a counted / for_each block, whose attributes evaluate with
-- `count.index` / `each` bound
local function inst_obj(b, inst, what, ctx) return { rinst = true, block = b, inst = inst, what = what, ctx = ctx } end
local function ctx_suffix(ctx)
    if not ctx then return '' end
    if ctx.idx ~= nil then return '[' .. ctx.idx .. ']' end
    if ctx.key ~= nil then return '["' .. ctx.key .. '"]' end
    return ''
end

local function apply_steps(v, steps, from, inst, trail)
    for i = from, #steps do
        if is_u(v) then return v end
        local s = steps[i]
        if type(v) == 'table' and v.rinst then
            if not s.attr then return U(('an index into %s%s'):format(v.what, ctx_suffix(v.ctx))) end
            v = block_attr(v.block, s.attr, v.inst, v.what, v.ctx)
        elseif type(v) == 'table' and v.opaque then
            -- a step into an opaque is a deeper opaque: the address extends, identity is kept
            if s.attr then v = O(v.opaque .. '.' .. s.attr)
            else
                local k = eval(s.index, inst)
                if is_u(k) or is_sym(k) then return U('an unknown index into an opaque value (' .. trail .. ')') end
                v = O(v.opaque .. '[' .. tostring(tostr(k) or k) .. ']')
            end
        elseif s.attr then
            if type(v) == 'table' and v.map then
                local x = v.map[s.attr]
                if x == nil then return U(('attribute %s absent from %s'):format(s.attr, trail), true) end
                v = x
            else return U(('.%s on a non-object (%s)'):format(s.attr, trail)) end
        else
            local k = eval(s.index, inst)
            if is_u(k) then return k end
            if is_sym(k) then return U('an opaque index (' .. trail .. ')') end
            if type(v) == 'table' and v.list and type(k) == 'number' then v = v.list[math.floor(k) + 1]
            elseif type(v) == 'table' and v.map and tostr(k) then v = v.map[tostr(k)]
            else return U('index into a non-collection (' .. trail .. ')') end
            if v == nil then return U('index out of range (' .. trail .. ')', true) end
        end
    end
    return v
end

--- ★ PROVIDER FACTS: attributes a provider DOCUMENTS as equal to an argument. Believing one
--- PRODUCES a resolution, never suppresses a finding (the failure-asymmetry rule), and each
--- carries its source. Measured need: every DigitalOcean record names its zone as
--- `digitalocean_domain.X.id` — 6 of 7 records unresolved without this row.
M.PROVIDER_FACTS = {
    -- registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/domain:
    -- "id - The name of the domain"
    digitalocean_domain = { id = 'name' },
}

--- An argument of a block, evaluated with its instance context (`count.index`, `each`) bound.
--- A missing argument is OPAQUE: computed by the provider (or absent) — named, not guessed.
block_attr = function(b, attr, inst, what, ctx)
    if b.attrs.count and not (ctx and ctx.idx ~= nil) then
        return U(('%s uses count: an attribute needs an index'):format(what))
    end
    if b.attrs.for_each and not (ctx and ctx.key ~= nil) then
        return U(('%s uses for_each: an attribute needs a key'):format(what))
    end
    local e = b.attrs[attr]
    local fact = not e and M.PROVIDER_FACTS[b.labels[1]] and M.PROVIDER_FACTS[b.labels[1]][attr]
    if fact then e = b.attrs[fact] end
    if not e then
        return O(inst.key .. ':' .. what .. ctx_suffix(ctx) .. '.' .. attr, { inst = inst, block = b, attr = attr, ctx = ctx, what = what })
    end
    local si, se = inst.count_index, inst.each
    inst.count_index = ctx and ctx.idx
    inst.each = ctx and ctx.key ~= nil and { key = ctx.key, value = ctx.value } or nil
    local v = eval(e, inst)
    inst.count_index, inst.each = si, se
    return v
end

--- ★ THE KEYS OF A for_each, WHEN THEY ARE DECIDABLE: a map's keys (its values may stay
--- opaque — the instances are still known), or a set of strings. A collection whose KEYS are
--- opaque has no nameable instances.
local function foreach_keys(b, inst, what)
    local v = eval(b.attrs.for_each, inst)
    if is_u(v) then return nil, U(('the for_each of %s is unknown: %s'):format(what, v.unknown)) end
    if is_sym(v) then return nil, U(('the for_each of %s is opaque: %s'):format(what, render(v))) end
    local out = {}
    if type(v) == 'table' and v.map then
        for _, k in ipairs(v.keys) do out[#out + 1] = { key = k, value = v.map[k] } end
        return out
    end
    if type(v) == 'table' and v.list then
        for _, x in ipairs(v.list) do
            if x and x.rinst then return nil, U(('the for_each of %s iterates instance objects'):format(what)) end
            local k = tostr(x)
            if not k then return nil, U(('the for_each of %s holds an opaque or non-string element'):format(what)) end
            out[#out + 1] = { key = k, value = k }
        end
        return out
    end
    return nil, U(('the for_each of %s is not a map or a set'):format(what))
end
M._foreach_keys = foreach_keys

--- ★ COUNT, WHEN IT IS DECIDABLE (`var.x ? 1 : 0`, `length(data.z)`).
local function count_of(b, inst, what)
    local n = eval(b.attrs.count, inst)
    if is_u(n) then return nil, U(('the count of %s is unknown: %s'):format(what, n.unknown)) end
    if type(n) ~= 'number' then return nil, U(('the count of %s is not a number'):format(what)) end
    return n
end

--- A reference into a (possibly counted / for_each) block: `T.N.attr`, `T.N[i].attr`,
--- `T.N["k"].attr`, or `T.N` as the collection of its instance objects.
local function block_ref(b, st, first, inst, what)
    if b.attrs.count then
        local n, u = count_of(b, inst, what)
        if not n then return u end
        local s = st[first]
        if s and s.index then
            local i = eval(s.index, inst)
            if is_u(i) then return i end
            if type(i) ~= 'number' or i < 0 or i >= n then return U(('%s[%s] is beyond its count %d'):format(what, tostring(i), n)) end
            return apply_steps(inst_obj(b, inst, what, { idx = i }), st, first + 1, inst, what)
        end
        if s then return U(('%s uses count: .%s needs an index'):format(what, tostring(s.attr))) end
        local items = {}
        for i = 0, n - 1 do items[#items + 1] = inst_obj(b, inst, what, { idx = i }) end
        return list(items)
    end
    if b.attrs.for_each then
        local ks, u = foreach_keys(b, inst, what)
        if not ks then return u end
        local s = st[first]
        if s and s.index then
            local k = eval(s.index, inst)
            if is_u(k) then return k end
            k = tostr(k)
            for _, e in ipairs(ks) do
                if e.key == k then return apply_steps(inst_obj(b, inst, what, e), st, first + 1, inst, what) end
            end
            return U(('%s has no instance ["%s"]'):format(what, tostring(k)))
        end
        if s then return U(('%s uses for_each: .%s needs a key'):format(what, tostring(s.attr))) end
        local o, keys = {}, {}
        for _, e in ipairs(ks) do o[e.key] = inst_obj(b, inst, what, e); keys[#keys + 1] = e.key end
        return map(o, keys)
    end
    local a = st[first] and st[first].attr
    if not a then return U(('%s as a whole object is not evaluated'):format(what)) end
    return apply_steps(block_attr(b, a, inst, what), st, first + 1, inst, what)
end

--- A module call's instance (or instances, for a module with count/for_each).
local function child_instance(inst, name, ctx)
    local call = inst.mod.calls[name]
    if not call then return nil, U('no module "' .. name .. '"') end
    local src = call.attrs.source and eval(call.attrs.source, inst)
    if type(src) ~= 'string' then return nil, U('module ' .. name .. ': source not a string') end
    if not (src:sub(1, 2) == './' or src:sub(1, 3) == '../') then
        return nil, O(inst.key .. ':module.' .. name .. '(remote ' .. src .. ')'), 'remote'
    end
    local dir = join(inst.mod.dir, src)
    local child = dir and inst.models[dir]
    if not child then return nil, U(('module %s: source %s is not in the tree'):format(name, src)) end
    if (call.attrs.count or call.attrs.for_each) and not ctx then
        return nil, U(('module %s uses count/for_each: an output needs an index or key'):format(name))
    end
    local key = inst.key .. '/module.' .. name .. ctx_suffix(ctx)
    if inst.children[key] then return inst.children[key] end
    local inputs = {}
    for k, e in pairs(call.attrs) do if not META[k] then inputs[k] = { expr = e, inst = inst, ctx = ctx } end end
    local ci = instance(child, inputs, key, inst)
    ci.models, ci.children = inst.models, inst.children
    inst.children[key] = ci
    return ci
end
M._child_instance = child_instance

-- the instance contexts of a module call: one plain, or one per index / key
local function call_contexts(inst, name)
    local call = inst.mod.calls[name]
    if call.attrs.count then
        local n = count_of(call, inst, 'module.' .. name)
        if not n then return {} end
        local out = {}
        for i = 0, n - 1 do out[#out + 1] = { idx = i } end
        return out
    end
    if call.attrs.for_each then return foreach_keys(call, inst, 'module.' .. name) or {} end
    return { false }
end

local function eval_ref(e, inst)
    local root, st = e.root, e.steps
    local mod = inst.mod
    local function attr(i) return st[i] and st[i].attr end
    -- a `for` iterator in scope shadows everything
    inst.scope = inst.scope or {}
    for i = #inst.scope, 1, -1 do
        local sc = inst.scope[i]
        if sc[root] ~= nil then return apply_steps(sc[root], st, 1, inst, root) end
    end
    if root == 'local' then
        local name = attr(1)
        local ex = name and mod.locals[name]
        if not ex then return U('no local ' .. tostring(name)) end
        local mk = 'local.' .. name
        if inst.memo[mk] == nil then
            if inst.busy[mk] then return U('a cycle through local.' .. name) end
            inst.busy[mk] = true
            local v = eval(ex, inst)
            inst.memo[mk] = v == nil and { null = true } or v
            inst.busy[mk] = nil
        end
        local v = inst.memo[mk]
        if type(v) == 'table' and v.null then v = nil end
        return apply_steps(v, st, 2, inst, 'local.' .. name)
    end
    if root == 'var' then
        local name = attr(1)
        local bound = name and inst.inputs[name]
        local v
        if bound then
            local bi = bound.inst
            local si, se = bi.count_index, bi.each
            bi.count_index = bound.ctx and bound.ctx.idx
            bi.each = bound.ctx and bound.ctx.key ~= nil and { key = bound.ctx.key, value = bound.ctx.value } or nil
            v = eval(bound.expr, bi)
            bi.count_index, bi.each = si, se
        else
            local decl = name and mod.vars[name]
            if decl and decl.attrs.default then v = eval(decl.attrs.default, inst)
            else v = O(inst.key .. ':var.' .. tostring(name)) end -- supplied at apply time: an input from outside
        end
        return apply_steps(v, st, 2, inst, 'var.' .. tostring(name))
    end
    if root == 'data' then
        local key = (attr(1) or '?') .. '.' .. (attr(2) or '?')
        local b = mod.data[key]
        if not b then return U('no data ' .. key) end
        return block_ref(b, st, 3, inst, 'data.' .. key)
    end
    if root == 'module' then
        local name = attr(1) or '?'
        local call = mod.calls[name]
        local first, ctx = 2, nil
        if call and (call.attrs.count or call.attrs.for_each) and st[2] and st[2].index then
            local k = eval(st[2].index, inst)
            if is_u(k) then return k end
            if call.attrs.count then ctx = { idx = k }
            else
                for _, c in ipairs(call_contexts(inst, name)) do if c and c.key == tostr(k) then ctx = c end end
                if not ctx then return U(('module %s has no instance ["%s"]'):format(name, tostring(k))) end
            end
            first = 3
        end
        local ci, u = child_instance(inst, name, ctx)
        if not ci then
            if type(u) == 'table' and u.opaque then return apply_steps(u, st, first, inst, 'module.' .. name) end
            return u
        end
        local oname = attr(first) or '?'
        local out = ci.mod.outputs[oname]
        if not out or not out.attrs.value then return U(('module %s has no output %s'):format(name, oname)) end
        return apply_steps(eval(out.attrs.value, ci), st, first + 1, inst, 'module.' .. name .. '.' .. oname)
    end
    if root == 'count' and attr(1) == 'index' and inst.count_index ~= nil then return inst.count_index end
    if root == 'each' and inst.each then
        if attr(1) == 'key' then return apply_steps(inst.each.key, st, 2, inst, 'each.key') end
        if attr(1) == 'value' then return apply_steps(inst.each.value, st, 2, inst, 'each.value') end
    end
    -- ★ path.module IS STATICALLY KNOWN: it is the module's own directory (relative to the root)
    if root == 'path' and (attr(1) == 'module' or attr(1) == 'root') then
        local d = attr(1) == 'module' and inst.mod.dir or ''
        return apply_steps(d == '' and '.' or d, st, 2, inst, 'path.' .. attr(1))
    end
    if root == 'path' or root == 'terraform' then return O(inst.key .. ':' .. root .. '.' .. tostring(attr(1))) end
    if root == 'each' or root == 'count' or root == 'self' then
        return U(root .. '.* outside the block that binds it')
    end
    local key = root .. '.' .. (attr(1) or '?')
    local b = mod.resources[key]
    if not b then return U('no resource ' .. key) end
    return block_ref(b, st, 2, inst, key)
end

-- functions that accept an opaque string and return a residual CALL (the value stays named)
local STRINGISH = { lower = true, upper = true, tostring = true, trimsuffix = true, trimprefix = true,
    replace = true, trimspace = true, coalesce = true }

eval = function(e, inst, depth)
    depth = (depth or 0) + 1
    if depth > 80 then return U('evaluation too deep') end
    local t = e.t
    if t == 'lit' then return e.v end
    if t == 'null' then return nil end
    if t == 'tmpl' then
        local pieces = {}
        for _, p in ipairs(e.parts) do
            if type(p) == 'string' then pieces[#pieces + 1] = p
            else
                local v = eval(p, inst, depth)
                if is_u(v) then return v end
                if is_sym(v) then pieces[#pieces + 1] = v
                else
                    local s = tostr(v)
                    if s == nil then return U('a template interpolates a non-string value') end
                    pieces[#pieces + 1] = s
                end
            end
        end
        return residual(pieces)
    end
    if t == 'ref' then return eval_ref(e, inst) end
    if t == 'step' then
        local b = eval(e.base, inst, depth)
        return apply_steps(b, { e.step }, 1, inst, 'an expression')
    end
    if t == 'call' and (e.name == 'can' or e.name == 'try') then
        -- ★ SPECIAL FORMS: they catch an ABSENT attribute/index (`can(v["secret_name"])`), never
        -- a real unknown — an unimplemented function inside stays unknown
        for i, a in ipairs(e.args) do
            local v = eval(a, inst, depth)
            if e.name == 'can' then
                if is_u(v) then if v.absent then return false end; return v end
                return true
            end
            if not (is_u(v) and v.absent) or i == #e.args then return v end
        end
        return U('try with no alternative')
    end
    if t == 'call' and e.name == 'file' then
        local pv = e.args[1] and eval(e.args[1], inst, depth)
        if is_u(pv) or is_sym(pv) then return is_u(pv) and pv or U('file of an opaque path') end
        local rel = tostr(pv) and join('', (tostr(pv):gsub('^%./', '')))
        if not rel or not inst.fsroot then return U('file outside the tree') end -- never read outside the root
        local fd = io.open(inst.fsroot .. '/' .. rel, 'rb')
        if not fd then return U('file ' .. rel .. ' is not in the tree') end
        local body = fd:read('*a'); fd:close()
        return body
    end
    if t == 'call' then
        local f = FUNCS[e.name]
        if not f then return U('function ' .. e.name .. ' is not evaluated') end
        local args, sym = {}, false
        for i, a in ipairs(e.args) do
            local v = eval(a, inst, depth)
            if is_u(v) then return v end
            if is_sym(v) then sym = true end
            args[i] = v
        end
        if sym then
            if STRINGISH[e.name] then return { call = e.name, args = args } end
            if e.name == 'format' then
                local fmt = tostr(args[1])
                if not fmt then return U('format with an opaque format string') end
                local pieces, k, last = {}, 1, 1
                for pos, c in fmt:gmatch('()%%([%%sdv])') do
                    pieces[#pieces + 1] = fmt:sub(last, pos - 1)
                    if c == '%' then pieces[#pieces + 1] = '%'
                    else
                        k = k + 1
                        local v = args[k]
                        if is_sym(v) then pieces[#pieces + 1] = v
                        else local sv = tostr(v); if not sv then return U('format: an argument is not a string') end; pieces[#pieces + 1] = sv end
                    end
                    last = pos + 2
                end
                pieces[#pieces + 1] = fmt:sub(last)
                return residual(pieces)
            end
            if e.name == 'join' then
                local sep = tostr(args[1])
                if not sep or type(args[2]) ~= 'table' or not args[2].list then return U('join over an opaque list') end
                local pieces = {}
                for i2, x in ipairs(args[2].list) do
                    if i2 > 1 then pieces[#pieces + 1] = sep end
                    if is_sym(x) then pieces[#pieces + 1] = x
                    else local sv = tostr(x); if not sv then return U('join: a non-string element') end; pieces[#pieces + 1] = sv end
                end
                return residual(pieces)
            end
            -- collection functions see only the collection's SHAPE; an opaque ARGUMENT is not one
            for _, v in ipairs(args) do
                if type(v) == 'table' and (v.opaque or v.tmpl or v.call) then
                    return U(('%s over an opaque value %s'):format(e.name, render(v)))
                end
            end
        end
        return f(args)
    end
    if t == 'tuple' then
        local items = {}
        for i, x in ipairs(e.items) do
            local v = eval(x, inst, depth)
            if is_u(v) then return v end
            items[i] = v
        end
        return list(items)
    end
    if t == 'object' then
        local o, keys = {}, {}
        for _, p in ipairs(e.pairs) do
            local k = p.k.t == 'ref' and #p.k.steps == 0 and p.k.root or tostr(eval(p.k, inst, depth))
            if not k then return U('an object key that is not a string') end
            local v = eval(p.v, inst, depth)
            if is_u(v) then return v end
            if o[k] == nil then keys[#keys + 1] = k end
            o[k] = v
        end
        return map(o, keys)
    end
    if t == 'for' then
        inst.scope = inst.scope or {}
        local c = eval(e.coll, inst, depth)
        if is_u(c) then return c end
        if is_u(c) then return c end
        if is_sym(c) then return U('a for expression over an opaque collection ' .. render(c)) end
        local pairs_ = {}
        if type(c) == 'table' and c.map then for _, k in ipairs(c.keys) do pairs_[#pairs_ + 1] = { k, c.map[k] } end
        elseif type(c) == 'table' and c.list then for i, x in ipairs(c.list) do pairs_[#pairs_ + 1] = { i - 1, x } end
        else return U('a for expression over a non-collection') end
        local kv, vv = e.vars[1], e.vars[2]
        if not vv then kv, vv = nil, e.vars[1] end
        local o, keys, items = {}, {}, {}
        for _, pr in ipairs(pairs_) do
            local sc = {}
            if kv then sc[kv] = pr[1] end
            sc[vv] = pr[2]
            inst.scope[#inst.scope + 1] = sc
            local keep = true
            if e.cond then
                local cv = eval(e.cond, inst, depth)
                if cv ~= true and cv ~= false then
                    inst.scope[#inst.scope] = nil
                    return is_u(cv) and cv or U('a for condition that is not a boolean')
                end
                keep = cv
            end
            if keep then
                if e.kind == 'object' then
                    local k = eval(e.bodies[1], inst, depth)
                    local v = e.bodies[2] and eval(e.bodies[2], inst, depth)
                    k = tostr(k)
                    if not k or is_u(v) then inst.scope[#inst.scope] = nil; return is_u(v) and v or U('a for key that is not a string') end
                    if o[k] ~= nil then
                        inst.scope[#inst.scope] = nil
                        if not e.group then return U('a for expression produced the key ' .. k .. ' twice') end
                        return U('grouping (...) in a for expression is not evaluated')
                    end
                    keys[#keys + 1] = k; o[k] = v
                else
                    local v = eval(e.bodies[1], inst, depth)
                    if is_u(v) then inst.scope[#inst.scope] = nil; return v end
                    items[#items + 1] = v
                end
            end
            inst.scope[#inst.scope] = nil
        end
        if e.kind == 'object' then return map(o, keys) end
        return list(items)
    end
    if t == 'cond' then
        local c = eval(e.c, inst, depth)
        if is_u(c) then return c end
        if c == true then return eval(e.a, inst, depth) end
        if c == false then return eval(e.b, inst, depth) end
        return U(is_sym(c) and ('a condition over an opaque value ' .. render(c)) or 'a condition that is not a boolean')
    end
    if t == 'op' then
        local vals = {}
        for i, a in ipairs(e.args) do
            local v = eval(a, inst, depth)
            if is_u(v) then return v end
            vals[i] = v
        end
        local op, a, b = e.op, vals[1], vals[2]
        if #e.args == 1 then
            if op == '!' then if type(a) == 'boolean' then return not a end; return U('! on a non-boolean') end
            if op == '-' then if type(a) == 'number' then return -a end; return U('- on a non-number') end
            return U('unary ' .. tostring(op))
        end
        if op == '==' or op == '!=' then
            local eqv
            if is_sym(a) or is_sym(b) then
                -- two opaques with ONE address are equal; anything else about an opaque is undecided
                if type(a) == 'table' and type(b) == 'table' and a.opaque and b.opaque and a.opaque == b.opaque then eqv = true
                else return U(('%s over an opaque value'):format(op)) end
            elseif a == nil or b == nil then eqv = (a == b)
            else eqv = (a == b) or (tostr(a) ~= nil and tostr(a) == tostr(b)) end
            if op == '==' then return eqv end
            return not eqv
        end
        if op == '&&' or op == '||' then
            if type(a) ~= 'boolean' or type(b) ~= 'boolean' then return U(op .. ' on a non-boolean') end
            if op == '&&' then return a and b end
            return a or b
        end
        if type(a) ~= 'number' or type(b) ~= 'number' then return U(('%s on a non-number'):format(op)) end
        if op == '+' then return a + b elseif op == '-' then return a - b elseif op == '*' then return a * b
        elseif op == '/' then return b ~= 0 and a / b or U('division by zero')
        elseif op == '%' then return b ~= 0 and a % b or U('modulo by zero')
        elseif op == '<' then return a < b elseif op == '>' then return a > b
        elseif op == '<=' then return a <= b elseif op == '>=' then return a >= b end
        return U('operator ' .. tostring(op))
    end
    return U('not evaluated: ' .. tostring(e.text or t))
end
M.eval = eval

-- ── DNS: the host a record declares ───────────────────────────────────────────
local function host_of(name, zone)
    if is_u(name) then return name end
    if is_u(zone) then return zone end
    if is_sym(name) or is_sym(zone) then
        if tostr(name) == '@' or tostr(name) == '' then return zone end
        return residual({ name, '.', zone })
    end
    local n, z = tostr(name), tostr(zone)
    if not n or not z then return U('the record name or zone is not a string') end
    if n == '@' or n == '' then return z end
    return n .. '.' .. z
end

--- ★ IDENTITY-DIRECTED RESOLUTION: an opaque `X.id` names the RESOURCE it belongs to, so a zone
--- passed as an id is that resource's declared `name` — read from the declaration the id comes
--- from, never parsed out of the id's text.
local function name_of_id(v)
    if type(v) == 'table' and v.opaque and v.ref and v.ref.attr == 'id' and v.ref.block then
        local b = v.ref.block
        if b.attrs.name then return block_attr(b, 'name', v.ref.inst, v.ref.what, v.ref.ctx) end
    end
    return nil
end
M._name_of_id = name_of_id

local RECORD = {
    -- type -> function(block, inst, eval_attr) -> list of { host, kind }
    azurerm_dns_zone = function(b, ev) return { { host = ev('name'), rr = 'zone' } } end,
    digitalocean_domain = function(b, ev) return { { host = ev('name'), rr = 'zone' } } end,
    digitalocean_record = function(b, ev) return { { host = host_of(ev('name'), ev('domain')), rr = tostr(ev('type')) or '?' } } end,
    fastly_service_vcl = function(b, _, inst)
        local out = {}
        for _, sub in ipairs(b.blocks) do
            if sub.kind == 'domain' and sub.attrs.name then out[#out + 1] = { host = eval(sub.attrs.name, inst), rr = 'cdn' } end
        end
        return out
    end,
}
for _, rr in ipairs { 'a', 'aaaa', 'cname', 'txt', 'mx', 'ns', 'srv', 'caa', 'ptr' } do
    RECORD['azurerm_dns_' .. rr .. '_record'] = function(b, ev)
        return { { host = host_of(ev('name'), ev('zone_name')), rr = rr:upper() } }
    end
    RECORD['azurerm_private_dns_' .. rr .. '_record'] = function(b, ev)
        local zone = b.attrs.zone_name and ev('zone_name')
        if not zone and b.attrs.private_dns_zone_id then
            local zid = ev('private_dns_zone_id')
            zone = name_of_id(zid) or zid
        end
        return { { host = host_of(ev('name'), zone or ev('zone_name')), rr = rr:upper(), private = true } }
    end
end
RECORD.azurerm_private_dns_zone = function(b, ev) return { { host = ev('name'), rr = 'zone', private = true } } end
M.RECORD = RECORD

-- ── reading a tree ────────────────────────────────────────────────────────────
local function readf(p) local fd = io.open(p, 'rb'); if not fd then return nil end; local s = fd:read('*a'); fd:close(); return s end

--- Every .tf file under `root`, as root-relative paths (the walk's exclusion set; `.terraform`
--- and other dot-directories are skipped).
function M.find(root, tp)
    tp = tp or require 'cartograph.transport'
    local ex = require('cartograph.providers.treesitter').EXCLUDE_DIRS or {}
    local out = {}
    local function rec(rel)
        for name, t in tp.dir(rel == '' and root or (root .. '/' .. rel)) do
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if t == 'directory' then if not ex[name:lower()] then rec(r) end
                elseif name:match('%.tf$') then out[#out + 1] = r end
            end
        end
    end
    rec('')
    table.sort(out)
    return out
end

--- Read a tree of .tf files into modules, instances and DNS records.
--- @return table model { models, roots, instances, records, resources, refusals }
function M.read(root, files)
    local models, refusals = {}, {}
    for _, rel in ipairs(files) do
        local src = readf(root .. '/' .. rel)
        if src then
            local blocks, why = M.parse(src, rel)
            if not blocks then refusals[#refusals + 1] = rel .. ': ' .. tostring(why)
            else
                if why then refusals[#refusals + 1] = rel .. ': ' .. why end
                local dir = rel:match('^(.*)/[^/]+$') or ''
                models[dir] = models[dir] or new_module(dir)
                table.insert(models[dir].files, rel)
                M.add_blocks(models[dir], blocks)
            end
        end
    end
    -- a ROOT module is a directory no local module call points at
    local called = {}
    for dir, mod in pairs(models) do
        for _, call in pairs(mod.calls) do
            local s = call.attrs.source
            if s and s.t == 'lit' and type(s.v) == 'string' and (s.v:sub(1, 2) == './' or s.v:sub(1, 3) == '../') then
                local d = join(dir, s.v); if d then called[d] = true end
            end
        end
    end
    local roots, dirs = {}, {}
    for dir in pairs(models) do dirs[#dirs + 1] = dir end
    table.sort(dirs)
    local children = {}
    for _, dir in ipairs(dirs) do
        if not called[dir] then
            local inst = instance(models[dir], nil, dir == '' and '.' or dir, nil)
            inst.models, inst.children, inst.fsroot = models, children, root
            roots[#roots + 1] = inst
        end
    end
    -- every instance: the roots, then each local module call, depth-first
    local instances = {}
    local function visit(inst, depth)
        instances[#instances + 1] = inst
        if depth > 8 then return end
        local names = {}
        for n in pairs(inst.mod.calls) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do
            for _, c in ipairs(call_contexts(inst, n)) do
                local ci = child_instance(inst, n, c or nil)
                if type(ci) == 'table' and ci.mod then visit(ci, depth + 1) end
            end
        end
    end
    for _, r in ipairs(roots) do visit(r, 0) end
    -- resources and DNS records, per instance
    local records, resources = {}, {}
    for _, inst in ipairs(instances) do
        for _, key in ipairs(inst.mod.order) do
            local b = inst.mod.resources[key]
            resources[#resources + 1] = { address = inst.key .. ':' .. key, type = b.labels[1], file = b.file, line = b.line }
            local rec = RECORD[b.labels[1]]
            if rec then
                -- a counted record is one record per index, a for_each record one per key; a
                -- count of 0 declares none here; an undecidable count/for_each is one unknown
                local ctxs, why = { false }, nil
                if b.attrs.count then
                    local n, u = count_of(b, inst, key)
                    if n then ctxs = {}; for i = 0, n - 1 do ctxs[#ctxs + 1] = { idx = i } end
                    else why = u.unknown end
                elseif b.attrs.for_each then
                    local ks, u = foreach_keys(b, inst, key)
                    if ks then ctxs = ks else why = u.unknown end
                end
                for _, c in ipairs(ctxs) do
                    local ctx = c or nil
                    local function ev(a2)
                        if why then return U(why) end
                        return block_attr(b, a2, inst, key, ctx)
                    end
                    local si, se = inst.count_index, inst.each
                    inst.count_index = ctx and ctx.idx
                    inst.each = ctx and ctx.key ~= nil and { key = ctx.key, value = ctx.value } or nil
                    local rs = rec(b, ev, inst)
                    -- what an A/AAAA/CNAME record POINTS AT: identities, even when opaque
                    local targets = {}
                    local tv = not why and (b.attrs.records or b.attrs.record) and ev(b.attrs.records and 'records' or 'record')
                    local function collect(v)
                        if type(v) == 'table' and v.list then for _, x in ipairs(v.list) do collect(x) end
                        elseif v ~= nil and not is_u(v) then targets[#targets + 1] = render(v) end
                    end
                    if tv then collect(tv) end
                    inst.count_index, inst.each = si, se
                    for _, r in ipairs(rs) do
                        r.address = inst.key .. ':' .. key .. ctx_suffix(ctx)
                        r.file, r.line, r.instance, r.targets = b.file, b.line, inst.key, targets
                        if is_u(r.host) then r.unresolved, r.host = r.host.unknown, nil
                        elseif is_sym(r.host) then r.partial, r.sym, r.host = render(r.host), r.host, nil end
                        records[#records + 1] = r
                    end
                end
            end
        end
    end
    -- ★ ENDPOINTS: record targets shared by several hosts are ONE endpoint, by identity
    local endpoints = {}
    for _, r in ipairs(records) do
        for _, t in ipairs(r.targets or {}) do
            endpoints[t] = endpoints[t] or {}
            local name = r.host or r.partial
            if name then
                local dup = false
                for _, x in ipairs(endpoints[t]) do if x == name then dup = true end end
                if not dup then table.insert(endpoints[t], name) end
            end
        end
    end
    return { models = models, roots = roots, instances = instances, records = records, resources = resources, refusals = refusals, endpoints = endpoints }
end

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

--- Mint the declared cloud layer into `data`. Idempotent under refresh.
function M.attach(data, opts)
    local stats = { files = 0, modules = 0, instances = 0, resources = 0, records = 0, resolved = 0, partial = 0, shared = 0, refusals = {} }
    if not data or not data.root then data.terraform = nil; return stats end
    local keep, mine = {}, {}
    for _, n in ipairs(data.nodes or {}) do if n.tf then mine[n.id] = true else keep[#keep + 1] = n end end
    if next(mine) then
        local edges = {}
        for _, e in ipairs(data.edges or {}) do if not (e.tf or mine[e.from] or mine[e.to]) then edges[#edges + 1] = e end end
        data.nodes, data.edges = keep, edges
    end
    local files = (opts and opts.files) or M.find(data.root, opts and opts.transport)
    if #files == 0 then data.terraform = nil; return stats end
    local model = M.read(data.root, files)
    data.nodes = data.nodes or {}
    data.edges = data.edges or {}
    for _, rel in ipairs(files) do
        data.nodes[#data.nodes + 1] = { id = rel, name = rel, kind = 'module', file = rel, range = R0, order = 0, tf = true }
        stats.files = stats.files + 1
    end
    -- a module call is a `use` edge from the calling file to each file of the child module
    for dir, mod in pairs(model.models) do
        stats.modules = stats.modules + 1
        for name, call in pairs(mod.calls) do
            local s = call.attrs.source
            local d = s and s.t == 'lit' and type(s.v) == 'string' and s.v:match('^%.%.?/') and join(dir, s.v)
            local child = d and model.models[d]
            for _, f in ipairs(child and child.files or {}) do
                data.edges[#data.edges + 1] = { from = call.file, to = f, kind = 'use', tf = 'module', module = name, at = {} }
            end
        end
    end
    stats.instances, stats.resources, stats.records = #model.instances, #model.resources, #model.records
    for _, r in ipairs(model.records) do
        if r.host then stats.resolved = stats.resolved + 1 elseif r.partial then stats.partial = stats.partial + 1 end
    end
    for _, hosts in pairs(model.endpoints) do if #hosts >= 2 then stats.shared = stats.shared + 1 end end
    stats.refusals = model.refusals
    data.terraform = model
    return stats
end

function M.summary(s)
    if not s or s.files == 0 then return nil end
    return ('terraform: %d file(s) in %d module(s), %d instance(s), %d resource(s); %d DNS record(s), %d resolved to a host,'
        .. ' %d partial (opaque holes), %d endpoint(s) shared by several hosts%s')
        :format(s.files, s.modules, s.instances, s.resources, s.records, s.resolved, s.partial, s.shared,
            #s.refusals > 0 and (' — %d file(s) with parse errors'):format(#s.refusals) or '')
end

return M
