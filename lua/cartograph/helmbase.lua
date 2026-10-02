-- cartograph.helmbase — a chart's AUTHORED base against the INFERRED base of the plain manifests it should produce
-- (CART-0873). The authored base is the chart rendered with NO values (helmprov symbolic: every values-dependent spot a
-- `⟨.Values…⟩` placeholder); the inferred base is the keyed generalization of the manifests (algebra kv_generalize:
-- the spots that VARY between them are its holes). Paired per document — the chart's `templates/<x>.yaml` with
-- `<manifests>/<x>.yaml`, same kind — and compared spot by spot:
--   a spot that varies between the manifests is, in the chart,
--     param      a placeholder there                      agreement
--     block      a placeholder ABOVE it (`toYaml .Values.x.resources`) — agreement at a coarser grain
--     hardcoded  a literal in every template              EXTEND THE CHART HERE — located to each template line
--     absent     missing from the chart
--   a chart placeholder where every manifest AGREES (no varying spot at or below it) is a KNOB THE CORPUS NEVER TURNS.
-- ⚠ "varies" is relative to the corpus: with one deployment per service, a service name is a constant of that corpus.
local M = {}

local MARK = '\u{27e8}'

local function readf(p) local fd = io.open(p); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end
local function placeholder(v) return type(v) == 'string' and v:find(MARK, 1, true) ~= nil end

--- the value at a generalizer site path (`$.a.b[name].server[1].c`) | nil
function M.at(v, path)
    local rest = path:gsub('^%$', ''):gsub('%?$', '')
    while rest ~= '' do
        if v == nil then return nil end
        local key, r2 = rest:match('^%.([^.%[]+)(.*)$')
        if key then
            if type(v) ~= 'table' or not v.o then return nil end
            v, rest = v.o[key], r2
        else
            local kf, r3 = rest:match('^%[(%a+)%](.*)$')
            if kf then
                local name, r4 = r3:match('^%.([^.%[]+)(.*)$')
                if not name or type(v) ~= 'table' or not v.a then return nil end
                local hit
                for _, x in ipairs(v.a) do if type(x) == 'table' and x.o and x.o[kf] == name then hit = x end end
                v, rest = hit, r4
            else
                local j, r5 = rest:match('^%[(%d+)%](.*)$')
                if not j or type(v) ~= 'table' or not v.a then return nil end
                v, rest = v.a[tonumber(j)], r5
            end
        end
    end
    return v
end

local function parent(path) return path:match('^(.*)%.[^.]+$') or path:match('^(.*)%[[^%]]+%]$') end

-- every document of a YAML text, with its kind and its 0-based byte offset in the text (separators: a `---` line)
local function docs(Y, src)
    local out, start = {}, 1
    local function take(stop)
        local chunk = src:sub(start, stop)
        local d = Y.read_one(chunk)
        if type(d) == 'table' and d.o and type(d.o.kind) == 'string' then out[#out + 1] = { kind = d.o.kind, value = d, text = chunk, at = start - 1 } end
    end
    local pos = 1
    while true do
        local a, b = src:find('%-%-%-[^\n]*\n', pos)
        if not a then break end
        if a == 1 or src:sub(a - 1, a - 1) == '\n' then take(a - 1); start = b + 1 end
        pos = b + 1
    end
    take(#src)
    return out
end

--- the template line that wrote the literal of a hardcoded spot: its `key: value` text in the rendered document,
--- through helmprov's spans -> file, line | nil
local function locate(P, prov, fname, doc, site, literal)
    local key = site:match('%.([^.%[]+)$')
    if not key or type(literal) ~= 'string' then return nil end
    local i = doc.text:find(key .. ':%s*["\']?' .. vim.pesc(literal) .. '["\']?%s*\n')
        or doc.text:find('name:%s*' .. vim.pesc(key) .. '%s*\n%s*value:%s*["\']?' .. vim.pesc(literal))
    if not i then return nil end
    local b = doc.at + doc.text:find(vim.pesc(literal), i) - 1
    local file, line = P.position(prov, fname, b)
    return file, line
end

--- DIFF a chart against a directory of plain manifests -> { pairs = { { name, kind } }, sites = { { site, kind, class,
--- per = { [name] = class }, at = { "file:line" … } } }, knobs = { { name, kind, site, value } }, counts } | nil, why
function M.diff(chart, manifests)
    local P = require 'cartograph.helmprov'
    local Y = require 'cartograph.yamlvalue'
    local A = require('cartograph.algebra').load()
    local prov, why = P.render(chart, { symbolic = true })
    if not prov then return nil, why end
    -- the pairs, per kind
    local bykind, paired = {}, {}
    for _, f in ipairs(vim.fn.glob(manifests .. '/*.yaml', false, true)) do
        local x = vim.fn.fnamemodify(f, ':t:r')
        local fname
        for name in next, prov.files do if name:match('/templates/' .. vim.pesc(x) .. '%.yaml$') then fname = name end end
        if fname then
            -- the i-th document of a kind in the manifest with the i-th of that kind in the template (an authored name
            -- is a placeholder, so names cannot pair them)
            local adocs, mdocs = docs(Y, prov.files[fname].content), docs(Y, readf(f) or '')
            local nth = {}
            for _, a in ipairs(adocs) do nth[a.kind] = nth[a.kind] or {}; table.insert(nth[a.kind], a) end
            local used = {}
            for _, m in ipairs(mdocs) do
                used[m.kind] = (used[m.kind] or 0) + 1
                local a = nth[m.kind] and nth[m.kind][used[m.kind]]
                if a then
                    local nm = x .. (used[m.kind] > 1 and ('#' .. used[m.kind]) or '')
                    bykind[m.kind] = bykind[m.kind] or {}
                    table.insert(bykind[m.kind], { name = nm, m = m.value, a = a.value, adoc = a, fname = fname })
                    paired[#paired + 1] = { name = nm, kind = m.kind }
                end
            end
        end
    end
    local out = { pairs = paired, sites = {}, knobs = {}, counts = { param = 0, block = 0, hardcoded = 0, absent = 0, mixed = 0, knobs = 0 } }
    local kinds = vim.tbl_keys(bykind)
    table.sort(kinds)
    for _, kind in ipairs(kinds) do
        local xs = bykind[kind]
        if #xs >= 2 then -- one document generalizes to itself: nothing varies
            local inst = {}
            for i, x in ipairs(xs) do inst[i] = x.m end
            local R = A.kv_generalize(inst, {})
            local varying = {}
            for _, h in ipairs(R.holes) do
                if h.kind == 'value' then
                    for _, site in ipairs(h.sites) do
                        varying[site] = true
                        local per, seen, at = {}, {}, {}
                        for _, x in ipairs(xs) do
                            local mv = M.at(x.m, site)
                            if mv ~= nil then
                                local v = M.at(x.a, site)
                                local c = v == nil and 'absent' or placeholder(v) and 'param' or 'hardcoded'
                                if c == 'absent' then
                                    local pre = parent(site)
                                    while pre and pre ~= '$' and pre ~= '' do
                                        if placeholder(M.at(x.a, pre)) then c = 'block'; break end
                                        pre = parent(pre)
                                    end
                                end
                                if c == 'hardcoded' then
                                    local file, line = locate(P, prov, x.fname, x.adoc, site, tostring(v))
                                    if file then at[#at + 1] = file .. ':' .. line end
                                end
                                per[x.name], seen[c] = c, true
                            end
                        end
                        local class = vim.tbl_count(seen) == 1 and next(seen) or 'mixed'
                        out.counts[class] = out.counts[class] + 1
                        out.sites[#out.sites + 1] = { site = site, kind = kind, class = class, per = per, at = at }
                    end
                end
            end
            -- knobs: a placeholder at a spot with nothing varying at or below it, present in the manifest
            local function walk(v, path, x)
                if placeholder(v) then
                    for site in pairs(varying) do
                        if site == path or site:sub(1, #path + 1) == path .. '.' or site:sub(1, #path + 1) == path .. '[' then return end
                    end
                    if M.at(x.m, path) ~= nil then
                        out.knobs[#out.knobs + 1] = { name = x.name, kind = kind, site = path, value = v }
                        out.counts.knobs = out.counts.knobs + 1
                    end
                elseif type(v) == 'table' and v.o then
                    for _, k in ipairs(v.keys) do walk(v.o[k], path .. '.' .. k, x) end
                elseif type(v) == 'table' and v.a then
                    local keyed = #v.a > 0
                    for _, e in ipairs(v.a) do if not (type(e) == 'table' and e.o and type(e.o.name) == 'string') then keyed = false end end
                    for j, e in ipairs(v.a) do walk(e, keyed and (path .. '[name].' .. e.o.name) or (path .. '[' .. j .. ']'), x) end
                end
            end
            for _, x in ipairs(xs) do walk(x.a, '$', x) end
        end
    end
    return out
end

--- the report, one line per finding
function M.lines(r)
    local c = r.counts
    local l = { ('helmbase: %d paired document(s); %d varying spot(s): %d parameter, %d block parameter, %d HARDCODED, %d absent from the chart, %d mixed; %d knob(s) the corpus never turns')
        :format(#r.pairs, c.param + c.block + c.hardcoded + c.absent + c.mixed, c.param, c.block, c.hardcoded, c.absent, c.mixed, c.knobs) }
    for _, s in ipairs(r.sites) do
        if s.class ~= 'param' and s.class ~= 'block' then
            local detail = ''
            if s.class == 'mixed' then -- which documents differ from the rest
                local by = {}
                for name, c in pairs(s.per) do by[c] = by[c] or {}; table.insert(by[c], name) end
                local parts = {}
                for c, names in pairs(by) do table.sort(names); parts[#parts + 1] = c .. ': ' .. (#names > 3 and (#names .. ' documents') or table.concat(names, ' ')) end
                table.sort(parts)
                detail = ' (' .. table.concat(parts, '; ') .. ')'
            end
            l[#l + 1] = ('  %s %s %s%s%s'):format(s.class == 'hardcoded' and 'EXTEND THE CHART HERE:' or s.class .. ':', s.kind, s.site, detail,
                #s.at > 0 and ('  at ' .. table.concat(s.at, ' ')) or '')
        end
    end
    for _, k in ipairs(r.knobs) do l[#l + 1] = ('  knob never turned: %s %s %s = %s'):format(k.kind, k.name, k.site, k.value) end
    return l
end

--- quickfix items: every template line holding a literal where the manifests vary (hardcoded, or the hardcoded part of
--- a mixed spot) — the lines to extend the chart at
function M.items(chart, r)
    local items = {}
    for _, s in ipairs(r.sites) do
        for _, at in ipairs(s.at) do
            local file, line = at:match('^(.*):(%d+)$')
            items[#items + 1] = { filename = chart .. '/' .. file, lnum = tonumber(line), col = 1,
                text = ('extend the chart here: %s %s varies across the manifests, hardcoded in the template'):format(s.kind, s.site) }
        end
    end
    return items
end

return M
