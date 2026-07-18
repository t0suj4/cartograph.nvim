-- harvest_scan — the disagreement harvest AT SCALE ([[cartograph-goal-vm-linker]]).
-- Over a root of projects (each a subdir with a lua-ls `.luals-graph.json` dump —
-- generate with `lua-language-server --graph=<dir>`), extract each with cartograph,
-- diff resolved CALL targets against the dump, and AGGREGATE: the corpus-wide
-- agreement rate (the north-star metric) + a deduped CONFLICT roster (the bug
-- product — each a real disagreement to triage as our bug or lua-ls's).
--
--   nvim --headless -u NONE -l tools/harvest_scan.lua <root> [maxdirs]
--
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local ts = require 'cartograph.providers.treesitter'
local wt = require 'cartograph.wraptriage' -- wrap-idiom conflict triage

local root = arg[1]
local maxdirs = tonumber(arg[2]) or 9999
if not root then print('usage: harvest_scan <root> [maxdirs]'); os.exit(2) end

-- projects with a dump
local dumps = vim.fn.glob(root .. '/*/.luals-graph.json', false, true)
local function key(c) return (c.file or '?') .. '\31' .. tostring(c.line) .. '\31' .. (c.callee or c.full or '?') end
-- the NAME of a node from its `file::name@line` id (name may be dotted; line may be -1)
local function name_of(id) return id and id:match('::(.-)@%-?%d+$') end
-- reassignment-to-call sites of a source file (for the wrap-passthrough triage), cached.
-- cartograph's c.file may be repo-relative or a basename → try dir/file, else glob the basename.
local reassign_cache = {}
local function reassigns_for(dir, file)
    if reassign_cache[file] ~= nil then return reassign_cache[file] end
    local path = dir .. '/' .. file
    if vim.fn.filereadable(path) == 0 then
        local g = vim.fn.glob(dir .. '/**/' .. vim.fn.fnamemodify(file, ':t'), false, true)
        path = g[1]
    end
    local rs = {}
    if path then
        local fd = io.open(path)
        if fd then rs = wt.reassigns(fd:read('a')); fd:close() end
    end
    reassign_cache[file] = rs
    return rs
end

local T = { both = 0, agree = 0, conflict = 0, wrap_pt = 0, nested_pt = 0,
    cg_only = 0, ls_only = 0, projects = 0, failed = 0 }
local roster = {} -- "addon\31member" -> { n, sample = {site, cg, ls} }
local attr_roster = {} -- same, for conflicts ATTRIBUTED to lua-ls (wrap-passthrough / nested-patch)
for i, dumpf in ipairs(dumps) do
    if i > maxdirs then break end
    local dir = vim.fn.fnamemodify(dumpf, ':h')
    local name = vim.fn.fnamemodify(dir, ':t')
    reassign_cache = {} -- per-project: same basename can differ across addons
    local ok, ls = pcall(function ()
        local fd = io.open(dumpf); local j = vim.json.decode(fd:read('a')); fd:close(); return j
    end)
    local okc, cg = pcall(ts.extract, dir)
    if not (ok and okc and ls and cg) then T.failed = T.failed + 1
    else
        T.projects = T.projects + 1
        local lsto = {}
        for _, c in ipairs(ls.calls or {}) do if c.to then lsto[key(c)] = c.to end end
        -- cartograph's NON-top fn/method defs, by id — a lua-ls target here is a runtime
        -- reassignment (a nested monkey-patch) cartograph correctly did not follow.
        local nontop = {}
        for _, n in ipairs(cg.nodes or {}) do
            if (n.kind == 'function' or n.kind == 'method') and not n.top then nontop[n.id] = true end
        end
        local cgto = {}
        for _, c in ipairs(cg.calls or {}) do
            if c.to then
                cgto[key(c)] = true
                local lt = lsto[key(c)]
                if lt then
                    T.both = T.both + 1
                    if lt == c.to then T.agree = T.agree + 1
                    else
                        T.conflict = T.conflict + 1
                        local m = (c.callee or c.full or '?')
                        -- TRIAGE: did lua-ls follow a REASSIGNMENT of the called name that
                        -- cartograph correctly ignored? wrap-passthrough (luals→the factory
                        -- the name is reassigned from) or nested-patch (luals→a nested runtime
                        -- monkey-patch). Either is lua-ls's side, NOT a cartograph-suspect bug.
                        local verdict = wt.classify(c.callee or m, name_of(c.to),
                            name_of(lt), reassigns_for(dir, c.file or ''), nontop[lt])
                        local into = verdict and attr_roster or roster
                        if verdict == 'wrap-passthrough' then T.wrap_pt = T.wrap_pt + 1
                        elseif verdict == 'nested-patch' then T.nested_pt = T.nested_pt + 1 end
                        local rk = name .. '\31' .. m
                        local e = into[rk]
                        if not e then e = { n = 0, name = name, member = m, class = verdict,
                            site = (c.file or '?') .. ':' .. tostring(c.line), cg = c.to, ls = lt }; into[rk] = e end
                        e.n = e.n + 1
                    end
                else T.cg_only = T.cg_only + 1 end
            end
        end
        for k in pairs(lsto) do if not cgto[k] then T.ls_only = T.ls_only + 1 end end
    end
end

print(('harvest_scan %s — %d projects (%d dump-less/failed skipped)')
    :format(vim.fn.fnamemodify(root, ':t'), T.projects, T.failed))
local attributed = T.wrap_pt + T.nested_pt
local unexplained = T.conflict - attributed
print(('calls resolved by BOTH: %d — %d agree, %d CONFLICT  (%.3f%% agreement)')
    :format(T.both, T.agree, T.conflict, 100 * T.agree / math.max(1, T.both)))
print(('conflict triage: %d attributed to lua-ls (%d wrap-passthrough → factory, %d nested-patch')
    :format(attributed, T.wrap_pt, T.nested_pt))
print(('   → a runtime monkey-patch; cartograph kept the load-time binding) · %d unexplained')
    :format(unexplained))
print(('   effective agreement %.3f%% (attributed conflicts counted as cartograph-correct)')
    :format(100 * (T.agree + attributed) / math.max(1, T.both)))
print(('coverage: cartograph-only=%d  lua-ls-only=%d  (reach gaps, not conflicts)')
    :format(T.cg_only, T.ls_only))
local function dump_roster(tbl, title)
    local rk = {}
    for _, e in pairs(tbl) do rk[#rk + 1] = e end
    table.sort(rk, function (a, b) return a.n > b.n end)
    print(('\n%s — %d distinct (addon, member) classes:'):format(title, #rk))
    for _, e in ipairs(rk) do
        print(('  [%s] %s ×%d%s   %s\n      cartograph → %s\n      lua-ls     → %s')
            :format(e.name, e.member, e.n, e.class and (' {' .. e.class .. '}') or '', e.site, e.cg, e.ls))
    end
end
dump_roster(roster, 'UNEXPLAINED CONFLICT roster (triage as our bug or lua-ls\'s)')
dump_roster(attr_roster, 'ATTRIBUTED-TO-LUA-LS roster (followed a reassignment; cartograph correct)')
