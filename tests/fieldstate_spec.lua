-- fieldstate: INSTANCE STATE on the write axis (CART-1575) — a method's reads and writes through its receiver
-- (`self.f`, `this.f`) are `use` edges to one `field` node per (file, class, field), carrying rw and the guard class,
-- so an instance memo is SET-ONCE like a module one. A method CALL through the receiver is no field; a closure nested
-- in a method binds no receiver of its own. And the effects consequence: a lua colon method writing `self.i` — its
-- `self` is implicit, no parameter — had read PURE.

local ts = require 'cartograph.providers.treesitter'

local function ready(lang) return pcall(vim.treesitter.language.add, lang) end
local function fields_of(data)
    local byid, out = {}, {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    for _, e in ipairs(data.edges) do
        local t, f = byid[e.to], byid[e.from]
        if e.kind == 'use' and t and t.kind == 'field' and f then out[f.name .. ' -> ' .. t.name] = { rw = e.rw, gw = e.gw } end
    end
    return out, byid
end

test('fieldstate: python / javascript / lua — per-class fields, rw, and the instance memo SET-ONCE; a call is no field, a nested closure binds no receiver', function ()
    for _, l in ipairs({ 'python', 'javascript', 'lua' }) do if not ready(l) then skip('no ' .. l .. ' parser') end end
    local root = mkroot('m.py', table.concat({
        'class Repo:',
        '    def get(self, k):',
        '        if self._cache is None:',
        '            self._cache = {}',
        '        return self._cache.get(k)',
        '    def put(self, v):',
        '        self.value = v',
        '        self.flush()',                      -- a CALL: no field `flush`
        '    def merge(self, other):',
        '        other.count = 1',                    -- ANOTHER parameter: no field of Repo
        '    def later(self):',
        '        def inner():',
        '            self.ghost = 1',                 -- a closure: no receiver of its own
        '        return inner',
    }, '\n'))
    local f = assert(io.open(root .. '/m.js', 'w'))
    f:write('class Store {\n  get(k) { this.cache ??= new Map(); return this.cache.get(k); }\n  put(v) { this.value = v; this.flush(); }\n}\n'
        .. 'const o = { m() { this.z = 1; } };\n') -- (an OBJECT-literal method: no class)
    f:close()
    f = assert(io.open(root .. '/m.lua', 'w'))
    f:write('local T = {}\nfunction T:get(k) self.cache = self.cache or {}; return self.cache[k] end\nfunction T:put(v) self.value = v end\nreturn T\n')
    f:close()
    local got = fields_of(ts.extract(root))
    eq({ rw = 3, gw = 3 }, got['Repo.get -> Repo._cache'], 'python: `if self._cache is None:` memo, set-once')
    eq({ rw = 2, gw = 1 }, got['Repo.put -> Repo.value'], 'python: a plain write')
    eq(nil, got['Repo.put -> Repo.flush'], 'python: a method call is no field')
    eq(nil, got['Repo.later -> Repo.ghost'], 'python: a closure binds no receiver')
    eq(nil, got['Repo.merge -> Repo.count'], 'python: only the FIRST parameter is the receiver')
    for k in pairs(got) do ok(not k:find('%.z$'), 'js: an object-literal method is no class method: ' .. k) end
    eq({ rw = 3, gw = 3 }, got['Store.get -> Store.cache'], 'js: `this.cache ??=` set-once')
    eq({ rw = 2, gw = 1 }, got['Store.put -> Store.value'], 'js: a plain write')
    eq(nil, got['Store.put -> Store.flush'], 'js: a method call is no field')
    eq({ rw = 3, gw = 3 }, got['T:get -> T.cache'], 'lua: `self.cache = self.cache or {}` set-once')
    eq({ rw = 2, gw = 1 }, got['T:put -> T.value'], 'lua: a plain write')
end)

test('fieldstate: a lua colon method writing self is no longer PURE to effects (its self is implicit, no parameter)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local store = require 'cartograph.store'
    store.ingest(ts.extract(mkroot('m.lua', 'local P = {}\nfunction P:accept(x) if self.t == x then self.i = self.i + 1; return true end return false end\nreturn P\n')))
    local id
    for _, n in ipairs(store.data.nodes) do if n.name == 'P:accept' then id = n.id end end
    eq('writes', require('cartograph.effects').purity(store, id))
end)