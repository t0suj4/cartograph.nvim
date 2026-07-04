-- WoW-addon load-order adapter. A .toc file is the addon's MANIFEST: an
-- ordered list of files (plus XML files that <Script>/<Include> more of
-- them) which the engine loads top to bottom. That order is load-bearing —
-- a load-time reference to a symbol from a file that loads LATER is nil,
-- the classic addon bug. This module parses the manifest into a load-order
-- model; the store, browser and linter consume it. Pure over the
-- filesystem: nothing here mutates the store.
--
-- XML files also reference handler FUNCTIONS by name (function="X"
-- attributes and inline <OnClick>Foo()</OnClick> bodies): engine-dispatched
-- entry points the call graph can't see, collected into model.handlers.

local M = {}

--- Parse .toc text: `## Key: value` directives + the ordered file list.
function M.parse_toc(text)
    local directives, files = {}, {}
    for line in text:gmatch('[^\r\n]+') do
        line = line:gsub('^\239\187\191', '') -- strip a UTF-8 BOM
        local k, v = line:match('^%s*##%s*([%w%-_]+)%s*:%s*(.-)%s*$')
        if k then
            directives[k] = v
        elseif not line:match('^%s*#') then
            local f = line:match('^%s*(.-)%s*$')
            if f ~= '' then files[#files + 1] = (f:gsub('\\', '/')) end
        end
    end
    return { directives = directives, files = files }
end

--- Parse a UI XML file: ordered <Script file=>/<Include file=> refs plus
--- handler function names (function="X" attrs, inline <OnEvent> bodies).
function M.parse_xml(text)
    text = text:gsub('<!%-%-.-%-%->', '')
    local files, handlers = {}, {}
    for tag, f in text:gmatch('<%s*(%a+)%s+file%s*=%s*["\']([^"\']+)["\']') do
        tag = tag:lower()
        if tag == 'script' or tag == 'include' then
            files[#files + 1] = (f:gsub('\\', '/'))
        end
    end
    for name in text:gmatch('function%s*=%s*["\']([%a_][%w_.:]*)["\']') do
        handlers[name] = true
    end
    for body in text:gmatch('<On%a+[^>/]*>(.-)</On%a+>') do
        for name in body:gmatch('%f[%w_]([%a_][%w_]*)%s*%(') do
            handlers[name] = true
        end
    end
    return { files = files, handlers = handlers }
end

-- .toc/XML paths are written for a case-insensitive filesystem with
-- backslashes; resolve them against the real tree via one recursive scan.
local function walk(root)
    local map = {}
    local function rec(rel)
        local it = vim.uv.fs_scandir(rel == '' and root or (root .. '/' .. rel))
        while it do
            local name, t = vim.uv.fs_scandir_next(it)
            if not name then break end
            local r = rel == '' and name or (rel .. '/' .. name)
            if t == 'directory' then rec(r) else map[r:lower()] = r end
        end
    end
    rec('')
    return map
end

--- Build the load-order model for an addon root. Returns model or
--- nil, reason. model = { toc, entries = {{file, via, depth}, ...},
--- index = {[file]=i}, handlers = {[name]=true}, directives, missing }.
function M.load(root)
    root = root:gsub('/+$', '')
    local map = walk(root)
    local base = root:match('([^/]+)$') or ''
    local toc = map[(base .. '.toc'):lower()]
    if not toc then -- fall back to any manifest at the top level
        for low, actual in pairs(map) do
            if low:match('^[^/]+%.toc$') and (not toc or actual < toc) then
                toc = actual
            end
        end
    end
    if not toc then return nil, 'no .toc manifest in ' .. root end
    local function read(rel)
        local f = io.open(root .. '/' .. rel, 'r')
        if not f then return nil end
        local t = f:read('a')
        f:close()
        return t
    end

    local model = { toc = toc, entries = {}, index = {}, handlers = {},
        directives = {}, missing = {} }
    local parsed = M.parse_toc(read(toc) or '')
    model.directives = parsed.directives

    local function add(rel, via, depth)
        local low = rel:lower()
        local actual = map[low]
        if low:match('%.lua$') then
            if not actual then
                model.missing[#model.missing + 1] = { file = rel, via = via }
            elseif not model.index[actual] then -- first mention loads it
                model.entries[#model.entries + 1] = { file = actual, via = via, depth = depth }
                model.index[actual] = #model.entries
            end
            return
        end
        if not low:match('%.xml$') then return end
        local text = actual and read(actual)
        if not text then
            model.missing[#model.missing + 1] = { file = rel, via = via }
            return
        end
        local x = M.parse_xml(text)
        for h in pairs(x.handlers) do model.handlers[h] = true end
        -- xml-relative paths first (the WoW rule), addon-relative as fallback
        local dir = actual:match('^(.*)/[^/]*$')
        for _, f in ipairs(x.files) do
            local cand = dir and (dir .. '/' .. f) or f
            add(map[cand:lower()] and cand or f, actual, depth + 1)
        end
    end
    for _, f in ipairs(parsed.files) do add(f, toc, 0) end
    return model
end

-- ── cross-addon: the addons FOLDER is itself an ordered world ────────────────
-- `## Dependencies` / `## RequiredDeps` name sibling addons that must load
-- first; `## OptionalDeps` order-before-if-present. The client loads addons
-- alphabetically with dependencies promoted (a DFS); a missing required dep
-- disables the addon, a dependency cycle disables both.

local function split_names(v)
    local out = {}
    for name in (v or ''):gmatch('[^,]+') do
        name = name:match('^%s*(.-)%s*$')
        if name ~= '' then out[#out + 1] = name end
    end
    return out
end

--- Required and optional dependency lists from toc directives (both
--- `Dependencies` and `RequiredDeps` spellings occur in the wild).
function M.deps(directives)
    local req, opt = {}, {}
    for k, v in pairs(directives or {}) do
        local lk = k:lower()
        if lk == 'dependencies' or lk == 'requireddeps' then
            for _, n in ipairs(split_names(v)) do req[#req + 1] = n end
        elseif lk == 'optionaldeps' then
            for _, n in ipairs(split_names(v)) do opt[#opt + 1] = n end
        end
    end
    return req, opt
end

--- Model a whole addons folder: every subdirectory with a manifest.
--- Returns { addons = {[lowername] = {dir,name,title,req,opt,lod,pos}},
--- order = {names in client load order}, missing = {{addon,dep}},
--- cycles = {{addon,dep}} } or nil if the folder holds no addons.
function M.folder(root)
    root = root:gsub('/+$', '')
    local addons, names = {}, {}
    local it = vim.uv.fs_scandir(root)
    while it do
        local name, t = vim.uv.fs_scandir_next(it)
        if not name then break end
        if t == 'directory' then
            local tocname, text = name, nil
            local f = io.open(('%s/%s/%s.toc'):format(root, name, name), 'r')
            if not f then -- manifest named differently from the folder
                local sub = vim.uv.fs_scandir(root .. '/' .. name)
                while sub do
                    local n2, t2 = vim.uv.fs_scandir_next(sub)
                    if not n2 then break end
                    if t2 == 'file' and n2:lower():match('%.toc$') then
                        f = io.open(('%s/%s/%s'):format(root, name, n2), 'r')
                        tocname = n2:gsub('%.[Tt][Oo][Cc]$', '')
                        break
                    end
                end
            end
            if f then
                text = f:read('a')
                f:close()
                local p = M.parse_toc(text)
                local req, opt = M.deps(p.directives)
                local a = { dir = name, name = tocname,
                    title = p.directives.Title, req = req, opt = opt,
                    lod = p.directives.LoadOnDemand == '1' }
                addons[tocname:lower()] = a
                if name:lower() ~= tocname:lower() then addons[name:lower()] = a end
                names[#names + 1] = tocname
            end
        end
    end
    if #names == 0 then return nil end
    table.sort(names, function (x, y) return x:lower() < y:lower() end)

    local order, state, cycles, missing, mseen = {}, {}, {}, {}, {}
    local function visit(low, fromname)
        local a = addons[low]
        if not a then return end
        if state[a] == 'done' then return end
        if state[a] == 'visiting' then
            cycles[#cycles + 1] = { addon = fromname, dep = a.name }
            return
        end
        state[a] = 'visiting'
        for _, dep in ipairs(a.req) do
            if not addons[dep:lower()] then
                local k = a.name .. '\31' .. dep
                if not mseen[k] then
                    mseen[k] = true
                    missing[#missing + 1] = { addon = a.name, dep = dep }
                end
            else
                visit(dep:lower(), a.name)
            end
        end
        for _, dep in ipairs(a.opt) do
            if addons[dep:lower()] then visit(dep:lower(), a.name) end
        end
        state[a] = 'done'
        a.pos = #order + 1
        order[#order + 1] = a.name
    end
    for _, n in ipairs(names) do
        local a = addons[n:lower()]
        -- LoadOnDemand addons load only when something pulls them in
        if not a.lod then visit(n:lower()) end
    end
    return { addons = addons, order = order, missing = missing, cycles = cycles }
end

--- Global function names defined by SIBLING addons — honest scope: only
--- siblings with an extracted dump (.luals-graph.json) can testify.
--- Returns { [global fn name] = addon name }, cached on the model.
function M.sibling_defs(model)
    if model._sibdefs then return model._sibdefs end
    local out, seen = {}, {}
    if model.folder and model.parent then
        for _, a in pairs(model.folder.addons) do
            if not seen[a] and a.dir:lower() ~= (model.self or ''):lower() then
                seen[a] = true
                local f = io.open(('%s/%s/.luals-graph.json'):format(model.parent, a.dir), 'r')
                if f then
                    local okj, data = pcall(vim.json.decode, f:read('a'))
                    f:close()
                    if okj and type(data) == 'table' then
                        for _, n in ipairs(data.nodes or {}) do
                            if n.kind == 'function' and n.name
                                and not n.name:find('[.:]') then
                                out[n.name] = out[n.name] or a.name
                            end
                        end
                    end
                end
            end
        end
    end
    model._sibdefs = out
    return out
end

--- Attach the model to a store (store.toc): adds `unlisted` — lua files the
--- graph saw that no manifest path reaches, i.e. files that never load —
--- and, when the addon sits in an addons folder, the cross-addon model
--- (model.folder / model.parent / model.self).
function M.attach(store)
    local root = store.data.root:gsub('/+$', '')
    local model, why = M.load(root)
    if model then
        model.unlisted = {}
        for _, f in ipairs(store.files) do
            if not model.index[f] then model.unlisted[#model.unlisted + 1] = f end
        end
        local parent = root:match('^(.*)/[^/]+$')
        local selfdir = root:match('([^/]+)$')
        local fol = parent and M.folder(parent)
        -- cross-addon knowledge only if there ARE siblings with manifests
        local others = false
        for _, a in pairs(fol and fol.addons or {}) do
            if a.dir:lower() ~= selfdir:lower() then others = true break end
        end
        if fol and fol.addons[selfdir:lower()] and others then
            model.folder, model.parent, model.self = fol, parent, selfdir
        end
    end
    store.toc = model
    return model, why
end

return M
