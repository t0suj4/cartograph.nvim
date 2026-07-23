-- eagergate — the BAND-LOCAL EAGER-RESOLUTION probe (federation, [[cartograph-band-
-- federation]]). f2gate asks "can a band REPRODUCE a resolution"; this asks "can a band
-- COMMIT a resolution EAGERLY (at band-build, before seeing other bands) that SURVIVES the
-- merge unchanged" — the fraction M.relink's global re-resolution could SKIP.
--
-- For every whole-graph resolution (c.to = ground truth), resolve using the SOURCE BAND's
-- index ALONE (bandresolve.in_band_fit — no cross-band, no global tail-witness) and classify:
--   EAGER-STABLE — in-band EXACT match == c.to AND the key is GLOBALLY UNIQUE (no def under
--     that key in any other band) → monotone under merge, safe to commit at band-build. The
--     merge-skippable fraction.
--   TAIL-DEFER   — band-local matches c.to only via TAIL → tail uniqueness is GLOBAL, not
--     eager-safe (another band's same tail would force a global refusal). Defer to linkage.
--   CONTESTED    — in-band exact == c.to BUT the key ALSO exists in another band → the global
--     outcome depends on scope rules; not committable band-local without the witness. Defer.
--   EAGER-WRONG  — band-local exact commits a DIFFERENT id than c.to (a same-key decoy) → the
--     HAZARD: proves naive band-local-exact is unsound; the globally-unique gate excludes it.
--   DEFER-MISS   — band-local can't resolve (absent/ambiguous) → the linkage pass. Correct.
--
--   nvim --headless -u NONE -l tools/eagergate.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ports = require 'cartograph.ports'
local bandlink = require 'cartograph.bandlink'
local bandresolve = require 'cartograph.bandresolve'
local ts = require 'cartograph.providers.treesitter'

local name = arg[1]
if not name then print('usage: eagergate <corpus>'); os.exit(2) end
local data = bench.extract(name)
local band_of = ports.default_band_of(3)
local idx = bandlink.indexes(data, band_of, ts.build_symtab)

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

-- is `key` satisfiable (a lang-fit exact def) in MORE THAN ONE band? (cross-band competitor)
local function contested(key, clang)
    local seen = 0
    for _, ix in pairs(idx) do
        local ents = ix.exact[key]
        if ents then
            for _, e in ipairs(ents) do
                if (e.kind == 'function' or e.kind == 'method') and ts.lang_of(e.file) == clang then
                    seen = seen + 1
                    if seen > 1 then return true end
                    break
                end
            end
        end
    end
    return false
end

local total, stable, taildefer, contest, defermiss = 0, 0, 0, 0, 0
local wrong_exact, wrong_tail = 0, 0 -- exact = the real eager hazard; tail = never committed
local wrong_ex = {}
for _, c in ipairs(data.calls or {}) do
    if c.to and c.file then
        local t = node_index[c.to]
        if t and t.file and not t.external then
            total = total + 1
            local key, clang, sb = c.full or c.callee, ts.lang_of(c.file), band_of(c.file)
            local fit, why = bandresolve.in_band_fit(key, idx[sb], clang, ts.lang_of)
            if fit and fit.id == c.to then
                if why == 'exact' then
                    if contested(key, clang) then contest = contest + 1
                    else stable = stable + 1 end
                else taildefer = taildefer + 1 end -- tail match: not eager-safe
            elseif fit and fit.id ~= c.to then
                -- band-local disagrees with whole-graph. via TAIL: irrelevant (eager never
                -- commits tail — the global-witness's job). via EXACT: the REAL eager hazard.
                if why == 'exact' then
                    wrong_exact = wrong_exact + 1
                    if #wrong_ex < 8 then wrong_ex[#wrong_ex + 1] =
                        ('%s (EXACT): band→%s vs whole→%s'):format(tostring(key), fit.id, c.to) end
                else wrong_tail = wrong_tail + 1 end
            else
                defermiss = defermiss + 1
            end
        end
    end
end

local function pc(x) return total > 0 and 100 * x / total or 0 end
print(('eagergate %s — %d resolved calls'):format(name, total))
print(('  EAGER-STABLE (in-band exact, globally-unique key — MERGE-SKIPPABLE): %d (%.1f%%)')
    :format(stable, pc(stable)))
print(('  deferred to linkage: tail %d (%.1f%%) · contested %d (%.1f%%) · absent/ambig %d (%.1f%%)')
    :format(taildefer, pc(taildefer), contest, pc(contest), defermiss, pc(defermiss)))
print(('  EAGER HAZARD: exact-wrong %d (%.2f%%)  <- the real risk, MUST be ~0 for the eager-stable class')
    :format(wrong_exact, pc(wrong_exact)))
print(('  (tail-wrong %d — irrelevant: tail is never eagerly committed, it is the global witness\'s job)')
    :format(wrong_tail))
for _, e in ipairs(wrong_ex) do print('  HAZARD-ex ' .. e) end
vim.cmd('qall!')
