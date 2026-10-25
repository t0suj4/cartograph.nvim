-- wowdistill — distil WORLD OF WARCRAFT's Lua environment into an L2 environment profile (`wow`), from the LuaLS
-- annotations of Ketho's vscode-wow-api (MIT) ([[cartograph-stdlib-profile]], CART-1827).
--
--   nvim --headless -u NONE -l tools/wowdistill.lua --annotations <vscode-wow-api>/Annotations/Core [--show] [--out <file>]
--
-- ★★ TWO TIERS, BECAUSE THE ANNOTATIONS DESCRIBE TODAY'S CLIENT. WoW addons in the wild target many clients (the
-- corpus here is mostly 3.3.5: 170 of 224 .toc files declare Interface 30300), and the annotations are the current
-- one's. The user's choice (2026-10-25):
--   LUA   — `Lua/*.lua`: WoW's Lua 5.1 and its extensions (string.trim / split / join, the compat aliases strtrim,
--           tinsert …, bit). Unchanged since the original client: every declared return is believed.
--   API   — the documented GLOBAL functions (`Data/Wiki.lua`, and the bare globals of
--           `Blizzard_APIDocumentationGenerated`): debugstack, GetCursorInfo … A global's later returns may have moved
--           between clients (3.3.5's GetAddOnInfo returns name, title, notes, ENABLED, loadable …; today's
--           C_AddOns.GetAddOnInfo has no `enabled`), so only its FIRST return is believed, and only a primitive one.
-- NOT read: the `C_*` namespaces, the widget classes and FrameXML — the modern client's API, which would misdescribe
-- an older addon. A name the annotations lack (3.3.5's GetSpellName) is simply absent: no claim.
-- Read in RETURN position only, like `nvim`: no free functions, no namespace set — this profile changes no call's
-- disposition on its own.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path

local OUT = REPO .. '/lua/cartograph/spec/profile/wow.mpack'
local ANN, SHOW = nil, false
local i = 1
while arg[i] do
    if arg[i] == '--show' then SHOW = true
    elseif arg[i] == '--annotations' and arg[i + 1] then ANN = vim.fn.expand(arg[i + 1]); i = i + 1
    elseif arg[i] == '--out' and arg[i + 1] then OUT = vim.fn.expand(arg[i + 1]); i = i + 1
    else io.stderr:write('wowdistill: unknown argument ' .. arg[i] .. '\n'); os.exit(2) end
    i = i + 1
end
ANN = ANN and ANN:gsub('/$', '')
if not ANN or vim.fn.isdirectory(ANN .. '/Lua') ~= 1 then
    print('wowdistill: --annotations must name vscode-wow-api\'s Annotations/Core (it holds Lua/, Data/ …)')
    os.exit(2)
end
-- (the annotation set's commit: the profile's version, so a re-distil against a newer set says so)
local version = vim.fn.system({ 'git', '-C', ANN, 'rev-parse', '--short', 'HEAD' }):gsub('%s+$', '')
if vim.v.shell_error ~= 0 or version == '' then version = ANN:match('vscode%-wow%-api%-(%x+)') or 'unknown' end

local R = require('cartograph.metaread').new()
local sigs, n = {}, { lua = 0, api = 0, dup = 0, alias = 0 }
local PRIM = { string = true, number = true, integer = true, boolean = true }
local LIBS = { string = true, table = true, math = true, bit = true, os = true, coroutine = true, debug = true }

local function add(key, s, tier, rel, line)
    if sigs[key] then n.dup = n.dup + 1; return end
    s.file, s.line, s.tier = rel, line, tier
    -- (API: the first return only, and only a Lua PRIMITIVE — a struct or class may have changed shape between clients:
    -- 3.3.5's GetContainerItemInfo returns a texture string, today's a ContainerItemInfo. As CART-1827's debuginfo
    -- fields: a primitive is believed, nothing else is claimed)
    if tier == 'api' and s.returns then
        local r1 = s.returns[1]
        local t = r1 and r1.type and r1.type:gsub('%?$', '')
        s.returns = (t and PRIM[t]) and { r1 } or {}
    end
    sigs[key] = s
    n[tier] = n[tier] + 1
end

local function read(path, tier)
    local lines = vim.fn.readfile(path)
    local rel = path:sub(#ANN + 2)
    R:each_function(lines, {
        -- (LUA: a library table's members; API: bare globals only — a namespaced function is the modern client's)
        owner_of = function (o) return tier == 'lua' and LIBS[o] and o or nil end,
    }, function (f)
        if f.owner or (f.bare and not f.owner) then
            if tier == 'api' and f.owner then return end
            local s = f.sig
            if f.sep == ':' then s.method = true end
            add(f.key, s, tier, rel, f.line)
        end
    end)
    return lines, rel
end

-- LUA tier: the library files, then compat.lua's aliases (`local str = string` … `strtrim = str.trim`): an alias's
-- signature is its target's, read above, not restated
local luafiles = vim.fn.globpath(ANN .. '/Lua', '*.lua', false, true)
table.sort(luafiles)
for _, p in ipairs(luafiles) do read(p, 'lua') end
for _, p in ipairs(luafiles) do
    local loc = {}
    for _, l in ipairs(vim.fn.readfile(p)) do
        local a, lib = l:match('^local%s+([%a_][%w_]*)%s*=%s*([%a_][%w_]*)%s*$')
        if a and LIBS[lib] then loc[a] = lib end
        local name, t, m = l:match('^([%a_][%w_]*)%s*=%s*([%a_][%w_]*)%.([%a_][%w_]*)%s*$')
        local lib2 = t and (loc[t] or (LIBS[t] and t))
        local target = lib2 and sigs[lib2 .. '#' .. m]
        if name and target and not sigs[name] then
            local s = vim.deepcopy(target)
            s.alias_of = lib2 .. '#' .. m
            sigs[name] = s
            n.alias = n.alias + 1
        end
    end
end
-- API tier: Blizzard's own generated documentation first, the wiki's after it
local apifiles = vim.fn.globpath(ANN .. '/Blizzard_APIDocumentationGenerated', '*.lua', false, true)
table.sort(apifiles)
apifiles[#apifiles + 1] = ANN .. '/Data/Wiki.lua'
for _, p in ipairs(apifiles) do if vim.fn.filereadable(p) == 1 then read(p, 'api') end end

local prof = {
    schema = 1, runtime = 'wow', lang = 'lua', version = version,
    stamp = ('distilled from vscode-wow-api %s (Annotations/Core: Lua/ in full; documented globals, a primitive first return only)'):format(version),
    sig_kind = 'annotation', sig_source = ANN,
    sigs = sigs,
    free = {},
}
local n_str = 0
for _, s in pairs(sigs) do if s.returns and s.returns[1] and s.returns[1].type == 'string' then n_str = n_str + 1 end end
print(('wowdistill  %s  (vscode-wow-api %s)'):format(ANN, version))
print(('  lua tier %d, api tier %d (a primitive first return only), %d compat aliases, %d duplicates folded, %d multi-line types UNKNOWN; %d return a string first')
    :format(n.lua, n.api, n.alias, n.dup, R.multiline, n_str))
if SHOW then
    for _, k in ipairs { 'string#trim', 'strtrim', 'string#split', 'strsplit', 'tinsert', 'debugstack', 'GetCursorInfo', 'GetAddOnInfo', 'GetSpellName' } do
        local s = sigs[k]
        print(('  %-16s %s'):format(k, s and (s.sig .. (s.tier == 'api' and ('  [believed: ' .. tostring(s.returns[1] and s.returns[1].type) .. ']') or '')) or 'ABSENT'))
    end
    os.exit(0)
end
local fd = assert(io.open(OUT, 'wb'))
fd:write(vim.mpack.encode(prof)); fd:close()
print(('  wrote %s (%d bytes); re-run against a newer annotation set to update'):format(OUT:sub(#REPO + 2), vim.fn.getfsize(OUT)))
