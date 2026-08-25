-- Minimal dependency-free test runner. Run via tests/run.sh (nvim --headless).
-- Specs are tests/*_spec.lua and use the globals defined here: test/eq/ok/skip.

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

-- shared fixture writer: `write(root, name, lines)` writes a table of lines to a file.
-- Was copy-pasted byte-identically across ~10 spec files; hoisted here (a spec that needs
-- a different `write` still declares its own local, which shadows this). A specfile-local
-- `write` always wins — this only fills in for specs that had the identical copy.
function _G.write(root, name, lines)
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
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

local pass, fail, skipped = 0, 0, 0
print('')
for _, t in ipairs(reg) do
    local good, err = pcall(t.fn)
    if good then
        pass = pass + 1
        print('  ok    ' .. t.name)
    elseif type(err) == 'table' and err.__skip then
        skipped = skipped + 1
        print('  skip  ' .. t.name .. (err.msg and ('  (' .. err.msg .. ')') or ''))
    else
        fail = fail + 1
        print('  FAIL  ' .. t.name)
        print('        ' .. tostring(err):gsub('\n', '\n        '))
    end
end
print(('\n%d passed, %d failed, %d skipped\n'):format(pass, fail, skipped))

if fail > 0 then vim.cmd('cquit 1') else vim.cmd('qall!') end
