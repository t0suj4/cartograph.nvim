-- ANNOTATION CENSUS ([[CART-0240]]): what is actually IN a corpus's type
-- annotations, and what would a consumer of them get?
--
--   nvim --headless -u NONE -l tools/annotcensus.lua <corpus|path> [--show <bucket>]
--     buckets: bad (the lint's findings) · ret (returns naming a declared class)
--              opq (returns whose type we keep opaque)
--
-- WHY A CENSUS AND NOT A GATE: annotations are the one input whose volume varies by
-- three orders of magnitude between corpora we gate on (wow_addons: 3 lines in 2.27M;
-- nvim-nio: 1851 in 6982), so a feature built against our own tree ships untested by
-- construction. This measures the fuel BEFORE anything is built on it, and it takes a
-- bare PATH as well as a registered corpus name precisely so a candidate corpus can be
-- weighed before it is registered.
--
-- WHAT IT MEASURED, and what each number decided (CART-0240):
--   * 76% of the fuel is @class/@field — TYPE DECLARATIONS, not def annotations. The
--     def-attached rows are @param and @return almost exclusively.
--   * the ATTACH RATE varies 1.7% (nvim-lspconfig: 6600 tags, nearly all config
--     schemas adhering to nothing) to 97.3% (our own tree: we only annotate defs).
--     "How many annotations are there" is the wrong question; "how many reach a def"
--     is the one that predicts what a consumer sees.
--   * `X|nil` is LuaLS's other spelling of `X?` and dominates generated code: reading
--     it as nullability rather than as a union moved 75 of nio's 148 returns from
--     opaque to "names a class this corpus declares" (13 -> 88).
--   * @param-vs-signature disagreement is RARE (8 in ~2350 matched rows across 8
--     roots) and REAL (every one hand-read, lua-ls agrees on all of them) — which is
--     what made it the one annotation check worth shipping as a lint.
local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local annot = require 'cartograph.annot'
local store = require 'cartograph.store'
local lint = require 'cartograph.lint'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'

local target = arg[1]
if not target then
    print('usage: nvim --headless -u NONE -l tools/annotcensus.lua <corpus|path> [--show bad|ret|opq]')
    os.exit(2)
end
local show
for i = 2, #(arg or {}) do if arg[i] == '--show' then show = arg[i + 1] end end

-- a registered corpus name, else a bare path
local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then
    print('not a directory: ' .. root)
    os.exit(2)
end

-- the primitive vocabulary: a type that names no class, and never will
local PRIM = { ['nil'] = true, any = true, string = true, number = true,
    integer = true, boolean = true, table = true, ['function'] = true,
    thread = true, userdata = true, lightuserdata = true, unknown = true,
    self = true, ['true'] = true, ['false'] = true }

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)
store.ingest(data)

local lines_of = {}
local function flines(f)
    if lines_of[f] == nil then
        lines_of[f] = store.content({ file = f }) or false
    end
    return lines_of[f] or nil
end

-- ── 1. the whole-file tag census: what is here, and what must be ignored ──
local declared, aliases = {}, {}
local tagmix, prose, files = {}, {}, 0
for _, n in ipairs(data.nodes) do
    if n.kind == 'module' and n.file then
        local pat = ts.annot_tag(n.file)
        local ls = pat and flines(n.file)
        if ls then
            files = files + 1
            for _, l in ipairs(ls) do
                local tag, body = l:match(pat)
                if tag then
                    if annot.TAGS[tag] then
                        tagmix[tag] = (tagmix[tag] or 0) + 1
                        local r = annot.parse_body(annot.TAGS[tag], body)
                        if r and r.kind == 'class' then declared[r.name] = true end
                        if r and r.kind == 'alias' then aliases[r.name] = true end
                    else
                        prose[tag] = (prose[tag] or 0) + 1
                    end
                end
            end
        end
    end
end

-- ── 2. what ADHERES to a def, and what the rows say about it ──
local rows, withrows, ndefs = 0, 0, 0
local bykind = {}
local rknown, rprim, rother, ropaque = 0, 0, 0, 0
local retex, opqex = {}, {}
for _, n in ipairs(data.nodes) do
    if (n.kind == 'function' or n.kind == 'method') and n.file and n.range then
        local pat = ts.annot_tag(n.file)
        local ls = pat and flines(n.file)
        local adh = pat and ts.attach_pats(n.file) or {}
        if ls and #adh > 0 then
            ndefs = ndefs + 1
            local s = at.sl(n.range)
            local top = txn.attach_above(ls, s, adh)
            if top < s then
                local blk = {}
                for i = top + 1, s do blk[#blk + 1] = ls[i] end
                local rs = annot.read_block(blk, top, pat)
                if #rs > 0 then
                    withrows = withrows + 1
                    rows = rows + #rs
                    for _, r in ipairs(rs) do
                        bykind[r.kind] = (bykind[r.kind] or 0) + 1
                        if r.kind == 'return' then
                            local t = r.type or ''
                            if PRIM[t] then rprim = rprim + 1
                            elseif declared[t] or aliases[t] then
                                rknown = rknown + 1
                                if #retex < 15 then
                                    retex[#retex + 1] = ('%s:%d  %s -> %s')
                                        :format(n.file, r.line + 1, n.name, t)
                                end
                            elseif t:match('^[%w_%.]+$') then rother = rother + 1
                            else
                                ropaque = ropaque + 1
                                if #opqex < 15 then
                                    opqex[#opqex + 1] = ('%s:%d  %s -> %q')
                                        :format(n.file, r.line + 1, n.name, t)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

local function count(t) local k = 0; for _ in pairs(t) do k = k + 1 end; return k end
local tot, ptot = 0, 0
for _, v in pairs(tagmix) do tot = tot + v end
for _, v in pairs(prose) do ptot = ptot + v end

print(('%s — %d annotatable files, %d defs'):format(root:gsub('/$', ''):gsub('^.*/', ''),
    files, ndefs))
print(('  TYPE TAGS %d   prose tags IGNORED %d (%d distinct)'):format(tot, ptot, count(prose)))
local ks = {}
for k in pairs(tagmix) do ks[#ks + 1] = k end
table.sort(ks, function (a, b) return tagmix[a] > tagmix[b] end)
local parts = {}
for _, k in ipairs(ks) do parts[#parts + 1] = ('%s=%d'):format(k, tagmix[k]) end
if #parts > 0 then print('    ' .. table.concat(parts, ' ')) end
print(('  DECLARED types: @class %d  @alias %d'):format(count(declared), count(aliases)))
print(('  ATTACHED to a def: %d rows on %d/%d defs — %.1f%% of type tags reach a def')
    :format(rows, withrows, ndefs, tot > 0 and rows / tot * 100 or 0))
local bs = {}
for k, v in pairs(bykind) do bs[#bs + 1] = ('%s=%d'):format(k, v) end
table.sort(bs)
if #bs > 0 then print('    ' .. table.concat(bs, ' ')) end
print(('  @return type names: a DECLARED class/alias %d · a primitive %d · some other name %d · OPAQUE %d')
    :format(rknown, rprim, rother, ropaque))

-- ── 3. the lint's own verdict, run through the SHIPPED rule ──
local findings = lint.run(store, { only = { ['annotation-mismatch'] = true } })
print(('  annotation-mismatch findings: %d'):format(#findings))
if show == 'bad' then
    for _, f in ipairs(findings) do
        print(('    %s:%d  %s'):format((f.file:gsub('^' .. root .. '/', '')), f.line,
            f.message))
    end
end
if show == 'ret' then for _, e in ipairs(retex) do print('    ' .. e) end end
if show == 'opq' then for _, e in ipairs(opqex) do print('    ' .. e) end end
