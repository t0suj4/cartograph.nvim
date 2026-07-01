-- Hub / heat classification (pure). Given a function's fan-in (callers) and
-- fan-out (callees) — and whether it looks exported — name its role. Used by the
-- symbols overlay to surface load-bearing APIs, coordinators, leaves, and
-- suspicious no-caller functions.
--
-- Honest about the entry-point trap: a function with no callers is only flagged
-- "unused?" when it's a local; an exported/method one is "api" (a public entry
-- the static graph can't see being called from outside).

local M = {}

M.HUB_IN, M.COORD_OUT = 4, 4

--- @param fanin integer   number of callers
--- @param fanout integer  number of callees
--- @param exported boolean  looks public (method, or a module-table field like M.x)
--- @return { tag:string, hl:string }
function M.role(fanin, fanout, exported)
    if fanin == 0 and fanout == 0 then return { tag = 'isolated', hl = 'Comment' } end
    if fanin == 0 then
        if exported then return { tag = 'api', hl = 'DiagnosticHint' } end
        return { tag = 'unused?', hl = 'DiagnosticWarn' }
    end
    if fanin >= M.HUB_IN and fanin >= 2 * fanout then return { tag = 'hub', hl = 'Title' } end
    if fanout >= M.COORD_OUT and fanout >= 2 * fanin then return { tag = 'coordinator', hl = 'DiagnosticInfo' } end
    if fanout == 0 then return { tag = 'leaf', hl = 'Comment' } end
    return { tag = '', hl = 'Comment' }
end

return M
