-- THE POSITIVE CONTROL: a bare mention in DATA position is a genuine
-- registration and must survive the member-key veto untouched.
-- ★ THE `local function` IS LOAD-BEARING, and not for the registry: the fn-ref
-- pass is gated on the file having functions at all (CART-0501, closed NO-GO),
-- so a purely data-only file is never scanned and this control would silently
-- produce nothing. Removing it makes this test pass for the wrong reason.
local function keepalive() return true end

local registry = { distinctive_handler }
return registry, keepalive
