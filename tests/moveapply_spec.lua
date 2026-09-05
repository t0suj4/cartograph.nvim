-- moveapply / extract-module: the founding write verb. Focus here = the
-- MODULE-LEVEL VARIABLE extension (constants move, function-locals don't) — the
-- capability the spec-module extraction needs ([[cartograph-spec-layering]]).

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local moveapply = require 'cartograph.moveapply'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

-- write a whole tree (rel -> text), ingest it, return the store
local function ingest_files(files)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local dir = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(dir, 'p') end
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text); fd:close()
    end
    store.ingest(ts.extract(root))
    return store
end

-- write a lua source, ingest it, return the store's node table
local function ingest(src)
    return ingest_files({ ['m.lua'] = src })
end

local FIXTURE = table.concat({
    'local CFG = {',        -- a module-level constant (multi-line table)
    "    kind = 'demo',",
    '    limit = 3,',
    '}',
    '',
    'local function helper(x)',
    '    local scratch = x + CFG.limit', -- function-local var; references CFG
    '    return scratch',
    'end',
    '',
    'return { helper = helper }', -- CFG is NOT re-exported: private to helper
}, '\n')

local function node_by(st, name, kind)
    for _, n in ipairs(st.data.nodes) do
        if n.name == name and (not kind or n.kind == kind) then return n end
    end
end

test('moveapply: a MODULE-LEVEL constant is extractable', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local cfg = node_by(st, 'CFG', 'var')
    ok(cfg, 'CFG captured as a var node')
    local plan, err = moveapply.plan_extract_ids(st, { cfg.id }, 'sub/cfg.lua')
    ok(plan, 'plan built (not refused): ' .. tostring(err))
    -- the const's full declaration is in the move-set
    local moved
    for _, m in ipairs(plan and plan.moves or {}) do
        if m.name == 'CFG' then moved = m end
    end
    ok(moved, 'CFG is in the move-set')
    ok(moved and moved.lines.e >= moved.lines.s + 3,
        'the multi-line table range travels whole (>=4 lines)')
end)

test('moveapply: a function-local variable is REFUSED', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local scratch = node_by(st, 'scratch', 'var')
    if not scratch then
        skip('function-local vars are not minted as nodes (guard is defensive)')
    end
    local plan, err = moveapply.plan_extract_ids(st, { scratch.id }, 'sub/x.lua')
    ok(not plan, 'refused')
    ok(err and err:find('function%-local'), 'refusal names the reason: ' .. tostring(err))
end)

test('moveapply: functions still move (regression)', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    ok(helper, 'helper captured')
    local plan = moveapply.plan_extract_ids(st, { helper.id }, 'sub/h.lua')
    ok(plan and #plan.moves >= 1, 'function extract-module still plans')
end)

test('moveapply: close_moveset pulls in a PRIVATE captured constant, ordered', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    local cfg = node_by(st, 'CFG', 'var')
    local set = moveapply.close_moveset(st, { helper.id }, 'sub/m.lua')
    local has = {}
    for _, id in ipairs(set) do has[id] = true end
    ok(has[cfg.id], 'CFG (private, read only by helper) was pulled into the set')
    -- ordered by source line: CFG (line 1) precedes helper (line ~6)
    eq(cfg.id, set[1])
end)

test('moveapply: plan lays moves out in SOURCE order', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    local cfg = node_by(st, 'CFG', 'var')
    -- pass helper BEFORE cfg; the plan must still order them by source line
    local plan = moveapply.plan_extract_ids(st, { helper.id, cfg.id }, 'sub/m.lua')
    eq('CFG', plan.moves[1].name)   -- line 1
    eq('helper', plan.moves[2].name) -- line ~6
end)

test('moveapply: COPY leaves the original + discloses duplication', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    local cfg = node_by(st, 'CFG', 'var')
    local plan = moveapply.plan_extract_ids(st, { helper.id, cfg.id }, 'sub/m.lua',
        { copy = { [cfg.id] = true } })
    local cfgmove
    for _, m in ipairs(plan.moves) do if m.name == 'CFG' then cfgmove = m end end
    eq('copy', cfgmove.mode)
    eq('move', (function () for _, m in ipairs(plan.moves) do if m.name == 'helper' then return m.mode end end end)())
    local dup = false
    for _, h in ipairs(plan.hazards) do if h:find('CFG is COPIED') then dup = true end end
    ok(dup, 'duplication disclosed')
end)

-- ── THE MODULE SCAFFOLD (CART-0542) ──────────────────────────────────────────
-- The witness is EXECUTION, not parsing: `function M.scan(x)` with no `local M`
-- COMPILES (M is a global at compile time) and only dies when the module is
-- first required. A parse-only assertion passes with and without the scaffold,
-- which is exactly why the hazard went unenforced.

local MODFIXTURE = table.concat({
    'local M = {}',
    '',
    'local function tiny(x) return x + 1 end',
    '',
    '-- doc for scan',
    'function M.scan(x)',
    '    return tiny(x) + 1',
    'end',
    '',
    'function M.stays(y)',
    '    return M.scan(y)',
    'end',
    '',
    'return M',
}, '\n')

-- the same file, except the moved body reaches a member that STAYS behind
local RESIDUAL = MODFIXTURE
    :gsub('    return tiny%(x%) %+ 1', '    return M.stays(x) + 1')

local function dest_text(st, plan)
    local _, after = require('cartograph.txn').dryrun(st, plan)
    return after and after[plan.dest]
end

local function haz(plan, pat)
    for _, h in ipairs(plan.hazards) do if h:find(pat) then return h end end
end

test('moveapply: an extracted module LOADS — scaffold written, not disclosed', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(MODFIXTURE)
    local scan = node_by(st, 'M.scan', 'function')
    ok(scan, 'M.scan captured')
    local plan, err = moveapply.plan_extract_ids(st, { scan.id }, 'sub/new.lua')
    ok(plan, 'plan built: ' .. tostring(err))
    local text = dest_text(st, plan)
    ok(text, 'dry-run produced the created file')
    -- THE WITNESS: run the chunk, the way `require` would
    local chunk, lerr = load(text, 'sub/new.lua')
    ok(chunk, 'the created module compiles: ' .. tostring(lerr))
    local okrun, mod = pcall(chunk)
    ok(okrun, 'the created module RUNS (this is what failed): ' .. tostring(mod))
    eq('table', type(mod))
    eq('function', type(okrun and mod.scan))
    -- and the shape is the idiom, not an accident
    eq('local M = {}', vim.split(text, '\n', { plain = true })[1])
    ok(text:find('\nreturn M\n'), 'the epilogue is written: ' .. text)
    -- the capture hazard is RETIRED: its instruction ("require it, or copy it")
    -- would alias the OLD module's table, which is now the wrong table
    ok(not haz(plan, '^capture: M%f[%W]'),
        'the M capture is written, so it is no longer disclosed')
end)

test('moveapply: a member left BEHIND stays disclosed (the scaffold is not a lie)', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(RESIDUAL)
    local scan = node_by(st, 'M.scan', 'function')
    local plan = moveapply.plan_extract_ids(st, { scan.id }, 'sub/new.lua')
    ok(plan and plan.scaffold, 'scaffold still written (the file must load)')
    local text = dest_text(st, plan)
    ok(select(1, pcall(load(text, 'd'))), 'and it does load')
    local h = haz(plan, 'M%.stays')
    ok(h, 'the residual member is named: ' .. table.concat(plan.hazards, ' | '))
    ok(h and h:find('created FRESH'), 'and it says WHY the reference is now dead')
end)

test('moveapply: a file with NO module idiom gets no guessed prologue', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE) -- `return { helper = helper }` — not the idiom
    local helper = node_by(st, 'helper', 'function')
    local plan = moveapply.plan_extract_ids(st, { helper.id }, 'sub/h.lua')
    ok(plan, 'plan built')
    eq(nil, plan.scaffold)
    local text = dest_text(st, plan)
    ok(not text:find('local M = {}'), 'nothing invented: ' .. text)
end)

test('moveapply: module_table reads the idiom, and refuses anything else', function ()
    if not ready() then skip('no lua parser') end
    local lines = vim.split(MODFIXTURE, '\n', { plain = true })
    eq('M', ts.module_table('m.lua', lines))
    eq(nil, ts.module_table('m.lua', vim.split(FIXTURE, '\n', { plain = true })))
    -- a language that declares no idiom writes nothing (absence = NOT DECLARED)
    eq(nil, ts.module_table('m.py', lines))
    eq(nil, ts.module_scaffold('m.py', 'M'))
end)

-- ── THE TWO REFUSALS (CART-0576) ─────────────────────────────────────────────
-- apply's last rung compares the LIVE move-set against the plan and used to
-- refuse with ONE string for two opposite situations: "you never staged" (fix
-- your call sequence, zero risk) and "the set moved under you" (STOP, re-plan).
-- These specs pin that they now render differently, and that the guarantee still
-- fires for the real changed-set case — including through the new entry point.

local function refusal(st, plan)
    local okay, why = moveapply.apply(st, plan)
    ok(not okay, 'apply refused')
    return tostring(why)
end

test('moveapply: NOTHING STAGED and a CHANGED move-set refuse differently', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    st.clear_stage()
    local helper = node_by(st, 'helper', 'function')
    local plan, perr = moveapply.plan_extract_ids(st, { helper.id }, 'sub/h.lua')
    ok(plan, 'plan built: ' .. tostring(perr))

    -- (1) the naive-agent sequence: plan, then apply, never staging
    local empty = refusal(st, plan)
    ok(empty:find('nothing is staged', 1, true),
        'names the missing premise: ' .. empty)
    ok(not empty:find('changed since planning', 1, true),
        'and is NOT the world-moved refusal: ' .. empty)
    ok(empty:find('plan_moveset', 1, true), 'names the repair: ' .. empty)

    -- (2) the real thing the rung guards: a move-set that is not the plan's.
    -- Same SIZE as the plan (1 symbol) — so this is the identity check firing,
    -- not a count check.
    local cfg = node_by(st, 'CFG', 'var')
    st.stage(cfg.id)
    local changed = refusal(st, plan)
    eq(1, #plan.moves)
    ok(changed:find('changed since planning', 1, true),
        'names the world-moved premise: ' .. changed)
    ok(not changed:find('nothing is staged', 1, true),
        'and is NOT the never-staged refusal: ' .. changed)
    ok(changed:find('CFG', 1, true), 'names what differs: ' .. changed)
    ok(changed:find('helper', 1, true), 'both sides of the difference: ' .. changed)
    st.clear_stage()
end)

test('moveapply: plan_moveset stages what it plans — apply, headless, no boilerplate', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local journal = require 'cartograph.journal'
    journal.wipe(st.data.root)
    local helper = node_by(st, 'helper', 'function')
    local plan, why = moveapply.plan_moveset(st, { helper.id }, 'sub/h.lua')
    ok(plan, 'planned: ' .. tostring(why))
    eq('extract-module', plan.verb) -- dest does not exist yet
    -- the closure came along (CFG is helper's private capture) AND is staged
    eq(2, #plan.moves)
    eq(#plan.moves, #st.staged_ids())
    -- THE POINT: apply's rung passes with no staging calls in the caller
    local entry, aerr = moveapply.apply(st, plan)
    ok(entry, 'applied: ' .. tostring(aerr))
    local fd = io.open(st.data.root .. '/sub/h.lua', 'r')
    ok(fd, 'the new module was written')
    local text = fd and fd:read('a') or ''
    if fd then fd:close() end
    ok(text:find('function helper', 1, true), 'and it holds the moved text: ' .. text)
    eq(0, #st.staged_ids()) -- the move-set was consumed
    journal.wipe(st.data.root)
end)

test('moveapply: plan_moveset still refuses when the set genuinely changed', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    local plan, why = moveapply.plan_moveset(st, { helper.id }, 'sub/h.lua')
    ok(plan, 'planned: ' .. tostring(why))
    -- the world moves under the plan: someone unstages one of its symbols
    st.unstage(plan.moves[1].id)
    local changed = refusal(st, plan)
    ok(changed:find('changed since planning', 1, true),
        'the guarantee is intact through the new entry point: ' .. changed)
    ok(not changed:find('nothing is staged', 1, true), changed)
    ok(not io.open(st.data.root .. '/sub/h.lua', 'r'), 'and nothing was written')
    st.clear_stage()
end)

test('moveapply: plan_moveset dispatches on the destination, and says which verb', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest_files({ ['m.lua'] = FIXTURE, ['dest.lua'] = 'local d = 1\n' })
    local helper = node_by(st, 'helper', 'function')
    local plan, why = moveapply.plan_moveset(st, { helper.id }, 'dest.lua')
    ok(plan, 'planned: ' .. tostring(why))
    eq('move', plan.verb) -- the file exists: this is a MOVE, not an extract
    eq(#plan.moves, #st.staged_ids())
    -- and the extract-only option is refused rather than silently dropped
    local nope, cerr = moveapply.plan_moveset(st, { helper.id }, 'dest.lua',
        { copy = { [helper.id] = true } })
    ok(not nope, 'copy into an existing file refused')
    ok(cerr and cerr:find('extract%-module option'), tostring(cerr))
    st.clear_stage()
end)

test('moveapply: plan_moveset leaves no half-built move-set behind a refusal', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local scratch = node_by(st, 'scratch', 'var')
    local seed = scratch and scratch.id or node_by(st, 'helper', 'function').id
    -- a destination the extract verb refuses outright (escaping the root).
    -- CART-0577 moved this refusal EARLIER — containment is now checked before
    -- disk_stamp and before clear_stage, so nothing is half-built because nothing
    -- is built at all. The message moved with it: one rule (txn.contained), one
    -- spelling, instead of the inline `plain path` test this used to hit.
    local plan, why = moveapply.plan_moveset(st, { seed }, '../outside.lua')
    ok(not plan, 'refused')
    ok(why and why:find('escapes the project root'), tostring(why))
    eq(0, #st.staged_ids()) -- the staging was rolled back with it
    eq(nil, st.dest)
end)

-- ── CART-0577: containment on BOTH planning paths, not just one ─────────────
-- plan_extract_ids always refused an escaping path; M.plan (MOVE) never did, so a
-- dest of `../x.lua` planned and applied OUTSIDE the project, creating parent dirs
-- on the way. Interactively `dest` came from pressing `p` on a file row and could
-- only be inside the tree — the guarantee belonged to the UI, and making the verb
-- agent-drivable removed it. These fence the rule, not one caller's spelling of it.

test('txn.contained: absolute and .. SEGMENTS are refused, a legal name is not', function ()
    local txn = require 'cartograph.txn'
    ok(txn.contained('lua/cartograph/x.lua'), 'an ordinary relative path')
    ok(not txn.contained('/etc/passwd'), 'absolute')
    ok(not txn.contained('../x.lua'), 'leading ..')
    ok(not txn.contained('a/../../x.lua'), 'a .. in the middle still escapes')
    ok(not txn.contained(''), 'empty')
    -- ★ a `..` SEGMENT, not the substring. The old inline test matched `%.%.`
    -- anywhere and so refused this, which is a refusal with no premise behind it.
    ok(txn.contained('a..b.lua'), 'a legal filename containing dots escapes nothing')
    ok(txn.contained('dir/a..b.lua'), 'same, nested')
end)

test('CART-0577: the MOVE path refuses a destination outside the project', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local id
    for _, n in ipairs(st.data.nodes) do
        if n.name == 'helper' then id = n.id break end
    end
    ok(id, 'fixture has helper')
    st.clear_stage(); st.stage(id)
    -- a MOVE (the dest must be readable), aimed outside the root
    st.set_dest('../escape.lua')
    local plan, why = moveapply.plan(st)
    ok(not plan, 'the move must not plan')
    ok(why and why:match('escapes the project root'),
        'and it must say WHY, not "cannot read": got ' .. tostring(why))
    st.clear_stage()
end)

test('CART-0577: plan_moveset refuses before it touches the staged set', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local id
    for _, n in ipairs(st.data.nodes) do
        if n.name == 'helper' then id = n.id break end
    end
    -- something the caller staged BEFORE asking for a bad plan
    st.clear_stage(); st.stage(id)
    local plan, why = moveapply.plan_moveset(st, { id }, '../nope.lua')
    ok(not plan, 'refused')
    ok(why and why:match('escapes the project root'), 'with the reason: ' .. tostring(why))
    -- ★ A REFUSAL MUST NOT COST THE CALLER THEIR STAGING. This one is refused
    -- early (containment is checked before plan_moveset touches anything), and
    -- CART-0583 made the LATE refusals restore too — the test below fences that
    -- half, which used to `clear_stage()` and silently charge the caller.
    eq(1, #st.staged_ids(), 'the staged set survived THIS refusal')
    st.clear_stage()
end)

test('CART-0577: txn.execute refuses an escaping plan before the journal opens', function ()
    if not ready() then skip('no lua parser') end
    local txn = require 'cartograph.txn'
    local st = ingest(FIXTURE)
    -- the backstop: a plan built by any future caller that skipped the planner
    local plan = { verb = 'move', generation = st.generation, dest = '../out.lua',
        moves = {}, hazards = {}, stamps = {}, touched = { '../out.lua' } }
    local okx, why = txn.execute(st, plan, 'test', function () return '' end)
    ok(not okx, 'execute refuses')
    ok(why and why:match('outside the project'), 'and says so: ' .. tostring(why))
    -- nothing may have been written, and no journal entry may exist for it
    ok(vim.fn.filereadable(st.data.root .. '/../out.lua') == 0, 'no file was written')
end)

-- ── CART-0583: staging is ARMING, and a refusal restores what it borrowed ───

test('CART-0583: a LATE refusal restores the caller\'s move-set, it does not clear it', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    local cfg = node_by(st, 'CFG', 'var')
    ok(helper and cfg, 'fixture has both')
    -- the caller had something staged, and a destination set, BEFORE asking
    st.clear_stage(); st.stage(cfg.id); st.set_dest('m.lua')
    -- ★ THE REFUSAL MUST BE REACHED *AFTER* STAGING, or this test proves nothing.
    -- My first version used the copy-into-existing refusal, which returns BEFORE
    -- the staging block — it passed against the old clear-on-failure code. The
    -- unknown-extension refusal lives inside plan_extract_ids, so staging has
    -- already happened by the time it fires, which is the path being fenced.
    local plan, why = moveapply.plan_moveset(st, { helper.id }, 'sub/new.nope')
    ok(not plan, 'refused')
    ok(why and why:find('no language spec'), tostring(why))
    -- the caller's set and dest come back, rather than being cleared to nothing
    eq(1, #st.staged_ids(), 'the prior move-set is RESTORED, not cleared')
    eq(cfg.id, st.staged_ids()[1], 'and it is the caller\'s symbol, not the seed')
    eq('m.lua', st.dest, 'the prior destination comes back too')
    st.clear_stage()
end)

test('CART-0583: arm=false plans without touching the move-set, and still previews', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(FIXTURE)
    local helper = node_by(st, 'helper', 'function')
    local cfg = node_by(st, 'CFG', 'var')
    st.clear_stage(); st.stage(cfg.id); st.set_dest('m.lua')
    -- an UNARMED plan: what a read-only host asks for. Apply is unreachable there,
    -- so arming would only cost a cockpit user their staged set.
    local plan, why = moveapply.plan_moveset(st, { helper.id }, 'sub/new.lua', { arm = false })
    ok(plan, tostring(why))
    eq(1, #st.staged_ids(), 'the live move-set was never touched')
    eq(cfg.id, st.staged_ids()[1])
    eq('m.lua', st.dest, 'nor was the destination')
    -- and it is a real plan: preview reads the PLAN, never the staged set
    local before, after, pwhy = moveapply.preview(st, plan)
    ok(before, tostring(pwhy))
    ok(after, 'an unarmed plan still diffs')
    st.clear_stage()
end)

-- ── CART-0770: a move lifts the definition, not its container ────────────────
-- The `var` branch above has always refused a function-local variable as
-- "lexically scoped, and lifting it to another file is meaningless (and
-- unsound)". A FUNCTION or METHOD got no such check, so its text was lifted out
-- of whatever it sat inside and appended at the destination's TOP LEVEL.
-- MEASURED before the fix: 369 broken plans over three corpora — 12 on our own
-- tree, 84 on desynced, 273 on grocy — every one of them a file that no longer
-- parses, and nothing refused.

local function php_ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'php')
end

-- ★★ THE REGRESSION THAT MATTERS MOST, AND IT IS WHY THE PREDICATE IS SYNTACTIC.
-- `function M.foo()` is a member of M SEMANTICALLY and a top-level statement
-- SYNTACTICALLY. A first cut refusing "a method is a member of its type" refused
-- 129 of 216 working moves on desynced — the verb's commonest legitimate use.
test('moveapply: a top-level `function M.foo()` STILL MOVES (the syntactic/semantic split)', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest_files({ ['m.lua'] = table.concat({
        'local M = {}',
        'function M.foo(x)',
        '    return x + 1',
        'end',
        'return M',
    }, '\n') })
    local foo = node_by(st, 'M.foo') or node_by(st, 'foo')
    ok(foo, 'M.foo captured')
    local plan, err = moveapply.plan_extract_ids(st, { foo.id }, 'sub/f.lua')
    ok(plan, 'a top-level definition moves, whatever its NAME says: ' .. tostring(err))
end)

-- the lua half of the defect: `color = function ... end,` inside a table
-- constructor, moved with its trailing comma
test('moveapply: a function inside a TABLE CONSTRUCTOR is refused, naming the container', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest_files({ ['m.lua'] = table.concat({
        'local filters = {',
        '    color = function (def) return def.tag end,',
        '    world = function (def) return def.w end,',
        '}',
        'return filters',
    }, '\n') })
    local color = node_by(st, 'color') or node_by(st, 'filters.color')
    if not color then skip('table-field functions are not minted as nodes here') end
    local plan, err = moveapply.plan_extract_ids(st, { color.id }, 'sub/c.lua')
    ok(not plan, 'refused')
    ok(err and err:find('table_constructor'),
        'and NAMES the container rather than saying it is inside something: ' .. tostring(err))
end)

-- a NESTED function: parses fine after a move and loses its upvalues, which is
-- exactly the unsoundness the `var` branch already refuses. A parses-clean
-- oracle cannot see it, which is why the measured "cost" of this guard is an
-- over-estimate.
test('moveapply: a NESTED function is refused, like a function-local var', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest_files({ ['m.lua'] = table.concat({
        'local function outer(a)',
        '    local function inner(b)',
        '        return a + b',
        '    end',
        '    return inner(1)',
        'end',
        'return outer',
    }, '\n') })
    local inner = node_by(st, 'inner', 'function')
    if not inner then skip('nested functions are not minted as nodes here') end
    local plan, err = moveapply.plan_extract_ids(st, { inner.id }, 'sub/i.lua')
    ok(not plan, 'refused')
    ok(err and err:find('not at module level'), tostring(err))
end)

-- ★ THE PHP HALF, hand-read from grocy: `BaseApiController::ApiResponse` moved
-- into another file landed AFTER the class's closing brace, and a
-- `protected function` at php top level does not parse. 273 of grocy's 300
-- sampled plans were this.
test('moveapply: a php CLASS METHOD is refused, naming the class declaration', function ()
    if not php_ready() then skip('no php parser') end
    local st = ingest_files({
        ['a.php'] = '<?php\nclass A\n{\n\tprotected function helper($x)\n\t{\n\t\treturn $x;\n\t}\n}\n',
        ['b.php'] = '<?php\nclass B\n{\n}\n',
    })
    local m = node_by(st, 'A::helper', 'method')
    if not m then skip('php method node not captured in this environment') end
    local plan, err = moveapply.plan_ids(st, { m.id }, 'b.php')
    ok(not plan, 'refused')
    ok(err and err:find('class_declaration'),
        'and names the class body it sits in: ' .. tostring(err))
end)
