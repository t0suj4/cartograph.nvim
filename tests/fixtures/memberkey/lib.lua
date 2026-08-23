-- GLOBAL on purpose: a file-local cannot be matched across files by the scope
-- model, so a local here would make the control below silently unlinkable and
-- the test would pass for the wrong reason.
function distinctive_handler(x) return x + 1 end

local exports = {}
-- ★ THE KEY IS NOT A REFERENCE. `exports.distinctive_handler` on the LEFT of an
-- assignment is a member NAME being defined; the bare `distinctive_handler` on
-- the right IS the reference. Before CART-0529 both occurrences were recorded
-- against the same edge, so the count claimed two references where the source
-- has one.
exports.distinctive_handler = distinctive_handler
return exports
