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

function _G.test(name, fn) reg[#reg + 1] = { name = name, fn = fn } end

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
for _, f in ipairs(vim.fn.glob('tests/*_spec.lua', false, true)) do
    if not only or only[f:match('([^/]+)%.lua$')] then
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
        local chunk, lerr = loadfile(f)
        if not chunk then
            print(('\nLOAD ERROR — cannot compile %s:\n  %s'):format(f, tostring(lerr)))
            vim.cmd('cquit 1')
        end
        local okc, cerr = pcall(chunk)
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
local cover
if vim.env.COVER and vim.env.COVER ~= '' then
    cover = {}
    debug.sethook(function (_, line)
        local i = debug.getinfo(2, 'S')
        local s = i and i.short_src
        if s and s:find('lua/cartograph/', 1, true) then
            local t = cover[s]
            if not t then t = {}; cover[s] = t end
            t[line] = true
        end
    end, 'l')
end

local pass, fail, skipped, pending = 0, 0, 0, 0
print('')
for _, t in ipairs(reg) do
    local good, err = pcall(t.fn)
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
    for src, lines in pairs(cover) do
        local rel = src:match('lua/cartograph/.*$') or src
        for line in pairs(lines) do out[#out + 1] = rel .. ':' .. line end
    end
    table.sort(out)
    local fd = io.open(vim.env.COVER, 'w')
    if fd then fd:write(table.concat(out, '\n')); fd:close() end
    print(('coverage: %d executed line(s) under lua/cartograph/'):format(#out))
end

print(('\n%d passed, %d failed, %d skipped%s\n'):format(pass, fail, skipped,
    pending > 0 and (', %d PENDING REVIEW'):format(pending) or ''))

-- ⚠ PENDING DOES NOT FAIL THE RUN. A generated case awaiting review is not a broken
-- tree, and gating on it would make the suite unusable the moment anything is generated.
-- It is loud in the output and counted in the summary; the fence that keeps unreviewed
-- cases out of the push is that they live outside `tests/*_spec.lua` until promoted.
if fail > 0 then vim.cmd('cquit 1') else vim.cmd('qall!') end
