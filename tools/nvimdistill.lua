-- nvimdistill — distil the NEOVIM RUNTIME's Lua API into an L2 environment profile (`nvim`), from the runtime's OWN
-- LuaLS annotations ([[cartograph-stdlib-profile]], CART-1150).
--
--   nvim --headless -u NONE -l tools/nvimdistill.lua [--show] [--runtime <dir>]
--
-- ★★ THE SOURCE IS THE RUNTIME THAT RUNS THE CODE, NOT A LIST. Neovim ships its API annotated for lua-language-server:
-- `_meta/vimfn.gen.lua` (every `vim.fn.*`), `_meta/api.gen.lua` (every `vim.api.nvim_*`), and the Lua modules
-- themselves (`vim/treesitter.lua`'s `---@return string` over `get_node_text`). This reads those blocks with the SAME
-- reader luadistill uses (cartograph.metaread), so the profile is derived and version-stamped, and an upgrade
-- re-distils. Nothing here is authored.
--
-- WHICH DEFINITIONS COUNT — a public name, never a file's private helper:
--   * an owner rooted at `vim` as written (`function vim.fn.system(…)`, `function vim.trim(…)`)
--   * a file's MODULE TABLE (`local M = {}` … `return M`), named by the file's path: `vim/treesitter.lua`'s `M.x` is
--     `vim.treesitter.x`, an `init.lua` names its directory
--   * a class the same file declares (`---@class TSNode` … `function TSNode:type()`)
-- A CLAIM TIER: signatures are `sig_kind = 'annotation'` (docblocks can lie, CART-0240) and are read in RETURN
-- position only (a string receiver, spec/lua.lua) — this profile names no namespace and no free function, so it
-- changes no call's disposition on its own.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))

local OUT = REPO .. '/lua/cartograph/spec/profile/nvim.mpack'
local RUNTIME = vim.env.VIMRUNTIME
local SHOW = false
local i = 1
while arg[i] do
    if arg[i] == '--show' then SHOW = true
    elseif arg[i] == '--runtime' and arg[i + 1] then RUNTIME = vim.fn.expand(arg[i + 1]); i = i + 1
    else io.stderr:write('nvimdistill: unknown argument ' .. arg[i] .. '\n'); os.exit(2) end
    i = i + 1
end
if not RUNTIME or vim.fn.isdirectory(RUNTIME .. '/lua/vim') ~= 1 then
    print('nvimdistill: no Neovim runtime at ' .. tostring(RUNTIME) .. ' — this distils from the runtime that RUNS it')
    os.exit(2)
end
local version = tostring(vim.version())

local ts = require 'cartograph.providers.treesitter'
local R = require('cartograph.metaread').new()
local files = vim.fn.globpath(RUNTIME .. '/lua/vim', '**/*.lua', false, true)
table.sort(files)

local sigs, n_sig, n_dup, n_str, per_root = {}, 0, 0, 0, {}
for _, path in ipairs(files) do
    local lines = vim.fn.readfile(path)
    local rel = path:sub(#RUNTIME + #'/lua/' + 1)
    local modname = rel:gsub('%.lua$', ''):gsub('/init$', ''):gsub('/', '.')
    -- the MODULE TABLE: the name the file's last statement returns. (ts.module_table's strict idiom also wants a bare
    -- `local M = {}`, and the runtime builds several with `vim._defer_require(…)` — treesitter.lua among them)
    local mtbl
    for j = #lines, 1, -1 do
        if lines[j]:match('%S') then mtbl = lines[j]:match('^return%s+([%a_][%w_]*)%s*$'); break end
    end
    mtbl = mtbl or ts.module_table(path, lines)
    local classes, alias = {}, {}
    -- (a class's methods often hang off a LOCAL named for it: `---@class vim.treesitter.LanguageTree` … `local
    -- LanguageTree = {}` … `function LanguageTree:parse()` — the methods are the declared class's, so the local is an
    -- ALIAS of it when only annotation lines stand between the two; without this every LanguageTree method was lost,
    -- and a value from `get_string_parser(…):parse()` had no type)
    local pending
    for _, l in ipairs(lines) do
        local body = l:match('^%-%-%-%s*@class%s+(.*)$')
        local c = body and body:gsub('^%(%w+%)%s*', ''):match('^([%w_%.]+)')
        if c then classes[c] = true; pending = c
        elseif l:match('^%-%-%-') or not l:match('%S') then -- (still the annotation block)
        else
            local x = l:match('^local%s+([%a_][%w_]*)%s*=')
            if pending and x and x ~= pending then alias[x] = pending end
            pending = nil
        end
    end
    local function owner_of(o)
        -- a `vim`-rooted owner is PUBLIC AS WRITTEN, even where the file returns that table (shared.lua ends
        -- `return vim`, and mapping it to the path would have named `vim.trim` `vim.shared.trim`)
        if o == 'vim' or o:match('^vim%.') then return o end
        if mtbl and o == mtbl then return modname end
        if classes[o] then return o end
        if alias[o] then return alias[o] end
        return nil -- a file-local helper table: not an API
    end
    R:each_function(lines, { owner_of = owner_of }, function (f)
        if not f.owner then return end -- a bare global in the runtime: not declared as an API here
        local s = f.sig
        s.file, s.line = rel, f.line
        if f.sep == ':' then s.method = true end
        -- (a file that RETURNS a class alias — languagetree.lua returns LanguageTree — names its functions by the path,
        -- `vim.treesitter.languagetree#parse`; a value TYPED by the class, `vim.treesitter.LanguageTree`, looks its
        -- methods up under the class: both names)
        if mtbl and alias[mtbl] and f.owner == modname then
            local cls_key = alias[mtbl] .. '#' .. f.key:sub(#modname + 2)
            if not sigs[cls_key] then sigs[cls_key] = s end
        end
        if sigs[f.key] then
            n_dup = n_dup + 1
            sigs[f.key].overloads = (sigs[f.key].overloads or 1) + 1
        else
            sigs[f.key] = s
            n_sig = n_sig + 1
            local r1 = s.returns[1]
            if r1 and r1.type == 'string' then n_str = n_str + 1 end
            local root = f.owner:match('^vim%.[%w_]+') or f.owner
            per_root[root] = (per_root[root] or 0) + 1
        end
    end)
end

local prof = {
    schema = 1, runtime = 'nvim', lang = 'lua', version = version,
    stamp = ('distilled from the LuaLS annotations of %s (nvim %s)'):format(RUNTIME, version),
    sig_kind = 'annotation', sig_source = RUNTIME,
    sigs = sigs,
    -- NO free functions and NO namespace set, on purpose: `vim.*` calls are already external by the Lua spec's
    -- stdlib prefix, and this profile is read in RETURN position only (prof_ext requires the table to exist)
    free = {},
}
print(('nvimdistill  %s  nvim %s'):format(RUNTIME, version))
print(('  %d files, %d signatures (%d overloads folded, %d multi-line types UNKNOWN), %d return a string first')
    :format(#files, n_sig, n_dup, R.multiline, n_str))
local roots = {}
for k, v in pairs(per_root) do roots[#roots + 1] = { k, v } end
table.sort(roots, function (a, b) return a[2] > b[2] end)
local shown = {}
for j = 1, math.min(12, #roots) do shown[#shown + 1] = roots[j][1] .. ' ' .. roots[j][2] end
print('  by owner: ' .. table.concat(shown, ', '))
if SHOW then
    for _, k in ipairs { 'vim.fn#system', 'vim.api#nvim_buf_get_name', 'vim.treesitter#get_node_text', 'vim#trim', 'TSNode#type' } do
        print(('  %-32s %s'):format(k, sigs[k] and sigs[k].sig or 'ABSENT'))
    end
    os.exit(0)
end
local fd = assert(io.open(OUT, 'wb'))
fd:write(vim.mpack.encode(prof)); fd:close()
print(('  wrote %s (%d bytes); re-run after a Neovim upgrade'):format(OUT:sub(#REPO + 2), vim.fn.getfsize(OUT)))
