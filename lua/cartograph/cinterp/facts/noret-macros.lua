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
        if not next(n) then
            -- (a tree with NO noreturn token at all has no raiser — QuickJS returns its errors: an empty answer; a tree
            -- whose tokens declare nothing is a gap, as erts' `#  define` once was)
            for _, p in ipairs(files) do
                local t = F.readfile(p) or ''
                if t:find('noreturn', 1, true) or t:find('_Noreturn', 1, true) then return nil, 'noreturn tokens, and no declaration carries one' end
            end
            return {}
        end
        return n
    end,
}
