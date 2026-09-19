-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ This part reaches back for NOTHING: a section boundary that is also a
-- dependency boundary.
return function (M, SHARED)
local _ = SHARED

-- ── the algebra's negatives, classified on the reading axis ──────────────────────────
local ABSENCE_RULES = {
    -- match refusals: the comparison is closed, so a mismatch is a complete reading
    { pat = '^arity',                              absence = 'absent' },
    { pat = '^kind ',                              absence = 'absent' },
    { pat = '^literal ',                           absence = 'absent' },
    { pat = '^name ',                              absence = 'absent' },
    { pat = 'already bound to',                    absence = 'absent' },  -- the store law is part of membership
    { pat = 'hedge variable cannot fill',          absence = 'absent' },
    { pat = 'budget exceeded',                     absence = 'frontier' }, -- the analysis did not finish
    { pat = 'context variables is not implemented', absence = 'unavailable' },
    { pat = 'keyed nodes',                          absence = 'unavailable' },
    { pat = 'is a context hole',                    absence = 'unavailable' }, -- classify: context holes stay unsupported (CLASSIFY.md)
    { pat = '^stale',                               absence = 'frontier' },    -- a read the source has moved past licenses no write (REGISTRY.md)
    { pat = 'a blob column cannot be written',      absence = 'refused' },
    { pat = 'no data: ',                            absence = 'absent' },      -- §13.10 rule 4: no object row to write
    { pat = 'holds a comment and cannot be inlined', absence = 'refused' },    -- render_call: the writer declines the field (RENDER.md)
    { pat = 'crossed the boundary of hedge',       absence = 'absent' },      -- classify: the edit does not fit the family's shape (CLASSIFY.md)
    { pat = 'two hedges meet at',                   absence = 'absent' },
    { pat = '^key [^ ]+ is missing',                absence = 'absent' },
    { pat = 'has no counterpart in the template',   absence = 'absent' },
    { pat = '^alignment: ',                         absence = 'absent' },
    { pat = '^keys out of order',                   absence = 'absent' },
    { pat = 'does not parse',                      absence = 'absent' },
    { pat = 'not a string',                        absence = 'absent' },
    { pat = 'does not entail',                     absence = 'refused' },
    { pat = '^hole [^:]+: ',                       absence = 'refused' },  -- a domain declined; candidates = the domain
    -- migrate's dropped members
    { pat = 'value differs',                       absence = 'absent' },
    { pat = 'values differ',                       absence = 'absent' },
    { pat = 'lacks a value under',                 absence = 'absent' },
    { pat = 'domain refuses',                      absence = 'refused' },
    { pat = 'no value for',                        absence = 'frontier' },
    { pat = 'value without a site',                absence = 'refused' },
    { pat = '^join: ',                             absence = 'refused' },
    -- classify
    { pat = 'repetition/context hole',             absence = 'unavailable' },
    { pat = 'does not reproduce the edit',         absence = 'refused' },
    { pat = 'domain refuses the new value',        absence = 'refused' },
}
--- Classify a negative answer: a match result, an instantiate result, a classify result or
--- a migrate `dropped` record. Returns { absence, licenses, why, cands? }; errors on a
--- negative it cannot place, which is the point: a bare refusal is unrepresentable.
function M.absence_of(neg)
    local why
    if neg.refusal then why = neg.refusal.why
    elseif neg.unfilled or neg.rejected or neg.extra then
        if neg.rejected and #neg.rejected > 0 then why = 'domain refuses ' .. table.concat(neg.rejected, '; ')
        elseif neg.unfilled and #neg.unfilled > 0 then why = 'no value for ' .. table.concat(neg.unfilled, ', ')
        else why = 'value without a site ' .. table.concat(neg.extra or {}, ', ') end
    elseif neg.kind == 'unsupported' or neg.kind == 'straddle' then why = neg.why
    else why = neg.why end
    assert(type(why) == 'string', 'a negative answer with no reason cannot be classified')
    for _, r in ipairs(ABSENCE_RULES) do
        if why:find(r.pat) then
            local out = { absence = r.absence, licenses = M.ABSENCE[r.absence].licenses, why = why }
            if neg.proposal then out.cands = { neg.proposal } end
            return out
        end
    end
    error('undeclared negative: ' .. why)
end
end
