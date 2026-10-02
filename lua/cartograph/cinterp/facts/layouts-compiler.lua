-- LAYOUTS: where a FIELD of an aggregate lies, as the COMPILER lays it out — an ORACLE, asked on demand: `lookup(unit,
-- type, path)` compiles ONE probe the first time (the unit's own text, its own flags, `gcc -S`: nothing linked, a
-- unit-local struct laid out too), memoized; the answers are read back from `.size` lines:
--   offsetof(T, path) · sizeof(field) · __builtin_classify_type(field) (1 integer, 5 pointer, 8 real, 12/13 record /
--   union) · signedness ((typeof)-1 > 0) · ARRAY-ness (typeof(f) is not typeof(f + 0) — an array decays) · an array's
--   element, the same three.
-- A question the compiler refuses for this field (a struct has no -1, a scalar no [0]) is dropped and the rest asked
-- again. No struct is listed: the engine asks for what a path reads. -> { lookup = function (unit, T, path) -> { off,
-- to = { k = 'i', w, u } | { k = 'd' } | { k = 'p' } | { k = 's' }, array?, elem? } | nil }
-- ★ ANSWERS ARE KEPT ACROSS RUNS (CART-1303), by CONTENT (cartograph.stampcache): an answer depends on the unit's text,
-- its flags, the compiler, and every header it includes — the probe compile writes that INCLUDE CLOSURE (`-MD`), and a
-- later run reuses an answer only while the unit, its flags, the compiler identity and the CONTENTS of every file in the
-- closure are unchanged. Measured: ~20% of the cpython gate's readings went to these compiles, re-asked every run.
return {
    fact = 'layouts',
    needs = { 'compdb' },
    summary = 'where a field of an aggregate lies, asked of the compiler on demand (offsetof / sizeof / classify)',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local db = got.compdb
        local byname = {}
        for _, u in ipairs(db.units) do
            local name = u.file:sub(1, #db.dir + 1) == db.dir .. '/' and u.file:sub(#db.dir + 2) or u.file
            byname[name] = u
        end
        local memo, raw = {}, {}
        local SC = require 'cartograph.stampcache'
        local gccid
        local function compiler_id()
            if not gccid then
                local r = vim.system({ 'gcc', '-dumpfullversion', '-dumpmachine' }, { text = true }):wait()
                gccid = (vim.fn.exepath('gcc') or 'gcc') .. '\0' .. vim.trim((r and r.stdout) or '')
            end
            return gccid
        end
        local depslog
        local function unit_stamp(u)
            raw[u.file] = raw[u.file] or F.readfile(u.file) or ''
            return SC.key({ u.file, raw[u.file], table.concat(u.flags or {}, '\1'), u.cwd or '', compiler_id() })
        end
        -- the answers log of a unit, while its include closure is known and unchanged | nil
        local scopes = {}
        local function scope_of(u)
            depslog = depslog or SC.log('layouts-deps', SC.key({ 'deps', compiler_id() }))
            local us = unit_stamp(u)
            local deps = depslog.get(us)
            if not deps then return nil end
            local hs = {}
            for _, d in ipairs(deps) do
                local h = SC.file(d)
                if not h then return nil end -- (a header gone: re-derive)
                hs[#hs + 1] = d .. '=' .. h
            end
            local key = SC.key({ us, table.concat(hs, '\1') })
            scopes[key] = scopes[key] or SC.log('layouts', key)
            return scopes[key]
        end
        -- the include closure a probe compile wrote (-MD), the probe file mapped back to the real unit
        local function record_deps(u, depfile, probe)
            if not depslog then depslog = SC.log('layouts-deps', SC.key({ 'deps', compiler_id() })) end
            local us = unit_stamp(u)
            if depslog.get(us) then return end
            local fd = io.open(depfile, 'r')
            if not fd then return end
            local txt = fd:read('a'):gsub('\\\n', ' ')
            fd:close()
            local deps, seen = { u.file }, { [u.file] = true }
            for word in (txt:match(':(.*)$') or ''):gmatch('%S+') do
                local p = word:sub(1, 1) == '/' and word or ((u.cwd or '.') .. '/' .. word)
                if p ~= probe and not seen[p] then seen[p] = true; deps[#deps + 1] = p end
            end
            depslog.put(us, deps)
        end
        local function ask(u, qs)
            raw[u.file] = raw[u.file] or F.readfile(u.file) or ''
            local text = raw[u.file]
            local first = select(2, text:gsub('\n', '\n')) + 3 -- (as sizes-compiler: the third line after text's last newline)
            local live = {}
            for i, q in ipairs(qs) do live[i] = q end
            for _ = 1, 6 do
                local lines, lineof = { text, '' }, {}
                for i, q in ipairs(qs) do
                    if live[i] then lines[#lines + 1] = ('char __cart_q_%d[%s];'):format(i, q); lineof[first + #lines - 3] = i end
                end
                local tmp = vim.fn.tempname()
                vim.fn.mkdir(tmp, 'p')
                local c = tmp .. '/' .. vim.fn.fnamemodify(u.file, ':t')
                local fd = assert(io.open(c, 'w')); fd:write('#include <stddef.h>\n', table.concat(lines, '\n'), '\n'); fd:close()
                local cmd = { 'gcc', '-S', '-w', '-o', '-', '-MD', '-MF', tmp .. '/deps.d' }
                vim.list_extend(cmd, u.flags)
                vim.list_extend(cmd, { '-I' .. vim.fn.fnamemodify(u.file, ':h'), c })
                local r = vim.system(cmd, { text = true, cwd = u.cwd, env = db.env }):wait()
                if r.code == 0 then record_deps(u, tmp .. '/deps.d', c) end
                vim.fn.delete(tmp, 'rf')
                if r.code == 0 then
                    local out = {}
                    for i, n in (r.stdout or ''):gmatch('%.size%s+__cart_q_(%d+),%s*(%d+)') do out[tonumber(i)] = tonumber(n) end
                    for i, n in (r.stdout or ''):gmatch('%.comm%s+__cart_q_(%d+),%s*(%d+)') do out[tonumber(i)] = tonumber(n) end
                    return out
                end
                -- (+1: the prepended #include <stddef.h> is one line more)
                local dropped = false
                for ln in (r.stderr or ''):gmatch(':(%d+):%d+: error') do
                    local i = lineof[tonumber(ln) - 1]
                    if i and live[i] then live[i] = nil; dropped = true end
                end
                if not dropped then return nil end
            end
            return nil
        end
        local function ty(sz, cls, u)
            if cls == 1 then return sz and { k = 'i', w = sz * 8, u = u == 2 } end
            if cls == 8 then return sz == 8 and { k = 'd' } or nil end
            if cls == 5 then return { k = 'p' } end
            if cls == 12 or cls == 13 then return { k = 's' } end
            return nil
        end
        local function lookup(unit, T, path)
            local key = unit .. '\0' .. T .. '\0' .. path
            local m = memo[key]
            if m ~= nil then return m or nil end
            local u = byname[unit]
            if not u then memo[key] = false; return nil end
            local q = T .. '\0' .. path
            local scope = scope_of(u)
            if scope then
                local v, found = scope.get(q)
                if found then memo[key] = v or false; return v or nil end
            end
            local f = ('(((%s *)0)->%s)'):format(T, path)
            local qs = {
                ('offsetof(%s, %s) + 1'):format(T, path), ('sizeof(%s)'):format(f), ('__builtin_classify_type(%s) + 1'):format(f),
                ('((__typeof__(%s))-1 > 0) + 1'):format(f), ('__builtin_types_compatible_p(__typeof__(%s), __typeof__(%s + 0)) + 1'):format(f, f),
                ('sizeof((%s)[0])'):format(f), ('__builtin_classify_type((%s)[0]) + 1'):format(f), ('((__typeof__((%s)[0]))-1 > 0) + 1'):format(f),
            }
            local a = ask(u, qs)
            local function keep(v) local sc = scope or scope_of(u); if sc then sc.put(q, v) end end
            if not (a and a[1] and a[3]) then memo[key] = false; keep(false); return nil end
            local r = { off = a[1] - 1 }
            local cls = a[3] - 1
            if cls == 5 and a[5] == 1 then -- (an ARRAY: its storage, the element's type)
                r.array, r.elem = true, ty(a[6], a[7] and a[7] - 1, a[8])
            else r.to = ty(a[2], cls, a[4]) end
            memo[key] = r
            keep(r)
            return r
        end
        return { lookup = lookup }
    end,
}
