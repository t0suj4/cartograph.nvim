-- portdeps — WHO SUPPLIES WHAT THIS MOD EDITS, and have they ported yet (CART-0656).
--
--   nvim --headless -u NONE -l tools/portdeps.lua <package-name-or-root> [options]
--     --dir <mods dir>   where the other packages live (default: the ecosystem's own
--                        user root, e.g. the Factorio mods folder)
--     --eco <name>       ecosystem spec (default: lua-factorio)
--     --all              resolve against EVERY package in the roster, not just the
--                        subject's declared dependencies (slow: extracts all of them)
--     --cap <n>          stop after n dependency extractions (default 12)
--
-- ★★ PORTING IS TRANSITIVE, AND THE ENVIRONMENT DIFF CANNOT SEE IT. A mod that rewrites
-- another mod's prototypes cannot be ported before that other mod is, and its worklist
-- holds items no api diff can produce: `data.raw.recipe["angels-ore1-crushed"]` is a
-- demand on angelsrefining, and the base prototype-api knows nothing about that name.
-- The port surface diffs a mod against two ENVIRONMENT versions and models no other
-- package at all. This joins the two sides that already exist:
--
--   DEMAND   every record's `patch`/`base` descriptor — the (type, name) it reads from
--   SUPPLY   every record's registered name — a literal's own, or the new name a
--            deepcopy was renamed to
--
-- The reader has kept those apart all along (`p.base` = read-from, `p.name` =
-- registers-as); nothing had joined them across packages.
--
-- ⚠ BASE IS NOT IN THE SUPPLY SET, AND CANNOT BE FROM HERE. Every mod patches base
-- prototypes by INSTANCE name (`iron-plate`, `gun-turret`) and no shipped artifact
-- enumerates instances — the prototype-api gives TYPES. So an unmatched demand means
-- "no MOD in this roster supplies it", never "this does not exist". Measured on
-- dfb-OrbitalIonCannon against Krastorio2: 17 demands, 13 met, and all 4 unmatched are
-- base prototypes (corpse/small-scorchmark, ammo-turret/gun-turret, gui-style/default),
-- with no mod-supplied name unmatched. The residue IS the base gap, exactly.
--
-- ⚠ AND A DEPENDENCY'S 2.0 RELEASE IS NOT A PORT OF ITS 1.1 SELF. When a supplier ships
-- for 2.0 its authors also redesign, for reasons that have nothing to do with the
-- version. So a demand this tool reports as unmet against a ported supplier may be the
-- supplier's own evolution rather than porting work, and NOTHING HERE CAN SEPARATE THEM:
-- zero of the 198 packages in this roster exist at both versions, so there is no
-- self-diff to attribute against. The report says "no longer supplied by X", never
-- "porting removed this".

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/portdeps%.lua$')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = here .. '/?.lua;' .. here .. '/../lua/?.lua;'
    .. here .. '/../lua/?/init.lua;' .. package.path

local subject, dir, econame, all, cap = nil, nil, 'lua-factorio', false, 12
do
    local a = _G.arg or {}
    local i = 1
    while a[i] do
        if a[i] == '--dir' then i = i + 1; dir = a[i]
        elseif a[i] == '--eco' then i = i + 1; econame = a[i]
        elseif a[i] == '--all' then all = true
        elseif a[i] == '--cap' then i = i + 1; cap = tonumber(a[i]) or cap
        elseif not a[i]:match('^%-%-') then subject = subject or a[i] end
        i = i + 1
    end
end
if not subject then
    io.write('usage: portdeps.lua <package-name-or-root> [--dir D] [--eco E]'
        .. ' [--all] [--cap N]\n')
    os.exit(2)
end

local eco = require 'cartograph.spec.ecosystem'
local bench = require 'bench'
local store = require 'cartograph.store'
local function say(s) io.write(s .. '\n') end

local roster, why = eco.roster(econame, dir and { dir = dir } or {})
if not roster then say('portdeps: no roster — ' .. tostring(why)); os.exit(1) end
say(('portdeps — %s roster: %d package(s) at %s'):format(econame,
    #roster.packages, roster.dir))

local by_name = {}
for _, p in ipairs(roster.packages) do by_name[p.name] = p end

--- A package's files unpacked to a plain directory, because extraction takes a
--- filesystem root. An unpacked package is already one; an archive is expanded into a
--- tempdir holding only its .lua and its manifest, which is everything the data-stage
--- reader needs and a small fraction of the bytes.
local function root_of(pkg)
    if pkg.form == 'directory' then return pkg.base end
    local container, prefix = pkg.base.container, pkg.base.prefix
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local ok = os.execute(("unzip -qq -o %s '%s/*.lua' '%s/info.json' -d %s 2>/dev/null")
        :format(vim.fn.shellescape(container), prefix, prefix, vim.fn.shellescape(tmp)))
    if not ok then return nil end
    return tmp .. '/' .. prefix
end

--- SUPPLY and DEMAND from one root. Both come off the reader's own records; the roles
--- are separate fields and always were.
local function facts(root)
    local ok, data = pcall(bench.extract, root, { nocache = true })
    if not ok then return nil, tostring(data) end
    store.ingest(data)
    local protos = require('cartograph.prototypes').all(store)
    if not protos then return nil, 'no data stage (the adapter does not apply)' end
    local supply, demand, nameless = {}, {}, 0
    for _, m in ipairs(protos) do
        for _, p in ipairs(m.protos) do
            local ty = (p.base and p.base.type) or (p.patch and p.patch.type)
                or p.declared_type
            if ty and p.name then supply[ty .. '/' .. p.name] = true end
            -- ⚠ A DECLARATION WHOSE NAME THE READER COULD NOT GET is a HOLE IN THE
            -- SUPPLY SET, and it shows up downstream as the mod's own prototypes
            -- appearing unmatched. CircuitProcessing builds its `cp-*` items through a
            -- helper, so the reader attributes one name to the whole mod and 19 of its
            -- demands look unsupplied when most are its own.
            if not (p.patch or p.base) and not p.name and not p.container then
                nameless = nameless + 1
            end
            local src = p.patch or p.base
            if src and src.type and src.name then
                demand[#demand + 1] = { key = src.type .. '/' .. src.name,
                    file = m.file, line = p.line }
            end
        end
    end
    return { supply = supply, demand = demand, nameless = nameless }
end

-- ── the subject ──────────────────────────────────────────────────────────────
local subj_pkg = by_name[subject]
local subj_root = subj_pkg and root_of(subj_pkg) or vim.fn.expand(subject)
local subj, serr = facts(subj_root)
if not subj then say('portdeps: cannot read ' .. tostring(subj_root) .. ' — '
    .. tostring(serr)); os.exit(1) end
local nsup = 0; for _ in pairs(subj.supply) do nsup = nsup + 1 end
say(('subject %s: declares %d readable name(s), demands %d'):format(subject, nsup,
    #subj.demand))
if subj.nameless > 0 then
    say(('    ⚠ %d of this mod\'s OWN records register a name the reader could not'):format(
        subj.nameless))
    say('      read (built through a helper, or a computed name), so its supply set is')
    say('      INCOMPLETE and some unmatched demands below may be its own prototypes.')
end

-- ── whose supply to consult ──────────────────────────────────────────────────
-- DECLARED DEPENDENCIES BY DEFAULT. `--all` is offered and not the default because a
-- roster of 198 packages is 198 extractions, and the manifest already says which
-- packages this one claims to need — a claim worth testing rather than bypassing.
local wanted, unresolved = {}, {}
if all then
    for _, p in ipairs(roster.packages) do
        if p.name ~= subject then wanted[#wanted + 1] = p end
    end
else
    for _, d in ipairs((subj_pkg and subj_pkg.deps) or {}) do
        -- a dependency string carries prefixes (! ? ~ (?)) and a version constraint;
        -- the NAME is what is left
        local nm = d:match('^%s*[!%?~%(%)]*%s*([%w%s%-_]-)%s*[<>=]') or
            d:match('^%s*[!%?~%(%)]*%s*([%w%s%-_]+)%s*$')
        nm = nm and nm:gsub('%s+$', '')
        if nm and nm ~= '' and nm ~= 'base' then
            if by_name[nm] then wanted[#wanted + 1] = by_name[nm]
            else unresolved[#unresolved + 1] = nm end
        end
    end
end

-- ── build the supply set ─────────────────────────────────────────────────────
local supply_of, failed, n = {}, {}, 0
for _, pkg in ipairs(wanted) do
    if n >= cap then break end
    n = n + 1
    local r = root_of(pkg)
    -- ⚠ `local f, err = r and facts(r)` TRUNCATES TO ONE VALUE — Lua's `and` yields a
    -- single result, so every failure reported the fallback reason instead of its own.
    -- The first run blamed "unpack failed" for a package that had unpacked fine.
    local f, err
    if r then f, err = facts(r) else err = 'could not unpack the archive' end
    if f then
        for k in pairs(f.supply) do supply_of[k] = supply_of[k] or pkg end
    else
        failed[#failed + 1] = ('%s (%s)'):format(pkg.name, tostring(err or 'no reason given'))
    end
end
say(('supply from %d package(s)%s%s'):format(n,
    #wanted > n and (' of %d declared — raise --cap'):format(#wanted) or '',
    #failed > 0 and ('; %d unreadable'):format(#failed) or ''))
if #wanted > n then
    -- NAMED, not just counted: a demand can only be matched against a supplier that was
    -- actually read, so a capped-out package is a reason the answer below is a FLOOR.
    local skipped = {}
    for i = n + 1, #wanted do skipped[#skipped + 1] = wanted[i].name end
    say(('    not read (cap): %s'):format(table.concat(skipped, ', ')))
end
for _, f in ipairs(failed) do say('    unreadable: ' .. f) end
if #unresolved > 0 then
    say(('    %d declared dependency(ies) NOT in this roster (not installed here,'
        .. ' so nothing can be said about them): %s'):format(#unresolved,
        table.concat(unresolved, ', ')))
end

-- ── the join ─────────────────────────────────────────────────────────────────
local met, own, unmatched, byp = 0, 0, {}, {}
for _, d in ipairs(subj.demand) do
    local pkg = supply_of[d.key]
    if pkg then
        met = met + 1
        local k = ('%s (%s, declares %s)'):format(pkg.name, tostring(pkg.version),
            tostring(pkg.target))
        byp[k] = (byp[k] or 0) + 1
    elseif subj.supply[d.key] then own = own + 1
    else unmatched[#unmatched + 1] = d end
end
say('')
say(('DEMANDS: %d — %d supplied by a dependency, %d by this mod itself, %d unmatched')
    :format(#subj.demand, met, own, #unmatched))
local ks = {}
for k in pairs(byp) do ks[#ks + 1] = k end
table.sort(ks, function (x, y) return byp[x] > byp[y] end)
for _, k in ipairs(ks) do say(('    %4d  %s'):format(byp[k], k)) end

-- ★ THE PORT-ORDER ANSWER, and the reason the supplier's declared version is printed
-- above: a dependency still declaring the OLD version is work that must happen first.
local behind = {}
for _, k in ipairs(ks) do
    local pkgname = k:match('^([^%s]+)')
    local p = by_name[pkgname]
    if p and tostring(p.target) == tostring(subj_pkg and subj_pkg.target) then
        behind[#behind + 1] = ('%s (%s)'):format(p.name, tostring(p.target))
    end
end
if #behind > 0 then
    say('')
    say(('  ⚠ PORT THESE FIRST — %d supplier(s) still declare %s, the version this mod'
        .. ' is moving off:'):format(#behind, tostring(subj_pkg and subj_pkg.target)))
    say('      ' .. table.concat(behind, ', '))
end

if #unmatched > 0 then
    say('')
    say(('  %d demand(s) matched by NO package in this roster:'):format(#unmatched))
    say('    ⚠ THIS IS NOT "MISSING". Base is not in the supply set and cannot be —')
    say('      every mod patches base prototypes by INSTANCE name and no shipped')
    say('      artifact enumerates instances (the prototype-api gives TYPES). A base')
    say('      prototype lands here, and so does a dependency that is not installed.')
    for i = 1, math.min(20, #unmatched) do
        say(('      %-44s %s:%s'):format(unmatched[i].key, unmatched[i].file,
            tostring(unmatched[i].line)))
    end
    if #unmatched > 20 then say(('      … and %d more'):format(#unmatched - 20)) end
end
