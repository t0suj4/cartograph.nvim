-- approvals — SIGNED APPROVALS THAT TRAVEL (cartograph.approvals, CART-1183): answer a teammate's decision with your
-- ssh key, or check the tokens a store holds.
--
--   nvim --headless -u NONE -l tools/approvals.lua sign <private key> <principal> <kind> <portable key> <out dir> [why]
--   nvim --headless -u NONE -l tools/approvals.lua list <dir>          each token: principal, kind, key, VERIFIED or why not
--   nvim --headless -u NONE -l tools/approvals.lua roster              where the roster (ssh allowed_signers) lives
-- A stopped run prints each option's `portable_key` (the question as it reads from any checkout of the same origin).
-- A token answers a run (`tools/toolbelt.lua run … approvals=<dir>`, `tactic.run(…, { approvals = dir })`) only when its
-- signature verifies against YOUR roster and config `deciders[kind]` routes that kind, for every file, to its principal.
-- ★ THIS CLI IS THE ONLY DOOR THAT SIGNS: no MCP verb and no tactic path does — an agent that could sign could approve
-- its own plans. It takes the key file you name; it never looks in ~/.ssh on its own.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
local A = require 'cartograph.approvals'
local cmd = arg[1] or 'roster'
if cmd == 'sign' then
    local keyfile, principal, kind, key, out = arg[2], arg[3], arg[4], arg[5], arg[6]
    if not (keyfile and principal and kind and key and out) then
        io.stderr:write('usage: sign <private key> <principal> <kind> <portable key> <out dir> [why]\n'); os.exit(2)
    end
    local tok, why = A.sign({ key = key, kind = kind, principal = principal, why = arg[7] }, vim.fn.expand(keyfile))
    if not tok then io.write('refused: ', tostring(why), '\n'); os.exit(1) end
    io.write('signed ', A.write(out, tok), '\n')
elseif cmd == 'list' then
    local dir = arg[2]
    if not dir then io.stderr:write('usage: list <dir>\n'); os.exit(2) end
    local toks, skipped = A.load(dir)
    for _, t in ipairs(toks) do
        local okv, vwhy = A.verify(t)
        io.write(('%s  %-20s %-14s %s  %s%s\n'):format(A.id(t), tostring(t.payload.principal), tostring(t.payload.kind),
            tostring(t.payload.key):sub(1, 23), okv and 'VERIFIED' or ('NOT VERIFIED: ' .. tostring(vwhy)),
            t.payload.why and ('  — ' .. t.payload.why) or ''))
    end
    io.write(('%d token(s)%s\n'):format(#toks, skipped > 0 and (', %d file(s) skipped (not tokens)'):format(skipped) or ''))
elseif cmd == 'roster' then
    io.write(A.roster_path, vim.fn.filereadable(A.roster_path) == 1 and '' or '  (absent: no signed answer is accepted)', '\n')
else
    io.stderr:write('approvals: unknown command ' .. cmd .. '\n'); os.exit(2)
end
