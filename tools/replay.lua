-- replay — MERGE BY REPLAYING INTENTS (cartograph.replay, CART-1191): re-run the invocations another checkout's ledger
-- notes carry, here, in order; each step classifies itself (done / applied / conflict / frontier).
--
--   nvim --headless -u NONE -l tools/replay.lua <into dir> <from repo> <range> [apply=1] [approvals=<dir>]
--   nvim --headless -u NONE -l tools/replay.lua <into dir> --remote <name> <range> [apply=1] [approvals=<dir>]
--   e.g. tools/replay.lua . ../their-checkout main..their-branch            preview, step by step
--        tools/replay.lua . --remote origin HEAD..origin/their-branch    fetch their branch + notes, then replay
-- `--remote`: a teammate PUSHED their branch and their ledger notes (refs/notes/cartograph) to a shared remote; the
-- notes are fetched into a mirror (refs/notes/cartograph-remotes/<name>), never merged into this repo's own.
-- ⚠ A PREVIEW plans every step against this world AS IT IS: a later step that builds on an earlier one reads as a
-- conflict until the earlier one is applied. apply=1 is the merge (journaled, undoable; a conflict stops it, and the
-- steps before it stay applied — forward recovery).
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local into, from, range = arg[1], arg[2], arg[3]
if not (into and from and range) then
    io.stderr:write('usage: replay.lua <into dir> <from repo> <range> [apply=1] [approvals=<dir>]\n'); os.exit(2)
end
local apply, approvals = false, nil
-- the options follow the range: arg 4 on, or arg 5 on in the `--remote <name> <range>` form
for i = from == '--remote' and 5 or 4, #arg do
    local k, v = arg[i]:match('^([%w_]+)=(.*)$')
    if k == 'apply' then apply = v == '1' elseif k == 'approvals' then approvals = v
    else io.stderr:write('replay: unknown argument ' .. arg[i] .. '\n'); os.exit(2) end
end
local R = require 'cartograph.replay'
local store = require 'cartograph.store'
into = (vim.fn.fnamemodify(into, ':p'):gsub('/$', ''))
store.ingest(require('cartograph.providers.treesitter').extract(into))
local items
if from == '--remote' then
    -- the range follows the remote's name: <into> --remote <name> <range>
    local remote
    remote, range = arg[3], arg[4]
    if not (remote and range) then io.stderr:write('usage: replay.lua <into dir> --remote <name> <range>\n'); os.exit(2) end
    local ref, why = R.fetch(into, remote)
    if not ref then io.write('refused: ', tostring(why), '\n'); os.exit(1) end
    items = R.from_notes(into, range, ref)
else
    items = R.from_notes(vim.fn.fnamemodify(from, ':p'), range)
end
local r = R.run(store, items, { apply = apply, approvals = approvals })
for _, s in ipairs(r.steps) do
    io.write(('%-12s %-18s %-28s %s\n'):format(s.outcome, tostring(s.verb), tostring(s.id), s.why and ('— ' .. s.why) or ''))
end
io.write(('%s: %d step(s), %d applied, %d already here%s\n'):format(r.status, #r.steps, r.applied, r.done,
    r.why and (' — stopped at ' .. tostring(r.at) .. ': ' .. r.why) or ''))
os.exit((r.status == 'done' or r.status == 'previewed') and 0 or 1)
