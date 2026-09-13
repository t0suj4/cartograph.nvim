-- algebraledger — HOW MUCH OF THE PROTOTYPE IS ACTUALLY ABSORBED, derived.
--
-- ★★★ WHY A TOOL AND NOT A TABLE. The prototype carries its own mapping table
-- (ALGEBRA.md, "here | cartograph"), and by the time this was written one of its
-- rows was already wrong in our favour: `partition` still read "the near tier's
-- similarity threshold; no objective" after `clones.families` had been running
-- `A.partition` with MDL for a day. A hand-maintained ledger drifts in BOTH
-- directions, and the direction that flatters you is the one nobody checks.
-- Everything here is derived from the two trees on every run.
--
-- ★★ ABSORB MEANS GIVE IT A HOME, NOT MAKE A COPY (cartograph.algebra's header).
-- So "absorbed" is not "the code is present" — it is "a SHIPPED consumer calls
-- it". An arrow used only from `tools/` is a measurement, and one used only from
-- `tests/` is an assertion about the prototype, not a capability of cartograph.
-- The three tiers are reported separately for exactly that reason.
--
-- ⚠ IT READS THE PROTOTYPE AS TEXT, NEVER `dofile`s IT. The seam executes the
-- prototype deliberately and says so; a ledger has no reason to, and the path it
-- reads is the DECLARED one (`algebra.path()`), never a path from the analysed
-- tree — the same rule the seam states.
--
-- ★ THE GROUPING IS THE PROTOTYPE'S OWN. Sections come from its `-- ── title ──`
-- headers, so a flat "6 of 159" does not mislead: `terms` is plumbing and its
-- constructors are used everywhere, while `transplant` and `unification` are
-- capabilities and sit at zero. Attributing exports by hand would be a second
-- authority that drifts, which is the thing this file exists to avoid.

-- the same self-location every tool in here uses: resolve the repo from this
-- file's own path so the ledger runs from anywhere, including a pre-commit hook
local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path

local M = {}

local function read(path)
    local fd = io.open(path, 'r'); if not fd then return nil end
    local s = fd:read('*a'); fd:close(); return s
end

local function ls(dir, out)
    out = out or {}
    local p = io.popen(('find %q -name "*.lua" -type f 2>/dev/null'):format(dir))
    if not p then return out end
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

--- ★★★ EVERY NAME ON THE MODULE TABLE, NOT EVERY `function M.x` (CART-0911).
--- The first predicate was `^function M%.` and nothing else, which is the
--- hand-rolled-parser failure this repo has a rule about: it described the
--- instances its author had in mind rather than the CLASS. MEASURED on the
--- vendored algebra, four shapes were invisible to it:
---
---     function M.x(...)          159   counted
---     M.x = <identifier>           5   an ALIAS of a local function — an ARROW
---     M.x.y = function(...)        4   a NAMESPACED arrow (M.rigidity.lcs)
---     M.x = {...} / setmetatable   ~8   a VALUE: data that is part of the contract
---
--- ⚠ AND A VALUE IS NOT AN ARROW, SO THEY ARE COUNTED SEPARATELY RATHER THAN
--- TOGETHER OR NOT AT ALL. `M.KV_ABSENT` is a sentinel a consumer must handle to
--- use the KV section at all — dropping it says the contract is smaller than it
--- is, and folding it into the arrow count says more arrows exist than do. The
--- report carries both numbers because they answer different questions.
---
--- ⚠ `M.grammar('sh', {...})` IS A CALL, NOT AN EXPORT — it INVOKES an exported
--- function to register a grammar. The `=` is what makes an assignment, and the
--- patterns below require it.
--- ★★ AND A DEFINITION OUTRANKS AN ASSIGNMENT, which is not a nicety: once a
--- section is extracted, `core.lua` carries `M.alpha_eq = hopau.alpha_eq` while
--- `hopau.lua` carries `function M.alpha_eq`. Taking the first sighting read our
--- OWN re-export as data and put the name in the wrong section — MEASURED, the
--- split moved the breakdown 168 arrow/9 value to 156/21 while the total held.
--- A `function M.x` is a stronger claim about a name than any assignment to it,
--- so it wins both the KIND and the SECTION.
--- @return table sect, table order, table of, table kind, table rank
function M.exports(src)
    local sect, order, of, kind, rank = {}, {}, {}, {}, {}
    local cur = '(preamble)'
    sect[cur] = {}; order[#order + 1] = cur
    local function add(name, k, r)
        if not name then return end
        if not of[name] then
            of[name], kind[name], rank[name] = cur, k, r
            sect[cur][#sect[cur] + 1] = name
        elseif r > rank[name] then
            -- drop it from the weaker section and re-file it under this one
            local old = sect[of[name]]
            for i, n in ipairs(old) do
                if n == name then table.remove(old, i); break end
            end
            of[name], kind[name], rank[name] = cur, k, r
            sect[cur][#sect[cur] + 1] = name
        end
    end
    for line in src:gmatch('[^\n]*') do
        local title = line:match('^%-%- \226\148\128\226\148\128 (.-) [\226\148\128 ]*$')
            or line:match('^%-%- \226\148\128\226\148\128 (.+)$')
        if title then
            cur = title:gsub('[\226\148\128%s]+$', '')
            if not sect[cur] then sect[cur] = {}; order[#order + 1] = cur end
        else
            local fn = line:match('^function M%.([%w_%.]+)')
            if fn then
                add(fn, 'arrow', 2)
            else
                local name, rhs = line:match('^M%.([%w_%.]+)%s*=%s*(.+)$')
                if name then
                    -- an ALIAS is a bare identifier; a `function` literal is an
                    -- arrow written the other way round; anything else (a table,
                    -- a setmetatable, a literal) is DATA
                    add(name, (rhs:match('^[%a_][%w_]*%s*$') or rhs:match('^function%f[%W]'))
                        and 'arrow' or 'value', 1)
                end
            end
        end
    end
    return sect, order, of, kind, rank
end

--- ★★★ THE EXPORT SURFACE IS A DIRECTORY, NOT A FILE (CART-0918). While the
--- algebra was one vendored file, reading `core.lua` was the whole surface. The
--- moment cartograph's own move-set extracted a section (rung 3 of CART-0912),
--- 12 exports left that file and the ledger read 159 -> 147 — with the NUMERATOR
--- untouched, so absorption "improved" from 15.1% to 16.3% for moving code.
---
--- ⚠ AND THAT IS THE FLATTERING DIRECTION, WHICH IS THE ONE NOBODY QUESTIONS.
--- This file's own header says so about UNDERCOUNTING the numerator; a shrinking
--- DENOMINATOR is the same failure with a bigger lever — split the module enough
--- times and absorption reaches 100% with no arrow gaining a consumer. A ratio
--- whose denominator is a side effect of file layout is not a measurement.
---
--- ★ THE SECTION GROUPING SURVIVES THE SPLIT FOR FREE, because the `-- ── title ──`
--- headers travel WITH the moved text — the move-set carries the comment block
--- verbatim. So the merge is by section TITLE and needs no new authority.
--- @return table sect, table order, table of, table files, table kind
function M.exports_dir(dir)
    local sect, order, of, files, kind, rank = {}, {}, {}, {}, {}, {}
    local paths = ls(dir)
    table.sort(paths, function (a, b)
        -- core first, then stable: the preamble and the bulk of the sections
        -- come from it, so the section ORDER reads like the original file
        local ac, bc = a:find('core%.lua$') and 0 or 1, b:find('core%.lua$') and 0 or 1
        if ac ~= bc then return ac < bc end
        return a < b
    end)
    for _, path in ipairs(paths) do
        -- the stamp is a record, not code: it exports nothing and its fields
        -- would read as a section-less preamble
        if not path:find('origin%.lua$') then
            local src = read(path)
            if src then
                files[#files + 1] = path
                local s2, o2, of2, k2, r2 = M.exports(src)
                for _, title in ipairs(o2) do
                    if not sect[title] then sect[title] = {}; order[#order + 1] = title end
                    for _, fn in ipairs(s2[title]) do
                        -- ⚠ FIRST FILE WINS on a duplicate name. Two files
                        -- exporting one name is a real defect (the module table
                        -- would take whichever loaded last), and counting it
                        -- twice would inflate the denominator — the very thing
                        -- this function exists to stop.
                        if not of[fn] then
                            of[fn], kind[fn], rank[fn] = of2[fn], k2[fn], r2[fn]
                            sect[title][#sect[title] + 1] = fn
                        elseif (r2[fn] or 0) > (rank[fn] or 0) then
                            -- the DEFINITION found in a later file outranks the
                            -- re-export the first file carries (see M.exports)
                            local old = sect[of[fn]]
                            for i, n in ipairs(old or {}) do
                                if n == fn then table.remove(old, i); break end
                            end
                            of[fn], kind[fn], rank[fn] = of2[fn], k2[fn], r2[fn]
                            sect[title][#sect[title] + 1] = fn
                        end
                    end
                end
            end
        end
    end
    return sect, order, of, files, kind
end

--- the local each consumer binds the loaded algebra to — DERIVED, not assumed.
--- `clones.lua` writes `local A, why = alg.load()` and the seam writes
--- `local A = M.load()`; a tool that hardcoded `A` would silently miss any file
--- that picked another name, and report it as unabsorbed.
local function bindings(text)
    -- ⚠ LINE-ORIENTED AND WRAPPER-BLIND ON PURPOSE. Three shapes are in the
    -- tree already and a fourth will appear:
    --     local A       = alg.load()                     -- clones.lua
    --     local A, why  = alg.load()                     -- families
    --     local A       = assert(alg.load(), '...')      -- tools/familydiff.lua
    -- Matching the CALL rather than the expression around it covers all of them;
    -- the earlier `[%w_.]-load%(` form silently missed the assert-wrapped one.
    local names = {}
    for line in text:gmatch('[^\n]*') do
        local v = line:match('^%s*local%s+([%w_]+)%s*=.*load%s*%(')
            or line:match('^%s*local%s+([%w_]+)%s*,%s*[%w_]+%s*=.*load%s*%(')
        if v then names[v] = true end
    end

    -- ★ ONE LEVEL OF INDIRECTION, because the spec binds through a helper:
    --     local function need() ... return alg.load() end
    --     local A = need()
    -- The first cut matched only the direct form and reported 0 TEST-ONLY
    -- arrows while `join` and `unify` were sitting in `algebra_spec.lua`. An
    -- absorption ledger that UNDERCOUNTS reads as "less absorbed than we are",
    -- which is the flattering direction for a tool whose job is to find gaps —
    -- and therefore the one that would never have been questioned.
    local loaders, cur = {}, nil
    for line in text:gmatch('[^\n]*') do
        local fn = line:match('^%s*local function ([%w_]+)')
        if fn then cur = fn end
        if cur and line:match('return%s+[%w_]+%.load%s*%(') then loaders[cur] = true end
    end
    for v, f in text:gmatch('local%s+([%w_]+)%s*=%s*([%w_]+)%s*%(%s*%)') do
        if loaders[f] then names[v] = true end
    end
    return names
end

-- exposed for the spec: the binding shapes are where this tool's bugs live
M._bindings = bindings

--- ★★★ CODE-AS-DATA IS NOT CODE (CART-0910). A text scan cannot tell a call from
--- a STRING that spells one, and this tool's own spec holds fixtures like
---     ['direct'] = 'local A = alg.load()\nA.partition(x)\n'
--- which read as a file that loads the algebra and binds it invisibly. Comments
--- do the same: every header here names arrows in prose.
--- ⚠ NOT A PARSER, AND NOT PRETENDING TO BE. It blanks the CONTENTS of quoted
--- strings and comments while preserving line structure, which is exactly enough
--- for the line-oriented predicates below, and it is deliberately blind to long
--- brackets with levels — a `[==[` would survive. The real fix is to ask the
--- GRAPH (CART-0912's "hand-rolled enumerators on both sides of a relation");
--- this is the honest interim, and it fails toward the text as written.
--- @return string
local function decommented(text)
    local out = {}
    for line in text:gmatch('[^\n]*') do
        local l = line:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-.*$', '')
        -- blank a string's CONTENTS, keep its quotes: the line still parses as
        -- an assignment, it just stops spelling anything
        l = l:gsub('(["\'])(.-)%1', '%1%1')
        out[#out + 1] = l
    end
    return table.concat(out, '\n')
end

--- the SEAM's own API, derived from the seam file rather than listed here — a
--- hardcoded list is the second authority this whole tool exists to avoid.
--- @return table set
local function seam_api(root)
    local src = read(root .. '/lua/cartograph/algebra.lua') or ''
    local set = {}
    for fn in src:gmatch('\nfunction M%.([%w_]+)') do set[fn] = true end
    return set
end

--- ★★★ WHICH FILES REACH FOR THE ALGEBRA IN A SHAPE WE CANNOT SEE — structurally,
--- not by spotting arrow names (CART-0910). The previous test asked whether the
--- text contained `.<arrow>` for ANY of the 168 arrows, and the arrow names
--- include `name`, `at`, `apply`, `copy`, `size`, `ref` and `match`. MEASURED, it
--- fired on all three files that touch the algebra and on nothing else — 15
--- "hits" in `agent.lua`, which is a verb catalogue full of `.name` fields, and 0
--- of them a use of the algebra. A warning that has been wrong on every run since
--- it shipped is the inverse of a fence that never fires, and it costs the same:
--- nobody reads the line.
---
--- THE STRUCTURAL QUESTION INSTEAD: this file binds the SEAM, and calls `load()`
--- on it — so it holds the algebra — yet no binding shape was recognised. That is
--- precisely "it loaded the arrows and we cannot see what it called them", and a
--- file that only asks `available()` or converts a term is not it.
--- ⚠ TWO TEXTS, AND MIXING THEM UP COST A ROUND. The seam VAR is found in the
--- RAW text, because `require 'cartograph.algebra'` IS a string and
--- `decommented` blanks it — stripping the evidence the detector runs on. The
--- REACHES are found in the stripped text, because that is where fixtures and
--- prose lie. Same file, two readings, and each predicate takes the one it needs.
--- @return string|nil member  the seam var whose load we saw
local function loads_unseen(raw, code, api)
    local seams = {}
    for line in raw:gmatch('[^\n]*') do
        local v = line:match('^%s*local%s+([%w_]+)%s*=%s*require%s*%(?%s*[\'"]cartograph%.algebra[\'"]')
        if v then seams[v] = true end
    end
    for v in pairs(seams) do
        if code:find('%f[%w_]' .. v .. '%.load%s*%(') then return v end
        -- a member that is NOT part of the seam's API is a reach we do not model
        for m in code:gmatch('%f[%w_]' .. v .. '%.([%w_]+)') do
            if not api[m] then return v end
        end
    end
    return nil
end

--- count uses of each arrow, per tier
function M.uses(root, arrows)
    M.unbound = {}
    local api = seam_api(root)
    local tiers = { lua = {}, tools = {}, tests = {} }
    local _ = root
    for tier, dir in pairs { lua = root .. '/lua', tools = root .. '/tools', tests = root .. '/tests' } do
        for _, f in ipairs(ls(dir)) do
            local text = read(f)
            -- ⚠ NOT ITSELF. This file names the arrows in its own prose (`A.partition`
            -- in the header), so it looks like a consumer that binds nothing. A
            -- measurement that includes the measuring instrument reports the
            -- instrument.
            if f:find('algebraledger%.lua$') then text = nil end
            -- ⚠ NOR THE ALGEBRA ITSELF. Since the vendoring (CART-0912) the
            -- algebra lives at `lua/cartograph/algebra/core.lua`, INSIDE the
            -- tier this counts. Its 6001 lines call its own arrows constantly,
            -- so counting them would report every export as shipped and the
            -- ledger would read 164 of 164 the day it stopped meaning anything.
            -- ★ ABSORBED STILL MEANS "SOMETHING ELSE CALLS IT". Owning the code
            -- did not change the question; it changed which files are allowed
            -- to answer it.
            -- ⚠ AND THE EXCLUSION IS DELIBERATE, NOT INHERITED. `core.lua` is
            -- skipped today only because it does not contain the string
            -- `cartograph.algebra` — an accident of the guard below that would
            -- evaporate the moment the vendored file gained one self-reference.
            if f:find('/cartograph/algebra/') then text = nil end
            if text and text:find('cartograph.algebra', 1, true) then
                local code = decommented(text)
                local vars = bindings(code)
                -- ⚠ ABSENCE RENDERED AS SILENCE IS THE FAILURE MODE HERE. A file
                -- that requires the algebra but binds it in a shape this does
                -- not recognise contributes ZERO, which is indistinguishable
                -- from "uses nothing". Say so instead.
                if not next(vars) then
                    -- ⚠ ONLY WARN IF THE FILE ACTUALLY HOLDS THE ARROWS.
                    -- `health.lua` requires the algebra to ask `available()` and
                    -- touches no operator at all; flagging it would be a fence
                    -- that cries wolf, and a warning nobody believes is worse
                    -- than none. See `loads_unseen` for why this is structural
                    -- and no longer a search for arrow NAMES.
                    local v = loads_unseen(text, code, api)
                    if v then
                        M.unbound[#M.unbound + 1] = ('%s (binds `%s`)')
                            :format(f:gsub('^' .. (root or ''), ''), v)
                    end
                end
                for v in pairs(vars) do
                    for a in pairs(arrows) do
                        local n = select(2, text:gsub(v .. '%.' .. a:gsub('%.', '%%.') .. '%f[^%w_]', ''))
                        if n > 0 then tiers[tier][a] = (tiers[tier][a] or 0) + n end
                    end
                end
            end
        end
    end
    return tiers
end

function M.run(opts)
    opts = opts or {}
    local root = opts.root or REPO
    -- ★★★ THE LEFT SIDE IS OUR OWN FILE NOW (CART-0912). Before the vendoring
    -- this read the donor at `algebra.path()`; that made the ledger a statement
    -- about SOMEONE ELSE'S module. The code is cartograph's own, so the export
    -- surface being measured is `lua/cartograph/algebra/core.lua` — and the day
    -- we adapt it (split it by its 38 sections) the ledger follows the edit
    -- instead of quietly measuring a file we no longer run.
    -- ⚠ COMPARING THE TWO IS A DIFFERENT TOOL. `tools/vendordrift.lua` answers
    -- "has the copy or the donor moved"; a ledger that silently read whichever
    -- it found would answer neither question reliably.
    local dir = root .. '/lua/cartograph/algebra'
    local sect, order, of, files, kind = M.exports_dir(dir)
    if #files == 0 then
        print(('algebraledger: no vendored algebra under %s'):format(dir))
        return 1
    end
    local arrows = {}
    for a in pairs(of) do arrows[a] = true end
    local nexp = 0; for _ in pairs(arrows) do nexp = nexp + 1 end
    local tiers = M.uses(root, arrows)

    local shipped, harness, testonly, absent = {}, {}, {}, {}
    for a in pairs(arrows) do
        if (tiers.lua[a] or 0) > 0 then shipped[a] = true
        elseif (tiers.tools[a] or 0) > 0 then harness[a] = true
        elseif (tiers.tests[a] or 0) > 0 then testonly[a] = true
        else absent[a] = true end
    end
    local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

    print(('ALGEBRA ABSORPTION LEDGER'))
    print(('  vendored: %s  (%d file%s)'):format(
        dir:gsub('^' .. (root or ''), ''), #files, #files == 1 and '' or 's'))
    if #files > 1 then
        -- name them: once the split starts, WHICH files carry the surface is
        -- the thing a reader cannot infer from a count
        local names = {}
        for _, f in ipairs(files) do names[#names + 1] = f:match('([^/]+)$') end
        print(('    %s'):format(table.concat(names, ' ')))
    end
    local narrow, nvalue = 0, 0
    for a in pairs(arrows) do
        if kind[a] == 'value' then nvalue = nvalue + 1 else narrow = narrow + 1 end
    end
    -- ★ TWO NUMBERS, BECAUSE THEY ANSWER DIFFERENT QUESTIONS: how much of the
    -- CAPABILITY is reachable, and how much of the CONTRACT is. A sentinel a
    -- consumer must handle is part of the second and not of the first.
    print(('  exports: %d   (%d arrow · %d value)'):format(nexp, narrow, nvalue))
    print(('    SHIPPED  (a consumer in lua/):  %3d'):format(count(shipped)))
    print(('    HARNESS  (tools/ only):         %3d'):format(count(harness)))
    print(('    TEST     (tests/ only):         %3d'):format(count(testonly)))
    print(('    ABSENT   (no consumer at all):  %3d'):format(count(absent)))
    print('')
    print(('  %-58s %5s %5s %5s %5s'):format('section (the prototype\'s own)', 'exp', 'ship', 'harn', 'test'))
    for _, s in ipairs(order) do
        local list = sect[s]
        if #list > 0 then
            local e, sh, h, t = #list, 0, 0, 0
            for _, a in ipairs(list) do
                if shipped[a] then sh = sh + 1
                elseif harness[a] then h = h + 1
                elseif testonly[a] then t = t + 1 end
            end
            local mark = (sh == 0 and e > 0) and '  <- nothing shipped' or ''
            print(('  %-58s %5d %5d %5d %5d%s'):format(s:sub(1, 58), e, sh, h, t, mark))
        end
    end
    if opts.verbose then
        print('\n  SHIPPED arrows:')
        local names = {}; for a in pairs(shipped) do names[#names + 1] = a end
        table.sort(names)
        for _, a in ipairs(names) do
            print(('    %-20s lua %d  tools %d  tests %d'):format(a,
                tiers.lua[a] or 0, tiers.tools[a] or 0, tiers.tests[a] or 0))
        end
    end

    -- ★ THE RATCHET. A ledger nobody gates is a report, and a report that only
    -- goes up when someone looks is not a measurement. `--min N` fails when the
    -- shipped count DROPS, which is the regression worth catching: an arrow
    -- losing its last shipped consumer looks like a refactor, not a loss.
    if opts.min and count(shipped) < opts.min then
        print(('\nalgebraledger: FAIL — %d shipped arrows, floor is %d')
            :format(count(shipped), opts.min))
        return 1
    end
    if #(M.unbound or {}) > 0 then
        print('\n  \226\154\160 files that require the algebra but bind it in an unrecognised shape')
        print('    (their uses are NOT counted above — fix the binding detection, not the file):')
        for _, f in ipairs(M.unbound) do print('      ' .. f) end
    end
    print('\nalgebraledger: ok')
    return 0
end

if not pcall(debug.getlocal, 4, 1) then
    local opts = { verbose = false }
    for _, a in ipairs(vim.v.argv or {}) do
        if a == '--verbose' then opts.verbose = true end
        local m = a:match('^%-%-min=(%d+)$'); if m then opts.min = tonumber(m) end
    end
    os.exit(M.run(opts))
end
return M
