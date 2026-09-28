-- provledger — the travelling PROVENANCE LEDGER (CART-1180): one git note per commit (refs/notes/cartograph) naming the
-- journal entries that explain it, the decisions they were applied under, and the open intents at commit time.
--
--   nvim --headless -u NONE -l tools/provledger.lua write [<rev>]     (default HEAD; the post-commit hook runs this)
--   nvim --headless -u NONE -l tools/provledger.lua show  [<rev>]
-- Notes travel only when pushed: `git push origin refs/notes/cartograph`. The ledger only TIGHTENS (reported, a gate);
-- nothing reads it to skip a check or as an accepted decision.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
local P = require 'cartograph.provenance'
local cmd, rev = arg[1] or 'show', arg[2] or 'HEAD'
local repo = vim.fn.getcwd()
local sha = (P.git(repo, { 'rev-parse', rev }) or ''):gsub('%s+$', '')
if sha == '' then io.stderr:write('provledger: no such revision ' .. rev .. '\n'); os.exit(2) end
if cmd == 'write' then
    local row, why = P.write_note(repo, sha)
    if not row then io.stderr:write('provledger: ' .. tostring(why) .. '\n'); os.exit(1) end
    io.write(('ledger %s: %d bytes explained by %d entr(ies), %d by hand, %d open intent(s)\n')
        :format(sha:sub(1, 7), row.explained, #row.entries, row.hand, #row.open_intents))
elseif cmd == 'show' then
    local row = P.read_note(repo, sha)
    if not row then io.write('no ledger note on ', sha:sub(1, 7), '\n'); os.exit(1) end
    io.write(vim.inspect(row), '\n')
else
    io.stderr:write('provledger: unknown command ' .. cmd .. '\n'); os.exit(2)
end
