-- CALLCOLS PARITY GATE (per-corpus CLI) — the resident-store faithfulness fence.
--   nvim --headless -u NONE -l tools/callgate.lua <corpus>
--
-- Per-corpus by design (like dfgate): the matrix harness spawns one process per
-- corpus for memory isolation — scale corpora (ghost/libs) peak multi-GB, so a
-- single inline --all would OOM. Fan out via the matrix, not a loop here.
--
-- callcols.view(calls) must be a behaviour-faithful DROP-IN for data.calls: the
-- columns read back byte-equal to the records, and the proxy row-handle round-
-- trips every field (covered → column, else residual). This is the resident
-- analog of the graphdiff-empty cache round-trip — it must be GREEN before brick
-- 3 replaces data.calls with the columnar store. Parity is an INVARIANT (0
-- mismatches), so nothing is pinned; the coverage block is the honest disclosure
-- of what still rides the residual. Exit 1 on any mismatch, 2 if not applicable.
-- The check core lives in tools/callparity.lua (dofile-able, pure over `data`).

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/callgate%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local cp = dofile(here .. '/callparity.lua')

local name = arg and arg[1]
if not name then print('usage: callgate <corpus>'); os.exit(2) end

local ok, corpus = pcall(bench.corpus, name)
if not ok or not corpus then print('unknown corpus: ' .. name); os.exit(2) end

local data = bench.extract(name)
local r = cp.check(data)
print(('callgate %-8s'):format(name))
for _, l in ipairs(cp.report(r)) do print(l) end

if #r.mismatches > 0 then
    print(('FAIL: %d parity mismatch(es) — callcols is NOT a faithful drop-in for data.calls')
        :format(#r.mismatches))
    vim.cmd('cquit 1')
else
    print('OK — callcols.view is a faithful drop-in for data.calls (brick 3 may proceed)')
    vim.cmd('qall!')
end
