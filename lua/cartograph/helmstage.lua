-- cartograph.helmstage — a PLAIN CHART'S STAGES (CART-1269, design helm-charts/02 §4-5): a chart deployed per stage
-- by a `helm template|upgrade|install … --values A --values B` line in CI or a script — no helmfile — read as releases
-- × layered values, then RENDERED per stage and compared ACROSS stages.
--
-- THE LAYERING IS DISCOVERED, never listed: the repo's own command lines (CI YAML, shell, Makefiles; `\` continuations
-- joined) name the chart and the `--values` / `-f` chain; a variable inside a values path (`stages/${STAGE}/values.yaml`)
-- is a FAMILY, expanded against the filesystem: one stage per directory that holds the file, the variable's value the
-- matched segment. A chain whose chart or values cannot be resolved is a named refusal.
--
-- PER STAGE: the EFFECTIVE values (the chart's values.yaml, then each layer, by Helm's merge — helmfile.merge), and the
-- render (cartograph.helm with that chain). FINDINGS:
--   placeholder  an effective value still of the form `{a.b.c}` naming a values path: a MUST-OVERRIDE contract left
--                unmet (design §5: "must be further overridden" per stage), checkable without rendering
--   no-op        a stage layer leaf restating what the layers before it already give (helmfile.noops)
--   secret       a value under a secret-shaped KEY (password, secret, token, apiKey, credentials, private key) in a
--                plaintext values file: COUNTED and REDACTED wherever this module prints a value — never echoed
--   drift        ACROSS stages: a service rendered in some stages and not others, and a declared peer or soft-edge
--                reference that resolves in one stage and dangles in another (the higher-value form, design §4)
local M = {}
local HF = require 'cartograph.helmfile'
local Y = require 'cartograph.yamlvalue'

local function readf(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end

-- ── DISCOVERY ─────────────────────────────────────────────────────────────────────────────────────────────────────
--- every `helm template|upgrade|install` command in the repo's text files -> { { file, chart, values = { path… } } }
function M.commands(root, files)
    local out = {}
    for _, rel in ipairs(files) do
        local src = readf(root .. '/' .. rel)
        if src and src:find('helm', 1, true) then
            src = src:gsub('\\\r?\n%s*', ' ')
            for line in src:gmatch('[^\n]+') do
                local rest = line:match('helm%s+template%s+(.*)') or line:match('helm%s+upgrade%s+(.*)') or line:match('helm%s+install%s+(.*)')
                if rest then
                    local words, i = {}, 1
                    for w in rest:gmatch('%S+') do words[#words + 1] = (w:gsub('^["\']', ''):gsub('["\']$', '')) end
                    local pos, values = {}, {}
                    while i <= #words do
                        local w = words[i]
                        if w == '-f' or w == '--values' then values[#values + 1] = words[i + 1]; i = i + 2
                        elseif w:match('^%-%-values=') then values[#values + 1] = w:sub(10); i = i + 1
                        elseif w:match('^%-') then
                            -- (another flag: its value is the next word unless it is `--x=v` or a boolean flag)
                            if not w:find('=', 1, true) and words[i + 1] and not words[i + 1]:match('^%-') and not ({ ['--install'] = 1, ['--debug'] = 1, ['--atomic'] = 1, ['--wait'] = 1, ['--dry-run'] = 1, ['--create-namespace'] = 1, ['--include-crds'] = 1 })[w] then i = i + 2 else i = i + 1 end
                        -- (the command ends at a separator, a comment or a REDIRECTION: `> out.yaml` is no chart)
                        elseif w:match('^%d?[;&|#<>]') then break
                        else pos[#pos + 1] = w; i = i + 1 end
                    end
                    -- (`helm template [NAME] CHART`: the chart is the LAST positional)
                    if #pos >= 1 then out[#out + 1] = { file = rel, chart = pos[#pos], release = #pos >= 2 and pos[1] or nil, values = values } end
                end
            end
        end
    end
    return out
end

--- a path with ${VAR} / $VAR expanded against the filesystem -> { { stage = value | '', path } } (one per match)
local function expand(root, path)
    local var = path:match('%${?([%w_]+)}?')
    if not var then return vim.fn.filereadable(root .. '/' .. path) == 1 and { { stage = '', path = path } } or {} end
    local pat = path:gsub('%${?[%w_]+}?', '*')
    local out = {}
    for _, p in ipairs(vim.fn.glob(root .. '/' .. pat, false, true)) do
        local rel = p:sub(#root + 2)
        -- (the variable's value: what the `*` matched — the segment where the path and the pattern differ)
        local pre = pat:match('^(.-)%*')
        local suf = pat:match('%*(.*)$')
        local val = rel:sub(#pre + 1, #rel - #suf)
        out[#out + 1] = { stage = val, path = rel }
    end
    table.sort(out, function (a, b) return a.stage < b.stage end)
    return out, var
end
M._expand = expand

--- the STAGES of every chart a command deploys -> { { chart, stage, values = { path… }, from } }, refusals
function M.discover(root, files)
    local stages, refusals, seen = {}, {}, {}
    for _, c in ipairs(M.commands(root, files)) do
        local chart = c.chart:gsub('^%./', ''):gsub('/$', '')
        if vim.fn.filereadable(root .. '/' .. chart .. '/Chart.yaml') == 0 then
            refusals[#refusals + 1] = ('%s: chart `%s` is not a chart directory in the repo'):format(c.file, c.chart)
        else
            -- (every values path expanded; the FAMILY variable's stages, when one path carries it)
            local fixed, family, famvar = {}, nil, nil
            for _, v in ipairs(c.values) do
                local hits, var = expand(root, v)
                if var then family, famvar = { idx = #fixed + 1, hits = hits }, var; fixed[#fixed + 1] = false
                elseif #hits == 1 then fixed[#fixed + 1] = hits[1].path
                else refusals[#refusals + 1] = ('%s: values file `%s` is not in the repo'):format(c.file, v) end
            end
            local instances = family and family.hits or { { stage = '' } }
            for _, h in ipairs(instances) do
                local chain = {}
                for i, f in ipairs(fixed) do chain[#chain + 1] = (i == (family and family.idx)) and h.path or f end
                local key = chart .. '\0' .. table.concat(chain, '\0')
                if not seen[key] then
                    seen[key] = true
                    stages[#stages + 1] = { chart = chart, stage = h.stage ~= '' and h.stage or 'default', values = chain, from = c.file, var = famvar }
                end
            end
        end
    end
    return stages, refusals
end

-- ── EFFECTIVE VALUES AND THEIR FINDINGS ───────────────────────────────────────────────────────────────────────────
local SECRET = { 'password', 'passwd', 'secret', 'token', 'apikey', 'api_key', 'credential', 'privatekey', 'private_key' }
--- is a KEY secret-shaped? (a key-name rule, and it says so: a secret under any other key is not seen)
function M.secret_key(k)
    local l = tostring(k):lower():gsub('[%-]', '')
    for _, s in ipairs(SECRET) do if l:find(s, 1, true) then return true end end
    return false
end
--- a value as printable text, REDACTED under a secret-shaped key
function M.show(k, v) if M.secret_key(k) then return '<redacted>' end return tostring(v) end

local function read_values(root, rel)
    local src = readf(root .. '/' .. rel)
    if not src then return nil, 'unreadable' end
    local v = Y.read_one(src)
    if v == nil then return nil, 'not data' end
    return v
end

--- walk leaves -> fn(path, key, value)
local function leaves(v, path, key, fn)
    if type(v) == 'table' and v.o then for _, k in ipairs(v.keys) do leaves(v.o[k], path .. '.' .. k, k, fn) end
    elseif type(v) == 'table' and v.a then for i, x in ipairs(v.a) do leaves(x, path .. '[' .. i .. ']', key, fn) end
    else fn(path, key, v) end
end
local function at(v, dotted)
    for seg in dotted:gmatch('[^.]+') do if type(v) ~= 'table' or not v.o then return nil end v = v.o[seg] end
    return v
end

--- one stage's EFFECTIVE values and value findings -> { values, placeholders = { path… }, noops = { path… },
--- secrets = n, layers = { { path, state } } }
function M.effective(root, st)
    local chartv = read_values(root, st.chart .. '/values.yaml') or { o = {}, keys = {} }
    local eff, layers, noops, secrets = chartv, {}, {}, 0
    for _, rel in ipairs(st.values) do
        local v, why = read_values(root, rel)
        layers[#layers + 1] = { path = rel, state = v and 'read' or why }
        if v then
            for _, p in ipairs(HF.noops(eff, v)) do noops[#noops + 1] = rel .. ' ' .. p end
            leaves(v, '$', nil, function (_, k, x) if k and M.secret_key(k) and type(x) == 'string' and x ~= '' then secrets = secrets + 1 end end)
            eff = HF.merge(eff, v)
        end
    end
    local placeholders = {}
    leaves(eff, '$', nil, function (path, _, x)
        local ref = type(x) == 'string' and x:match('^{([%w_][%w_.%-]*)}$')
        if ref and at(eff, ref) ~= nil then placeholders[#placeholders + 1] = path .. ' = {' .. ref .. '}' end
    end)
    table.sort(placeholders)
    return { values = eff, placeholders = placeholders, noops = noops, secrets = secrets, layers = layers }
end

-- ── PER-STAGE RENDER AND THE CROSS-STAGE DIFF ─────────────────────────────────────────────────────────────────────
--- every stage of every chart: effective values + the render + the cross-stage findings ->
--- { stages = { { chart, stage, values, eff, render | nil, refused } }, drift = { line… }, refusals }
function M.run(root, files, opts)
    opts = opts or {}
    local H = require 'cartograph.helm'
    local stages, refusals = M.discover(root, files)
    for _, st in ipairs(stages) do
        st.eff = M.effective(root, st)
        local vals = {}
        for _, rel in ipairs(st.values) do vals[#vals + 1] = root .. '/' .. rel end
        local s, why = H.attach(root .. '/' .. st.chart, { release = opts.release or st.chart:match('([^/]+)$'), values = vals })
        if s then st.render = s else st.refused = why end
    end
    -- DRIFT, per chart: what each stage renders, and which declared peers / references resolve
    local drift = {}
    local bychart = {}
    for _, st in ipairs(stages) do if st.render then bychart[st.chart] = bychart[st.chart] or {}; table.insert(bychart[st.chart], st) end end
    for chart, list in pairs(bychart) do
        if #list > 1 then
            local svc, dang = {}, {}
            for _, st in ipairs(list) do
                for _, sv in pairs(st.render.services_map) do svc[sv.name] = svc[sv.name] or {}; svc[sv.name][st.stage] = true end
                for _, d in ipairs(st.render.dangling or {}) do local k = d:gsub(', absent from .*$', ''); dang[k] = dang[k] or {}; dang[k][st.stage] = true end
                for _, d in ipairs(st.render.soft and st.render.soft.dangling or {}) do local k = d:gsub(', absent from .*$', ''); dang[k] = dang[k] or {}; dang[k][st.stage] = true end
            end
            local names = {}
            for _, st in ipairs(list) do names[#names + 1] = st.stage end
            local function missing(set) local m = {} for _, n in ipairs(names) do if not set[n] then m[#m + 1] = n end end return m end
            local function present(set) local m = {} for _, n in ipairs(names) do if set[n] then m[#m + 1] = n end end return m end
            for name, set in pairs(svc) do
                local m = missing(set)
                if #m > 0 then drift[#drift + 1] = ('%s: service %s rendered in [%s], NOT in [%s]'):format(chart, name, table.concat(present(set), ' '), table.concat(m, ' ')) end
            end
            for k, set in pairs(dang) do
                local m = missing(set)
                if #m > 0 then drift[#drift + 1] = ('%s: %s — dangles in [%s], resolves in [%s]'):format(chart, k, table.concat(present(set), ' '), table.concat(m, ' ')) end
            end
        end
    end
    table.sort(drift)
    return { stages = stages, drift = drift, refusals = refusals }
end

--- the report as lines (values REDACTED under secret-shaped keys; only paths are printed for placeholders anyway)
function M.lines(r)
    local l = {}
    l[#l + 1] = ('helm stages: %d stage(s) discovered from the repo\'s own helm command lines, %d refused'):format(#r.stages, #r.refusals)
    for _, st in ipairs(r.stages) do
        local e = st.eff
        l[#l + 1] = ('  %s [%s] values %s — %s'):format(st.chart, st.stage, table.concat(st.values, ' + '),
            st.render and (('%d service(s), %d dangling peer(s), %d dangling reference(s)'):format(st.render.services, #(st.render.dangling or {}), #(st.render.soft and st.render.soft.dangling or {})))
                or ('NOT RENDERED: ' .. tostring(st.refused)))
        if #e.placeholders > 0 then l[#l + 1] = ('    ⚠ %d un-overridden placeholder(s) (must-override): %s'):format(#e.placeholders, table.concat(e.placeholders, ' · ')) end
        if #e.noops > 0 then l[#l + 1] = ('    %d no-op override(s): %s'):format(#e.noops, table.concat(e.noops, ' · ')) end
        if e.secrets > 0 then l[#l + 1] = ('    ⚠ %d secret-shaped value(s) in plaintext values files (redacted here)'):format(e.secrets) end
    end
    for _, d in ipairs(r.drift) do l[#l + 1] = '  ⚠ STAGE DRIFT ' .. d end
    for _, x in ipairs(r.refusals) do l[#l + 1] = '  refused: ' .. x end
    return l
end

return M
