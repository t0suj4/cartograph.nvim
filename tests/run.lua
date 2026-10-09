-- Minimal dependency-free test runner. Run via tests/run.sh (nvim --headless).
-- Specs are tests/*_spec.lua and use the globals defined here: test/eq/ok/skip.

-- ⚠ STATE ISOLATION IS THE WRAPPER'S JOB, AND A DIRECT RUN LOSES IT (CART-0644).
-- The suite exercises write verbs against `vim.fn.tempname()` roots, and three
-- modules persist per-root records under `stdpath('state')` — the txn journal, the
-- working set, cockpit feedback. Those are a USER RECORD by design, so nothing
-- prunes them, and a fixture root gets the same permanent treatment as a real
-- project: 27798 journal directories had accumulated, 27794 of them for tempdirs
-- that no longer exist.
--
-- tests/run.sh points XDG_STATE_HOME at a throwaway. Running this file directly is
-- legitimate — and it leaks, ~17 directories a run. SAY SO rather than let it be
-- invisible, which is the whole reason it went unnoticed for 1949 runs.
local st = vim.fn.stdpath('state')
if not st:match('cartograph%-test%-state') then
    io.stderr:write(('\n⚠ NOT STATE-ISOLATED: writes will land in %s\n'
        .. '  Use tests/run.sh — it points XDG_STATE_HOME at a throwaway dir.\n\n')
        :format(st))
end

local reg = {}

-- the spec file each test came from (TIMES groups by it)
local current_spec
local load_ms = {}
function _G.test(name, fn) reg[#reg + 1] = { name = name, fn = fn, spec = current_spec } end

local function fmt(v) return type(v) == 'table' and vim.inspect(v) or tostring(v) end

function _G.eq(expected, got, msg)
    if not vim.deep_equal(expected, got) then
        error(('%s\n       expected: %s\n       got:      %s'):format(msg or 'eq', fmt(expected), fmt(got)), 2)
    end
end

function _G.ok(cond, msg)
    if not cond then error(msg or 'expected truthy value', 2) end
end

-- skip the current test (sentinel table so the runner can tell it apart)
function _G.skip(msg) error({ __skip = true, msg = msg }, 0) end

--- ⚠⚠ PENDING — A GENERATED CASE NOBODY HAS REVIEWED YET (CART-0991).
--- It ERRORS, so inaction cannot turn a machine-written test into coverage; and it is
--- COUNTED AND RENDERED SEPARATELY, because "nobody has looked at this yet" and
--- "something broke" are different facts and a runner that spells them the same way
--- trains people to ignore the first.
--- ★ IT SITS AFTER A PRE-FILLED ASSERTION, not instead of one. The generator writes the
--- assertion from what it observed, so review is JUDGEMENT ("is that right?") rather than
--- AUTHORSHIP ("write the assertion") — and PROMOTION IS DELETING THIS ONE LINE, which is
--- a smaller, more visible and more attributable act than writing a test.
--- ⚠ THE CEILING, SAID OUT LOUD: a reviewer who deletes it without reading pins the bug
--- forever. This makes the act deliberate and greppable; it cannot make review real.
function _G.PENDING(msg) error({ __pending = true, msg = msg }, 0) end

-- shared fixture writer: `write(root, name, lines)` writes a table of lines to a file.
-- Was copy-pasted byte-identically across ~10 spec files; hoisted here (a spec that needs
-- a different `write` still declares its own local, which shadows this). A specfile-local
-- `write` always wins — this only fills in for specs that had the identical copy.
function _G.write(root, name, lines)
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
end

-- does tree-sitter REALLY have this language? NOT `pcall(vim.treesitter.language.add, l)`: in nvim 0.11 a missing
-- parser makes language.add RETURN nil (the pcall still succeeds), so that guard can never skip — 37 guards here were
-- that form (CART-1075). language.add returns true once the language is loaded, so the result is read, not the pcall.
function _G.parser_available(lang)
    local ok, loaded = pcall(vim.treesitter.language.add, lang)
    return ok and loaded == true
end

-- shared fixture: `mkroot(name, src)` makes a temp dir with one file (src = a string) and
-- returns the dir. Also copy-pasted identically; same shadowing rule as `write`.
function _G.mkroot(name, src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(src)
    fd:close()
    return root
end

-- THE RUNNING CHECKOUT. `repo()` is the root of the tree this suite is running FROM,
-- and `repo(rel)` a path inside it. Any spec that needs a real file of this project --
-- a source to scan, a profile artifact to stamp -- must go through here.
--
-- WHY IT EXISTS (CART-0440, measured): four specs hard-coded the author's own checkout
-- instead. Run from a git worktree, they READ the running tree and WROTE the other one:
-- the suite went red in the worktree and green in the main tree, and, worse, a worktree
-- run moved the mtime of a TRACKED file in the main checkout -- which is exactly what
-- this project's cache validity is keyed on ([[cartograph-validity-layer]]), so two
-- workers running suites in parallel perturbed each other through a file neither owned.
-- Derived from this file's own path, the pattern tools/bench.lua and tools/snapshot.lua
-- already use; `:p` because a source can be relative (`luafile tests/run.lua`).
-- tests/isolation_spec.lua fences the regression.
local ROOT = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
function _G.repo(rel) return rel and (ROOT .. '/' .. rel) or ROOT end

-- ── FLAKE FORENSICS (CART-1588) ───────────────────────────────────────────────
-- A FLAKY assertion fails once in a full parallel run and never alone, so by the time anyone looks the process
-- that knew why is gone. flake_dump(tag, state) writes a POST-MORTEM — not an OS core (the failure is a wrong
-- VALUE, and an nvim core holds C frames, not the Lua tables that produced it) but the state that decides a
-- replay: the caller's own state, this WORKER's spec list and every test it ran before this one IN ORDER (the
-- suspect is state an earlier spec left behind), the JIT's status, the modules loaded, and the command that
-- replays the exact sequence in one process. -> the dump's path. Lands in .git/flake-dumps/ (never committed;
-- the worker's state home is a throwaway that dies with the run).
_G.__run_log = {}
function _G.flake_dump(tag, state)
    -- (a git WORKTREE's .git is a file: there the dumps go to the user cache, which outlives the run too)
    local dir = vim.fn.isdirectory(ROOT .. '/.git') == 1 and (ROOT .. '/.git/flake-dumps')
        or (vim.fn.stdpath('cache') .. '/cartograph-flake-dumps')
    vim.fn.mkdir(dir, 'p')
    local loaded = {}
    for k in pairs(package.loaded) do loaded[#loaded + 1] = tostring(k) end
    table.sort(loaded)
    local jit_ok, jit_st = pcall(function () return { require('jit').status() } end)
    local spec = vim.env.SPEC
    local dump = {
        tag = tag, at = os.date('!%Y-%m-%dT%H:%M:%SZ'), pid = vim.uv.os_getpid(),
        worker_specs = spec, jobs = vim.env.JOBS,
        replay = ('SPEC=%s JOBS=1 bash tests/run.sh'):format(spec or '<whole suite: SPEC unset>'),
        ran_before = vim.deepcopy(_G.__run_log), -- (every test this process started, the failing one LAST)
        jit = jit_ok and jit_st or tostring(jit_st), jit_version = (jit and jit.version) or nil,
        gc_kb = collectgarbage('count'), loaded = loaded,
        state = state,
    }
    local path = ('%s/%s-%s-%d.lua'):format(dir, tag:gsub('[^%w_-]', '_'), os.date('!%Y%m%dT%H%M%S'), dump.pid)
    local fd, err = io.open(path, 'w')
    if not fd then -- (say so: a dump that silently failed reads as "no dump was needed")
        io.stderr:write(('\n⚠ FLAKE DUMP (%s) NOT WRITTEN: %s\n'):format(tag, tostring(err)))
        return nil
    end
    fd:write('return ', vim.inspect(dump), '\n'); fd:close()
    io.stderr:write(('\n⚠ FLAKE DUMP (%s): %s\n'):format(tag, path))
    return path
end

-- load every spec — or only $SPEC (comma list of basenames: the
-- preflight's test-selection hook; the full suite still guards the push)
local only
do
    local sel = vim.env.SPEC
    if sel and sel ~= '' then
        only = {}
        for n in sel:gmatch('[^,]+') do only[n] = true end
    end
end
-- COMMON SETUP, once for every unit this file loads (hoisted by cartograph: redundancy.lua, 247 copies removed)
do
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
end
-- ── COVER_EARLY: the coverage hook, installed before any spec loads ───────────
-- `COVER=<file>` (CART-0990) records every (source, line) under lua/cartograph/ the suite executes. `COVER_SPEC=1`
-- (the mutation campaign) keys each line by the SPEC that executed it — load time included, which is why the hook goes
-- in before the loop: a spec's top-level fixture work (an extract at load) is that spec's coverage too.
-- ⚠ JIT OFF: LuaJIT does not call hooks from compiled traces, so a hot loop would execute lines the hook never sees
-- — a coverage map with holes exactly where the code is busiest.
local cover, cover_spec
if vim.env.COVER and vim.env.COVER ~= '' then
    cover = {}
    if rawget(_G, 'jit') then jit.off(); jit.flush() end
    local by_spec = vim.env.COVER_SPEC == '1'
    debug.sethook(function (_, line)
        local i = debug.getinfo(2, 'S')
        local s = i and i.short_src
        if s and s:find('lua/cartograph/', 1, true) then
            local key = by_spec and ((cover_spec or '?') .. '\t' .. s) or s
            local t = cover[key]
            if not t then t = {}; cover[key] = t end
            t[line] = true
        end
    end, 'l')
end
for _, f in ipairs(vim.fn.glob('tests/*_spec.lua', false, true)) do
    if not only or only[f:match('([^/]+)%.lua$')] then
        cover_spec = f:match('([^/]+)%.lua$')
        -- A LOAD-TIME FAILURE MUST EXIT, NOT ESCAPE. Both paths below used to raise out of
        -- run.lua's main chunk — and an error there means `vim.cmd('qall!')` at the bottom
        -- is NEVER REACHED, so headless nvim prints a traceback and then sits in the event
        -- loop FOREVER. run.sh's `set -euo pipefail` cannot catch it: the process never
        -- exits, so there is no exit code to test. The suite stops failing and starts
        -- HANGING — which also hangs the pre-commit hook that runs it.
        -- MEASURED, twice: a broken `require` in cloneextract_spec left a headless nvim
        -- idle in do_epoll_wait for ~3h, and an older one for 6 DAYS. The same incident
        -- also bought a wrong diagnosis — the suite was read as "slow" for 500s when it
        -- had in fact already died. A hang is the worst shape a gate can fail in, because
        -- it is indistinguishable from slow work.
        current_spec = f:match('([^/]+)%.lua$')
        local chunk, lerr = loadfile(f)
        if not chunk then
            print(('\nLOAD ERROR — cannot compile %s:\n  %s'):format(f, tostring(lerr)))
            vim.cmd('cquit 1')
        end
        local l0 = vim.uv.hrtime()
        local okc, cerr = pcall(chunk)
        -- a spec's LOAD time (top-level fixture work) is time too: TIMES reports it as the spec's `(load)` row
        load_ms[current_spec] = (vim.uv.hrtime() - l0) / 1e6
        if not okc then
            print(('\nLOAD ERROR — %s raised while loading:\n  %s')
                :format(f, tostring(cerr):gsub('\n', '\n  ')))
            vim.cmd('cquit 1')
        end
    end
end

-- ── OPT-IN LINE COVERAGE (CART-0990) ───────────────────────────────────────
-- `COVER=<file>` records every (source, line) the suite executes and writes them there.
-- Opt-in and off by default for the same reason `SPEC` is: this is a measurement hook,
-- and a line hook costs real time on every line of every test.
-- ⚠ IT RECORDS ONLY `lua/cartograph/**`. The hook fires for every line in the process —
-- the spec files, the harness, nvim's own runtime — and the census only ever asks about
-- our engine, so filtering in the handler keeps the table small and the join honest.
-- (the hook itself is installed BEFORE the specs load — see COVER_EARLY above — so a spec's top-level fixture work counts)

-- ── OPT-IN TIMINGS ──────────────────────────────────────────────────────────
-- `TIMES=<file>` records each test's wall time as `ms<TAB>spec<TAB>status<TAB>name` there (TIMES_QUIET=1: no printed summary) and prints the slowest specs and
-- tests at the end. Opt-in like COVER: the default output is what the fences and hooks read.
local times = vim.env.TIMES and vim.env.TIMES ~= '' and {} or nil

local pass, fail, skipped, pending = 0, 0, 0, 0
print('')
for _, t in ipairs(reg) do
    cover_spec = t.spec
    _G.__run_log[#_G.__run_log + 1] = (t.spec or '?') .. ' :: ' .. t.name -- (flake_dump's ran_before)
    local t0 = times and vim.uv.hrtime()
    local good, err = pcall(t.fn)
    if times then
        times[#times + 1] = { ms = (vim.uv.hrtime() - t0) / 1e6, spec = t.spec or '?', name = t.name,
            status = good and 'ok' or type(err) == 'table' and (err.__pending and 'pend' or err.__skip and 'skip') or 'FAIL' }
    end
    if good then
        pass = pass + 1
        print('  ok    ' .. t.name)
    elseif type(err) == 'table' and err.__pending then
        pending = pending + 1
        print('  PEND  ' .. t.name .. (err.msg and ('  (' .. err.msg .. ')') or ''))
    elseif type(err) == 'table' and err.__skip then
        skipped = skipped + 1
        print('  skip  ' .. t.name .. (err.msg and ('  (' .. err.msg .. ')') or ''))
    else
        fail = fail + 1
        print('  FAIL  ' .. t.name)
        print('        ' .. tostring(err):gsub('\n', '\n        '))
    end
end
if cover then
    debug.sethook()
    local out = {}
    for key, lines in pairs(cover) do
        local spec, src = key:match('^(.-)\t(.*)$')
        src = src or key
        local rel = src:match('lua/cartograph/.*$') or src
        for line in pairs(lines) do out[#out + 1] = (spec and (spec .. '\t') or '') .. rel .. ':' .. line end
    end
    table.sort(out)
    local fd = io.open(vim.env.COVER, 'w')
    if fd then fd:write(table.concat(out, '\n')); fd:close() end
    print(('coverage: %d executed line(s) under lua/cartograph/'):format(#out))
end

if times then
    local lines, by_spec, total = {}, {}, 0
    for s, ms in pairs(load_ms) do if ms >= 1 then times[#times + 1] = { ms = ms, spec = s, name = '(load)' } end end
    for _, r in ipairs(times) do
        lines[#lines + 1] = ('%.1f\t%s\t%s\t%s'):format(r.ms, r.spec, r.status or 'load', r.name)
        by_spec[r.spec] = (by_spec[r.spec] or 0) + r.ms
        total = total + r.ms
    end
    local fd = io.open(vim.env.TIMES, 'w')
    if fd then fd:write(table.concat(lines, '\n'), '\n'); fd:close() end
    local specs = {}
    for s, ms in pairs(by_spec) do specs[#specs + 1] = { s = s, ms = ms } end
    table.sort(specs, function (a, b) return a.ms > b.ms end)
    table.sort(times, function (a, b) return a.ms > b.ms end)
    if vim.env.TIMES_QUIET == '1' then goto quiet end
    io.write(('\ntimings: %d test(s), %.0f s in tests (written to %s)\n  slowest specs:\n'):format(#times, total / 1e3, vim.env.TIMES))
    for i = 1, math.min(10, #specs) do io.write(('    %7.1f s  %5.1f%%  %s\n'):format(specs[i].ms / 1e3, 100 * specs[i].ms / total, specs[i].s)) end
    io.write('  slowest tests:\n')
    for i = 1, math.min(10, #times) do io.write(('    %7.1f s  %s: %s\n'):format(times[i].ms / 1e3, times[i].spec, times[i].name:sub(1, 90))) end
    ::quiet::
end

print(('\n%d passed, %d failed, %d skipped%s\n'):format(pass, fail, skipped,
    pending > 0 and (', %d PENDING REVIEW'):format(pending) or ''))

-- ⚠ PENDING DOES NOT FAIL THE RUN. A generated case awaiting review is not a broken
-- tree, and gating on it would make the suite unusable the moment anything is generated.
-- It is loud in the output and counted in the summary; the fence that keeps unreviewed
-- cases out of the push is that they live outside `tests/*_spec.lua` until promoted.
if fail > 0 then vim.cmd('cquit 1') else vim.cmd('qall!') end
