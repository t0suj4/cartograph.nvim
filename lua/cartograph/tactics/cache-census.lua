-- CACHE-CENSUS (discovery, CART-1430 step 1): every process-level CACHE of a Lua tree, read off the STATE ATLAS's
-- field decomposition (atlas.fields): a module table whose COMPUTED-KEY bucket (`t[k]`, any key not a literal) is both
-- written and read is a memo or a lookup table. Each row says what the storage hierarchy needs to know about it:
--   writer   'load'     the module chunk fills it (constant after load — a lookup table, not a cache)
--            'function' a function writes it at run time (a cache, a registry, or state)
--   bound    'weak'     declared with __mode (the GC bounds it)
--            'reset'    a function rebinds the whole table (a generation / one-shot memo)
--            'unbounded' neither: it grows for the life of the process
--   guarded  every write is ABSENCE-GUARDED (gw = 3: `if not c[k]`, an early exit on presence, an alias of either —
--            CART-1433): the textbook memo, written once per key
--   key      the key expression at the first write site — the DOMAIN decides whether `unbounded` is a defect (a
--            language or an extension is a small domain; a node, a file, a text grows with the input)
-- A named-field table a function REBINDS whole (`cache = { gen = g, keys = {} }`) is a GENERATION SLOT: counted, listed
-- with its fields. ⚠ A one-slot cache that only rewrites its fields (expr's last-parse `pc`) is not told from a state
-- record by shape, and is not listed.
-- ⚠ It reads SHAPE: whether a function-written table is a cache or state (a registry, declared config) and which
-- freshness its readers need are questions for a reader (the census's two open columns). MEASURED on lua/ 2026-10-04:
-- 71 computed-key tables (21 load, 12 weak, 12 reset, 26 function-written strong), 34 absence-guarded.
-- CLAIM: the tree holds a cache (a memo or a slot).
local function shortline(s) return vim.trim(s or ''):sub(1, 100) end

local function measure(store, p)
    local atlas = require 'cartograph.atlas'
    local at = require 'cartograph.at'
    local prefix = p.prefix or ''
    local parse, text_of = {}, {}
    local function lines(file)
        if text_of[file] == nil then
            local fd = io.open(store.abs(file))
            text_of[file] = fd and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
        end
        return text_of[file] or {}
    end
    local function key_at(file, name)
        -- (a key holds no `]`; the `=` must not be the first half of `==`)
        local pat = '%f[%w_]' .. vim.pesc(name) .. '%[([^%]]*)%]%s*=()'
        for _, l in ipairs(lines(file)) do
            for k, after in l:gmatch(pat) do
                if l:sub(after, after) ~= '=' then return k end
            end
        end
        return nil
    end
    local memos, slots, nvars = {}, {}, 0
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'var' and n.file and n.file:sub(1, #prefix) == prefix and n.file:match('%.lua$') then
            nvars = nvars + 1
            local f = atlas.fields(store, n.id, parse)
            if f then
                local line = n.range and (at.sl(n.range) + 1) or 0
                local decl = lines(n.file)[line] or ''
                local weak = decl:find('__mode', 1, true) ~= nil
                local dyn = f.fields['[]']
                if dyn and dyn.nw > 0 and dyn.nr > 0 then
                    local writer = 'load'
                    for w in pairs(dyn.writers) do
                        local wn = store.node(w)
                        if wn and (wn.kind == 'function' or wn.kind == 'method') then writer = 'function' end
                    end
                    memos[#memos + 1] = { name = n.name, file = n.file, line = line, writer = writer,
                        bound = weak and 'weak' or (f.whole.nw > 0 and 'reset' or 'unbounded'),
                        guarded = dyn.gw == 3, key = key_at(n.file, n.name), decl = shortline(decl) }
                else
                    local names = {}
                    for name, rec in pairs(f.fields) do if name ~= '[]' and rec.nw > 0 then names[#names + 1] = name end end
                    if #names > 0 and f.whole.nw > 0 then
                        table.sort(names)
                        slots[#slots + 1] = { name = n.name, file = n.file, line = line, fields = names }
                    end
                end
            end
        end
    end
    local function order(a, b) if a.file ~= b.file then return a.file < b.file end return a.line < b.line end
    table.sort(memos, order); table.sort(slots, order)
    local counts = { load = 0, weak = 0, reset = 0, unbounded = 0, guarded = 0 }
    for _, m in ipairs(memos) do
        if m.writer == 'load' then counts.load = counts.load + 1 else counts[m.bound] = counts[m.bound] + 1 end
        if m.guarded then counts.guarded = counts.guarded + 1 end
    end
    return { vars = nvars, memos = memos, slots = slots, counts = counts }
end

local E = {
    name = 'cache-census',
    kind = 'discovery',
    measures = 'CART-1430',
    summary = 'every process-level cache of a Lua tree from the state atlas: computed-key tables written and read (writer load | function, bound weak | reset | unbounded, absence-guarded, the key at the write) and generation slots; prefix = a path prefix (default: the whole graph)',
    params = { prefix = 'string?' },
    measure = measure,
    claim = function (v)
        local n = #v.memos + #v.slots
        if n == 0 then return false, ('no cache among %d module vars'):format(v.vars) end
        local c = v.counts
        return true, ('%d computed-key tables (%d load, %d weak, %d reset, %d unbounded; %d absence-guarded), %d slots'):format(
            #v.memos, c.load, c.weak, c.reset, c.unbounded, c.guarded, #v.slots)
    end,
}

local FILES = {
    ['m.lua'] = table.concat({
        'local memo = {}',
        'local function twice(k) if memo[k] then return memo[k] end memo[k] = k * 2 return memo[k] end',
        'local weak = setmetatable({}, { __mode = "k" })',
        'local function box(o) local v = weak[o] if v == nil then v = {} weak[o] = v end return v end',
        'local KNOWN = {}',
        'for _, s in ipairs({ "a", "b" }) do KNOWN[s] = true end',
        'local function known(x) return KNOWN[x] end',
        'local gen = {}',
        'local function put(k) gen[k] = 1 return gen[k] end',
        'local function clear() gen = {} end',
        'return { twice = twice, box = box, known = known, put = put, clear = clear }',
    }, '\n') .. '\n',
}
local function row(v, name) for _, m in ipairs(v.memos) do if m.name == name then return m end end end

E.examples = {
    {
        name = 'a run-time memo whose writes are absence-guarded, unbounded, its key read off the write',
        files = FILES, params = function () return {} end,
        expect = { holds = true, check = function (v)
            local m = row(v, 'memo')
            return m and m.writer == 'function' and m.bound == 'unbounded' and m.guarded and m.key == 'k', vim.inspect(m)
        end },
    },
    {
        name = 'a WEAK memo is bounded by the GC; a table the module chunk fills is a LOAD-time lookup, not a cache',
        files = FILES, params = function () return {} end,
        expect = { holds = true, check = function (v)
            local w, k = row(v, 'weak'), row(v, 'KNOWN')
            return w and w.bound == 'weak' and w.guarded and k and k.writer == 'load', vim.inspect({ w, k })
        end },
    },
    {
        name = 'a table a function rebinds is a RESET cache (a generation / one-shot memo)',
        files = FILES, params = function () return {} end,
        expect = { holds = true, check = function (v)
            local g = row(v, 'gen')
            return g and g.bound == 'reset' and not g.guarded, vim.inspect(g)
        end },
    },
    {
        name = 'a tree with no cache: the claim fails, and says how many vars it read',
        files = { ['n.lua'] = 'local x = 1\nlocal function f() return x end\nreturn f\n' }, params = function () return {} end,
        expect = { holds = false, check = function (v) return #v.memos == 0, vim.inspect(v.counts) end },
    },
}

return E
