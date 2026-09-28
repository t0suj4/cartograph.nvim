-- FAMILY-PREMISE (discovery): do these FILES share near-clone families — is "edit one, propagate to the rest" a
-- premise that holds for them? MEASURED 2026-09-28 before CART-1152's plugin reshaping: of 32 families in
-- lua/cartograph, 2 touched the xmpp/peer modules, both incidental helpers — the premise failed, and the goal was
-- re-chosen. CLAIM: some family has at least two members inside the given file set.
return {
    name = 'family-premise',
    kind = 'discovery',
    summary = 'the near-clone families with 2+ members inside a file set (params.files = { rel, ... }; omitted = every file)',
    params = { files = 'list?' },
    measure = function (store, p)
        local set
        if p.files then set = {}; for _, f in ipairs(p.files) do set[f] = true end end
        local r = require('cartograph.clones').families(store, {})
        local v = { families = 0, inside = {} }
        for _, fam in ipairs((r and r.families) or {}) do
            v.families = v.families + 1
            local names = {}
            for _, m in ipairs(fam.members) do if not set or set[m.file] then names[#names + 1] = m.file .. '::' .. m.name end end
            if #names >= 2 then v.inside[#v.inside + 1] = names end
        end
        return v
    end,
    claim = function (v)
        return #v.inside > 0, ('%d of %d families have 2+ members in the set'):format(#v.inside, v.families)
    end,
    examples = {
        {
            name = 'two near-clone members in the set: the premise holds',
            files = { ['a.lua'] = 'local M = {}\nfunction M.f(t)\n  local n = 0\n  for i = 1, #t do n = n + t[i] * 2 end\n  local s = tostring(n)\n  local p = string.rep("-", #s)\n  return p .. s\nend\nreturn M\n',
                ['b.lua'] = 'local M = {}\nfunction M.g(t)\n  local n = 0\n  for i = 1, #t do n = n + t[i] * 3 end\n  local s = tostring(n)\n  local p = string.rep("-", #s)\n  return p .. s\nend\nreturn M\n' },
            params = { files = { 'a.lua', 'b.lua' } },
            expect = { holds = true },
        },
        {
            name = 'unrelated modules: the premise fails, and propagation has nothing to cross',
            files = { ['a.lua'] = 'local M = {}\nfunction M.f(x) return x end\nreturn M\n',
                ['b.lua'] = 'local M = {}\nfunction M.g(a, b)\n  local t = {}\n  t[a] = b\n  return t\nend\nreturn M\n' },
            params = { files = { 'a.lua', 'b.lua' } },
            expect = { holds = false },
        },
    },
}
