-- FRAME as an ARGUMENT ARRAY: the tree's argument macros `#define <P>ARG_1 (<A>[0])` (erts' bif.h: BIF_ARG_1 is
-- BIF__ARGS[0]) — the frame is the parameter <A>, its slots its elements, the ARITY fixed per function (no count)
return {
    fact = 'frame',
    needs = { 'compdb' },
    summary = 'an argument array, from the <P>ARG_1 (<A>[0]) macro family',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        for _, p in ipairs(F.files(got, 'h')) do
            local t = F.readfile(p) or ''
            local macro, arr = t:match('#%s*define%s+([%w_]*ARG_)1%s+%(%s*([%w_]+)%s*%[%s*0%s*%]%s*%)')
            if macro then return { kind = 'array', array = arr, argmacro = macro, header = p } end
        end
        return nil, 'no `#define <P>ARG_1 (<A>[0])` argument macro'
    end,
}
