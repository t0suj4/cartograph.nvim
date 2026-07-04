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

--- Attach the model to a store (store.toc): adds `unlisted` — lua files the
--- graph saw that no manifest path reaches, i.e. files that never load.
function M.attach(store)
    local model, why = M.load(store.data.root)
    if model then
        model.unlisted = {}
        for _, f in ipairs(store.files) do
            if not model.index[f] then model.unlisted[#model.unlisted + 1] = f end
        end
    end
    store.toc = model
    return model, why
end

return M
