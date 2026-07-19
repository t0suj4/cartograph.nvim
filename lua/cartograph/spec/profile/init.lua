-- L2 environment-profile loader ([[cartograph-stdlib-profile]], the P2 layering
-- artifact). A profile is a distilled stdlib surface (type→members, ctors,
-- derived vocab) written by tools/distill.lua as `<runtime>.mpack` beside this
-- file. Version-keyed data, NOT code — loaded once, composed at L2 into the
-- effective spec (vocab gate + stdlib-TIER minting) and served as a band for
-- LSP. Missing/corrupt = a clean nil (no profile, honest), never a half-load.

local M = {}

local DIR = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/init%.lua$')
local cache = {}

--- Load the profile for a runtime (e.g. 'zig-std', 'lua-factorio'). Returns the
--- profile table or nil. Memoized. Two artifact forms: a HAND-AUTHORED `.lua`
--- module (reviewable, git-diffable — Factorio) or a DISTILLED `.mpack` blob
--- (extracted from source — zig). The .lua form wins if both exist.
function M.load(runtime)
    if cache[runtime] ~= nil then
        return cache[runtime] or nil
    end
    local prof
    local ok_lua, mod = pcall(require, 'cartograph.spec.profile.' .. runtime)
    if ok_lua and type(mod) == 'table' and mod.schema == 1 then
        prof = mod
    else
        local fd = io.open(DIR .. '/' .. runtime .. '.mpack', 'rb')
        if fd then
            local blob = fd:read('*a'); fd:close()
            local ok, dec = pcall(vim.mpack.decode, blob)
            if ok and type(dec) == 'table' and dec.schema == 1 then prof = dec end
        end
    end
    cache[runtime] = prof or false
    return prof
end

return M
