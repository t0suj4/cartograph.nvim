-- LAYOUT: the slot type as the COMPILER lays it out (cartograph.cjs.compiler_layout) — through the header of the
-- build's own files that ends its typedef (`} TValue;`), with the flags of a unit that reads it
return {
    fact = 'layout',
    needs = { 'slot', 'sources', 'compdb' },
    summary = 'the slot type\'s layout, from the compiler, through the header defining it',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local ty = got.slot.type
        local header = F.find(F.files(got, 'h'), '}%s*' .. ty .. '%s*;')
        if not header then return nil, 'no header of the build ends a typedef of ' .. ty end
        local unit
        for _, s in ipairs(got.sources.units) do if s.text:find('}%s*' .. ty .. '%s*;') then unit = s; break end end
        if not unit then return nil, 'no preprocessed unit holds the typedef of ' .. ty end
        local flags = {}
        for _, u in ipairs(got.compdb.units) do
            if u.file:sub(-#unit.name) == unit.name then for _, f in ipairs(u.flags) do if f:match('^%-[DU]') then flags[#flags + 1] = f end end end
        end
        local L, why = require('cartograph.cjs').compiler_layout({ src = unit.text, type = ty, header = vim.fn.fnamemodify(header, ':t'),
            include = vim.fn.fnamemodify(header, ':h'), cflags = flags })
        if not L then return nil, why end
        return { layout = L, header = header, include = vim.fn.fnamemodify(header, ':h'), cflags = flags, unit = unit.name }
    end,
}
