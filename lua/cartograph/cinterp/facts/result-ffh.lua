-- RESULT: what a C function's return value says — a fast function's fallback returns FFH_RES(n) (`#define
-- FFH_RES(n) ((n)+OFFSET)`), FFH_RETRY no count; read from the build's header defining them
return {
    fact = 'result',
    needs = { 'compdb' },
    summary = 'the result-count convention, from FFH_RES / FFH_RETRY',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local p, h = F.find(F.files(got, 'h'), '#define%s+FFH_RES%(n%)')
        if not p then return nil, 'no header defines FFH_RES(n)' end
        return { offset = tonumber(h:match('#define%s+FFH_RES%(n%)%s*%(%(n%)%+(%d+)%)')), retry = tonumber(h:match('#define%s+FFH_RETRY%s+(%d+)')), header = p }
    end,
}
