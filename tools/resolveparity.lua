-- resolveparity — EXTRACT vs RELINK on the same graph: do the two resolution drivers
-- agree? ([[cartograph-resolution-pipeline]], the last hand-mirrored pair.)
--
-- WHY THIS EXISTS: the two drivers each carry their own base `resolve` body, kept in
-- agreement by hand. They disagree on a handful of sites, and nothing tracked it —
-- it surfaced only because on-demand call materialization goes through relink and its
-- answers were compared against a full extract's. That is an accident, not a gate.
--
-- THE MEASUREMENT: extract a corpus, snapshot every call's disposition, CLEAR the
-- dispositions, relink, and diff. Clearing matters: relink's base loop only reconsiders
-- calls whose `to` is nil, so relinking without clearing measures nothing at all — a
-- mistake that cost me two wrong conclusions.
--
-- Divergence is NOT symmetric in meaning, so it is broken out:
--   target   the two drivers name a DIFFERENT def — the serious kind
--   tier     same target, different `inferred` (confirmed vs ~)
--   refusal  one resolves where the other refuses, or a different rule
--
-- RATCHET: known counts are pinned below. The tool fails when a corpus divergence
-- GROWS, so a change that widens the gap is caught; shrinking is a win and prints as
-- one (re-pin it). Corpora not listed are measured and reported, never gated.
--
--   nvim --headless -u NONE -l tools/resolveparity.lua [corpus ...]
--     default: the plugin's own spec dir + ruby + rust

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local callrec = require 'cartograph.callrec'

-- known divergence, by corpus name (the ratchet). Measured 2026-07-26 with a
-- FILE-QUALIFIED site key — the numbers I first reported (6 / 7 / 0) came from a key
-- without the file and were inflated by cross-file comparisons. There is ONE real
-- asymmetry, not the three I thought: cbarg marks that the id pass mints AFTER
-- resolution, so extract takes the same-file CONFIRMED tier where relink, whose marks
-- are complete up front, hedges. All 5 are `tier`; no corpus has a `target` divergence.
local FLOOR = {
    ['lua-spec'] = 5,   -- cbarg marks minted post-resolution by the id pass
    ruby = 0,
    rust = 0,
}

local targets = {}
for i = 1, #arg do targets[#targets + 1] = arg[i] end
if #targets == 0 then targets = { 'lua-spec', 'ruby', 'rust' } end

local function root_of(name)
    if name == 'lua-spec' then return repo .. '/lua/cartograph/spec' end
    local okx, c = pcall(bench.corpus, name)
    if okx then return c.root end
    return name -- a literal path
end

-- the site key MUST carry the FILE. Without it, a module-level call (fn = nil) keys on
-- callee+line alone and collides across every file with the same call on the same line —
-- 740 collisions on activesupport, and the "divergences" that survived were comparisons
-- between DIFFERENT FILES' calls. The same collidable-key mistake twice in one session.
local function key(c)
    return ('%s\31%s\31%s\31%s\31%s'):format(tostring(callrec.file(c)),
        tostring(callrec.fn(c)), tostring(callrec.callee(c)),
        tostring(callrec.full(c)), tostring(callrec.line(c)))
end
local function rule(c)
    if not c.refused then return nil end
    return type(c.refused) == 'table' and (c.refused.rule or '?') or tostring(c.refused)
end


local rows = {}
for _, name in ipairs(targets) do
    local data = ts.extract(root_of(name))
    -- snapshot, then CLEAR: relink skips calls that already have a target
    local before, collided = {}, 0
    for _, c in ipairs(data.calls or {}) do
        local k = key(c)
        if before[k] ~= nil then collided = collided + 1; before[k] = 'COLLIDED'
        else before[k] = { to = c.to, inf = c.inferred and true or nil, rule = rule(c) } end
    end
    for _, c in ipairs(data.calls or {}) do
        c.to, c.inferred, c.refused, c.ext, c.prov = nil, nil, nil, nil, nil
    end
    ts.relink(data, {})

    local n, target, tier, refusal, examples = 0, 0, 0, 0, {}
    for _, c in ipairs(data.calls or {}) do
        local w = before[key(c)]
        if type(w) == 'table' then
            local now = { to = c.to, inf = c.inferred and true or nil, rule = rule(c) }
            if w.to ~= now.to or w.inf ~= now.inf or w.rule ~= now.rule then
                n = n + 1
                local kind
                if w.to and now.to and w.to ~= now.to then kind = 'target'; target = target + 1
                elseif (w.to == nil) ~= (now.to == nil) then kind = 'refusal'; refusal = refusal + 1
                elseif w.rule ~= now.rule then kind = 'refusal'; refusal = refusal + 1
                else kind = 'tier'; tier = tier + 1 end
                if #examples < 3 then
                    examples[#examples + 1] = ('    %-7s %s:%s %s  extract[to=%s inf=%s ref=%s] relink[to=%s inf=%s ref=%s]')
                        :format(kind, c.file, tostring(c.line), tostring(c.full or c.callee),
                            tostring(w.to), tostring(w.inf), tostring(w.rule),
                            tostring(now.to), tostring(now.inf), tostring(now.rule))
                end
            end
        end
    end
    rows[#rows + 1] = { name = name, calls = #(data.calls or {}), n = n,
        target = target, tier = tier, refusal = refusal, collided = collided,
        examples = examples }
end

print('resolveparity — extract vs relink, same graph')
local failed = false
for _, r in ipairs(rows) do
    local floor = FLOOR[r.name]
    local verdict
    if floor == nil then verdict = '(not gated)'
    elseif r.n > floor then verdict = ('GREW (was %d) <-- FAIL'):format(floor); failed = true
    elseif r.n < floor then verdict = ('SHRANK (was %d) — re-pin FLOOR'):format(floor)
    else verdict = 'at floor' end
    print(('  %-10s %6d calls · %3d diverge (target %d · tier %d · refusal %d) · %s')
        :format(r.name, r.calls, r.n, r.target, r.tier, r.refusal, verdict))
    if r.collided > 0 then
        print(('             %d site keys COLLIDED and were excluded (not compared)')
            :format(r.collided))
    end
    for _, e in ipairs(r.examples) do print(e) end
    if r.n > (FLOOR[r.name] or math.huge) then failed = true end
end

if failed then
    print('FAIL — the two resolution drivers agree on FEWER sites than before.')
    vim.cmd('cquit 1')
else
    print('OK — no corpus exceeds its known divergence.')
    print('  A target-kind divergence means the drivers name a DIFFERENT def; those')
    print('  matter most. Tier/refusal kinds are honesty-label disagreements.')
    vim.cmd('qall!')
end
