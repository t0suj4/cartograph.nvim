-- SIGNED APPROVALS THAT TRAVEL (CART-1183 pieces 1+2: principals + routing). A teammate answers a tactic's decision
-- with a token signed by their ssh key; it answers only when the signature verifies against the USER's roster AND the
-- deciders policy routes that kind, for every subject, to the signer. The oracles are the runs (stopped vs done, what
-- the disk holds) and the provenance: the residue and the journal entry name the principal and the token.
-- Keys are THROWAWAY (generated here); nothing reads ~/.ssh.
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local txn = require 'cartograph.txn'
local tactic = require 'cartograph.tactic'
local hazard = require 'cartograph.hazard'
local journal = require 'cartograph.journal'
local config = require 'cartograph.config'
local D = require 'cartograph.decisions'
local A = require 'cartograph.approvals'
local T = tactic.T

local function ready()
    return pcall(vim.treesitter.get_string_parser, '', 'lua') and vim.fn.executable('ssh-keygen') == 1 and vim.fn.executable('git') == 1
end

local function sh(root, ...) return vim.system({ 'git', '-C', root, ... }, { text = true }):wait() end
--- a git world with an origin (its PORTABLE name) — `origin = false` makes one with none
local function tree(files, origin)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, t in pairs(files) do
        local d = (root .. '/' .. rel):match('^(.*)/[^/]*$'); vim.fn.mkdir(d, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    sh(root, 'init', '-q')
    if origin ~= false then sh(root, 'remote', 'add', 'origin', origin or 'git@example.com:team/proj.git') end
    return root
end
local function disk(root, rel) local fd = io.open(root .. '/' .. rel); if not fd then return nil end; local s = fd:read('a'); fd:close(); return s end

-- the question's evidence names its file by ABSOLUTE path: the case a local key cannot carry to another checkout
local VERBS = {
    ask = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
        if (txn.read_file(store.data.root, a.file) or ''):find(a.line, 1, true) then return nil, 'already there', 'empty' end
        return txn.protocol({ verb = 'ask', guards = {}, refspecs = {}, touched = { a.file }, generation = store.generation,
            stamps = { [a.file] = txn.disk_stamp(store.data.root, a.file) }, desc = 'ask', preserves = 'none',
            hazards = { hazard.new(a.kind or 'approve', ('approve the change to %s'):format(a.file), nil,
                { path = store.data.root .. '/' .. a.file }, 'decision') } },
            function () return function (_, before) return before .. a.line .. '\n' end end)
    end },
}

local KEYS
local function keys()
    if KEYS then return KEYS end
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
    local function gen(name)
        vim.system({ 'ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', name, '-f', dir .. '/' .. name }):wait()
        local fd = assert(io.open(dir .. '/' .. name .. '.pub')); local pub = fd:read('a'); fd:close()
        return { key = dir .. '/' .. name, pub = pub:match('^(%S+ %S+)') }
    end
    KEYS = { dir = dir, alice = gen('alice'), mallory = gen('mallory') }
    return KEYS
end

--- run `fn` with the roster at `roster` (a list of principal -> key rows, or false = no roster file), `deciders`/`roles`
--- as the policy, and a fresh remembered-decisions file; everything restored after
local function with(o, fn)
    local k = keys()
    local saved = { roster = A.roster_path, dpath = D.path, deciders = config.deciders, roles = config.roles }
    A.roster_path = vim.fn.tempname() .. '-allowed_signers'
    if o.roster ~= false then
        local fd = assert(io.open(A.roster_path, 'w'))
        for _, r in ipairs(o.roster or { { 'alice@team', 'alice' }, { 'mallory@team', 'mallory' } }) do
            fd:write(('%s namespaces="%s" %s\n'):format(r[1], A.NS, k[r[2]].pub))
        end
        fd:close()
    end
    D.path = vim.fn.tempname() .. '-decisions.json'
    config.deciders = o.deciders == nil and { approve = { 'alice@team' } } or o.deciders or nil
    config.roles = o.roles
    local okr, err = pcall(fn, k)
    A.roster_path, D.path, config.deciders, config.roles = saved.roster, saved.dpath, saved.deciders, saved.roles
    if not okr then error(err, 0) end
end

local function run(term, o) o = o or {}; o.verbs = VERBS; if o.apply == nil then o.apply = true end; return tactic.run(store, term, o) end

--- stop on `term` in the loaded world and sign its question as `who` -> the stop's option, the token
local function stop_and_sign(term, who, k, principal)
    local r = run(term)
    eq('stopped', r.status)
    local opt = r.options[1]
    ok(opt.portable_key, 'the stop names the PORTABLE key a teammate signs: ' .. tostring(opt.portable_why))
    local tok = assert(A.sign({ key = opt.portable_key, kind = opt.kind, principal = principal or (who .. '@team'), why = 'looks right' }, k[who].key))
    return opt, tok
end

test('approvals: a token signed against ONE checkout answers the same question in ANOTHER at a different path — and the journal names the principal', function ()
    if not ready() then skip 'no lua parser / ssh-keygen / git' end
    with({}, function (k)
        local files = { ['a.lua'] = 'local a = 1\nreturn a\n' }
        local r1, r2 = tree(files), tree(files)
        local term = T.step('ask', { file = 'a.lua', line = '-- one' })
        store.ingest(ts.extract(r1))
        local opt1, tok = stop_and_sign(term, 'alice', k)
        local dir = vim.fn.tempname()
        A.write(dir, tok)
        store.ingest(ts.extract(r2))
        local stop2 = run(term)
        eq('stopped', stop2.status, 'no approvals given: the question stops as before')
        local opt2 = stop2.options[1]
        ok(opt1.key ~= opt2.key, 'the premise: the LOCAL keys differ across checkouts (they hash absolute paths)')
        eq(opt1.portable_key, opt2.portable_key, 'the portable key is the same question from either checkout')
        local done = run(term, { approvals = dir })
        eq('done', done.status, vim.inspect(done.trace))
        eq('local a = 1\nreturn a\n-- one\n', disk(r2, 'a.lua'))
        local cited
        for _, h in ipairs(done.residue) do if h.signed then cited = h end end
        ok(cited and cited.signed.principal == 'alice@team' and cited.text:find('approved by alice@team', 1, true), vim.inspect(done.residue))
        local e = journal.last(r2)
        eq('signed', e.decisions[1].by); eq('alice@team', e.decisions[1].principal); eq(A.id(tok), e.decisions[1].token)
    end)
end)

test('approvals: a token answers only ITS question — another file, another kind, another world stop as before', function ()
    if not ready() then skip 'no lua parser / ssh-keygen / git' end
    with({ deciders = { approve = { 'alice@team' }, other = { 'alice@team' } } }, function (k)
        local root = tree { ['a.lua'] = 'local a = 1\nreturn a\n', ['b.lua'] = 'local b = 1\nreturn b\n' }
        store.ingest(ts.extract(root))
        local _, tok = stop_and_sign(T.step('ask', { file = 'a.lua', line = '-- one' }), 'alice', k)
        eq('stopped', run(T.step('ask', { file = 'b.lua', line = '-- one' }), { approvals = { tok } }).status, 'another file')
        eq('stopped', run(T.step('ask', { file = 'a.lua', line = '-- one', kind = 'other' }), { approvals = { tok } }).status, 'another kind')
        local fork = tree({ ['a.lua'] = 'local a = 1\nreturn a\n' }, 'git@example.com:someone-else/proj.git')
        store.ingest(ts.extract(fork))
        eq('stopped', run(T.step('ask', { file = 'a.lua', line = '-- one' }), { approvals = { tok } }).status, 'another world (origin)')
        store.ingest(ts.extract(root))
        eq('done', run(T.step('ask', { file = 'a.lua', line = '-- one' }), { approvals = { tok } }).status, 'its own question')
    end)
end)

test('approvals: ROUTING — a valid signature from a principal the policy does not route this kind to stops, BY NAME; a role routes', function ()
    if not ready() then skip 'no lua parser / ssh-keygen / git' end
    local term = T.step('ask', { file = 'a.lua', line = '-- one' })
    with({}, function (k)
        store.ingest(ts.extract(tree { ['a.lua'] = 'local a = 1\nreturn a\n' }))
        local _, tok = stop_and_sign(term, 'mallory', k)
        local r = run(term, { approvals = { tok } })
        eq('stopped', r.status)
        local why = table.concat(r.options[1].refused_approvals or {}, ' | ')
        ok(why:find('mallory@team may not answer `approve`', 1, true), why)
    end)
    with({ deciders = false }, function (k)
        store.ingest(ts.extract(tree { ['a.lua'] = 'local a = 1\nreturn a\n' }))
        local _, tok = stop_and_sign(term, 'alice', k)
        local r = run(term, { approvals = { tok } })
        eq('stopped', r.status, 'no deciders policy: no signed answer (the default)')
        ok(table.concat(r.options[1].refused_approvals or {}, ''):find('no deciders policy', 1, true), vim.inspect(r.options[1]))
    end)
    with({ deciders = { approve = { 'role:reviewers' } }, roles = { reviewers = { 'alice@team' } } }, function (k)
        store.ingest(ts.extract(tree { ['a.lua'] = 'local a = 1\nreturn a\n' }))
        local _, tok = stop_and_sign(term, 'alice', k)
        eq('done', run(term, { approvals = { tok } }).status, 'alice holds the role the policy routes to')
    end)
    with({ deciders = { approve = { 'role:reviewers' } }, roles = { reviewers = { 'bob@team' } } }, function (k)
        store.ingest(ts.extract(tree { ['a.lua'] = 'local a = 1\nreturn a\n' }))
        local _, tok = stop_and_sign(term, 'alice', k)
        local r = run(term, { approvals = { tok } })
        eq('stopped', r.status, 'the role exists, and alice is not in it')
        ok(table.concat(r.options[1].refused_approvals or {}, ''):find('role:reviewers', 1, true), vim.inspect(r.options[1]))
    end)
    -- two most-specific scopes that DISAGREE about the deciders: never guessed, and said as such
    with({ deciders = false }, function (k)
        local root = tree { ['a.lua'] = 'local a = 1\nreturn a\n' }
        local saved = config.scoped
        config.scoped = { [root] = { deciders = { approve = { 'alice@team' } } }, { dir = root, values = { deciders = { approve = { 'bob@team' } } } } }
        local okr, err = pcall(function ()
            store.ingest(ts.extract(root))
            local _, tok = stop_and_sign(term, 'alice', k)
            local r = run(term, { approvals = { tok } })
            eq('stopped', r.status)
            ok(table.concat(r.options[1].refused_approvals or {}, ''):find('ambiguous', 1, true), vim.inspect(r.options[1]))
        end)
        config.scoped = saved
        if not okr then error(err, 0) end
    end)
    -- a token whose payload names ANOTHER kind is not an answer to this one, even over this question's key
    with({ deciders = { approve = { 'alice@team' }, other = { 'alice@team' } } }, function (k)
        store.ingest(ts.extract(tree { ['a.lua'] = 'local a = 1\nreturn a\n' }))
        local opt = run(term).options[1]
        local tok = assert(A.sign({ key = opt.portable_key, kind = 'other', principal = 'alice@team' }, k.alice.key))
        eq('stopped', run(term, { approvals = { tok } }).status)
    end)
end)

test('approvals: a TAMPERED payload, a principal claimed with ANOTHER key, a git-namespace signature, and no roster all refuse', function ()
    if not ready() then skip 'no lua parser / ssh-keygen / git' end
    local term = T.step('ask', { file = 'a.lua', line = '-- one' })
    local function refused(r) return table.concat(r.options and r.options[1].refused_approvals or {}, ' | ') end
    with({}, function (k)
        local root = tree { ['a.lua'] = 'local a = 1\nreturn a\n' }
        store.ingest(ts.extract(root))
        local opt, tok = stop_and_sign(term, 'alice', k)
        -- tampered: the reason changed after signing
        local t2 = vim.deepcopy(tok); t2.payload.why = 'something else'
        local r = run(term, { approvals = { t2 } })
        eq('stopped', r.status); ok(refused(r):find('does not verify', 1, true), refused(r))
        -- mallory's key claiming to be alice
        local forged = assert(A.sign({ key = opt.portable_key, kind = opt.kind, principal = 'alice@team' }, k.mallory.key))
        r = run(term, { approvals = { forged } })
        eq('stopped', r.status); ok(refused(r):find('does not verify for alice@team', 1, true), refused(r))
        -- alice's key, the right bytes, but the GIT namespace: a commit signature is never an approval
        local msg = vim.fn.tempname()
        local fd = assert(io.open(msg, 'wb')); fd:write(D.canon(tok.payload)); fd:close()
        vim.system({ 'ssh-keygen', '-q', '-Y', 'sign', '-f', k.alice.key, '-n', 'git', msg }):wait()
        fd = assert(io.open(msg .. '.sig')); local gsig = fd:read('a'); fd:close()
        r = run(term, { approvals = { { payload = tok.payload, sig = gsig } } })
        eq('stopped', r.status); ok(refused(r):find('does not verify', 1, true), refused(r))
        eq('done', run(term, { approvals = { tok } }).status, 'the untouched token answers (the refusals were the guards)')
    end)
    with({ roster = false }, function (k)
        -- a roster PLANTED in the analysed tree is not the user's roster: nothing verifies
        local root = tree { ['a.lua'] = 'local a = 1\nreturn a\n' }
        local fd = assert(io.open(root .. '/allowed_signers', 'w'))
        fd:write(('alice@team namespaces="%s" %s\n'):format(A.NS, k.alice.pub)); fd:close()
        store.ingest(ts.extract(root))
        local _, tok = stop_and_sign(term, 'alice', k)
        local r = run(term, { approvals = { tok } })
        eq('stopped', r.status); ok(refused(r):find('no roster', 1, true), refused(r))
    end)
end)

test('approvals: a world with NO portable name cannot be answered from elsewhere — the stop says so instead of a key', function ()
    if not ready() then skip 'no lua parser / ssh-keygen / git' end
    with({}, function ()
        store.ingest(ts.extract(tree({ ['a.lua'] = 'local a = 1\nreturn a\n' }, false)))
        local r = run(T.step('ask', { file = 'a.lua', line = '-- one' }))
        eq('stopped', r.status)
        eq(nil, r.options[1].portable_key)
        ok((r.options[1].portable_why or ''):find('no portable name', 1, true), vim.inspect(r.options[1]))
    end)
end)
