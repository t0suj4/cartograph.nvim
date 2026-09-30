-- LAYOUTS: where a FIELD of an aggregate lies, as the COMPILER lays it out — an ORACLE, asked on demand: `lookup(unit,
-- type, path)` compiles ONE probe the first time (the unit's own text, its own flags, `gcc -S`: nothing linked, a
-- unit-local struct laid out too), memoized; the answers are read back from `.size` lines:
--   offsetof(T, path) · sizeof(field) · __builtin_classify_type(field) (1 integer, 5 pointer, 8 real, 12/13 record /
--   union) · signedness ((typeof)-1 > 0) · ARRAY-ness (typeof(f) is not typeof(f + 0) — an array decays) · an array's
--   element, the same three.
-- A question the compiler refuses for this field (a struct has no -1, a scalar no [0]) is dropped and the rest asked
-- again. No struct is listed: the engine asks for what a path reads. -> { lookup = function (unit, T, path) -> { off,
-- to = { k = 'i', w, u } | { k = 'd' } | { k = 'p' } | { k = 's' }, array?, elem? } | nil }
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
                local cmd = { 'gcc', '-S', '-w', '-o', '-' }
                vim.list_extend(cmd, u.flags)
                vim.list_extend(cmd, { '-I' .. vim.fn.fnamemodify(u.file, ':h'), c })
                local r = vim.system(cmd, { text = true, cwd = u.cwd, env = db.env }):wait()
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
            local f = ('(((%s *)0)->%s)'):format(T, path)
            local qs = {
                ('offsetof(%s, %s) + 1'):format(T, path), ('sizeof(%s)'):format(f), ('__builtin_classify_type(%s) + 1'):format(f),
                ('((__typeof__(%s))-1 > 0) + 1'):format(f), ('__builtin_types_compatible_p(__typeof__(%s), __typeof__(%s + 0)) + 1'):format(f, f),
                ('sizeof((%s)[0])'):format(f), ('__builtin_classify_type((%s)[0]) + 1'):format(f), ('((__typeof__((%s)[0]))-1 > 0) + 1'):format(f),
            }
            local a = ask(u, qs)
            if not (a and a[1] and a[3]) then memo[key] = false; return nil end
            local r = { off = a[1] - 1 }
            local cls = a[3] - 1
            if cls == 5 and a[5] == 1 then -- (an ARRAY: its storage, the element's type)
                r.array, r.elem = true, ty(a[6], a[7] and a[7] - 1, a[8])
            else r.to = ty(a[2], cls, a[4]) end
            memo[key] = r
            return r
        end
        return { lookup = lookup }
    end,
}
