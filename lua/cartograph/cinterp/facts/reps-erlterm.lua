-- REPS of TAGGED WORDS (erts' Eterm), each built by the COMPILER with the tree's own constructors: make_small at
-- several values, NIL, every atom of the generated atom table (`am_<c>`), one atom past it, and a cons of a static
-- cell (make_list). BOXED stands for every boxed kind (tuple, float, bignum, binary, map, fun, …): its word is UNKNOWN
-- (sound — a check on it reads as content). Their TYPES are the guard BIFs' own answer (typenames-guardbifs).
return {
    fact = 'reps',
    needs = { 'layout', 'frame', 'registrations', 'compdb' },
    summary = 'tagged-word representatives from make_small / NIL / am_* / make_list',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        if not got.layout.layout.scalar then return nil, 'the slot is not a scalar word' end
        if got.frame.kind ~= 'array' then return nil, 'the frame is not an argument array' end
        local unit
        for _, u in ipairs(got.compdb.units) do if (F.readfile(u.file) or ''):find(got.frame.argmacro .. '1', 1, true) then unit = u; break end end
        if not unit then return nil, 'no unit uses ' .. got.frame.argmacro .. '1' end
        local src = F.readfile(unit.file) or ''
        if not (src:find('make_small') or F.find(F.files(got, 'h'), 'define%s+make_small')) then return nil, 'no make_small constructor' end
        local atoms = vim.tbl_keys(got.registrations.atoms); table.sort(atoms)
        local inc = {}
        for l in src:gmatch('[^\n]+') do if l:match('^%s*#%s*include%s') then inc[#inc + 1] = l end end
        local L = { '#include <stdio.h>' }
        vim.list_extend(L, inc)
        L[#L + 1] = 'static Eterm cell[2];'
        L[#L + 1] = 'static void row(const char *n, Eterm v) {'
        L[#L + 1] = '  printf("%s %llx\\n", n, (unsigned long long)v); }'
        L[#L + 1] = 'int main(void) {'
        for i, v in ipairs({ 0, 1, -1, 10, 256 }) do L[#L + 1] = ('  row("SMALL#%d", make_small(%d));'):format(i, v) end
        L[#L + 1] = '  row("NIL", NIL);'
        for _, c in ipairs(atoms) do L[#L + 1] = ('  row("ATOM:%s", am_%s);'):format(c, c) end
        L[#L + 1] = ('  row("ATOM", make_atom(%d));'):format(got.registrations.natoms)
        L[#L + 1] = '  cell[0] = make_small(1); cell[1] = NIL; row("CONS", make_list(cell));'
        L[#L + 1] = '  return 0; }'
        local out, why = F.run_c(table.concat(L, '\n') .. '\n', unit)
        if not out then return nil, why end
        local R = { order = {}, tag = {}, kind = 'erlterm', atoms = {} }
        for line in out:gmatch('[^\n]+') do
            local f = vim.split(line, ' ', { plain = true })
            local hex = ('%016s'):format(f[2]):gsub(' ', '0')
            R.order[#R.order + 1] = f[1]
            R.tag[f[1]] = { u64 = hex }
            local c = f[1]:match('^ATOM:(.+)$')
            if c then R.atoms[c] = f[1] end
        end
        R.order[#R.order + 1] = 'BOXED'
        R.tag.BOXED = {}
        return R
    end,
}
