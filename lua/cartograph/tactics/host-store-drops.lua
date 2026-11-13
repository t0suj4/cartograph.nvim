-- HOST-STORE-DROPS (discovery, CART-2045, asked by flowpath FLOW-0183): every store flowtype's HOST-KIND RULE refuses —
-- the edge the solve does not make, which no other verb shows. A value of a HOST type (a profile's `file`, `TSNode`, a
-- `string`) takes a store only when its kind is `open` (CART-1761): `prim` (string, number, function …) raises in Lua, so
-- the store goes nowhere; `members` has its declared members only, so a store of any other field is dropped; `open` is
-- an ordinary object and keeps every store. A row: `stores  kind  type.field  sites` — the stores refused (distinct store
-- instructions), the type's kind, the field, and the stores' sites (`file:line:col`, 0-based; `-` where the store was not
-- an assignment the walk placed: a `function t.f()` declaration, a model's store). The kind comes from the profile
-- (`kinds`, a type's own `kind`) or the default (G7.hostkind: a scalar or function type `prim`, any other `members`).
-- WHY IT MATTERS: a dropped store is a read that later reads nothing of it — `local T = hostmake(); T.k = A; T.k`
-- reads nothing when T is a `members` host object. Sound only if the type really refuses the field; a host type the
-- profile marks too narrowly drops a store the runtime keeps, so a row here is the place to check that.
-- Runs the solve with explain on (closed by default). params: mode = closed | open, top = rows in the value (default 30).
-- CLAIM: the solve ran; the value lists the drops.

local function measure(store, p)
    local t0 = vim.uv.hrtime()
    local R = require('cartograph.flowtype').solve(store, { open = p.mode == 'open', ctx = false, explain = true })
    local drops = R.host_store_drops()
    local v = { secs = (vim.uv.hrtime() - t0) / 1e9, types = 0, stores = 0, kinds = {}, rows = {} }
    local seen = {}
    for _, d in ipairs(drops) do
        if not seen[d.type] then seen[d.type] = true; v.types = v.types + 1 end
        v.stores = v.stores + d.n
        v.kinds[d.kind] = (v.kinds[d.kind] or 0) + d.n
    end
    table.sort(drops, function (a, b)
        if a.n ~= b.n then return a.n > b.n end
        if a.type ~= b.type then return a.type < b.type end
        return a.field < b.field
    end)
    for i = 1, math.min(#drops, tonumber(p.top) or 30) do
        local d = drops[i]
        local s = #d.sites > 0 and table.concat(vim.list_slice(d.sites, 1, 5), ' ') .. (#d.sites > 5 and (' +' .. (#d.sites - 5)) or '') or '-'
        v.rows[i] = ('%5d  %-8s %s.%s  %s'):format(d.n, d.kind, d.type, d.field, s)
    end
    v.fields = #drops
    return v
end

local FX = { ['m.lua'] = table.concat({
    'local f = io.open("x")',
    'f.k = 1',
    'local s = "abc"',
    'local t = { s = s }',
    't.s.z = 2',
    'local function put(o) o.w = 3 end',
    'put(io.stdout)',
    'local own = {}',
    'own.k = 4',
    'local q = "x"',
    'q.y = 5',
    'local ins = table.insert', -- (by VALUE: the model stores while the SOLVE runs, into a port that already holds the
    'ins(q, 6)' }, '\n') .. '\n' }  -- string — refused at the store itself, with no walk site: `-`)

return {
    name = 'host-store-drops',
    kind = 'discovery',
    tags = { 'measure', 'flow', 'code' },
    summary = 'every store flowtype\'s HOST-KIND RULE refuses (CART-1761, the edge the solve does not make): a host-typed value takes a store only when its kind is `open` — `prim` (string, number, function) raises, `members` keeps its declared members only — as rows `stores kind type.field sites` (sites file:line:col, 0-based); the place to check a profile that marks a host type too narrowly; mode = closed | open, top = rows',
    params = { mode = 'string?', top = 'string?' },
    measure = measure,
    claim = function (v)
        local ks = {}
        for k, n in pairs(v.kinds) do ks[#ks + 1] = ('%s %d'):format(k, n) end
        table.sort(ks)
        return true, ('%d stores refused by a host type\'s kind, over %d field(s) of %d type(s) (%s); %.1f s')
            :format(v.stores, v.fields, v.types, #ks > 0 and table.concat(ks, ', ') or 'none', v.secs)
    end,
    examples = {
        {
            name = 'a file\'s and a string\'s stores are refused, with their sites — at the store or when the value arrives; an ordinary table\'s store is kept',
            files = FX,
            params = function () return { top = '10' } end,
            expect = { holds = true, check = function (v)
                local want = {
                    '    2  prim     string.#  -',
                    '    1  members  file.k  m.lua:1:2',
                    '    1  members  file.w  m.lua:5:24',
                    '    1  prim     string.y  m.lua:10:2',
                    '    1  prim     string.z  m.lua:4:4',
                }
                return vim.deep_equal(v.rows, want) and v.stores == 6 and v.types == 2, vim.inspect(v)
            end },
        },
    },
}
