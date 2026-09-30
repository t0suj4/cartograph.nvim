-- VOCABULARY: the runtime's own error wording — ERRDEF(NAME, "text") of the build's header (packmap.vocabulary), what
-- the witness reads a refusal in
return {
    fact = 'vocabulary',
    needs = { 'compdb' },
    summary = 'the error messages, from ERRDEF',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        if not F.find(F.files(got, 'h'), 'ERRDEF%(') then return nil, 'no header carries ERRDEF(…)' end
        return require('cartograph.luajs.packmap').vocabulary(got.compdb.dir)
    end,
}
