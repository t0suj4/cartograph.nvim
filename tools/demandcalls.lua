-- demandcalls — MEASURE what on-demand call materialization costs in fidelity
-- (store.materialize_file_calls), the calls half of index-and-reduce
-- ([[cartograph-merging-strategies]]).
--
-- This is deliberately NOT a pass/fail gate on identity, because identity is not
-- expected: two resolution inputs are GLOBAL EVIDENCE derived from other files'
-- calls, which a demand graph does not have —
--   · the cbarg / dispatch pre-scan (a def passed as a callback ANYWHERE is marked),
--   · the `returns` rounds fixpoint (settles less with fewer calls resident).
-- The other 10 of 12 RESOLVE_PASSES read the def index and the per-language fact
-- tables, and the thin index carries both COMPLETE. So the question is not "is it
-- identical" but "HOW MUCH is identical, and how does the rest differ" — which is
-- exactly what a demand mode has to be able to promise.
--
-- THE ORACLE is a full extract's calls for the same file, compared per call site
-- (keyed by fn + callee + full + line, which a demand extract reproduces because
-- extraction of one file is byte-faithful — only RESOLUTION differs).
--
-- WHAT IS FATAL, and is gated: a demand call that resolves SOMEWHERE ELSE than the
-- full graph's. Under-resolution is a tier loss and gets counted; MIS-resolution
-- means the file cut leaked in, and that fails the run.
--
--   nvim --headless -u NONE -l tools/demandcalls.lua [corpus] [files]
--     corpus  default: the plugin's spec dir (small, multi-language)
--     files   how many files to materialize (default 12)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local callrec = require 'cartograph.callrec'
local hr = vim.uv.hrtime

local name = arg[1] or (repo .. '/lua/cartograph/spec')
local nfiles = tonumber(arg[2] or '12') or 12

-- === the ORACLE: a full extract ===
local full = bench.extract(name)
local root = full.root
local oracle = {}   -- file -> site key -> { to, inferred, refused, ext, dynamic }
local function key(c)
    return ('%s\31%s\31%s\31%s'):format(tostring(callrec.fn(c)),
        tostring(callrec.callee(c)), tostring(callrec.full(c)),
        tostring(callrec.line and callrec.line(c) or c.line))
end
local function disp(c)
    return { to = c.to, inferred = c.inferred and true or nil,
        refused = c.refused and true or nil, ext = c.ext and true or nil,
        dynamic = c.dynamic and true or nil }
end
-- COLLISIONS: the site key is fn+callee+full+line, which is NOT unique — two calls
-- can share all four (`a.b(x) or a.b(y)` on one line). A map keyed by it silently
-- DEDUPES, and a fidelity percentage measured over a deduped set is not a
-- measurement. So collisions are counted and excluded from the comparison rather
-- than folded into it, and the count is reported.
local ocount, ocollide = 0, 0
for _, c in ipairs(full.calls or {}) do
    local f = callrec.file(c)
    if f then
        ocount = ocount + 1
        oracle[f] = oracle[f] or {}
        local k = key(c)
        if oracle[f][k] ~= nil then
            ocollide = ocollide + 1
            oracle[f][k] = 'COLLIDED' -- ambiguous: cannot be compared site-wise
        else
            oracle[f][k] = disp(c)
        end
    end
end

-- pick files that actually HAVE calls, spread across the corpus
local cand = {}
for f, sites in pairs(oracle) do
    local n = 0; for _ in pairs(sites) do n = n + 1 end
    if n > 0 then cand[#cand + 1] = f end
end
table.sort(cand)
local pick = {}
for i = 1, math.min(nfiles, #cand) do
    pick[#pick + 1] = cand[math.floor((i - 0.5) * #cand / math.min(nfiles, #cand)) + 1] or cand[i]
end

-- === the DEMAND graph: thin index + per-file call materialization ===
-- CARRY MODE (arg 3): `carry` seeds the whole-graph self-type map (the poison set)
-- before materializing, which is how a demand graph avoids reading its own missing
-- poison as licence to self-type. `nocarry` clears it, so the run measures the
-- fallback — withdrawing what resolve_self landed rather than over-claiming.
local mode = arg[3] or 'carry'
-- read the map straight off the provider: the full extract above just resolved this
-- root, and taking it here avoids ingesting the ORACLE graph (ingest folds/wraps it,
-- and it must stay exactly as extract produced it to be a fair comparison)
local carried = (ts._selft_root == root) and ts._selft or nil
store.ingest(ts.index_only(root))
if mode == 'carry' then
    store.selft_map(carried)
    if not carried then print('demandcalls: WARNING no map was captured to carry') end
elseif mode == 'nocarry' then
    store._selft_map = nil -- exercise the withdrawal fallback
else
    print('demandcalls: mode must be carry|nocarry'); vim.cmd('cquit 2'); return
end
if not store.is_index_only() then
    print('demandcalls: expected a thin index'); vim.cmd('cquit 1'); return
end
local n_thin_calls = #((store.data or {}).calls or {})

local stats = { sites = 0, same = 0, tier = 0, lost = 0, extra = 0, mis = 0, missing = 0 }
local examples = {}
local function note(kind, s)
    if #examples < 8 then examples[#examples + 1] = ('%-8s %s'):format(kind, s) end
end

local t0 = hr()
for _, f in ipairs(pick) do store.materialize_file_calls(f) end
local t_mat = (hr() - t0) / 1e6

-- index the demand graph's calls by file+site
local got = {}
for _, c in ipairs(store.data.calls or {}) do
    local f = callrec.file(c)
    if f then got[f] = got[f] or {}; got[f][key(c)] = disp(c) end
end

-- BOTH DIRECTIONS. oracle->demand finds lost sites; demand->oracle finds INVENTED
-- ones. Checking only the first would let a demand graph fabricate call sites
-- unnoticed, and "100% of what I looked for" is not the same claim as "100%".
local picked = {}
for _, f in ipairs(pick) do picked[f] = true end
local raw_oracle, raw_demand = 0, 0
for _, c in ipairs(full.calls or {}) do
    if picked[callrec.file(c) or ''] then raw_oracle = raw_oracle + 1 end
end
for _, c in ipairs(store.data.calls or {}) do
    if picked[callrec.file(c) or ''] then raw_demand = raw_demand + 1 end
end
for _, f in ipairs(pick) do
    for k in pairs(got[f] or {}) do
        if (oracle[f] or {})[k] == nil then
            stats.invented = (stats.invented or 0) + 1
            note('INVENT', f .. ' ' .. k:gsub('\31', ' '))
        end
    end
end

for _, f in ipairs(pick) do
    local want, have = oracle[f] or {}, got[f] or {}
    for k, w in pairs(want) do
        if w == 'COLLIDED' then
            stats.collided = (stats.collided or 0) + 1
            goto continue
        end
        stats.sites = stats.sites + 1
        local h = have[k]
        if not h then
            stats.missing = stats.missing + 1
            note('MISSING', f .. ' ' .. k:gsub('\31', ' '))
        elseif w.to == h.to and w.inferred == h.inferred
            and w.refused == h.refused and w.ext == h.ext and w.dynamic == h.dynamic then
            stats.same = stats.same + 1
        elseif w.to and h.to and w.to ~= h.to then
            stats.mis = stats.mis + 1          -- FATAL: points somewhere else
            note('MIS', ('%s %s: full=%s demand=%s'):format(f,
                k:gsub('\31', ' '), tostring(w.to), tostring(h.to)))
        elseif w.to and not h.to then
            stats.lost = stats.lost + 1        -- full resolved, demand did not
            note('LOST', f .. ' ' .. k:gsub('\31', ' '))
        elseif h.to and not w.to then
            stats.extra = stats.extra + 1      -- demand resolved, full did not
            note('EXTRA', f .. ' ' .. k:gsub('\31', ' '))
        else
            -- same target: name WHICH honesty field moved, else the breakdown is
            -- unattributed and the percentage says nothing about the cause
            stats.tier = stats.tier + 1
            local d = {}
            for _, fld in ipairs({ 'inferred', 'refused', 'ext', 'dynamic' }) do
                if w[fld] ~= h[fld] then
                    d[#d + 1] = ('%s %s->%s'):format(fld, tostring(w[fld]), tostring(h[fld]))
                    stats['tier_' .. fld] = (stats['tier_' .. fld] or 0) + 1
                end
            end
            note('TIER', ('%s [%s] %s'):format(f, table.concat(d, ', '),
                (k:gsub('\31', ' '))))
        end
        ::continue::
    end
end

local function pc(n) return stats.sites > 0 and (n / stats.sites) * 100 or 0 end
print(('demandcalls %s'):format(name))
print(('  MODE      %s (self-type map %s)'):format(mode,
    mode == 'carry' and (carried and 'CARRIED from the full graph' or 'MISSING')
        or 'deliberately absent'))
print(('  corpus    %d files with calls · materialized %d · %.0f ms')
    :format(#cand, #pick, t_mat))
print(('  thin index started with %d calls; now %d')
    :format(n_thin_calls, #(store.data.calls or {})))
print(('  index_only marker still set: %s (one file\'s calls is not a call graph)')
    :format(tostring(store.is_index_only())))
print(('  RAW CALLS in the picked files: full %d · demand %d%s')
    :format(raw_oracle, raw_demand,
        raw_oracle == raw_demand and ' (equal — extraction is byte-faithful)'
            or ' <-- COUNTS DIFFER'))
print(('  SITES     %d compared · %d excluded as key COLLISIONS (%d in the whole corpus)')
    :format(stats.sites, stats.collided or 0, ocollide))
print(('    same      %6d  %5.1f%%'):format(stats.same, pc(stats.same)))
print(('    tier      %6d  %5.1f%%   same target, different honesty mark')
    :format(stats.tier, pc(stats.tier)))
for _, fld in ipairs({ 'inferred', 'refused', 'ext', 'dynamic' }) do
    if (stats['tier_' .. fld] or 0) > 0 then
        print(('              %6d          ...of those, `%s` moved')
            :format(stats['tier_' .. fld], fld))
    end
end
print(('    lost      %6d  %5.1f%%   full resolved, demand did not (under-resolution)')
    :format(stats.lost, pc(stats.lost)))
print(('    extra     %6d  %5.1f%%   demand resolved, full did not')
    :format(stats.extra, pc(stats.extra)))
print(('    missing   %6d  %5.1f%%   site absent from the demand graph')
    :format(stats.missing, pc(stats.missing)))
print(('    MIS       %6d  %5.1f%%   points ELSEWHERE (fatal)')
    :format(stats.mis, pc(stats.mis)))
print(('    invented  %6d          site in the demand graph but not the full one (fatal)')
    :format(stats.invented or 0))
for _, s in ipairs(examples) do print('    ' .. s) end

if stats.mis == 0 and stats.missing == 0 and (stats.invented or 0) == 0
    and raw_oracle == raw_demand then
    -- exact COUNT, not a rounded percentage: 8967/8971 prints as "100.0%" and would
    -- bury a real divergence. Anything short of every site is stated as a fraction.
    if stats.same == stats.sites then
        print(('OK — every one of %d sites matches the full extract exactly.')
            :format(stats.sites))
    else
        print(('OK (no mis-resolution, no lost/invented sites) — but NOT substitutable:'
            .. ' %d of %d sites match; %d tier · %d under · %d OVER-resolved.')
            :format(stats.same, stats.sites, stats.tier, stats.lost, stats.extra))
        if stats.extra > 0 then
            print('       OVER-resolution is the direction a partial graph should never')
            print('       manage. KNOWN CARRIER: resolve_self\'s `selft` poison — a call')
            print('       anywhere with an untypeable receiver poisons that method id, so')
            print('       a partial call set carries LESS poison and self-types MORE. The')
            print('       degradation is therefore ANTI-monotone: the less you materialize,')
            print('       the more you over-claim. Bounded to the hedged (~) tier. Fix is')
            print('       to precompute the poison set once, like the file->scope table.')
        end
    end
    -- THE MONOTONICITY RATCHET, and it is RED on purpose. A demand graph may know LESS
    -- than the whole graph; it may never know MORE. `extra` counts exactly the violations
    -- of that, and until now the tool PRINTED them and exited 0 — so the one direction a
    -- partial graph must never take was reported and never gated.
    --
    -- The target is 0, not today's numbers: pinning the measured counts would make the
    -- gap permanent. Measured 2026-07-26, both awaiting a fix:
    --   .        carry     7   one nested 2-char `cb` in fsm.lua; needs the polyglot ROOT
    --                          scope — lua/cartograph alone is 0 over 2836 sites
    --   rust     nocarry   1   resolve_self poison anti-monotonicity, no carried map
    -- Measured at 0 and expected to STAY there: lua-spec, ruby, lua/cartograph (carry).
    -- Neither red case has a fixture-scale reproduction — tests/thinindex_gaps_spec.lua
    -- records what was tried and why this tool is the only thing holding them.
    if stats.extra > 0 then
        print(('MONOTONICITY FAIL — %d site(s) the demand graph resolved and the full'
            .. ' graph declined.'):format(stats.extra))
        print('       Ratchet target is 0; under-resolution is the only honest')
        print('       degradation. See tests/thinindex_gaps_spec.lua.')
        vim.cmd('cquit 1')
    end
    vim.cmd('qall!')
else
    print('FAIL — a demand-resolved call points somewhere the full graph does not, or a')
    print('       site went missing / was invented, or the raw call counts differ. Those')
    print('       are the file cut leaking in, not a tier loss.')
    vim.cmd('cquit 1')
end
