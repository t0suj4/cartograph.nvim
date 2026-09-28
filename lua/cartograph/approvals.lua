-- cartograph.approvals — SIGNED APPROVALS THAT TRAVEL (CART-1183, collaboration pieces 1+2: PRINCIPALS and ROUTING).
--
-- A tactic stops only on a decision; the local user answers it with the term's `accept` list or a REMEMBERED decision
-- (cartograph.decisions). A teammate answers it with a TOKEN: the question's PORTABLE identity plus `accept`, signed by
-- the principal's ssh key (`ssh-keygen -Y sign -n cartograph-decision`). The token may sit in ANY store — a directory,
-- the analysed tree itself, a git note — because its AUTHORITY is the signature checked against the USER's roster, not
-- the place it was found. That is how "the tree selects, never supplies" survives collaboration: a token found in the
-- tree is a claim, and the user's roster + policy decide whether it answers anything.
--
--   THE ROSTER    M.roster_path: an ssh `allowed_signers` file in the USER's state dir (principal -> public key). Never
--                 read from the analysed tree. No roster = no signed answer is ever accepted.
--   ROUTING       config.at(subject, 'deciders') = { [kind] = { 'alice@team', 'role:reviewers', … } } and
--                 config.at(subject, 'roles') = { reviewers = { … } }: WHO may answer WHICH KIND of decision about
--                 WHICH files (policy over views, CART-1160 step 6). A plan is covered only when EVERY subject's policy
--                 authorizes the signer. Default: no policy -> no signed answer (today's behaviour).
--   PORTABLE KEY  the local decision key hashes absolute paths (subjects, targets), so a teammate's checkout at another
--                 path asks a DIFFERENT question — a valid token would never match, and the stop would read as a
--                 correct refusal. The portable key names each world by its DERIVED identity (git origin + the prefix
--                 inside the repo) and rewrites every path under a known world root to it. A world with no origin has no
--                 portable name: its questions cannot be answered from elsewhere, and the stop says so.
--   SIGNING       only tools/approvals.lua (the CLI, the user's key). No MCP verb and no tactic path signs: an agent that
--                 could sign could approve its own plans.
-- ⚠ NAMESPACE: the ssh signature binds `cartograph-decision`, so a git commit/tag signature (`-n git`) can never be
-- replayed as an approval (probed: "namespace does not match").
local M = {}

M.NS = 'cartograph-decision'
--- the user's roster (tests point it elsewhere)
M.roster_path = vim.fn.stdpath('state') .. '/cartograph/allowed_signers'

local function canon(v) return require('cartograph.decisions').canon(v) end

-- ── world identity ────────────────────────────────────────────────────────────────────────────────────────────────
local ids = {}
local function git(root, ...)
    local r = vim.system({ 'git', '-C', root, ... }, { text = true }):wait()
    return r.code == 0 and vim.trim(r.stdout or '') or nil
end

--- normalize a remote url: `git@host:a/b.git`, `ssh://git@host/a/b`, `https://host/a/b.git` -> `host/a/b`
local function norm_url(u)
    u = u:gsub('%.git$', ''):gsub('/+$', '')
    local host, path = u:match('^[%w+.-]+://[^@/]*@?([^/:]+)[:%d]*/(.*)$')
    if not host then host, path = u:match('^[^@/]+@([^:/]+):(.*)$') end
    if host then return host .. '/' .. path end
    return u
end

--- the PORTABLE name of the world rooted at `root`: `<origin>:<prefix>` | nil, why
function M.world_id(root)
    if ids[root] ~= nil then return ids[root] or nil, 'no git origin' end
    local url = vim.fn.isdirectory(root) == 1 and git(root, 'remote', 'get-url', 'origin') or nil
    if not url or url == '' then ids[root] = false; return nil, 'no git origin', 'frontier' end
    local prefix = (git(root, 'rev-parse', '--show-prefix') or ''):gsub('/+$', '')
    ids[root] = norm_url(url) .. ':' .. prefix
    return ids[root]
end

--- the question's identity as it reads from ANY checkout -> 'sha256:…' | nil, why
function M.portable_key(store, plan, h)
    local txn = require 'cartograph.txn'
    local own = store.data and store.data.root
    local target = txn.target_root(store, plan)
    local roots = {}
    for _, r in ipairs { target, own } do
        if r then
            local id, why = M.world_id(r)
            if not id then return nil, ('%s has no portable name (%s): its questions can only be answered here'):format(r, why), 'frontier' end
            roots[#roots + 1] = { root = r, id = id }
        end
    end
    -- the LONGEST root first: a target nested inside the graph's own root names its paths by the target
    table.sort(roots, function (a, b) return #a.root > #b.root end)
    local function rewrite(v)
        if type(v) == 'string' then
            for _, r in ipairs(roots) do
                if v == r.root then return '@' .. r.id end
                if v:sub(1, #r.root + 1) == r.root .. '/' then return '@' .. r.id .. '/' .. v:sub(#r.root + 2) end
            end
            return v
        elseif type(v) == 'table' then
            local o = {}
            for k, x in pairs(v) do o[k] = rewrite(x) end
            return o
        end
        return v
    end
    local subjects = {}
    for _, rel in ipairs(plan.touched or {}) do subjects[#subjects + 1] = rewrite(target .. '/' .. rel) end
    table.sort(subjects)
    local tgt = type(plan.target) == 'table' and plan.target.root and rewrite(plan.target.root) or nil
    return 'sha256:' .. vim.fn.sha256(canon {
        kind = h.kind, verb = plan.verb, evidence = rewrite(h.evidence), subjects = subjects, target = tgt })
end

-- ── tokens ────────────────────────────────────────────────────────────────────────────────────────────────────────
local function bytes(payload) return canon(payload) end

local function tmpfile(content)
    local p = vim.fn.tempname()
    local fd = assert(io.open(p, 'wb')); fd:write(content); fd:close()
    return p
end

--- SIGN an answer with the principal's private key (the CLI's door, never a run's) -> token | nil, why
--- payload = { key = portable key, kind, principal, why? }; `answer` is always accept and `at` is stamped here
function M.sign(payload, keyfile)
    if type(payload) ~= 'table' or type(payload.key) ~= 'string' or type(payload.kind) ~= 'string'
        or type(payload.principal) ~= 'string' then
        return nil, 'a token needs key, kind and principal', 'ill-posed'
    end
    local p = { v = 1, key = payload.key, kind = payload.kind, principal = payload.principal, answer = 'accept',
        why = payload.why, at = payload.at or os.date('!%Y-%m-%dT%H:%M:%SZ') }
    local msg = tmpfile(bytes(p))
    local r = vim.system({ 'ssh-keygen', '-q', '-Y', 'sign', '-f', keyfile, '-n', M.NS, msg }, { text = true }):wait()
    local fd = io.open(msg .. '.sig')
    local sig = fd and fd:read('a'); if fd then fd:close() end
    os.remove(msg); os.remove(msg .. '.sig')
    if r.code ~= 0 or not sig then return nil, 'ssh-keygen could not sign: ' .. vim.trim((r.stderr or '') .. (r.stdout or '')), 'environment' end
    return { payload = p, sig = sig }
end

--- the token's identity (a file name, a cache key)
function M.id(token) return vim.fn.sha256(bytes(token.payload) .. '\0' .. tostring(token.sig)):sub(1, 16) end

--- write a token into a directory store (idempotent: its name is its identity) -> path
function M.write(dir, token)
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. M.id(token) .. '.json'
    local fd = assert(io.open(path, 'w')); fd:write(vim.json.encode(token)); fd:close()
    return path
end

--- every token in a directory store (a file that is not a token is skipped, and counted) -> tokens, skipped
function M.load(dir)
    local out, skipped = {}, 0
    for _, name in ipairs(vim.fn.readdir(dir) or {}) do
        if name:match('%.json$') then
            local fd = io.open(dir .. '/' .. name)
            local ok, t = pcall(vim.json.decode, fd and fd:read('a') or '')
            if fd then fd:close() end
            if ok and type(t) == 'table' and type(t.payload) == 'table' and type(t.sig) == 'string' then
                t.file = dir .. '/' .. name; out[#out + 1] = t
            else skipped = skipped + 1 end
        end
    end
    return out, skipped
end

local verified = {}
--- is the signature the named principal's, over exactly these bytes, in the decision namespace? -> true | nil, why
function M.verify(token)
    local fd = io.open(M.roster_path)
    if not fd then return nil, 'no roster (' .. M.roster_path .. '): no signed answer is accepted', 'decision' end
    local roster = fd:read('a'); fd:close()
    local ck = M.id(token) .. vim.fn.sha256(roster)
    if verified[ck] ~= nil then return verified[ck] or nil, 'the signature does not verify' end
    local sig = tmpfile(token.sig)
    local r = vim.system({ 'ssh-keygen', '-Y', 'verify', '-f', M.roster_path, '-I', tostring(token.payload.principal),
        '-n', M.NS, '-s', sig }, { text = true, stdin = bytes(token.payload) }):wait()
    os.remove(sig)
    verified[ck] = r.code == 0
    if r.code ~= 0 then return nil, 'the signature does not verify for ' .. tostring(token.payload.principal), 'decision' end
    return true
end

-- ── routing ───────────────────────────────────────────────────────────────────────────────────────────────────────
--- may `principal` answer a `kind` decision about every one of `subjects` (absolute paths)? -> true | nil, why
function M.authorized(principal, kind, subjects)
    local config = require 'cartograph.config'
    if #subjects == 0 then return nil, 'the decision is about no file: no policy can route it', 'decision' end
    for _, s in ipairs(subjects) do
        local deciders, prov = config.at(s, 'deciders')
        if prov and prov.source == 'ambiguous' then return nil, ('the deciders policy for %s is ambiguous'):format(s), 'decision' end
        local list = type(deciders) == 'table' and deciders[kind] or nil
        if type(list) ~= 'table' then return nil, ('no deciders policy routes `%s` decisions about %s'):format(kind, s), 'decision' end
        local roles = config.at(s, 'roles') or {}
        local hit = false
        for _, d in ipairs(list) do
            if d == principal then hit = true; break end
            local role = type(d) == 'string' and d:match('^role:(.+)$')
            if role and type(roles[role]) == 'table' and vim.tbl_contains(roles[role], principal) then hit = true; break end
        end
        if not hit then
            return nil, ('%s may not answer `%s` decisions about %s (deciders: %s)'):format(principal, kind, s, table.concat(list, ', ')), 'decision'
        end
    end
    return true
end

--- the tokens as given to a run: a directory, a list of tokens, or a list of directories -> tokens
function M.gather(src)
    if type(src) == 'string' then return (M.load(src)) end
    local out = {}
    for _, x in ipairs(src or {}) do
        if type(x) == 'string' then vim.list_extend(out, (M.load(x))) else out[#out + 1] = x end
    end
    return out
end

--- does a signed token answer this decision? -> token | nil, { why per candidate token }
function M.lookup(tokens, pkey, kind, subjects)
    local refused = {}
    for _, t in ipairs(tokens or {}) do
        local p = t.payload
        if p.key == pkey and p.kind == kind and p.answer == 'accept' then
            local okv, vwhy = M.verify(t)
            if not okv then refused[#refused + 1] = vwhy
            else
                local oka, awhy = M.authorized(p.principal, kind, subjects)
                if oka then return t end
                refused[#refused + 1] = awhy
            end
        end
    end
    return nil, refused, 'decision'
end

return M