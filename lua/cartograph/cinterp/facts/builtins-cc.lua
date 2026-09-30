-- BUILTINS: the compiler's own builtins a body may call (`__builtin_expect` is its first argument) — the C
-- language's, from cartograph.cjs, not the tree's
return {
    fact = 'builtins',
    summary = 'the compiler builtins\' meanings (cartograph.cjs.BUILTINS)',
    derive = function () return require('cartograph.cjs').BUILTINS end,
}
