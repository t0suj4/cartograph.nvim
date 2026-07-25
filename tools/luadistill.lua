-- luadistill — mint a `luajit` L2 profile by INTROSPECTING the interpreter this
-- runs in, rather than by transcribing a manual. The distinction matters: a
-- hand-typed provides-set is a claim, while `for k in pairs(string)` is a
-- measurement of the runtime that will actually execute the code.
--
-- Motivation ([[cartograph-portability-lever]]): the A-to-B move diff needs TWO
-- name-queryable profiles for ONE language, and only `lua-factorio` shipped. This
-- is its sibling, so "which parts of this mod need Factorio rather than plain
-- Lua?" becomes answerable — and the answer is derived from artifacts, not
-- authored.
--
-- HONESTY about what this profile IS:
--   · the surface of the LuaJIT embedded in the nvim that ran the distiller —
--     recorded in `version` and `stamp`, not implied.
--   · nvim's own additions are EXCLUDED by an explicit deny-list, because a
--     profile called `luajit` must not quietly promise `vim`.
--   · namespaces are taken as the interpreter presents them; a member list is
--     whatever the table actually holds, so nothing is asserted that is absent.
--
--   nvim --headless -u NONE -l tools/luadistill.lua        -- writes the .mpack
--   nvim --headless -u NONE -l tools/luadistill.lua --show -- print, write nothing

local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local OUT = REPO .. '/lua/cartograph/spec/profile/luajit.mpack'

local SHOW = false
for _, a in ipairs(arg or {}) do
    if a == '--show' then SHOW = true
    else print('luadistill: unknown argument ' .. a); os.exit(2) end
end

-- what nvim injects, and must not ride along under the name `luajit`
local DENY = { vim = true, _G = true, arg = true, unpack = false }
-- LuaJIT ships these beyond 5.1's set; they are part of the runtime, so they stay
local NAMESPACES = { string = true, table = true, math = true, os = true,
    io = true, coroutine = true, debug = true, package = true,
    bit = true, jit = true, ffi = true }

local free, namespaces, nsset, types, vocab = {}, {}, {}, {}, {}
local n_members = 0

for k, v in pairs(_G) do
    if not DENY[k] then
        if type(v) == 'function' then
            free[k] = true
            vocab[k] = true
        elseif type(v) == 'table' and NAMESPACES[k] then
            namespaces[k] = true
            nsset[k] = true
            vocab[k] = true
            local members = {}
            local ok = pcall(function ()
                for mk, mv in pairs(v) do
                    if type(mk) == 'string' then
                        members[mk] = true
                        vocab[mk] = true
                        n_members = n_members + 1
                        local _ = mv
                    end
                end
            end)
            if not ok then members = {} end -- a table that refuses iteration
            types[k] = { members = members }
        end
    end
end

local version = (type(jit) == 'table' and jit.version) or _VERSION or 'lua'
local prof = {
    schema = 1, runtime = 'luajit', lang = 'lua',
    version = version,
    stamp = ('introspected from %s; nvim additions (%s) excluded')
        :format(version, table.concat(vim.tbl_keys(DENY), ' ')),
    free = free, namespaces = namespaces, nsset = nsset, types = types,
    vocab = vocab,
}

local nfree, nns, nvocab = 0, 0, 0
for _ in pairs(free) do nfree = nfree + 1 end
for _ in pairs(nsset) do nns = nns + 1 end
for _ in pairs(vocab) do nvocab = nvocab + 1 end

print(('luadistill — %s'):format(version))
print(('  free functions   %d'):format(nfree))
print(('  namespaces       %d  (%s)'):format(nns,
    table.concat((function ()
        local ks = vim.tbl_keys(nsset); table.sort(ks); return ks
    end)(), ' ')))
print(('  members          %d'):format(n_members))
print(('  vocab (total)    %d'):format(nvocab))

if SHOW then
    print('  --show: nothing written')
    return
end

local blob = vim.mpack.encode(prof)
local fd = assert(io.open(OUT, 'wb'))
fd:write(blob)
fd:close()
print(('  wrote %s (%d bytes)'):format(OUT:sub(#REPO + 2), #blob))
print('  re-run after a LuaJIT upgrade; the profile records which one it saw')
