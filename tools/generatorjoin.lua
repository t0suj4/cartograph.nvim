-- generatorjoin — DOES A GENERATOR DECLARATION READ WHAT THE HAND-ROLLED READER IT RE-EXPRESSES READS? (CART-1125)
--
--   nvim --headless -u NONE -l tools/generatorjoin.lua erlreg <erlang root>      [--show N]
--   nvim --headless -u NONE -l tools/generatorjoin.lua ruby <corpus|dir>         [--show N]
--   nvim --headless -u NONE -l tools/generatorjoin.lua rails <corpus|dir>        [--show N]
--
-- The acceptance test for re-expressing a reader as a declaration read by cartograph.generators is a ROW JOIN
-- against the original ([[convergence-is-not-confirmation]]: diff ROWS, not totals), keyed by site, both
-- directions, first N differences each way. Both sides read the SAME declaration (erlreg.CARRIERS; ruby's RB_ATTR),
-- so the join tests the READING — site selection, matching, context, projection — not the declared positions.
--   erlreg   rows (file, line, arity, key, mod, fn), and the refusals split by reason: erlreg's "arity not declared"
--            against the engine's `shape`, its "not a value" against `hole`. The handler edge is NOT compared: both
--            would resolve through xlang.handler_by_module, so an equal edge count would witness nothing.
--   ruby     rows (file, line, col of the symbol, emitted name) from ruby_synth_defs against the `ruby.attr`
--            declaration. The owner walk is independent on the generator side, so it IS tested.
--   rails    the same rows from the rails pack's ruby_rails_synth against its `rails.dsl` declaration (the THIRD
--            reader: associations and delegate).
-- Each side prints its own nonzero count first: an empty run is not a pass.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local here = repo .. '/tools/'
local bench = dofile(here .. 'bench.lua')
bench.bootstrap()

local ts = require 'cartograph.providers.treesitter'
local G = require 'cartograph.generators'

local M = {}

local function parse(path, lang)
    local fd = io.open(path, 'rb'); if not fd then return nil end
    local src = fd:read('a'); fd:close()
    local ok, p = pcall(vim.treesitter.get_string_parser, src, lang)
    local tree = ok and p and p:parse()[1]
    return tree and tree:root(), src
end

--- a two-way diff of keyed rows: { both, only_a = {keys}, only_b = {keys} }
function M.diff(a, b)
    local only_a, only_b, both = {}, {}, 0
    for k in pairs(a) do if b[k] then both = both + 1 else only_a[#only_a + 1] = k end end
    for k in pairs(b) do if not a[k] then only_b[#only_b + 1] = k end end
    table.sort(only_a); table.sort(only_b)
    return { both = both, only_a = only_a, only_b = only_b }
end

--- erlreg vs the generator declared from erlreg.CARRIERS, over one erlang tree
function M.erlreg(root)
    local erlreg = require 'cartograph.erlreg'
    local data = ts.extract(root)
    local stats = erlreg.attach(data)
    local a, b = {}, {}
    for _, r in ipairs(stats.rows) do
        a[('%s:%d a%d key=%s mod=%s fn=%s'):format(r.file, r.line, r.arity, tostring(r.key), tostring(r.mod), tostring(r.fn))] = true
    end
    local arity_ref = 0
    for _, why in ipairs(stats.refused) do if why:find('arity %d+ not declared') then arity_ref = arity_ref + 1 end end
    local gens = G.from_erlreg(erlreg.CARRIERS)
    local reasons, selected = {}, 0
    for _, n in ipairs(data.nodes) do
        if n.kind == 'module' and n.file and n.file:match('%.erl$') then
            local troot, src = parse(root .. '/' .. n.file, 'erlang')
            if troot then
                for _, g in ipairs(gens) do
                    local facts, refusals, sel = G.read(g, troot, src, n.file)
                    selected = selected + sel
                    for _, f in ipairs(facts) do
                        local arity = tonumber((f.form or ''):match('%d+'))
                        b[('%s:%d a%d key=%s mod=%s fn=%s'):format(n.file, f.site[1] + 1, arity, f.parts[1], f.parts[2], f.parts[3])] = true
                    end
                    for _, r in ipairs(refusals) do reasons[r.reason] = (reasons[r.reason] or 0) + 1 end
                end
            end
        end
    end
    return {
        a_rows = stats.regs, b_rows = selected - (reasons.shape or 0) - (reasons.hole or 0) - (reasons.context or 0),
        a_tuples = stats.tuples, b_selected = selected,
        refusals = { { 'arity not declared', arity_ref, 'shape', reasons.shape or 0 },
            { 'not a value', stats.notvalue or 0, 'hole', reasons.hole or 0 } },
        diff = M.diff(a, b),
    }
end

--- a def-emitter (`synth(tsroot, src) -> {name, node}`) vs a generator declaration, over every .rb file under root
function M.ruby(root, synth, gen)
    local spec = require 'cartograph.spec.ruby'
    synth = synth or spec.synth_defs
    gen = gen or spec.generators[1]
    local a, b, reasons, selected, files = {}, {}, {}, 0, 0
    for _, rel in ipairs(ts.list_files(root)) do
        if rel:match('%.rb$') then
            local troot, src = parse(root .. '/' .. rel, 'ruby')
            if troot then
                files = files + 1
                for _, d in ipairs(synth(troot, src)) do
                    local l, c = d.node:start()
                    a[('%s:%d:%d %s'):format(rel, l + 1, c, d.name)] = true
                end
                local facts, refusals, sel = G.read(gen, troot, src, rel)
                selected = selected + sel
                for _, f in ipairs(facts) do
                    b[('%s:%d:%d %s'):format(rel, f.at[1] + 1, f.at[2], f.name)] = true
                end
                for _, r in ipairs(refusals) do
                    reasons[r.reason] = reasons[r.reason] or { n = 0, ex = {} }
                    reasons[r.reason].n = reasons[r.reason].n + 1
                    if #reasons[r.reason].ex < 4 then
                        reasons[r.reason].ex[#reasons[r.reason].ex + 1] = ('%s:%d %s'):format(rel, r.site[1] + 1, r.why or '')
                    end
                end
            end
        end
    end
    local na, nb = 0, 0
    for _ in pairs(a) do na = na + 1 end
    for _ in pairs(b) do nb = nb + 1 end
    return { files = files, a_rows = na, b_rows = nb, selected = selected, reasons = reasons, diff = M.diff(a, b) }
end

local function main()
    local a = _G.arg or {}
    local which, target, show = a[1], a[2], 12
    for i = 3, #a do if a[i] == '--show' then show = tonumber(a[i + 1]) or show end end
    if not (which and target) then
        io.write('usage: generatorjoin.lua erlreg|ruby <root|corpus> [--show N]\n'); os.exit(2)
    end
    local root = target
    if vim.fn.isdirectory(root) ~= 1 then
        local c = bench.corpus(target); root = c and c.root or target
    end
    local R
    if which == 'erlreg' then
        R = M.erlreg(root)
        io.write(('erlreg vs generator  %s\n  tuples selected: erlreg %d  generator %d\n  registrations: erlreg %d  generator %d\n')
            :format(root, R.a_tuples, R.b_selected, R.a_rows, R.b_rows))
        for _, x in ipairs(R.refusals) do
            io.write(('  refused "%s": erlreg %d  generator[%s] %d\n'):format(x[1], x[2], x[3], x[4]))
        end
    elseif which == 'ruby' or which == 'rails' then
        local pack = which == 'rails' and ts.packs.rails or nil
        R = M.ruby(root, pack and pack.synth_defs, pack and pack.generators[1])
        io.write(('%s vs %s  %s  (%d .rb files)\n  rows: original %d  generator %d  (sites selected %d)\n')
            :format(pack and 'ruby_rails_synth' or 'ruby_synth_defs', pack and 'rails.dsl' or 'ruby.attr',
                root, R.files, R.a_rows, R.b_rows, R.selected))
        for reason, x in pairs(R.reasons) do
            io.write(('  generator refused [%s] %d  e.g. %s\n'):format(reason, x.n, table.concat(x.ex, ' | ')))
        end
    else
        io.write('unknown join: ' .. which .. '\n'); os.exit(2)
    end
    local D = R.diff
    io.write(('JOIN: %d rows on both sides, %d only in the original, %d only in the generator\n')
        :format(D.both, #D.only_a, #D.only_b))
    for i = 1, math.min(show, #D.only_a) do io.write('  original only:  ', D.only_a[i], '\n') end
    for i = 1, math.min(show, #D.only_b) do io.write('  generator only: ', D.only_b[i], '\n') end
end

if _G.arg and _G.arg[0] and _G.arg[0]:match('generatorjoin%.lua$') then main() end
return M
