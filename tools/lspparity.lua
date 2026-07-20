-- lspparity — the dumpcompare ORACLE INVERSION, at the SERVING boundary. Where
-- dumpcompare diffs two extraction graphs, this drives cartograph's real LSP
-- handler (position -> call_at -> definition -> Location) at every call site and
-- measures TWO things ([[cartograph-lsp-surface]] dogfood):
--
--   SERVING CONSISTENCY — does the server faithfully serve the graph it holds?
--     definition(at the call's position) must land on the SAME node the call
--     resolved to. <100% = a position-math / call_at bug (the value over a bare
--     graph diff: it exercises the transport-facing path, not just c.to).
--   PARITY vs lua-ls — on sites BOTH engines resolve, do the targets AGREE?
--     the acceptance metric; a conflict is a real bug on ONE side (the charter
--     bar). Absence on one side = a coverage gap, not a conflict.
--
--   nvim --headless -u NONE -l tools/lspparity.lua <addon-dir> [--show] [--dump=<path>]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local lsp = require 'cartograph.lsp'
local atr = require 'cartograph.at'

local addon = arg[1]
local show, dumparg = false, nil
for i = 2, #arg do
    if arg[i] == '--show' then show = true
    elseif arg[i]:match('^%-%-dump=') then dumparg = arg[i]:gsub('^%-%-dump=', '') end
end
if not addon then print('usage: lspparity <addon-dir> [--show] [--dump=<path>]'); os.exit(2) end

local data = ts.extract(addon)
data.root = data.root or addon
store.ingest(data)

-- ── SERVING CONSISTENCY: definition at each call's own position == its c.to ──
local function pos_of(c) return { line = atr.sl(c.at), character = atr.sc(c.at) } end
local function uri_of(file) return vim.uri_from_fname(store.abs(file)) end

local served, consistent, mis = 0, 0, {}
for _, c in ipairs(data.calls or {}) do
    if c.to and c.at then
        local n = store.node(c.to)
        if n and n.file and not n.external and n.range then -- navigable target
            served = served + 1
            local res = lsp.handle(store, 'textDocument/definition', {
                textDocument = { uri = uri_of(c.file) }, position = pos_of(c),
            })
            local want_uri, want_line = uri_of(n.file), atr.sl(n.range)
            local hit = false
            for _, loc in ipairs(res or {}) do
                if loc.uri == want_uri and loc.range.start.line == want_line then hit = true break end
            end
            if hit then consistent = consistent + 1
            elseif #mis < 8 then
                mis[#mis + 1] = ('%s:%d %s'):format(c.file or '?', (c.line or 0) + 1, c.callee or '?')
            end
        end
    end
end

-- ── PARITY vs lua-ls (the dump), on the resolved overlap ──────────────────
local function key(c) return (c.file or '?') .. '\31' .. tostring(c.line) .. '\31' .. (c.callee or c.full or '?') end
local dumpf = dumparg or (addon .. '/.luals-graph.json')
local both, agree, conflict, cg_only, ls_only = 0, 0, 0, 0, 0
local conflicts = {}
local fd = io.open(dumpf)
if fd then
    local ls = vim.json.decode(fd:read('a')); fd:close()
    local lsto = {}
    for _, c in ipairs(ls.calls or {}) do if c.to then lsto[key(c)] = c.to end end
    local cgto = {}
    for _, c in ipairs(data.calls or {}) do
        if c.to then
            cgto[key(c)] = true
            local lt = lsto[key(c)]
            if lt then
                both = both + 1
                if lt == c.to then agree = agree + 1
                else
                    conflict = conflict + 1
                    if #conflicts < 12 then
                        conflicts[#conflicts + 1] = { site = key(c):gsub('\31', ':'), cg = c.to, ls = lt }
                    end
                end
            else cg_only = cg_only + 1 end
        end
    end
    for k in pairs(lsto) do if not cgto[k] then ls_only = ls_only + 1 end end
end

-- ── report ────────────────────────────────────────────────────────────────
local function pct(a, b) return b == 0 and '—' or ('%.1f%%'):format(a * 100 / b) end
print(('lspparity %s'):format(addon))
print(('  SERVING CONSISTENCY: %d/%d served definitions land on the graph target (%s)')
    :format(consistent, served, pct(consistent, served)))
if #mis > 0 then
    print('    inconsistent (position-math suspects):')
    for _, m in ipairs(mis) do print('      ' .. m) end
end
if fd then
    print(('  PARITY vs lua-ls: both=%d agree=%d (%s) conflict=%d')
        :format(both, agree, pct(agree, both), conflict))
    print(('    coverage: cartograph-only=%d  lua-ls-only=%d  (reach gaps, not conflicts)')
        :format(cg_only, ls_only))
    if show and #conflicts > 0 then
        print('  CONFLICTS (a real bug on ONE side):')
        for _, c in ipairs(conflicts) do
            print(('    %s\n      cartograph -> %s\n      lua-ls     -> %s'):format(c.site, c.cg, c.ls))
        end
    end
else
    print('  PARITY: no lua-ls dump (' .. dumpf .. ') — serving consistency only')
end
