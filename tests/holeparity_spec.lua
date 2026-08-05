-- HOLE-SET PARITY (CART-0284). The census and the emitter must not disagree about what a hole is,
-- and they did — for four hole kinds over two days, past the very module extracted to prevent it.
--
-- `holes.of` was pulled out of tools/holecensus so both surfaces would share one definition, and
-- then `reach`, `load`, `env` and `inspect` were added ONLY to characterize.plan. The census kept
-- counting the old four and its headline silently stopped describing what an emittable function
-- needs: 18.0% against the emitter's 3.7% on the same corpus. ONE SHARED FUNCTION IS NOT PARITY IF
-- NEW WORK GOES AROUND IT — so the census now CONSUMES characterize.plan, and these pin the two
-- properties that made the divergence possible in the first place.

local ch = require 'cartograph.characterize'
local holes = require 'cartograph.holes'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

-- one fixture reaching every kind: an annotated param (a TIER with no VALUE), a same-file const,
-- an io channel, a file-local function, and a returned value
local SRC = table.concat({
    'local M = {}',
    'local LIMIT = 3',
    -- `---@param`, NOT `--- @param`: the tag pattern is `^%s*%-%-%-@` and a space after the
    -- dashes matches nothing. My first fixture had the space and the tier came back nil, which
    -- looked like the code losing the annotation.
    '---@param n number',
    'function M.clamp(n) if n > LIMIT then return LIMIT end return n end',
    'function M.save(p) local f = io.open(p, "w") if f then f:close() end return p end',
    'local function hidden(x) return x end',
    -- INSIDE a table constructor, so it does not own its lines: the shape reconstruction
    -- refuses (CART-0289), which is what keeps a genuinely-blocking REACH hole in this
    -- fixture now that a plain file-level local is reachable.
    'local WRAPPED = setmetatable({}, { __tostring = function () return "w" end })',
    'return M',
}, '\n') .. '\n'

local root
local function proj()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    local d = ts.extract(root); d.root = d.root or root
    store.ingest(d)
end
local function cleanup() if root then vim.fn.delete(root, 'rf'); root = nil end end
local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end
local function fn(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and n.kind == 'function' then return n end
    end
end

test('parity: every kind holes.of produces, the PLAN produces too', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local base, full = {}, {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' then
            local lines = store.content(n)
            local ctx = holes.ctx_for(store, n, lines,
                ts.annot_tag and ts.annot_tag(n.file), ts.attach_pats and ts.attach_pats(n.file))
            for _, h in ipairs(holes.of(store, n, ctx) or {}) do base[h.kind] = true end
            local plan = select(1, ch.plan(store, n.id))
            for _, h in ipairs(plan and plan.holes or {}) do full[h.kind] = true end
        end
    end
    -- the plan may know MORE (it sees reachability, the module load, the environment); it must
    -- never know LESS, or a census reading it would under-report
    for k in pairs(base) do
        ok(full[k], ('the plan lost the hole kind %q that holes.of produces'):format(k))
    end
    -- and it DOES know more — pinned, so removing an emitter-only kind fails here rather than
    -- silently shrinking what the census measures
    ok(full.reach, 'the plan adds `reach` (a file-local function no spec can call)')
    ok(full.env, 'and `env` (a channel the environment must supply)')
    cleanup()
end)

test('parity: A TIER IS NOT A VALUE — emittable and runnable are different counts', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- THE SECOND CONFLATION, and it is independent of the first. holes.blocking() returns false
    -- whenever a TIER exists, so an `@param number` makes an input hole non-blocking — correct for
    -- "does anything at all speak to this hole" and wrong for "can we call it". While one word
    -- carried both questions the gap was invisible.
    local plan = assert(ch.plan(store, fn('M.clamp').id))
    local input
    for _, h in ipairs(plan.holes) do if h.id == 'input:n' then input = h end end
    ok(input, 'the annotated param is a hole')
    eq('claim', input.tier, 'with a TIER, from the @param')
    eq(nil, input.value, 'and NO value — a type is not a value')
    eq(false, holes.blocking(input), 'so it does not BLOCK...')
    -- ...and yet the function is not runnable, which is the distinction the census now prints as
    -- two numbers instead of one word
    local novalue = 0
    for _, h in ipairs(plan.holes) do
        if h.kind ~= 'oracle' and h.kind ~= 'effects' and not (h.value or h.satisfied_by) then
            novalue = novalue + 1
        end
    end
    ok(novalue > 0, 'it cannot be RUN: ' .. tostring(novalue) .. ' hole(s) carry no value')
    cleanup()
end)

test('parity: an unreachable function is not emittable, and that is the point', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- The census's OWN fixture was file-local until this ticket, so while it computed its own hole
    -- set it had never measured a function a spec could actually CALL — a large part of why its
    -- headline read so much higher than the emitter's.
    --
    -- `__tostring` is the subject now rather than `hidden`, because a plain file-level local IS
    -- reachable since CART-0289 (recompiled from its own declaration). This one sits inside
    -- `local WRAPPED = setmetatable({}, { … })`, so it owns none of its lines and no mechanism
    -- here can take it — the blocking case the parity check needs.
    local plan = assert(ch.plan(store, fn('__tostring').id))
    local reach
    for _, h in ipairs(plan.holes) do if h.kind == 'reach' then reach = h end end
    ok(reach, 'an unreachable function carries a REACH hole')
    eq(true, holes.blocking(reach), 'which BLOCKS: no spec can call it')

    -- AND ITS OPPOSITE, so this test pins the DISTINCTION rather than just the wall: the
    -- file-level local beside it is reachable, tiered, and does not block.
    local ok2 = assert(ch.plan(store, fn('hidden').id))
    local r2
    for _, h in ipairs(ok2.holes) do if h.kind == 'reach' then r2 = h end end
    eq('derived', r2 and r2.tier, 'a file-level local is DERIVED-reachable')
    eq(false, holes.blocking(r2), 'and does not block')
    cleanup()
end)
