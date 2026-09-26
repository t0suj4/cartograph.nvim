-- THE LUA DIALECT a root is written in, and the PARSE VIEW that follows from it.
-- @langs lua
--
-- tree-sitter-lua follows Lua 5.5, where `global` is a keyword (`global x = 1` declares a global). Every Lua before 5.5
-- has no such keyword: `global` is an ordinary name, and Factorio 1.x keeps its persistent state in a table called
-- exactly that. Parsed by the 5.5 grammar, `global.flag` loses its table child and `local t = global` loses its value
-- (measured on tree-sitter-lua 10fe005, which nvim 0.12 also bundles), so every read of Factorio's `global` vanished
-- from the graph.
--
-- The fix is tied to the DIALECT, because in 5.5 code the keyword is real. For a pre-5.5 root the grammar parses a
-- VIEW of the bytes in which each whole word `global` is `_lobal`: the same length, and an identifier to the grammar.
-- Every consumer reads node TEXT from the original bytes, so the name still comes out as `global` and every range
-- still addresses the file. Masking inside strings and comments is harmless for the same reason. A 5.5 root is parsed
-- as written.
--
-- WHERE THE DIALECT COMES FROM, first match wins: `.luarc.json`/`.luarc.jsonc` `runtime.version` (the lua-language-
-- server setting), `.luacheckrc` `std`, the root's environment PROFILE (Factorio runs Lua 5.2), else the DEFAULT:
-- before 5.5. The default is stated, not hidden: `resolve` returns the source with the version, the graph records both
-- (data.lua_dialect), and the cache compares them.
local M = {}

-- '5.1' .. '5.5' or 'jit'; nil = not set (the default reading applies)
local current

local function norm(v)
    if type(v) ~= 'string' then return nil end
    local s = v:lower()
    if s:find('jit', 1, true) then return 'jit' end
    local maj, min = s:match('(%d)%.?(%d)')
    if maj == '5' and min then return '5.' .. min end
    return nil
end

local function read(path)
    local fd = io.open(path, 'rb')
    if not fd then return nil end
    local s = fd:read('a'); fd:close()
    return s
end

--- The dialect a root declares: version ('5.1'..'5.5' | 'jit' | nil), source (a short label, never nil).
function M.resolve(root)
    root = root and vim.fn.fnamemodify(root, ':p'):gsub('/+$', '') or nil
    if root then
        for _, name in ipairs({ '.luarc.json', '.luarc.jsonc' }) do
            local s = read(root .. '/' .. name)
            if s then
                -- jsonc: drop // and /* */ comments before decoding
                local clean = s:gsub('/%*.-%*/', ''):gsub('\n%s*//[^\n]*', '\n')
                local ok, t = pcall(vim.json.decode, clean)
                local v = ok and type(t) == 'table'
                    and (t['runtime.version'] or (type(t.runtime) == 'table' and t.runtime.version)
                        or (type(t.Lua) == 'table' and type(t.Lua.runtime) == 'table' and t.Lua.runtime.version))
                if norm(v) then return norm(v), name end
            end
        end
        local rc = read(root .. '/.luacheckrc')
        local std = rc and rc:match('std%s*=%s*["\']([^"\']+)["\']')
        if std then
            -- a combined std (`luajit+busted`, `lua51c`) names its base first
            local base = std:match('^(lua%d%dc?)') or std:match('^(luajit)')
            local v = base and (base == 'luajit' and 'jit' or ('5.' .. base:sub(5, 5)))
            if v then return v, '.luacheckrc' end
        end
        local ok_s, shapes = pcall(require, 'cartograph.shapes')
        local pf = ok_s and shapes.profile_for and shapes.profile_for(root) or nil
        local prof = pf and pf.profile
        if type(prof) == 'string' then
            if prof:find('factorio', 1, true) then return '5.2', 'profile:' .. prof end
            if prof:find('luajit', 1, true) then return 'jit', 'profile:' .. prof end
        end
    end
    return nil, 'default (before 5.5)'
end

--- Set the dialect later parses use (extraction sets it per run; store.ingest re-adopts a graph's).
function M.set(v) current = norm(v) end
function M.get() return current end

--- Does this dialect read `global` as a name? Everything before 5.5, and the unset default.
function M.global_is_name(v)
    if v == nil then v = current end
    return v ~= '5.5'
end

--- The bytes to PARSE for `src` in `lang`. Identity for any language but lua, and for a 5.5 root.
function M.view(src, lang, v)
    if lang ~= 'lua' or type(src) ~= 'string' or not M.global_is_name(v) then return src end
    if not src:find('global', 1, true) then return src end
    -- whole word only: `global_x`, `myglobal`, `globals` are left alone
    return (src:gsub('%f[%w_]global%f[^%w_]', '_lobal'))
end

--- A string parser over the parse view. Callers keep reading node text from `src`, never from parser:source().
function M.parser(src, lang)
    return vim.treesitter.get_string_parser(M.view(src, lang), lang)
end

return M
