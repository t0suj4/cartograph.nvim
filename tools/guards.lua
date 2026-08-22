-- Development guards, self-applied: the CI-shaped dogfood run.
--   nvim --headless -u NONE -l tools/guards.lua [<root>]
-- Extracts the repo, declares cartograph's OWN representation seams, and
-- runs the guard lints (seam-guard / truncation / require-cycle).
-- Exit 1 on any warn-severity finding.

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local root = (arg and arg[1]) or repo
local config = require 'cartograph.config'
-- cartograph's representation seams: the fold contracts, as lint config
config.seams = {
    { name = 'at', -- range coords fold behind atr.sl/sc/el/ec
        patterns = { '%.start%.line', '%.start%.char',
            "%['end'%]%.line", "%['end'%]%.char" },
        -- AN OWNER IS A FILE THAT PRODUCES THE REPRESENTATION, and there are two
        -- kinds here, both earned rather than waived (CART-0502):
        --   THE FOLDERS -- callcols/segment read `r.start.line` in order to WRITE
        --   the sl/sc/el/ec columns the accessors then read. Routing them through
        --   atr would be circular: they are the producer of the folded form, so
        --   the raw read IS their job (at.lua is in this list for that reason).
        --   THE OTHER REPRESENTATION -- lsppos.lua owns the LSP WIRE range, whose
        --   shape is identical and whose `.line` is spelled the same, so a pattern
        --   scan cannot tell it from ours. See lsppos.lua's header: the rejected
        --   alternative was exempting whole FILES that read both representations
        --   three lines apart.
        owners = { '^lua/cartograph/providers/', '^lua/cartograph/at%.lua$',
            '^lua/cartograph/validate%.lua$',
            '^lua/cartograph/callcols%.lua$', '^lua/cartograph/segment%.lua$',
            '^lua/cartograph/lsppos%.lua$', '^tests/', '^tools/' } },
    { name = 'df', -- statement dataflow folds behind dfa.*
        patterns = { '%.df%.stmts', '%.df%.inputs' },
        -- store.lua dropped out at step 6: ingest no longer rebuilds df (it is
        -- flow.coarse, derived at extract) — it only folds, touching no df.stmts.
        owners = { '^lua/cartograph/providers/', '^lua/cartograph/df%.lua$',
            '^tests/', '^tools/' } },
    { name = 'argv', -- argument shapes fold behind argv.n/at/str
        patterns = { '%.argv%[', '%.args%[' },
        -- callview.lua is the REPRESENTATION-NEUTRAL call accessor: its record arm
        -- is `calls[i].argv[j][f]` by definition, which is what makes its columnar
        -- arm swappable. Owner for the same reason argv.lua is.
        owners = { '^lua/cartograph/providers/', '^lua/cartograph/argv%.lua$',
            '^lua/cartograph/callview%.lua$', '^tests/', '^tools/' } },
}

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
-- legacy_df: build the INDEPENDENT dfreg df beside flow (df-strangler step 6)
-- so the parity census below is a real coarse(flow)==df check, not a circular
-- echo of the now-flow-derived production df. The guard lints (seam-guard/
-- truncation/require-cycle) don't read df, so the choice is inert for them.
store.ingest(ts.extract(root, { legacy_df = true }))
local findings = require('cartograph.lint').run(store,
    { only = { ['seam-guard'] = true, truncation = true, ['require-cycle'] = true } })
local warns = 0
for _, f in ipairs(findings) do
    print(('%s:%d [%s/%s] %s'):format(f.file, f.line, f.rule, f.severity, f.message))
    if f.severity == 'warn' then warns = warns + 1 end
end
print(('guards: %d findings (%d warn)'):format(#findings, warns))

-- df/flow PARITY on the SELF repo: coarse(flow)==df + flow CFG invariants, the
-- check the structure snapshot can't do (it drops df). Reuses the extraction
-- above — no second pass. Skipped for a custom root (not a calibrated corpus).
local dffail = false
if root == repo then
    local dfp = dofile(repo .. '/tools/dfparity.lua')
    local r = dfp.check(store.data)
    -- flow is now sourced from the STORED graph (df-strangler step 4), so this
    -- census validates the ACTUAL extracted+folded flow's coarse projection == df.
    print(('df/flow parity (self): fns=%d stmts=%d%s flow-invariant-errors=%d · %s')
        :format(r.nfn, r.nstmt, (r.nskip or 0) > 0 and (' unpaired=' .. r.nskip) or '',
            r.ferr, dfp.census(r.cats)))
    -- HARD-GATE only the churn-INSENSITIVE signal: flow's CFG
    -- (successors/liveness/reaching) must never THROW on valid code, no matter
    -- how the repo evolves. The census itself CHURNS with cartograph's own code
    -- (every added closure ticks df-over-collects), like the self structure
    -- snapshot — so it's REPORTED here but pinned+gated only in the push-time
    -- CLI (`dfgate self`, recalibrated on commit); gating it in this dev-loop
    -- run would cry wolf. Asymmetry regressions are caught on the STABLE
    -- external corpora (`dfgate cpp|rust|…`), which don't churn.
    if r.ferr > 0 then
        print(('  FAIL: %d flow-invariant errors (successors/liveness/reaching threw)'):format(r.ferr))
        dffail = true
    end
end

if warns > 0 or dffail then os.exit(1) end
