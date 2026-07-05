-- handlers kept alive only by a top-level dispatch table: their sole
-- alibi is the registration edge, not a call
local function handle_start() return 1 end
local function handle_stop() return 2 end

local dispatch = {
    start = handle_start,
    stop = handle_stop,
}

return dispatch
