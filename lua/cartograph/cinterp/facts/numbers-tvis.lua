-- NUMBERS: the number tag (the one `tvisnumber` holds for) at several VALUES — a check may accept 10 and refuse 1.5 —
-- each a representative of its own that joins back into the tag. ⚠ adds the variants to reps.tag.
return {
    fact = 'numbers',
    needs = { 'reps' },
    summary = 'the number tag at several values (10, 1.5, 0, -1, 3), each its own representative',
    derive = function (_, got)
        local ffi = require 'ffi'
        local R = got.reps
        local numtag
        for name in pairs(R.tag) do if R.matrix.tvisnumber and R.matrix.tvisnumber[name] == 1 then numtag = name end end
        if not numtag then return nil, 'no tag tvisnumber holds for' end
        local out = { numtag = numtag, numvars = {}, numof = {} }
        local fb = ffi.new('double[1]')
        local ub = ffi.cast('uint64_t *', fb)
        for i, v in ipairs({ 10, 1.5, 0, -1, 3 }) do
            fb[0] = v
            local u = ub[0]
            local nm = numtag .. '#' .. i
            R.tag[nm] = { value = R.tag[numtag].value, u64 = ('%08x%08x'):format(tonumber(bit.rshift(u, 32)), tonumber(bit.band(u, 0xffffffff))) }
            out.numvars[#out.numvars + 1] = nm
            out.numof[nm] = numtag
        end
        return out
    end,
}
