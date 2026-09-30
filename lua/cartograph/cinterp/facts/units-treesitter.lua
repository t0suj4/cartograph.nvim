-- UNITS: every function per unit (its parameters with the type a pointer points to), typedefs, enum constants — the
-- tree-sitter C reading of the preprocessed sources (cartograph.cinterp.units)
return {
    fact = 'units',
    needs = { 'sources' },
    summary = 'functions, typedefs and enum constants of every preprocessed unit',
    derive = function (_, got)
        local u = require('cartograph.cinterp').units(got.sources.units)
        if not next(u.defs) then return nil, 'no function definition in any unit' end
        return u
    end,
}
