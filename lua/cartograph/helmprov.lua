-- cartograph.helmprov — HELM'S RENDER WITH ITS ATTRIBUTION KEPT (CART-0870): tools/helmprov is Helm's own engine over a
-- copy of text/template that records what the executor already knows — every rendered byte range to the template node
-- (file:line:col) that wrote it, every `.Values` chain to the node that evaluated it (inside included helpers too). The
-- renders are Helm's (verified per file against `helm template`, as documents); the attribution is exact (every text
-- span reproduces the template source at its location). Built OFFLINE on first use (tools/helmprov/build.sh).
-- USER, 2026-09-11: "quickly navigate into value use sites, so I can extend the helm chart there or here".
local tsutil = require 'cartograph.spec.tsutil' -- (tsutil.inext: indexed child iteration, CART-1453)
local M = {}

local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local SRC = REPO .. '/tools/helmprov'

--- the helmprov binary, built (offline) when missing or built from other sources -> path | nil, why. Freshness is a
--- CONTENT hash of tools/helmprov stamped beside the binary, never mtimes: a restore that keeps a file's old mtime
--- (a mutation run's) would leave a binary built from the mutated source looking newer than its sources.
function M.binary()
    local out = vim.fn.stdpath('cache') .. '/cartograph/helmprov/helmprov'
    local parts = {}
    local files = vim.fn.globpath(SRC, '**/*', false, true)
    table.sort(files)
    for _, f in ipairs(files) do
        if vim.fn.isdirectory(f) == 0 then
            local fd = io.open(f, 'rb')
            if fd then parts[#parts + 1] = f:sub(#SRC + 2) .. '\0' .. fd:read('a'); fd:close() end
        end
    end
    local hash = vim.fn.sha256(table.concat(parts, '\0'))
    local stamp = out .. '.src'
    local fd = io.open(stamp)
    local built = fd and fd:read('a'); if fd then fd:close() end
    if vim.fn.executable(out) == 1 and built == hash then return out end
    if vim.fn.executable('go') == 0 then return nil, 'no go toolchain on PATH: helmprov is built from tools/helmprov' end
    local r = vim.system({ 'sh', SRC .. '/build.sh' }, { text = true, env = { OUT = out } }):wait(600000)
    if not r or r.code ~= 0 then
        return nil, 'helmprov did not build (offline: the helm checkout and its modules must be local): ' .. vim.trim(((r and r.stderr) or ''):sub(1, 300))
    end
    fd = io.open(stamp, 'w')
    if fd then fd:write(hash); fd:close() end
    return out
end

--- RENDER with provenance -> { files = { [name] = { content, spans = { { start, end, loc, kind, values } } } },
--- reads = { { path, loc, untaken?, guard? } }, chart } | nil, why. opts: release, namespace, values = { file … },
--- set = { 'k=v' … }, branches (CART-0871: the arms the values did NOT take are executed too, in a second render whose
--- output never reaches `files` — their reads come back `untaken` with the guard that skipped them, plus `arms` (every
--- control node's execution: loc, kind, pipe, taken, else) and `explored` (each untaken arm's text; `err` = a HOLE)),
--- symbolic (CART-1302: NO values — `.Values` is a placeholder printed `⟨.Values.a.b⟩`, every condition on it UNKNOWN (the
--- then-arm renders, the else-arm is explored), a range over it one element `a[]`, a call that cannot take it a placeholder
--- named by its expression, a failing action a hole; `files` are then the chart's AUTHORED BASE, not a render)
function M.render(chart, opts)
    opts = opts or {}
    local bin, why = M.binary()
    if not bin then return nil, why end
    chart = vim.fn.fnamemodify(chart, ':p'):gsub('/$', '')
    local cmd = { bin, '-release', opts.release or 'release', '-namespace', opts.namespace or 'default' }
    for _, f in ipairs(opts.values or {}) do cmd[#cmd + 1] = '-f'; cmd[#cmd + 1] = f end
    for _, s in ipairs(opts.set or {}) do cmd[#cmd + 1] = '-set'; cmd[#cmd + 1] = s end
    if opts.branches then cmd[#cmd + 1] = '-branches' end
    if opts.symbolic then cmd[#cmd + 1] = '-symbolic' end
    if opts.origins then cmd[#cmd + 1] = '-origins' end
    if opts.dots then cmd[#cmd + 1] = '-dots' end
    cmd[#cmd + 1] = chart
    local r = vim.system(cmd, { text = true }):wait(opts.timeout or 120000)
    if not r or r.code ~= 0 then
        -- the error is helmprov's own `helmprov: …` line; Helm's loader may log INFO lines before it
        local err = r and r.stderr or ''
        local last
        for line in err:gmatch('[^\n]+') do if line:match('^helmprov: ') then last = line end end
        return nil, last or ('helmprov: ' .. (vim.trim(err) ~= '' and vim.trim(err):gsub('\n.*', '') or 'did not finish'))
    end
    local ok, d = pcall(vim.json.decode, r.stdout, { luanil = { object = true, array = true } })
    if not ok then return nil, 'helmprov: undecodable output' end
    d.chart = chart
    return d
end

--- a location `name/templates/x.yaml:12:4` -> the chart-relative file `templates/x.yaml`, line (1-based), col (0-based)
function M.loc(l)
    local path, line, col = l:match('^(.*):(%d+):(%d+)$')
    if not path then return nil end
    return path:match('^[^/]+/(.*)$') or path, tonumber(line), tonumber(col)
end

--- the USE SITES of a values path: every read of it, of a descendant, or of an ancestor (`toYaml .Values.x` reads all
--- of x) -> { { path, loc, file, line, col, untaken?, guard? } } sorted by location; a site read in a taken arm anywhere
--- is taken (a range body runs some iterations through each arm)
function M.uses(prov, path)
    local out, seen = {}, {}
    for pass = 1, 2 do
        for _, r in ipairs(prov.reads or {}) do
            local p = r.path
            if (pass == 1) == not r.untaken and (p == path or p:sub(1, #path + 1) == path .. '.' or p:sub(1, #path + 1) == path .. '['
                or path:sub(1, #p + 1) == p .. '.') then
                local key = p .. '\0' .. r.loc
                if not seen[key] then
                    seen[key] = true
                    local f, line, col = M.loc(r.loc)
                    out[#out + 1] = { path = p, loc = r.loc, file = f, line = line, col = col, untaken = r.untaken, guard = r.guard }
                end
            end
        end
    end
    table.sort(out, function (a, b) return a.loc < b.loc end)
    return out
end

--- the span that wrote byte `b` (0-based) of rendered file `name` -> span | nil
function M.at(prov, name, b)
    local f = prov.files and prov.files[name]
    for _, sp in ipairs(f and f.spans or {}) do if b >= sp.start and b < sp['end'] then return sp end end
    return nil
end

--- the EXACT template position of rendered byte `b` of file `name` -> file, line, col (0-based), kind | nil. A text span
--- reproduces its template source byte for byte, so a byte inside it sits at the span's start advanced by the bytes
--- between (newlines move the line); an action's bytes all come from its `{{ … }}` (its location).
function M.position(prov, name, b)
    local sp = M.at(prov, name, b)
    if not sp then return nil end
    local f, line, col = M.loc(sp.loc)
    if sp.kind == 'text' then
        local seg = (prov.files[name].content or ''):sub(sp.start + 1, b)
        local nl = select(2, seg:gsub('\n', ''))
        if nl > 0 then line = line + nl; col = #seg - (seg:match('^.*()\n') or 0) else col = col + #seg end
    end
    return f, line, col, sp.kind
end

--- where a rendered document's TEXT came from: the document of `kind`/`name` in the render, and the first occurrence of
--- `text` inside it -> span, rendered file | nil (attributed by the rendered text — the document is read, its bytes known)
function M.locate(prov, kind, name, text)
    for fname, f in pairs(prov.files or {}) do
        local c = f.content or ''
        local pos = 1
        for doc in (c .. '\n---\n'):gmatch('(.-)\n%-%-%-[^\n]*\n') do
            local s = pos
            pos = pos + #doc + 5
            if doc:match('\nkind:%s*' .. vim.pesc(kind) .. '%s') or doc:match('^kind:%s*' .. vim.pesc(kind) .. '%s') then
                if doc:match('\n%s+name:%s*["\']?' .. vim.pesc(name) .. '["\']?%s') then
                    local i = doc:find(text, 1, true)
                    if i then
                        local b = s - 1 + i - 1
                        local file, line, col, kind = M.position(prov, fname, b)
                        return { file = file, line = line, col = col, kind = kind, span = M.at(prov, fname, b) }, fname
                    end
                end
            end
        end
    end
    return nil
end

--- the chart's CONTROL FLOW as HOLE DOMAINS (CART-0871), from a `branches` render -> { { loc, file, line, col, kind,
--- pipe, domain, taken = { [arm] = executions }, untaken = { { arm, text, err?, at? } } } } by location. The domain is
--- the algebra's: an `if` with no else = PRESENCE (an optional block, its guard named), `if`/`else` = ALT, `range` =
--- REP, `with` = SCOPE. `taken` counts executions in arms the values took; `untaken` holds what the skipped arms render.
function M.domains(prov)
    local by, out = {}, {}
    local DOMAIN = { range = 'rep', with = 'scope' }
    for _, a in ipairs(prov.arms or {}) do
        local d = by[a.loc]
        if not d then
            local f, line, col = M.loc(a.loc)
            d = { loc = a.loc, file = f, line = line, col = col, kind = a.kind, pipe = a.pipe, taken = {}, untaken = {},
                domain = DOMAIN[a.kind] or (a['else'] and 'alt' or 'presence') }
            by[a.loc] = d
            out[#out + 1] = d
        end
        if not a.untaken then d.taken[a.taken] = (d.taken[a.taken] or 0) + 1 end
    end
    for _, x in ipairs(prov.explored or {}) do
        local d = by[x.guard:match('^(%S+)')]
        if d then d.untaken[#d.untaken + 1] = { arm = x.guard:match('%((%a+)%)$'), text = x.text, err = x.err, at = x.loc } end
    end
    table.sort(out, function (a, b) return a.loc < b.loc end)
    return out
end

--- BRANCH EVIDENCE (CART-1309), from a `branches` render (with `origins = true` too for the values' sources): every
--- if / with / range at its template line — the condition, what it EVALUATED TO, which arm the values took, and the
--- `.Values` paths it read with each one's origin -> { { file, line, col, kind, pipe, value, taken = { [arm] = n },
--- reads = { { path, value, from, over, removed_by } } } } by location. A condition run in several executions (inside a
--- range, a helper included twice) counts every arm it took; `value` is the first execution's.
function M.branches(prov)
    local by, out = {}, {}
    for _, a in ipairs(prov.arms or {}) do
        if not a.untaken then
            local d = by[a.loc]
            if not d then
                local f, line, col = M.loc(a.loc)
                d = { loc = a.loc, file = f, line = line, col = col, kind = a.kind, pipe = a.pipe, value = a.value, taken = {}, reads = {} }
                by[a.loc] = d
                out[#out + 1] = d
            end
            d.taken[a.taken] = (d.taken[a.taken] or 0) + 1
        end
    end
    -- the condition's reads: the taken-render reads at the condition's own line and file
    local seen = {}
    for _, r in ipairs(prov.reads or {}) do
        if not r.untaken then
            local f, line = M.loc(r.loc)
            for _, d in ipairs(out) do
                if d.file == f and d.line == line and (d.pipe or ''):find(r.path:gsub('%.', '%%.'), 1) and not seen[d.loc .. r.path] then
                    seen[d.loc .. r.path] = true
                    local o = prov.origins and M.origin(prov, r.path) or nil
                    d.reads[#d.reads + 1] = { path = r.path, value = o and o.value, from = o and (o.from or o.removed_by),
                        removed = o and o.removed_by ~= nil, over = o and o.over or {} }
                end
            end
        end
    end
    table.sort(out, function (a, b) if a.file ~= b.file then return tostring(a.file) < tostring(b.file) end return (a.line or 0) < (b.line or 0) end)
    return out
end

--- one branch as text: `if .Values.ingress.enabled -> bool:false (took none) <- values.yaml:40`
function M.branch_text(d)
    local took = {}
    for arm, n in pairs(d.taken) do took[#took + 1] = arm .. (n > 1 and ('×' .. n) or '') end
    table.sort(took)
    local parts = { ('%s %s -> %s (took %s)'):format(d.kind, d.pipe or '', tostring(d.value), table.concat(took, ', ')) }
    for _, r in ipairs(d.reads) do
        parts[#parts + 1] = ('.Values.%s %s %s'):format(r.path, r.removed and 'REMOVED by' or '<-', M.site_text(r.from))
    end
    return table.concat(parts, '; ')
end

-- ── RENDER DIFF (CART-1311): two values sets, the objects they render, field by field ───────────────────────────────
-- every object of a render by `Kind/name`, its leaves flattened (typed as the API server reads them), and for each leaf
-- the rendered byte where it starts (its template line comes from the spans)
local function objects_of(prov)
    local Y = require 'cartograph.yamlvalue'
    local out = {}
    for name, f in pairs(prov.files or {}) do
        local content = f.content or ''
        -- byte offset of each line's first non-blank character, for locating a leaf's template line
        local starts, b = {}, 0
        for line in (content .. '\n'):gmatch('([^\n]*)\n') do starts[#starts + 1] = b + #(line:match('^%s*') or ''); b = b + #line + 1 end
        local pos, line0 = 1, 0
        local function each(chunk, first)
            local docs = Y.read(chunk)
            local d = docs and docs[1]
            if not (d and type(d.value) == 'table' and d.value.o and type(d.value.o.kind) == 'string') then return end
            local md = d.value.o.metadata
            local key = d.value.o.kind .. '/' .. tostring(md and md.o and md.o.name or '?')
            local typed = Y.typed(d.raw, Y.IMPLEMENTATIONS.helm)
            local leaves = {}
            local function walk(v, path)
                if type(v) == 'table' and v.o then for _, k in ipairs(v.keys) do walk(v.o[k], (path == '' and '' or path .. '.') .. tostring(k):gsub('^%a+:', '')) end
                elseif type(v) == 'table' and v.a then for i, x in ipairs(v.a) do walk(x, path .. '[' .. i .. ']') end
                else leaves[path] = v end
            end
            walk(typed, '')
            local lines = M.key_lines(chunk)
            out[key] = { file = name, leaves = leaves, lines = lines, first = first, starts = starts }
        end
        for _ = 1, 100000 do
            local a, bb = content:find('\n%-%-%-[^\n]*\n', pos - 1)
            if not a then break end
            local chunk = content:sub(pos, a)
            each(chunk, line0 + 1)
            line0 = line0 + select(2, chunk:gsub('\n', '')) + 1
            pos = bb + 1
        end
        each(content:sub(pos), line0 + 1)
    end
    return out
end

-- the template position of a leaf of an object in a render
local function leaf_site(prov, obj, path)
    local p, l = path, nil
    for _ = 1, 20 do l = obj.lines[p]; if l or not p:find('[.%[]') then break end p = p:gsub('[.%[][^.%[]*$', '') end
    if not l then return nil end
    local file, tline = M.position(prov, obj.file, obj.starts[obj.first + l - 1] or 0)
    return file, tline
end

--- DIFF two renders of one chart -> { { object, path, change = added | removed | changed, old, new, file, line, from } }
--- (file / line = the template line that wrote the field — in B, or in A for a removal; `from` = the values source of
--- B's value when the field reads one at that line), objects only in one side as path '' rows. a / b = render opts.
function M.diff(chart, a, b)
    local A, wa = M.render(chart, vim.tbl_extend('force', a or {}, { origins = true }))
    if not A then return nil, 'render A: ' .. tostring(wa) end
    local B, wb = M.render(chart, vim.tbl_extend('force', b or {}, { origins = true }))
    if not B then return nil, 'render B: ' .. tostring(wb) end
    local OA, OB = objects_of(A), objects_of(B)
    local rows = {}
    -- the values source of the change: among the reads at that template line, the leaf (the read path itself, or one
    -- under it — `toYaml .Values.x.resources` reads a whole map) whose effective value DIFFERS between A and B
    local va, vb = (A.origins or {}).values or {}, (B.origins or {}).values or {}
    local function origin_at(file, line)
        for _, r in ipairs(B.reads or {}) do
            local f, l = M.loc(r.loc)
            if f == file and l == line then
                local leaves = {}
                for leaf in pairs(vb) do if leaf == r.path or leaf:sub(1, #r.path + 1) == r.path .. '.' then leaves[#leaves + 1] = leaf end end
                for leaf in pairs(va) do if vb[leaf] == nil and (leaf == r.path or leaf:sub(1, #r.path + 1) == r.path .. '.') then leaves[#leaves + 1] = leaf end end
                table.sort(leaves)
                for _, leaf in ipairs(leaves) do
                    if va[leaf] ~= vb[leaf] then
                        local o = M.origin(B, leaf)
                        if o then return o.from or o.removed_by, leaf end
                    end
                end
            end
        end
        return nil
    end
    local function tfile(name) return (name or ''):match('^[^/]+/(templates/.*)$') or name end
    local keys = {}
    for k in pairs(OA) do keys[k] = true end
    for k in pairs(OB) do keys[k] = true end
    local names = vim.tbl_keys(keys); table.sort(names)
    for _, k in ipairs(names) do
        local x, y = OA[k], OB[k]
        if not x then rows[#rows + 1] = { object = k, path = '', change = 'added', file = tfile(y.file) }
        elseif not y then rows[#rows + 1] = { object = k, path = '', change = 'removed', file = tfile(x.file) }
        else
            local paths = {}
            for p in pairs(x.leaves) do paths[p] = true end
            for p in pairs(y.leaves) do paths[p] = true end
            local ps = vim.tbl_keys(paths); table.sort(ps)
            for _, p in ipairs(ps) do
                local ov, nv = x.leaves[p], y.leaves[p]
                if ov ~= nv then
                    local change = ov == nil and 'added' or nv == nil and 'removed' or 'changed'
                    local prov, obj = (nv ~= nil) and B or A, (nv ~= nil) and y or x
                    local file, line = leaf_site(prov, obj, p)
                    local from, leaf
                    if nv ~= nil and file then from, leaf = origin_at(file, line) end
                    rows[#rows + 1] = { object = k, path = p, change = change, old = ov, new = nv, file = file, line = line,
                        from = from, value = leaf }
                end
            end
        end
    end
    return rows
end

--- a diff row as one line
function M.diff_text(r)
    if r.path == '' then return ('%s %s'):format(r.change == 'added' and '+' or '-', r.object) end
    local function v(x) return x == nil and '∅' or (tostring(x):gsub('^%a+:', '')) end
    return ('%s %s: %s -> %s%s'):format(r.object, r.path, v(r.old), v(r.new),
        r.from and ('  <- .Values.' .. tostring(r.value) .. ' ' .. M.site_text(r.from)) or '')
end

--- WHAT `.` WAS at the actions of one template line (CART-1310), from a render with { dots = true } -> { { col, values =
--- { up to five distinct descriptions }, n = executions } } in column order. `with` and `range` rebind `.`: a range body
--- sees each element, so `values` lists the first few and `n` counts them; the root context reads `$ (the root …)`.
function M.dots_at(prov, file, line)
    local out = {}
    for l, d in pairs(prov.dots or {}) do
        local f, ln, col = M.loc(l)
        if f == file and ln == line then out[#out + 1] = { col = col, values = d.values or {}, n = d.n or 0 } end
    end
    table.sort(out, function (a, b) return a.col < b.col end)
    return out
end

--- the HOLES of a `branches` render: untaken arms that fail under these values (`{{ if .Values.a }}{{ .Values.a.b }}`
--- with no a) -> { { guard, loc, err, text } } — not errors: what the chart would need to render that arm
function M.holes(prov)
    local out = {}
    for _, x in ipairs(prov.explored or {}) do if x.err then out[#out + 1] = x end end
    return out
end

--- the VALUES PATH of the key at a position of a YAML buffer (`images.tag` on the `tag:` line under `images:`) | nil — the
--- block mapping pairs enclosing the cursor, outermost first; a list item adds no segment (`.Values` chains do not index)
function M.path_at(buf, row, col)
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'yaml')
    if not ok or not parser then return nil end
    local root = parser:parse()[1]:root()
    local node = root:named_descendant_for_range(row, col, row, col)
    local segs = {}
    while node do
        if node:type() == 'block_mapping_pair' or node:type() == 'flow_pair' then
            local k = node:field('key')[1]
            if k then table.insert(segs, 1, (vim.treesitter.get_node_text(k, buf):gsub('^["\']', ''):gsub('["\']$', ''))) end
        end
        node = node:parent()
    end
    return #segs > 0 and table.concat(segs, '.') or nil
end

-- ── VALUE ORIGINS (CART-1307) ─────────────────────────────────────────────────────────────────────────────────────
-- A render with { origins = true } carries `origins` = { layers = { { id, kind = chart|subchart|file|set, file, set,
-- scope } }, values = { [path] = typed }, origin = { [path] = "<layer id>\31<path in that source>" }, defined = {
-- [layer id] = { { path, nil } } }, refused } — computed by Helm's own merge over marked copies of every source, and
-- REFUSED by name when the replicated merge does not reproduce Helm's effective values (tools/helmprov origin.go).

--- the line (1-based) of every key path of a YAML text -> { [path] = line } (list items as `a[1]`, `a[1].b`)
function M.key_lines(src)
    local out = {}
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'yaml')
    if not ok or not parser then return out end
    local function walk(node, prefix)
        for _, c in tsutil.inext, node, -1 do
            if c:type() == 'block_mapping_pair' or c:type() == 'flow_pair' then
                local k = c:field('key')[1]
                if k then
                    local key = (vim.treesitter.get_node_text(k, src):gsub('^["\']', ''):gsub('["\']$', ''))
                    local p = prefix == '' and key or (prefix .. '.' .. key)
                    if not out[p] then out[p] = k:start() + 1 end
                    local v = c:field('value')[1]
                    if v then walk(v, p) end
                end
            elseif c:type() == 'block_sequence' or c:type() == 'flow_sequence' then
                -- (a list's items: `containers[1].image`, 1-based — the path form of the schema check, CART-1308)
                local i = 0
                for _, item in tsutil.inext, c, -1 do
                    if item:named() and item:type() ~= 'comment' then
                        i = i + 1
                        local ip = prefix .. '[' .. i .. ']'
                        if not out[ip] then out[ip] = item:start() + 1 end
                        walk(item, ip)
                    end
                end
            elseif c:named() then
                walk(c, prefix)
            end
        end
    end
    walk(parser:parse()[1]:root(), '')
    return out
end

local function read(f) local fd = io.open(f); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end

-- precedence: a later --set over an earlier, --set over -f, a later -f over an earlier, the chart over its subcharts
local function rank(l, i)
    if l.kind == 'set' then return 3000 + i elseif l.kind == 'file' then return 2000 + i
    elseif l.kind == 'chart' then return 1000 end
    return 500 - select(2, (l.scope or ''):gsub('%.', ''))
end

--- where a layer would hold an EFFECTIVE path: its own path for it (a subchart's keys sit under its scope; a root
--- global reaches a subchart's `<scope>.global.*`) | nil
local function source_path(l, path)
    local scope = l.scope or ''
    if scope ~= '' then
        if path:sub(1, #scope + 1) == scope .. '.' then return path:sub(#scope + 2) end
        return nil
    end
    local g = path:match('^.-%.global%.(.+)$')
    if g then return 'global.' .. g, path end
    return path
end

--- the ORIGIN of an effective values path -> { path, value, from = { layer, src, file, line, set }, over = { … },
--- removed_by = … } | nil, why. `over` = every other source that sets the path, highest precedence first.
function M.origin(prov, path)
    local O = prov and prov.origins
    if not O then return nil, 'no origins: render with { origins = true }' end
    if O.refused then return nil, 'origins refused: ' .. O.refused end
    local byid, order = {}, {}
    for i, l in ipairs(O.layers or {}) do byid[l.id] = l; order[#order + 1] = { l = l, r = rank(l, i) } end
    table.sort(order, function (a, b) return a.r > b.r end)
    local lines = {}
    local function line_of(l, src)
        if not l.file then return nil end
        if not lines[l.file] then lines[l.file] = M.key_lines(read(l.file) or '') end
        return lines[l.file][src]
    end
    local function site(l, src) return { layer = l.id, kind = l.kind, file = l.file, set = l.set, src = src, line = line_of(l, src) } end
    local defs = {}
    for _, x in ipairs(order) do
        local sp, alt = source_path(x.l, path)
        for _, d in ipairs((O.defined or {})[x.l.id] or {}) do
            if d.path == sp or (alt and d.path == alt) then defs[#defs + 1] = { site = site(x.l, d.path), isnil = d.isnil or d['nil'] } end
        end
    end
    local o = (O.origin or {})[path]
    if not o and O.values[path] == 'map:{}' and defs[1] then
        -- an EMPTY table carries no marker (marking replaces leaves): its source is the highest-precedence one that
        -- sets it — INFERRED from precedence, and said so
        local over = {}
        for i = 2, #defs do over[#over + 1] = defs[i].site end
        return { path = path, value = O.values[path], from = defs[1].site, over = over, inferred = true }
    end
    if not o and O.values[path] == 'map:{}' and (path == 'global' or path:match('%.global$')) then
        -- (Helm gives every subchart a `global` table while coalescing: a value no source wrote)
        return { path = path, value = O.values[path], from = { kind = 'helm', src = path }, over = {} }
    end
    if not o then
        for _, d in ipairs(defs) do
            if d.isnil then
                local over = {}
                for _, x in ipairs(defs) do if x ~= d then over[#over + 1] = x.site end end
                return { path = path, removed_by = d.site, over = over }
            end
        end
        return nil, 'no effective value at ' .. path
    end
    local id, src = o:match('^(.-)\31(.*)$')
    local from = site(byid[id] or { id = id }, src)
    local over = {}
    for _, d in ipairs(defs) do if not (d.site.layer == from.layer and d.site.src == from.src) then over[#over + 1] = d.site end end
    return { path = path, value = O.values[path], from = from, over = over }
end

--- a source as text: `file:line` | `--set k=v`
function M.site_text(s)
    if not s then return '?' end
    if s.kind == 'set' then return '--set ' .. tostring(s.set) end
    if s.kind == 'helm' then return 'Helm itself (an empty subchart global table)' end
    return vim.fn.fnamemodify(s.file or '?', ':~:.') .. (s.line and (':' .. s.line) or '') .. (s.kind == 'subchart' and ' (subchart default)' or '')
end

--- the root chart and the effective-path prefix of a file inside it (a subchart's own files sit under its scope)
function M.root_of(file)
    local chart = M.chart_of(file)
    if not chart then return nil end
    local scope = {}
    for _ = 1, 20 do
        local parent, name = chart:match('^(.*)/charts/([^/]+)$')
        if not parent or vim.fn.filereadable(parent .. '/Chart.yaml') == 0 then break end
        table.insert(scope, 1, name)
        chart = parent
    end
    return chart, table.concat(scope, '.')
end

--- the chart a file belongs to: the nearest directory upward holding Chart.yaml | nil
function M.chart_of(file)
    local dir = vim.fn.fnamemodify(file, ':p:h')
    while dir and dir ~= '/' and dir ~= '' do
        if vim.fn.filereadable(dir .. '/Chart.yaml') == 1 then return dir end
        local up = vim.fn.fnamemodify(dir, ':h')
        if up == dir then break end
        dir = up
    end
    return nil
end

--- the USE SITES of a values path in a chart as quickfix items — rendered over ALL BRANCHES (helmprov: every read the
--- executor evaluates, helpers included, an untaken arm's read marked with its guard) when it builds, else the static
--- reads of every template (helmlint: every branch, no helpers' indirection) -> items, source ('rendered' | 'static')
function M.use_items(chart, path)
    local items = {}
    local prov = M.render(chart, { branches = true })
    if prov then
        for _, u in ipairs(M.uses(prov, path)) do
            items[#items + 1] = { filename = chart .. '/' .. u.file, lnum = u.line, col = u.col + 1,
                text = 'reads .Values.' .. u.path .. (u.untaken and (' (untaken: ' .. u.guard .. ')') or '') }
        end
        return items, 'rendered'
    end
    local L = require 'cartograph.helmlint'
    for _, f in ipairs(vim.fn.globpath(chart .. '/templates', '**/*', false, true)) do
        if vim.fn.isdirectory(f) == 0 then
            local fd = io.open(f); local src = fd and fd:read('a'); if fd then fd:close() end
            for _, r in ipairs((src and L.reads(src)) or {}) do
                local p = r.path
                if p == path or p:sub(1, #path + 1) == path .. '.' or path:sub(1, #p + 1) == p .. '.' then
                    items[#items + 1] = { filename = f, lnum = r.line, col = 1, text = 'reads .Values.' .. p .. (r.guarded and ' (guarded)' or '') }
                end
            end
        end
    end
    table.sort(items, function (a, b) return a.filename .. ('%06d'):format(a.lnum) < b.filename .. ('%06d'):format(b.lnum) end)
    return items, 'static'
end

return M
