-- NORET: the functions that never return — every declaration carrying a macro whose definition says `noreturn` (to a
-- @langs c
-- fixed point over the macros), read in the files the build reads (the units' and the include directories)
return {
    fact = 'noret',
    needs = { 'compdb' },
    summary = 'the no-return functions, from the noreturn macros of the build\'s own files',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local files = F.files(got, 'h')
        vim.list_extend(files, F.files(got, 'c'))
        local n = require('cartograph.luajs.boundary').noreturn(files)
        if not next(n) then return nil, 'no declaration carries a noreturn macro' end
        return n
    end,
}
