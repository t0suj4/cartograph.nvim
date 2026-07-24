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

--- A content-identity STAMP of the artifact(s) backing a profile — the file
--- mtime+size of the hand `.lua` module and/or the distilled `.mpack` blob (both
--- if present; the same files load() consults). ANY edit to a profile artifact
--- changes it, so a cached graph whose resolution used the profile can be
--- invalidated ([[cartograph-repo-shapes]] stamping gap: profiles are re-derived
--- but never stamped). Returns a stable string, or nil when no artifact exists
--- (an unknown runtime). Cheap: two fs_stat calls, no read/decode. NOTE: a hand
--- profile that internally loads ANOTHER runtime's .mpack (ruby-rails → ruby-core)
--- is not transitively covered — only its direct artifact; documented limit.
function M.stamp_of(runtime)
    local parts = {}
    for _, ext in ipairs({ 'lua', 'mpack' }) do
        local st = vim.uv.fs_stat(DIR .. '/' .. runtime .. '.' .. ext)
        if st then
            parts[#parts + 1] = ('%s:%d:%d'):format(ext, st.mtime.sec, st.size)
        end
    end
    return #parts > 0 and table.concat(parts, '|') or nil
end

return M
