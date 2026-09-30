-- REPS from a TAG FAMILY: the slot header's `#define LJ_T<NAME> (~Nu)` tags, each built by the COMPILER with the
-- header's own setters, and every `tvis*(o)` predicate over every one (cartograph.luajs.cpath.reps)
return {
    fact = 'reps',
    needs = { 'layout' },
    summary = 'each tag\'s representative and the predicate matrix, from an LJ_T* family and its tvis* predicates',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local h = F.readfile(got.layout.header) or ''
        if not h:find('#define%s+LJ_T%u+%s+%(~%d+u%)') then return nil, 'no `#define LJ_T<NAME> (~Nu)` tag family in ' .. vim.fn.fnamemodify(got.layout.header, ':t') end
        return require('cartograph.luajs.cpath').reps(got.layout.include, got.layout.cflags, got.layout.header)
    end,
}
