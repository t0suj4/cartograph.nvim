-- instrumentcensus — WHAT CAN THIS TREE NOT BE FALSIFIED BY? (CART-0751)
--
--   nvim --headless -u NONE -l tools/instrumentcensus.lua lines
--   nvim --headless -u NONE -l tools/instrumentcensus.lua entries <file> <TABLE>
--
-- ★★ IT REPORTS A FINDING, NEVER A REMEDY, AND THAT IS A DESIGN DECISION WITH A
-- REASON (CART-0751, user). The obvious next step — derive the missing test from
-- the declaration — is UNSOUND for anything but a differential assertion: a
-- template read off the implementation asserts whatever the implementation does,
-- so a WRONG entry would be promoted to a guard DEFENDING it, across hundreds of
-- entries that all pass. Checked against two of the same day's bugs: a template
-- derived from `expr.walk` would have asserted the kid-descent list that was
-- MISSING `assign` (CART-0743), and enshrined the soundness hole in is_pure.
-- An oracle's two sides must not share the thing under test; here they would
-- share everything.
--
-- ⚠ SO A ZERO FROM THIS TOOL IS NOT SAFETY. It answers "is this reached / is this
-- guarded", never "is this right". `ctrlcensus --coverage` states the same limit
-- for corpora: a corpus with zero instances of a form cannot fail on that form.
--
-- MODES
--   lines    — hook every line of lua/cartograph/ through one suite run and
--              report what NEVER EXECUTES, partitioned. A line the suite cannot
--              reach cannot be guarded by it.
--   entries  — ABLATION per declared table entry: rename the key so the entry
--              cannot match, run the whole suite, and report GUARDED (something
--              failed) or UNGUARDED (nothing noticed). This is the stronger
--              question — reached is not guarded — and it is the one that
--              would have caught a fence that never fires.
--
-- ★ ENTRIES MODE RUNS IN A COPY OF THE WORKING TREE, never in place: an ablation
-- that dies mid-run must not leave a mutated source behind. The copy includes
-- uncommitted work, so the answer is about the tree you have.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local mode = arg[1]

-- ── mode: lines ─────────────────────────────────────────────────────────────
-- ⚠ THE PARTITION IS NOT COSMETIC. A pane has no headless entry point, so
-- counting it with the analysis engine hides whichever of the two is thin. The
-- headline number alone invites "we are 77% safe", which is the reading this
-- whole tool exists to refuse.
local function band(rel)
    if rel:find('/panes/') or rel:find('/commands/') or rel:match('init%.lua$') then
        return 'UI / commands'
    end
    if rel:find('/spec/') then return 'language specs' end
    if rel:find('/providers/') then return 'providers' end
    return 'analysis engine'
end

local function mode_lines()
    local hits, seen = {}, {}
    debug.sethook(function (_, line)
        local s = debug.getinfo(2, 'S')
        -- ⚠ `short_src` IS TRUNCATED to ~60 chars with a leading `...`, so a deep
        -- path comes back unopenable. `source` is the real one (`@/abs/path`).
        local f = s and (s.source or ''):sub(1, 1) == '@' and s.source:sub(2) or nil
        if f and f:find('/lua/cartograph/', 1, true) then
            hits[f .. ':' .. line] = true; seen[f] = true
        end
    end, 'l')
    -- run.lua ends with `qall!` / `cquit`, which would kill the process before
    -- the report. Neutralise the exit for the duration of the run.
    local realcmd = vim.cmd
    vim.cmd = function (c)
        if type(c) == 'string' and (c:find('qall') or c:find('cquit')) then return end
        return realcmd(c)
    end
    local ok, err = pcall(dofile, repo .. '/tests/run.lua')
    vim.cmd = realcmd
    debug.sethook()
    if not ok then io.stderr:write('suite error: ' .. tostring(err) .. '\n') end

    local rows, bands = {}, {}
    for f in pairs(seen) do
        local fh = io.open(f, 'r')
        if fh then
            fh:close()
            local rel = f:gsub('^.*/lua/cartograph/', 'lua/cartograph/')
            local total, un, n = 0, 0, 0
            for line in io.lines(f) do
                n = n + 1
                local t = line:gsub('^%s+', '')
                -- an approximation, and deliberately a LOOSE one: a `}` or a bare
                -- `end` carries no behaviour, so counting it would inflate both
                -- sides of the ratio with lines no test could ever "cover".
                if t ~= '' and not t:match('^%-%-') and not t:match('^end%s*[,)]?$')
                    and not t:match('^else$') and not t:match('^}%s*,?$') then
                    total = total + 1
                    if not hits[f .. ':' .. n] then un = un + 1 end
                end
            end
            rows[#rows + 1] = { rel = rel, total = total, un = un }
            local b = band(rel)
            bands[b] = bands[b] or { t = 0, u = 0, n = 0 }
            bands[b].t = bands[b].t + total; bands[b].u = bands[b].u + un
            bands[b].n = bands[b].n + 1
        end
    end
    table.sort(rows, function (a, b)
        if a.un ~= b.un then return a.un > b.un end
        return a.rel < b.rel                    -- total order, or the rank is not a fact
    end)
    local T, U = 0, 0
    for _, r in ipairs(rows) do T = T + r.total; U = U + r.un end
    io.write(('\nLINES NEVER EXECUTED BY THE SUITE — %d of %d (%.1f%%), %d files\n')
        :format(U, T, T > 0 and U / T * 100 or 0, #rows))
    io.write('  (a line the suite cannot reach cannot be guarded by it; a COVERED\n')
    io.write('   line is not thereby CHECKED — see the header)\n\n')
    local bn = {}
    for k in pairs(bands) do bn[#bn + 1] = k end
    table.sort(bn, function (a, b) return bands[a].u > bands[b].u end)
    for _, k in ipairs(bn) do
        local b = bands[k]
        io.write(('  %-18s %6d of %6d  (%4.1f%%)  %d files\n')
            :format(k, b.u, b.t, b.t > 0 and b.u / b.t * 100 or 0, b.n))
    end
    io.write('\n')
    for i = 1, math.min(#rows, 12) do
        io.write(('  %-48s %5d never-run of %5d\n'):format(rows[i].rel, rows[i].un, rows[i].total))
    end
end

-- ── mode: entries ───────────────────────────────────────────────────────────

--- Read a declared table's ENTRIES out of our own source, through our own
--- expression IR — no text scraping. `.at` gives each key a source range, which
--- is the whole reason the IR stamps it ([[cartograph-descendable-data]]: an
--- interpretation derived from the code, liftable into spec).
local function read_entries(file, tname)
    local expr = require 'cartograph.expr'
    local src = table.concat(vim.fn.readfile(file), '\n')
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local found
    local function walk(n)
        if found then return end
        if n:type() == 'variable_declaration' or n:type() == 'assignment_statement' then
            local txt = vim.treesitter.get_node_text(n, src)
            local nm = txt:match('^local%s+([%w_]+)%s*=') or txt:match('^([%w_]+)%s*=')
            if nm == tname then
                local function tbl(x)
                    if x:type() == 'table_constructor' then return x end
                    for c in x:iter_children() do
                        if c:named() then local r = tbl(c); if r then return r end end
                    end
                end
                local t = tbl(n)
                if t then found = expr.build(t, src, 'lua') end
                return
            end
        end
        for c in n:iter_children() do if c:named() then walk(c) end end
    end
    walk(root)
    if not found then return nil, src end
    -- ⚠ THE RANGE COMES OFF THE **PAIR**, NOT THE KEY, AND THAT IS NOT A
    -- PREFERENCE. An unbracketed identifier key is the ONE node the IR builds
    -- without going through `build`, so it is the one node with no `.at`:
    --     if not bracketed and kn:type():match('identifier') then
    --         key = { k = 'lit', ty = 'str', v = txt(kn, src) }   -- no .at
    --     else key = build(kn, src, lang) end                     -- has .at
    -- `{ argument = true }` therefore has no key range while `{ ['x'] = 1 }`
    -- does. Filed separately; here we take the pair's range and find the key at
    -- its start, which is where an unbracketed key always is.
    local out = {}
    for _, kid in ipairs(found.kids or {}) do
        if kid.k == 'pair' and kid.key and kid.at then
            local nm = (kid.key.k == 'name' and kid.key.n)
                or (kid.key.k == 'lit' and tostring(kid.key.v)) or nil
            if nm then out[#out + 1] = { name = nm, at = kid.at, kind = kid.key.k } end
        end
    end
    return out, src
end

--- Rename a key so the entry cannot match, keeping the table SYNTACTICALLY
--- VALID. ★ RENAME, NOT DELETE, and the reason is that a deletion has to get the
--- commas right in every surrounding shape; a rename is one span and cannot
--- produce a file that fails to load — which would report every entry as
--- "guarded" by a syntax error rather than by a test.
local function ablate(src, e)
    local lines = vim.split(src, '\n')
    local row = e.at.start.line + 1
    local line = lines[row]
    if not line then return nil end
    local sc = e.at.start.char
    -- the key sits at the START of the pair's range, in one of two spellings.
    -- ★ VERIFY BEFORE SPLICING: a rename applied at the wrong offset would
    -- produce a file that still loads and silently ablates NOTHING, reporting
    -- the entry as guarded by a mutation that never happened.
    local head = line:sub(sc + 1)
    if head:sub(1, #e.name) == e.name then
        lines[row] = line:sub(1, sc) .. '__ablated_' .. head
    elseif head:match("^%[%s*['\"]" .. vim.pesc(e.name)) then
        lines[row] = line:sub(1, sc) .. (head:gsub(vim.pesc(e.name), '__ablated_' .. e.name, 1))
    else
        return nil -- cannot locate the key: SKIP rather than mutate blindly
    end
    return table.concat(lines, '\n')
end

local function mode_entries(file, tname)
    local entries, src = read_entries(file, tname)
    if not entries then
        print(('no table %q found in %s'):format(tname, file)); os.exit(2)
    end
    -- ⚠⚠ AN EMPTY LITERAL THAT IS POPULATED ELSEWHERE MUST REFUSE, NOT REPORT
    -- ZERO. `JAVA_SERVICE_MARKERS = {}` followed by a loop that fills it is a
    -- common idiom here, and the first version of this tool answered "0 of the 0
    -- declared entries [exhaustive]" for it — a confident EXHAUSTIVE claim over a
    -- scope it had failed to read, which is precisely the failure this tool
    -- exists to detect. The reader sees a table CONSTRUCTOR; entries added by a
    -- later loop or assignment are invisible to it, so say so.
    if #entries == 0 and src:find(tname .. '%[') then
        print(('%s is EMPTY as a literal but is indexed elsewhere in the file — '
            .. 'its entries are added by code this reader cannot see (a loop, a '
            .. 'later assignment). REFUSING rather than reporting an exhaustive '
            .. 'zero over a scope that was never read.'):format(tname))
        os.exit(2)
    end
    print(('%s %s — %d entries\n'):format(file, tname, #entries))
    -- ★ A COPY OF THE WORKING TREE, never the tree itself. An ablation that dies
    -- mid-run must not leave a mutated source behind; and it copies the WORKING
    -- tree rather than HEAD so the answer is about the code you have.
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local cp = vim.system({ 'bash', '-c',
        ('cd %q && tar --exclude=.git -cf - . | tar -xf - -C %q'):format(repo, tmp) },
        { text = true }):wait()
    if cp.code ~= 0 then print('copy failed: ' .. tostring(cp.stderr)); os.exit(2) end
    local rel = file:gsub('^' .. vim.pesc(repo) .. '/', '')
    local target = tmp .. '/' .. rel

    -- ⚠⚠ THE VERDICT IS PARSED FROM THE SUMMARY LINE, NOT TAKEN FROM THE EXIT
    -- CODE, and the first version of this got it wrong in the most on-theme way
    -- available: it ran `./tests/run.sh 2>&1 | tail -3` and read `r.code`. A
    -- PIPELINE'S EXIT STATUS IS ITS LAST COMMAND'S, and `tail` always succeeds —
    -- so `suite_passes` was CONSTANT TRUE and every entry came back UNGUARDED.
    -- A fence that never fires, inside the tool built to find fences that never
    -- fire. The baseline check could not catch it either, because a
    -- constant-true predicate passes the baseline too.
    --
    -- ★ AND `skipped` IS READ, NOT IGNORED. A guard that SKIPS (no parser for
    -- that language here) is not a guard that passed: if the skip count moves,
    -- the answer for that entry is UNKNOWN, not "unguarded".
    local function suite_result()
        local st = vim.fn.tempname()
        vim.fn.mkdir(st, 'p')
        local r = vim.system({ 'bash', '-c',
            ('cd %q && XDG_STATE_HOME=%q ./tests/run.sh 2>&1'):format(tmp, st) },
            { text = true }):wait(900000)
        vim.fn.delete(st, 'rf')
        local out = (r.stdout or '') .. (r.stderr or '')
        local pass, fail, skip = out:match('(%d+) passed, (%d+) failed, (%d+) skipped')
        if not pass then return nil, out end -- no summary: the run itself broke
        return { pass = tonumber(pass), fail = tonumber(fail), skip = tonumber(skip) }, out
    end

    -- ⚠ THE BASELINE IS NOT OPTIONAL. If the copied tree does not pass, every
    -- ablation "fails" and every entry reads as GUARDED — a tool that cannot
    -- report an unguarded entry, which is the failure it exists to detect.
    io.write('  baseline (unmutated copy) … ')
    local base, base_out = suite_result()
    if not base or base.fail > 0 then
        print('FAIL')
        print('  the copy does not pass unmutated — every result would be meaningless.')
        print((base_out or ''):sub(-400))
        vim.fn.delete(tmp, 'rf'); os.exit(2)
    end
    print(('%d passed, %d skipped'):format(base.pass, base.skip))

    local unguarded, skipped, unknown = {}, {}, {}
    for i, e in ipairs(entries) do
        local mutated = ablate(src, e)
        if not mutated or mutated == src then
            skipped[#skipped + 1] = e.name
        else
            vim.fn.writefile(vim.split(mutated, '\n'), target)
            local res = suite_result()
            local verdict
            if not res then verdict = 'BROKEN — the run produced no summary'
            elseif res.fail > 0 then verdict = ('guarded (%d failed)'):format(res.fail)
            elseif res.skip > base.skip then
                -- the guard for this entry may be one of the newly skipped tests
                verdict = ('UNKNOWN — %d more tests SKIPPED than baseline')
                    :format(res.skip - base.skip)
                unknown[#unknown + 1] = e.name
            else
                verdict = 'UNGUARDED — suite still green'
                unguarded[#unguarded + 1] = e.name
            end
            io.write(('  [%2d/%2d] %-34s %s\n'):format(i, #entries, e.name, verdict))
        end
    end
    vim.fn.writefile(vim.split(src, '\n'), target) -- restore the copy, for tidiness
    vim.fn.delete(tmp, 'rf')

    -- ★ RETURNED AS A SHORTLIST, not printed as prose. This is EXHAUSTIVE — every
    -- entry that could be mutated WAS, so an empty result is the finding "all
    -- guarded" rather than "we did not look". The entries we could not mutate
    -- ride in `skipped`, which is what keeps that claim true (CART-0755).
    local shortlist = require 'cartograph.shortlist'
    local rows = {}
    for _, n in ipairs(unguarded) do rows[#rows + 1] = { name = n, verdict = 'UNGUARDED' } end
    for _, n in ipairs(unknown) do rows[#rows + 1] = { name = n, verdict = 'UNKNOWN (skipped guard?)' } end
    local list, why = shortlist.new{
        subject = ('entries of %s with no guard'):format(tname),
        scope = ('the %d declared entries'):format(#entries),
        complete = shortlist.EXHAUSTIVE,
        rows = rows, columns = { 'verdict', 'name' }, skipped = skipped,
    }
    if not list then print('shortlist refused: ' .. tostring(why)); os.exit(2) end
    print('')
    print(table.concat(list:render(), '\n'))
    return list
end

if mode == 'lines' then mode_lines()
elseif mode == 'entries' then
    if not arg[2] or not arg[3] then
        print('usage: instrumentcensus.lua entries <file> <TABLE>'); os.exit(2)
    end
    mode_entries(vim.fn.fnamemodify(arg[2], ':p'), arg[3])
else
    print('usage: instrumentcensus.lua lines')
    print('       instrumentcensus.lua entries <file> <TABLE>')
    os.exit(2)
end
