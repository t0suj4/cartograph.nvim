-- RESULT by a STATUS FIELD: a function-like macro `NAME(p, r)` of the build's headers that stores `r` into a field of
-- `p` and returns a constant (erts' BIF_ERROR: `(p)->freason = r; return THE_NON_VALUE`). The constant is the result
-- SENTINEL, the field the STATUS; any other macro storing a constant name into that field names one more OUTCOME
-- (ERTS_BIF_PREP_TRAP: `->freason = TRAP`). The values are COMPILED, through a unit that uses the macro.
return {
    fact = 'result',
    needs = { 'compdb' },
    summary = 'the status field, the sentinel and the other outcomes, from an error macro\'s own body',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local macro, field, sentinel, outcomes = nil, nil, nil, {}
        local texts = {}
        for _, p in ipairs(F.files(got, 'h')) do texts[#texts + 1] = (F.readfile(p) or ''):gsub('\\\n', ' ') end
        for _, t in ipairs(texts) do
            for name, a, b, body in t:gmatch('#%s*define%s+([%w_]+)%(%s*([%w_]+)%s*,%s*([%w_]+)%s*%)([^\n]*)') do
                local f = body:match('%(?' .. a .. '%)?%s*%->%s*([%w_]+)%s*=%s*%(?' .. b .. '%)?%s*;')
                local s = body:match('return%s+([%w_]+)%s*;')
                if f and s and not macro then macro, field, sentinel = name, f, s end
            end
        end
        if not macro then return nil, 'no macro NAME(p, r) stores r into a field of p and returns a constant' end
        -- (an OUTCOME code is stored by a macro that returns the sentinel, or by one such a macro invokes: BIF_TRAP1 ->
        -- ERTS_BIF_PREP_TRAP -> `->freason = TRAP`; the emulator's own stores — EXC_CASE_CLAUSE — return nothing)
        local bodies = {}
        for _, t in ipairs(texts) do
            for name, body in t:gmatch('#%s*define%s+([%w_]+)%b()([^\n]*)') do bodies[name] = body end
        end
        local returning = {}
        for name, body in pairs(bodies) do if body:find('return%s+' .. sentinel .. '%f[^%w_]') then returning[name] = true end end
        for name, body in pairs(bodies) do
            local ok_m = returning[name]
            if not ok_m then for r in pairs(returning) do if bodies[r]:find(name .. '%s*%(') then ok_m = true; break end end end
            if ok_m then for c in body:gmatch('%->%s*' .. field .. '%s*=%s*([%u_][%u%d_]*)%s*;') do outcomes[c] = true end end
        end
        -- the values, compiled through a unit that uses the macro
        local unit
        for _, u in ipairs(got.compdb.units) do if (F.readfile(u.file) or ''):find(macro .. '(', 1, true) then unit = u; break end end
        if not unit then return nil, 'no unit uses ' .. macro end
        local inc = {}
        for l in (F.readfile(unit.file) or ''):gmatch('[^\n]+') do if l:match('^%s*#%s*include%s') then inc[#inc + 1] = l end end
        local names = vim.tbl_keys(outcomes); table.sort(names)
        local lines = { '#include <stdio.h>' }
        vim.list_extend(lines, inc)
        lines[#lines + 1] = 'int main(void) {'
        lines[#lines + 1] = ('  printf("%%llx\\n", (unsigned long long)(%s));'):format(sentinel)
        for _, n in ipairs(names) do lines[#lines + 1] = ('  printf("%%llx\\n", (unsigned long long)(%s));'):format(n) end
        lines[#lines + 1] = '  return 0; }'
        local out, why = F.run_c(table.concat(lines, '\n') .. '\n', unit)
        if not out then return nil, why end
        local vals = {}
        for l in out:gmatch('[^\n]+') do vals[#vals + 1] = l end
        local codes = {}
        for i, n in ipairs(names) do codes[n] = vals[i + 1] end
        return { kind = 'status', macro = macro, field = field, sentinel = { name = sentinel, u64 = vals[1] }, codes = codes }
    end,
}
