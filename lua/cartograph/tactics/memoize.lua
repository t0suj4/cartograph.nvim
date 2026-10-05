-- MEMOIZE (write, CART-1444): wrap a Lua function in a MEMO keyed by its arguments — the rewrite memo-advisor prices.
-- One ground edit at the function's header: the original body becomes `<name>_raw`, and the header now opens a
-- wrapper that answers from the memo and calls the raw function on a miss:
--     local f_raw, f_memo = nil, setmetatable({}, { __mode = 'k' }) -- memoize …
--     local function f_pack(...) return { n = select('#', ...), ... } end
--     function M.f(a)                        (the header, unchanged: callers, recursion and the module field see it)
--         if a == nil or a ~= a then return f_raw(a) end        (nil / NaN cannot key a table: not memoized)
--         local r = f_memo[a]
--         if r == nil then r = f_pack(f_raw(a)); f_memo[a] = r end
--         return unpack(r, 1, r.n)                              (every result, nil and multiple values included)
--     end
--     f_raw = function (a)                   (the original body, untouched)
-- Several parameters key a NESTED memo (one level each); a method keys `self` first. EXACT for a PURE function:
-- purity is the caller's to establish (effects.lua), and a result the callers MUTATE is now shared between them —
-- the A/B equivalence after the rewrite is the oracle for both (the optimize loop runs it).
-- ★ RESIDENCE IS THE DECISION (CART-1430): weak = by argument IDENTITY, an entry goes when its key is collected (a
-- string or number key is never collected: weak bounds nothing there); strong = for the process; generation = cleared
-- whenever `generation` (a Lua expression, e.g. `require('cartograph.store').generation`) changes. Without
-- `residence` the edit is gated by the `memo-residence` decision (accepting writes a WEAK memo); memo-advisor's key
-- kinds decide it mechanically in the loop (identity -> weak, scalar -> strong, mixed -> ask).
-- REFUSES BY NAME (unbuilt): a non-Lua file, a vararg function, no parameter to key on, a header this rewrite does not
-- read (`M.f = function (…)`).
local T = require('cartograph.tactic').T

local RESIDENCES = { weak = true, strong = true, generation = true }

local function build(p, store)
    local id = type(p.ref) == 'table' and store.resolve_ref(p.ref) or p.ref
    local n = id and store.node(id)
    if not n then return nil, ('the function to memoize does not resolve (%s)'):format(vim.inspect(p.ref)), 'stale' end
    if not tostring(n.file):match('%.lua$') then return nil, ('memoize writes Lua; %s is not a .lua file'):format(tostring(n.file)), 'unbuilt' end
    if p.residence and not RESIDENCES[p.residence] then return nil, ('residence = weak | strong | generation, not %q'):format(p.residence), 'ill-posed' end
    if p.residence == 'generation' and not p.generation then return nil, 'residence = generation needs generation = <a Lua expression>', 'ill-posed' end
    local text = require('cartograph.txn').read_file(store.data.root, n.file)
    if not text then return nil, ('cannot read %s'):format(n.file), 'stale' end
    local sl = require('cartograph.at').sl(n.range)
    local line = vim.split(text, '\n', { plain = true })[sl + 1] or ''
    local ind, loc, name, params = line:match('^(%s*)(local%s+)function%s+([%w_]+)%s*%(([^)]*)%)')
    if not ind then ind, name, params = line:match('^(%s*)function%s+([%w_.:]+)%s*%(([^)]*)%)'); loc = '' end
    if not ind then return nil, ('%s: the header `%s` is not `function NAME(…)` / `local function NAME(…)`'):format(tostring(n.name), vim.trim(line)), 'unbuilt' end
    local header = line:match('^(%s*' .. vim.pesc(loc) .. 'function%s+' .. vim.pesc(name) .. '%s*%b())')
    local ps = {}
    for x in params:gmatch('[^,%s]+') do ps[#ps + 1] = x end
    if vim.tbl_contains(ps, '...') then return nil, ('%s takes varargs: its key is not a fixed tuple'):format(name), 'unbuilt' end
    local method = name:find(':', 1, true) ~= nil
    local keys = vim.list_extend(method and { 'self' } or {}, ps)
    if #keys == 0 then return nil, ('%s takes no argument to key a memo on'):format(name), 'unbuilt' end
    -- the generated locals, named after the function and never colliding with a name the file already has
    local base = name:match('([%w_]+)$')
    local suffix = ''
    for i = 2, 99 do
        if not (text:find(base .. '_raw' .. suffix, 1, true) or text:find(base .. '_memo' .. suffix, 1, true)) then break end
        suffix = '_' .. i
    end
    local raw, memo, pack = base .. '_raw' .. suffix, base .. '_memo' .. suffix, base .. '_pack' .. suffix
    local residence = p.residence or 'weak'
    local mode = residence == 'weak' and "setmetatable({}, { __mode = 'k' })" or '{}'
    local args = table.concat(keys, ', ')
    -- `key` (CART-1445): memo only on the parameters the RESULT depends on — binding-times proves the others irrelevant;
    -- the raw function still gets every argument
    if p.key and #p.key > 0 then
        for _, k in ipairs(p.key) do
            if not vim.tbl_contains(keys, k) then return nil, ('key = %s: no parameter of %s (it takes: %s)'):format(k, name, args), 'ill-posed' end
        end
        local sub = {}
        for _, k in ipairs(keys) do if vim.tbl_contains(p.key, k) then sub[#sub + 1] = k end end
        keys = sub
    end
    local I = ind .. '    '
    local out = {}
    local function put(s) out[#out + 1] = s end
    put(('%slocal %s, %s%s = nil, %s%s -- memoize (CART-1444): %s, keyed by (%s)'):format(ind, raw, memo,
        residence == 'generation' and (', ' .. memo .. '_gen') or '', mode, residence == 'generation' and ', nil' or '', residence, table.concat(keys, ', ')))
    put(("%slocal function %s(...) return { n = select('#', ...), ... } end"):format(ind, pack))
    put(header)
    local guard = {}
    for _, k in ipairs(keys) do guard[#guard + 1] = ('%s == nil or %s ~= %s'):format(k, k, k) end
    put(('%sif %s then return %s(%s) end'):format(I, table.concat(guard, ' or '), raw, args))
    -- (the generation is read AFTER the nil guard: its expression may index a parameter — `store.generation`)
    if residence == 'generation' then
        put(('%slocal g = (%s)'):format(I, p.generation))
        put(('%sif g ~= %s_gen then %s, %s_gen = {}, g end'):format(I, memo, memo, memo))
    end
    put(('%slocal m = %s'):format(I, memo))
    for i = 1, #keys - 1 do
        put(('%slocal m%d = m[%s]; if m%d == nil then m%d = %s; m[%s] = m%d end; m = m%d'):format(I, i, keys[i], i, i, mode, keys[i], i, i))
    end
    put(('%slocal r = m[%s]'):format(I, keys[#keys]))
    put(('%sif r == nil then r = %s(%s(%s)); m[%s] = r end'):format(I, pack, raw, args, keys[#keys]))
    put(('%sreturn unpack(r, 1, r.n)'):format(I))
    put(ind .. 'end')
    put(('%s%s = function (%s)'):format(ind, raw, args))
    local after = table.concat(out, '\n')
    local decide = not p.residence and {
        kind = 'memo-residence',
        reason = ('where does the memo of %s live? accepting writes a WEAK memo by argument identity (an entry goes with its key; a scalar key is never collected) — or pass residence = strong (the process) | generation (+ generation = <expr>: cleared when it changes)'):format(name),
        evidence = { fn = name, residence = 'weak' } } or nil
    return T.step('edit', { file = n.file, before = header, after = after, decide = decide })
end

local SRC = table.concat({
    'local M = {}',
    'M.runs = 0',
    'function M.size(t) M.runs = M.runs + 1 return #t, nil, t[1] end',
    'function M.pair(a, b) M.runs = M.runs + 1 return a + b end',
    'function M.many(...) return select("#", ...) end',
    'return M', '' }, '\n')
local function ref_of(store, name)
    for _, n in ipairs(store.data.nodes) do if n.name == name then return store.ref_of(n.id) end end
end
local function load_m(root) return dofile(root .. '/m.lua') end

return {
    name = 'memoize',
    kind = 'write',
    tags = { 'code', 'optimize' },
    summary = 'wrap a Lua function in a memo keyed by its arguments (ref = file::name): the body becomes NAME_raw, the header a wrapper answering from the memo — every result kept (nil, multiple values); residence = weak (by identity) | strong | generation (+ generation = <expr>), absent = the memo-residence decision. Purity and unshared results are yours to establish: run ab-equivalence after',
    params = { ref = 'ref', residence = 'string?', generation = 'string?', key = 'list?' },
    build = build,
    examples = {
        {
            name = 'a WEAK memo: the second call on the same table does not run the body, and every result (a nil between) is kept',
            files = { ['m.lua'] = SRC },
            params = function (store) return { ref = ref_of(store, 'M.size'), residence = 'weak' } end,
            expect = { status = 'done', applied = 1, check = function (root)
                local m = load_m(root)
                local t = { 7, 8, 9 }
                local a = { m.size(t) }
                local b = { m.size(t) }
                local n = select('#', m.size(t))
                local src = io.open(root .. '/m.lua'):read('a')
                return m.runs == 1 and a[1] == 3 and a[2] == nil and a[3] == 7 and b[3] == 7 and n == 3
                    and src:find("__mode = 'k'", 1, true) ~= nil, src
            end },
        },
        {
            name = 'two parameters key a NESTED memo; a nil argument is passed through, never stored',
            files = { ['m.lua'] = SRC },
            params = function (store) return { ref = ref_of(store, 'M.pair'), residence = 'strong' } end,
            expect = { status = 'done', applied = 1, check = function (root)
                local m = load_m(root)
                local x = m.pair(1, 2) + m.pair(1, 2) + m.pair(1, 3)
                local okn = pcall(m.pair, nil, 1)
                return x == 10 and m.runs == 3 and not okn, ('runs %d, sum %s'):format(m.runs, tostring(x))
            end },
        },
        {
            name = 'a GENERATION memo is cleared when its generation moves; the generation reads a parameter, after the nil guard',
            files = { ['m.lua'] = SRC:gsub('function M.size%(t%)', 'function M.size(t)', 1) },
            params = function (store) return { ref = ref_of(store, 'M.size'), residence = 'generation', generation = 't.gen' } end,
            expect = { status = 'done', applied = 1, check = function (root)
                local m = load_m(root)
                local t = { 1, 2, gen = 1 }
                m.size(t); m.size(t)
                local after_one = m.runs
                t.gen = 2
                m.size(t)
                local after_two = m.runs
                -- (nil goes to the raw function, which raises on `#nil` — the GENERATION expression never saw it)
                local _, err = pcall(m.size, nil)
                return after_one == 1 and after_two == 2 and tostring(err):find('length of', 1, true) ~= nil,
                    ('runs %d then %d; %s'):format(after_one, after_two, tostring(err))
            end },
        },
        {
            name = 'key = a: a memo on the parameter the result depends on; the other still reaches the raw function',
            files = { ['m.lua'] = SRC:gsub('return a %+ b end', 'return a * 2, b end', 1) },
            params = function (store) return { ref = ref_of(store, 'M.pair'), residence = 'strong', key = 'a' } end,
            expect = { status = 'done', applied = 1, check = function (root)
                local m = load_m(root)
                local x = m.pair(1, 'p')
                local y = m.pair(1, 'q')
                local _, b2 = m.pair(1, nil)
                local src = io.open(root .. '/m.lua'):read('a')
                -- (keyed by a ONLY: the second call is a hit — and it answers the FIRST call's b, which is why the key must
                -- come from a proof like binding-times', never a guess)
                return x == 2 and y == 2 and m.runs == 1 and b2 == 'p' and src:find('keyed by (a)', 1, true) ~= nil, ('runs %d; %s'):format(m.runs, src)
            end },
        },
        {
            name = 'no residence: the run STOPS on the memo-residence decision and writes nothing',
            files = { ['m.lua'] = SRC },
            params = function (store) return { ref = ref_of(store, 'M.size') } end,
            expect = { status = 'stopped', applied = 0, check = function (root)
                return not io.open(root .. '/m.lua'):read('a'):find('_raw', 1, true), 'written without a decision'
            end },
        },
        {
            name = 'a vararg function has no fixed key: refused by name as UNBUILT, nothing written',
            files = { ['m.lua'] = SRC },
            params = function (store) return { ref = ref_of(store, 'M.many'), residence = 'strong' } end,
            expect = { status = 'failed', applied = 0, check = function (root)
                return not io.open(root .. '/m.lua'):read('a'):find('_raw', 1, true), 'written'
            end },
        },
    },
}
