-- fixture for the statement-level data-flow extraction (df).
-- compute(base, n): a reads `base` (a param -> input); c depends on a; the
-- return depends on c. A clean local def-use chain.
local M = {}

function M.compute(base, n)
    local a = base + 1          -- def a; use base(param)
    local b = n * 2             -- def b; use n(param)
    local c = a + b             -- def c; use a, b
    return c                    -- use c
end

return M
