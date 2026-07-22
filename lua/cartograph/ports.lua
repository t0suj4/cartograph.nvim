-- PORTS — the per-band PORT SURFACE (federation F1, [[cartograph-band-federation]]
-- / [[cartograph-merging-strategies]]). "Fold within a band, federate across bands":
-- a band PROVIDES the resolvable symbols it defines and NEEDS the free references it
-- makes to symbols it does not define. The linkage band matches needs <-> provides,
-- so cross-band resolution is a lookup, not a whole-graph pass.
--
-- This is the "needs" half made first-class (the lower-risk F1 piece): PURE
-- derivation from an already-resolved graph + a band_of(file) scheme (INJECTABLE —
-- the seam; default = directory depth, but scope_of / a gem/load-path bander drops
-- in). No resolution change. The cross-band resolution pass is the follow-on that
-- CONSUMES this surface; portgate self-checks it (every cross-band resolved target
-- is addressable through some band's provides + the constant->band index).
--
-- Free variables are already collected raw — flow's `free inputs` (per-fn upward-
-- exposed uses), callee_binding's param/local/free classes, and externals.lua's
-- external surface (refs resolving to nothing corpus-wide). This RE-SCOPES that to
-- per-band: a band's needs = refs whose target is not IN this band (cross-band
-- resolved OR frontier), which is broader than externals' corpus-wide "resolves to
-- nothing" (it includes refs that DID resolve, just across a band).

local M = {}

-- default band = the file's directory subtree at `depth` (a proxy for the scope
-- unit; the real bander is scope_of / gem / load-path — passed in by the caller).
function M.default_band_of(depth)
    depth = depth or 3
    return function (file)
        local parts, i = {}, 0
        for seg in file:gmatch('[^/]+') do i = i + 1; if i > depth then break end; parts[i] = seg end
        if #parts >= 1 and file:sub(-#parts[#parts]) == parts[#parts] and i <= depth then parts[#parts] = nil end
        return table.concat(parts, '/')
    end
end

-- owner CONSTANT of a def/ref name — the class/module path before the LAST method
-- separator, language-general: `::` (java/php/ruby-const `Foo::Bar::m`), `#` (ruby
-- instance `Foo#m`), `.` (ruby singleton / js `Foo.m`). nil if not method-qualified.
-- This is the key the constant->band cross-band linkage matches on.
function M.owner_of(name)
    if not name then return nil end
    return name:match('^(.+)::[%w_?!=]+$')
        or name:match('^(.+)#[%w_?!=]+$')
        or name:match('^(.+)%.[%w_?!=]+$')
end

-- build the port surface over a RESOLVED graph. band_of : file -> band id.
-- Returns {
--   bands = { [band] = {
--     files    = { file = true },
--     provides = { exact-key -> true },   -- resolvable symbols defined in-band
--     consts   = { constant -> true },    -- owner classes/modules defined in-band
--     needs    = { refkey -> { n, to? } } -- free refs; `to` = the band it resolved
--                                         --   to today (nil = frontier)
--   } },
--   const_index = { constant -> { band -> true } }, -- the constant->band(s) linkage map
-- }
function M.surface(data, band_of)
    band_of = band_of or M.default_band_of()
    local node_index = {}
    for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end
    local bands, const_index = {}, {}
    local function band(id)
        local b = bands[id]
        if not b then b = { files = {}, provides = {}, consts = {}, needs = {} }; bands[id] = b end
        return b
    end
    -- PROVIDES: each fn/method def's exact key (mirroring build_index's keying —
    -- torn/decl excluded, altkeys included) + its owner constant.
    for _, n in ipairs(data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and not n.torn and not n.decl and n.file then
            local bid = band_of(n.file)
            local b = band(bid)
            b.files[n.file] = true
            b.provides[n.name] = true
            for _, k in ipairs(n.altkeys or {}) do b.provides[k] = true end
            local oc = M.owner_of(n.name)
            if oc then
                b.consts[oc] = true
                const_index[oc] = const_index[oc] or {}
                const_index[oc][bid] = true
            end
        end
    end
    -- NEEDS: a call whose resolution target is NOT in this band — cross-band
    -- resolved (records the target band) or a frontier (no target: the honest
    -- unknown a cross-band link might satisfy). A same-band resolution is not a need.
    for _, c in ipairs(data.calls or {}) do
        if c.file then
            local key = c.full or c.callee
            if key then
                local sb = band_of(c.file)
                local to
                if c.to then
                    local t = node_index[c.to]
                    if t and t.file and not t.external then to = band_of(t.file) end
                end
                if to ~= sb then -- cross-band (to set) OR frontier (to nil)
                    local b = band(sb)
                    local rec = b.needs[key]
                    if not rec then rec = { n = 0 }; b.needs[key] = rec end
                    rec.n = rec.n + 1
                    if to then rec.to = to end
                end
            end
        end
    end
    return { bands = bands, const_index = const_index }
end

return M
