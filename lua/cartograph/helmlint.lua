-- cartograph.helmlint — HELM'S SILENT-SUCCESS CLASS on the TEMPLATES (CART-0156, design helm-charts/README "Lints that
-- fall out"): `helm lint`, `helm template`, `kubectl apply` and `helm upgrade` all report success while the release is
-- wrong. Read with the `helm` tree-sitter grammar (Go text/template inside YAML), joined with the render
-- (cartograph.helm) where a lint needs the rendered structure.
--   dangling-values-path  a template reads `.Values.a.b` that values.yaml never defines — it renders as empty,
--                         silently. A read guarded by `if`/`with` on that path, or piped to `default`, is not one.
--   orphan-value          a values.yaml key no template reads (the same edge read the other way). Keys named after a
--                         subchart, and `global`, belong to the subcharts. REFUSED for a chart that reads `.Values`
--                         whole or through `index` (every key may be read: a frontier, said).
--   chomped-separator     a blank line right before a `{{-` action is ALWAYS deleted by the chomp: an author's record
--                         separator (LDIF, PEM bundles) silently gone (design Finding 1)
--   checksum-under-coverage  a `checksum/…` pod annotation hashes some values / files, and a ConfigMap or Secret the pod
--                         REFERENCES (the render's soft edges) is produced by a template reading values the checksum
--                         does not cover: editing them changes the ConfigMap and not the pod — no roll (Finding 2)
-- ⚠ A `.Values` chain inside a `range`/`with` body with a PLAIN dot is relative to the rebound dot: counted as a
-- frontier, not resolved. Static values describe a HYPOTHETICAL release: `helm upgrade` with no -f/--set reuses the
-- previous release's values (Finding 3) — the report says so.
local M = {}
local Y = require 'cartograph.yamlvalue'

local function readf(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end
local function tx(n, src) return vim.treesitter.get_node_text(n, src) end

--- a selector chain rooted at .Values / $.Values -> 'a.b.c', absolute | nil
local function values_path(n, src)
    local segs = {}
    local cur = n
    while cur and cur:type() == 'selector_expression' do
        local f = cur:field('field')[1] or cur:named_child(cur:named_child_count() - 1)
        table.insert(segs, 1, tx(f, src))
        cur = cur:named_child(0)
    end
    if not cur then return nil end
    if cur:type() == 'field' and tx(cur, src) == '.Values' then return table.concat(segs, '.'), false end
    -- `$.Values.a` parses as selector($.Values) with the first segment `Values`
    if cur:type() == 'variable' and tx(cur, src) == '$' and segs[1] == 'Values' then table.remove(segs, 1); return table.concat(segs, '.'), true end
    return nil
end

--- every .Values READ in one template -> { { path, guarded, defaulted, relative, line } }, whole (reads .Values whole
--- or through index)
function M.reads(src)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'helm')
    if not ok then return nil, 'no helm grammar' end
    local root = parser:parse()[1]:root()
    local out, whole = {}, false
    -- (guards in force: the paths an enclosing `if`/`with` condition reads)
    local function walk(n, guards, scoped)
        local t = n:type()
        if t == 'selector_expression' and not (n:parent() and n:parent():type() == 'selector_expression') then
            local p, abs = values_path(n, src)
            if p then
                local defaulted = false
                local DEFAULTING = { default = true, required = true, coalesce = true }
                local pl = n:parent()
                while pl and pl:type() ~= 'chained_pipeline' and pl:type() ~= 'template' do
                    -- (an ARGUMENT of default/required/coalesce — `{{ default "Never" .Values.x }}` — is defaulted too)
                    if pl:type() == 'function_call' and pl:named_child(0) and DEFAULTING[tx(pl:named_child(0), src)] then defaulted = true end
                    pl = pl:parent()
                end
                if pl and pl:type() == 'chained_pipeline' then
                    for c in pl:iter_children() do
                        if c:type() == 'function_call' then
                            local fname = c:named_child(0) and tx(c:named_child(0), src)
                            if fname == 'default' or fname == 'required' then defaulted = true end
                        end
                    end
                end
                local guarded = false
                for _, g in ipairs(guards) do if p == g or p:sub(1, #g + 1) == g .. '.' then guarded = true end end
                out[#out + 1] = { path = p, guarded = guarded, defaulted = defaulted, relative = scoped and not abs, line = n:range() + 1 }
            end
            return
        end
        if t == 'field' and tx(n, src) == '.Values' and not (n:parent() and n:parent():type() == 'selector_expression') then whole = true end
        if t == 'function_call' and n:named_child(0) and tx(n:named_child(0), src) == 'index' then
            local args = n:named_child(1)
            local a1 = args and args:named_child(0)
            if a1 and (tx(a1, src) == '.Values' or tx(a1, src) == '$.Values' or tx(a1, src):match('^%$?%.Values%.')) then whole = true end
        end
        if t == 'if_action' or t == 'with_action' or t == 'range_action' then
            -- (the condition / pipeline: its reads are absolute in the OUTER scope and guard the body)
            local cond = n:named_child(0)
            local g2 = vim.list_extend({}, guards)
            if cond then
                walk(cond, guards, scoped)
                local stack = { cond }
                while #stack > 0 do
                    local x = table.remove(stack)
                    if x:type() == 'selector_expression' then local p = values_path(x, src); if p then g2[#g2 + 1] = p end end
                    for c in x:iter_children() do if c:named() then stack[#stack + 1] = c end end
                end
            end
            local inner_scoped = scoped or t == 'with_action' or t == 'range_action'
            for i = 1, n:named_child_count() - 1 do walk(n:named_child(i), (t ~= 'range_action') and g2 or guards, inner_scoped) end
            return
        end
        for c in n:iter_children() do if c:named() then walk(c, guards, scoped) end end
    end
    walk(root, {}, false)
    return out, whole
end

--- a RANGE emitting records into a YAML BLOCK SCALAR (`key: |`) whose closing `{{- end` chomps the blank line the
--- author wrote between records: the separator of an embedded format (LDIF, PEM bundles) silently deleted (design
--- Finding 1). A blank line before `{{-` anywhere else is the idiom for trimming, not a loss -> { line … }
function M.chomped(src)
    local out = {}
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'helm')
    if not ok then return out end
    local root = parser:parse()[1]:root()
    local lines = vim.split(src, '\n', { plain = true })
    local stack = { root }
    while #stack > 0 do
        local n = table.remove(stack)
        if n:type() == 'range_action' then
            local text = tx(n, src)
            local body = text:match('^(.*){{%-%s*end%s*%-?}}$')
            if body and body:match('\n[ \t]*\n[ \t]*$') then
                -- (inside a block scalar: the nearest content line above the range opens one)
                local srow = n:range()
                local i = srow
                while i >= 1 and lines[i]:match('^%s*$') do i = i - 1 end
                if i >= 1 and lines[i]:match(':%s*[|>][-+]?%d*%s*$') then
                    local erow = select(3, n:range())
                    out[#out + 1] = erow + 1
                end
            end
        end
        for c in n:iter_children() do if c:named() then stack[#stack + 1] = c end end
    end
    table.sort(out)
    return out
end

--- the values.yaml paths -> { [dotted] = true } (every node: maps and leaves)
local function value_paths(v, prefix, out)
    out = out or {}
    if type(v) == 'table' and v.o then
        for _, k in ipairs(v.keys) do
            local p = prefix == '' and k or (prefix .. '.' .. k)
            out[p] = (type(v.o[k]) == 'table' and v.o[k].o) and 'map' or 'leaf'
            value_paths(v.o[k], p, out)
        end
    end
    return out
end

--- LINT one chart directory -> { findings = { { lint, file, line?, msg } }, frontier = { … }, counts }
function M.lint(chart, opts)
    opts = opts or {}
    chart = vim.fn.fnamemodify(chart, ':p'):gsub('/$', '')
    local values = Y.read_one(readf(chart .. '/values.yaml') or '') or { o = {}, keys = {} }
    local defined = value_paths(values, '')
    local meta = Y.read_one(readf(chart .. '/Chart.yaml') or '') or { o = {} }
    local sub = { global = true }
    for _, d in ipairs((meta.o.dependencies and meta.o.dependencies.a) or {}) do
        local n = d.o and (d.o.alias or d.o.name)
        if type(n) == 'string' then sub[n] = true end
    end
    for _, d in ipairs(vim.fn.glob(chart .. '/charts/*', false, true)) do sub[vim.fn.fnamemodify(d, ':t'):gsub('%-%d.*$', '')] = true end
    local findings, frontier = {}, {}
    local reads_by_file, any_whole, relative = {}, false, 0
    -- (a LIBRARY chart's helpers read the values of the chart that includes them: the value lints do not apply)
    local library = type(meta.o.type) == 'string' and meta.o.type:lower() == 'library'
    if library then frontier[#frontier + 1] = 'a library chart: its templates read the INCLUDING chart\'s values (dangling / orphan not checked)' end
    local files = vim.fn.globpath(chart .. '/templates', '**/*', false, true)
    table.sort(files)
    for _, f in ipairs(files) do
        if vim.fn.isdirectory(f) == 0 and (f:match('%.ya?ml$') or f:match('%.tpl$') or f:match('%.txt$')) then
            local rel = f:sub(#chart + 2)
            local src = readf(f) or ''
            local reads, whole = M.reads(src)
            if reads then
                reads_by_file[rel] = reads
                if whole then any_whole = true; frontier[#frontier + 1] = rel .. ' reads .Values whole or through index' end
                for _, r in ipairs(reads) do
                    if r.relative then relative = relative + 1
                    elseif not library and not r.guarded and not r.defaulted and not defined[r.path] then
                        -- (the longest DEFINED prefix: a typo is a sibling of a real key)
                        local pre, segs = nil, {}
                        for seg in r.path:gmatch('[^.]+') do segs[#segs + 1] = seg; local p = table.concat(segs, '.'); if defined[p] then pre = p end end
                        if not (pre and defined[pre] == 'leaf') and not sub[r.path:match('^[^.]+')] then
                            findings[#findings + 1] = { lint = 'dangling-values-path', file = rel, line = r.line,
                                msg = ('.Values.%s is read but values.yaml never defines it (renders empty unless a values file supplies it)%s'):format(r.path, pre and (' — defined up to .Values.' .. pre) or '') }
                        end
                    end
                end
            end
            for _, l in ipairs(M.chomped(src)) do
                findings[#findings + 1] = { lint = 'chomped-separator', file = rel, line = l, msg = 'the closing `{{- end` of this range chomps the blank line between records of the block scalar: the separator is lost' }
            end
        end
    end
    -- ORPHAN VALUES: a defined path no read covers (a read covers itself, its descendants and its ancestors' subtree
    -- when it reads a map whole)
    if library then -- (said above)
    elseif any_whole then frontier[#frontier + 1] = 'orphan-value refused: a template reads .Values whole or through index'
    else
        local read = {}
        for _, rs in pairs(reads_by_file) do for _, r in ipairs(rs) do read[r.path] = true end end
        local function covered(p)
            if read[p] then return true end
            for r in pairs(read) do if p:sub(1, #r + 1) == r .. '.' or r:sub(1, #p + 1) == p .. '.' then return true end end
            return false
        end
        local orphans = {}
        for p, kind in pairs(defined) do
            if kind == 'leaf' and not sub[p:match('^[^.]+')] and not covered(p) then orphans[#orphans + 1] = p end
        end
        table.sort(orphans)
        for _, p in ipairs(orphans) do findings[#findings + 1] = { lint = 'orphan-value', file = 'values.yaml', msg = ('.Values.%s is defined and no template reads it'):format(p) } end
    end
    if relative > 0 then frontier[#frontier + 1] = ('%d .Values read(s) relative to a rebound dot inside range/with (not resolved)'):format(relative) end
    -- CHECKSUM COVERAGE (needs the render: which ConfigMap / Secret a pod references, and which template produced it)
    if opts.render ~= false and require('cartograph.helm').binary() then
        local s, data_or_why = require('cartograph.helm').attach(chart, opts)
        if s then M._checksums(chart, reads_by_file, s, findings)
        else frontier[#frontier + 1] = 'checksum-under-coverage not checked: ' .. tostring(data_or_why) end
    end
    frontier[#frontier + 1] = 'static values describe a HYPOTHETICAL release: `helm upgrade` with no -f/--set reuses the previous release\'s values'
    table.sort(findings, function (a, b) return a.lint .. a.file .. (a.line or 0) < b.lint .. b.file .. (b.line or 0) end)
    return { findings = findings, frontier = frontier }
end

--- the checksum annotations of each template: { [rel] = { { name, paths = set, files = set } } }
local function checksums(chart, rel, src)
    local out = {}
    for name, expr in src:gmatch('checksum/([%w%-_.]+)%s*:%s*({{.-}})') do
        local c = { name = name, paths = {}, files = {} }
        local reads = M.reads(expr) or {}
        for _, r in ipairs(reads) do c.paths[r.path] = true end
        for f in expr:gmatch('"/([^"]+)"') do c.files['templates/' .. f] = true end
        out[#out + 1] = c
    end
    return out
end

function M._checksums(chart, reads_by_file, s, findings)
    -- rendered documents by source template: '<chart>/templates/x.yaml' -> 'templates/x.yaml'
    local by_template, objects = {}, {}
    for _, e in ipairs(s.docs_soft or {}) do
        local srcrel = e.d.source and e.d.source:match('^[^/]+/(.*)$')
        if srcrel then by_template[srcrel] = by_template[srcrel] or {}; table.insert(by_template[srcrel], e.d) end
    end
    -- every object's source template, from the render's files ('<chart>/templates/cm.yaml')
    for k, file in pairs(s.objects or {}) do
        local kind, name = k:match('\31([^\31]+)\31(.+)$')
        objects[kind .. '/' .. name] = file:match('^[^/]+/(templates/.*)$') or file
    end
    for rel, reads in pairs(reads_by_file) do
        local src = readf(chart .. '/' .. rel) or ''
        for _, c in ipairs(checksums(chart, rel, src)) do
            for _, d in ipairs(by_template[rel] or {}) do
                for _, r in ipairs(d.refs or {}) do
                    if (r.kind == 'ConfigMap' or r.kind == 'Secret') and r.name then
                        local tpl = objects[r.kind .. '/' .. r.name]
                        if tpl and not c.files[tpl] and reads_by_file[tpl] then
                            local missed = {}
                            for _, x in ipairs(reads_by_file[tpl]) do
                                local cov = false
                                for p in pairs(c.paths) do if x.path == p or x.path:sub(1, #p + 1) == p .. '.' then cov = true end end
                                if not cov and not x.relative then missed[x.path] = true end
                            end
                            local ml = vim.tbl_keys(missed); table.sort(ml)
                            if #ml > 0 then
                                findings[#findings + 1] = { lint = 'checksum-under-coverage', file = rel,
                                    msg = ('checksum/%s does not cover %s/%s (%s), which also reads .Values.%s — editing them changes the %s and not the pod: no roll'):format(c.name, r.kind, r.name, tpl, table.concat(ml, ', .Values.'), r.kind) }
                            end
                        end
                    end
                end
            end
        end
    end
end

--- the report as lines
function M.lines(r)
    local l = {}
    local by = {}
    for _, f in ipairs(r.findings) do by[f.lint] = (by[f.lint] or 0) + 1 end
    local ks = vim.tbl_keys(by); table.sort(ks)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = k .. ' ' .. by[k] end
    l[#l + 1] = ('helm lint (silent-success class): %d finding(s)%s'):format(#r.findings, #parts > 0 and (' — ' .. table.concat(parts, ', ')) or '')
    for _, f in ipairs(r.findings) do l[#l + 1] = ('  %s %s%s: %s'):format(f.lint, f.file, f.line and (':' .. f.line) or '', f.msg) end
    for _, x in ipairs(r.frontier) do l[#l + 1] = '  frontier: ' .. x end
    return l
end

return M
