-- SIZES: what every `sizeof(<operand>)` of a unit is, as the COMPILER sizes it — the unit's own text, with its own flags,
-- plus one `char __cart_sz_<i>[sizeof(<operand>)];` per operand its preprocessed text holds, compiled to assembly
-- (`gcc -S`: nothing linked, a unit-local struct sized too) and read back from the `.size` / `.comm` lines. An operand
-- that is no type in file scope (`sizeof(localvar)`) is refused by the compiler: dropped, and the rest recompiled.
-- -> { [unit name] = { [operand text, whitespace collapsed] = bytes } }
local function norm(t)
    -- (whitespace collapsed; outer parentheses stripped while the whole operand is one balanced group — as cinterp does)
    t = vim.trim((t or ''):gsub('%s+', ' '))
    while t:match('^%b()$') do t = vim.trim(t:sub(2, -2)) end
    return t
end

return {
    fact = 'sizes',
    needs = { 'sources', 'compdb' },
    summary = 'every sizeof operand a unit holds, sized by the compiler (gcc -S on the unit itself)',
    norm = norm,
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local db = got.compdb
        local byname = {}
        for _, u in ipairs(db.units) do
            local name = u.file:sub(1, #db.dir + 1) == db.dir .. '/' and u.file:sub(#db.dir + 2) or u.file
            byname[name] = u
        end
        local jobs = {}
        for _, s in ipairs(got.sources.units) do
            local u = byname[s.name]
            local ops, seen = {}, {}
            for arg in s.text:gmatch('%f[%w_]sizeof%s*(%b())') do
                local o = norm(arg)
                if o ~= '' and not seen[o] then seen[o] = true; ops[#ops + 1] = o end
            end
            if u and #ops > 0 then jobs[#jobs + 1] = { name = s.name, u = u, ops = ops, raw = F.readfile(u.file) or '' } end
        end
        local out, total = {}, 0
        local function attempt(j)
            local tmp = vim.fn.tempname()
            vim.fn.mkdir(tmp, 'p')
            local c = tmp .. '/' .. vim.fn.fnamemodify(j.u.file, ':t')
            local lines = { j.raw, '' }
            -- (the line the first declaration lands on: concat({ raw, '', d1, … }, '\\n') puts d1 three lines after raw's
            -- last newline, whether or not raw ends with one)
            local first = select(2, j.raw:gsub('\n', '\n')) + 3
            j.lineof = {}
            for i, o in ipairs(j.ops) do if o then lines[#lines + 1] = ('char __cart_sz_%d[sizeof(%s)];'):format(i, o); j.lineof[first + #lines - 3] = i end end
            local fd = assert(io.open(c, 'w')); fd:write(table.concat(lines, '\n'), '\n'); fd:close()
            local cmd = { 'gcc', '-S', '-w', '-o', '-' }
            vim.list_extend(cmd, j.u.flags)
            vim.list_extend(cmd, { '-I' .. vim.fn.fnamemodify(j.u.file, ':h'), c })
            j.h = vim.system(cmd, { text = true, cwd = j.u.cwd, env = db.env })
            j.tmp = tmp
        end
        local pending = {}
        for _, j in ipairs(jobs) do j.tries = 0; pending[#pending + 1] = j end
        while #pending > 0 do
            local batch = {}
            for i = 1, math.min(16, #pending) do batch[i] = table.remove(pending, 1) end
            for _, j in ipairs(batch) do attempt(j) end
            for _, j in ipairs(batch) do
                local r = j.h:wait()
                vim.fn.delete(j.tmp, 'rf')
                j.tries = j.tries + 1
                if r.code == 0 then
                    local m = {}
                    for i, n in (r.stdout or ''):gmatch('%.size%s+__cart_sz_(%d+),%s*(%d+)') do m[tonumber(i)] = tonumber(n) end
                    for i, n in (r.stdout or ''):gmatch('%.comm%s+__cart_sz_(%d+),%s*(%d+)') do m[tonumber(i)] = tonumber(n) end
                    local t = {}
                    for i, o in ipairs(j.ops) do if o and m[i] then t[o] = m[i]; total = total + 1 end end
                    out[j.name] = t
                elseif j.tries < 4 then
                    -- (drop the operands the compiler refused — by the line their declaration is on — and try again)
                    local dropped = false
                    for ln in (r.stderr or ''):gmatch(':(%d+):%d+: error') do
                        local i = j.lineof[tonumber(ln)]
                        if i and j.ops[i] then j.ops[i] = false; dropped = true end
                    end
                    if dropped then pending[#pending + 1] = j end
                end
            end
        end
        -- (a tree with no sizeof — or none the compiler sizes — has an EMPTY table: nothing to size is an answer)
        return out
    end,
}
