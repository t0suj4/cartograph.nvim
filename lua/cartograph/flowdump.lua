-- FLOWDUMP (CART-1710): flowtype's program in the language-neutral core IR, with its solution — the input of the
-- flowpath Lean checker (~/work/flowpath/lean: FLOW C.1 reads it, C.2 checks the solution CLOSED against the program,
-- C.4 checks the answers against the solution). Decision 1 of the flowpath plan: check flowtype's OUTPUTS, not its
-- algorithm; decision 3: cartograph translates, unverified — translation completeness is the conformance suite's job
-- (T4), not the checker's.
--
-- HOW: `flowtype.solve(store, { dump = true })` (or `dump = '<path>'`) rebinds flowtype's primitives to recorders for
-- the WALK only: a primitive called by the walker is an instruction (addobj -> new, edge -> copy, field -> load,
-- storec -> store, callc -> call, metacall -> op); what a primitive does inside itself, and everything the solver
-- derives, is not. Builtins with a core opcode are translated explicitly (pcall, setmetatable, the coroutine
-- library, error / assert); builtins without one are GAPS. The solve runs without
-- per-site instances and without contexts (`ctx = false`): their ports are in no function's body, and the context
-- layer is FLOW C.3. The answers in the dump are that run's.
--
-- FORMAT 1 (CORE.md §5, with these decisions — revisable with the reader):
--   { format = 1, lang = 'lua', ver = 51, cartograph = <sha|nil>, corpus = { root, sha }, mode = 'closed', instances = false,
--   (cartograph: the PRODUCER's commit — the repo flowtype.lua is in; corpus.sha: the analysed tree's own commit, null
--   when its root is not a repository's top level)
--     names = { fields = [...], functions = [...] },
--     sites = [ { id, kind, label, fn } ... ],
--     functions = [ { id, params = [var...], self = var, body = [ins...], tags = [ [index, tag] ... ] } ... ],
--     solution = { v, top, h, hdyn, htop, htaint, err = { fn, cerr }, weak, rin, rout, rin_top?, rout_top?, cerr_top?,
--                  ctx = nil, live = nil,
--                  taint = { ports, seeds } },
--     gaps = [ { fn, kind, vars, at } ... ], answers = [ { call = [file, line, col], kind, targets, partial, contracts,
--       ins = [fn, index] | null — the CALL instruction the answer is about: index is 0-based in that function's dumped
--       body; null when the walk emitted none (CART-1725, flowpath C.4) } ... ] }
-- * FIELD IDS are the Lua instance's where it names them: 100 the metatable slot (flowtype's hidden `\1mt`), 101
--   `__index`, 102 `__newindex`, 103 `__call`, 105 `__gc`, 106 `__mode`; 104 and 107..109 are never emitted (evStoreLook
--   and the ghosts). Every other field name is interned at 0..99, then 110 on; names.fields[id + 1] is its name (JSON
--   null where unused). An operator's `k` is its metatable key's field id (`__add` ...).
-- * `[]` (a store under an unknown key) is not a field: `hdyn` [site, [sites]] means A.h site f b for EVERY f (the core's
--   storeDyn). A named load reads it (Lua: `t[k] = v` may write `t.name`).
-- * RAW accesses (FLOW-0090, the core's D16): `storeRaw` [x, f, y] is a table constructor's named field (no
--   __newindex); `loadRaw` [x, y, k | null] reads any field of the object ITSELF, with no __index and no prototype:
--   pairs' value (k null) and rawget(t, k) with a variable key (CART-1758). A constructor's computed key `[e] = v`
--   stays a storeDyn: the core has no raw dynamic store.
-- * SITES are flowtype's objects: `table`, `function` (fn = its function id: P.fnOf), `type` (a value the environment
--   profile types — a host value; `type:string` is the strings), `ext` (code outside the tree: EXT), `globals` (_G),
--   A `type` or `ext` site is a HOST value. A `type` site carries `host` = its KIND, from the environment profile
--   (CART-1761): `prim` (a store raises: string, number, a function type), `members` (its declared members only:
--   userdata such as TSNode; by default every non-primitive host type), `open` (an ordinary object, as the profile
--   declares: a WoW frame). A prim / members site, and
--   `ext`, has no fields in `h` (contract:host): a store to it is not followed, a load from it is its declared type
--   (the answers' `typed` / `string`), not a heap read. An open site's fields are in `h` as a table's are.
--   `thread`, `proxy`, `other`. label: flowtype's own name for it.
-- * VARIABLES are flowtype's ports; `self` (the closure object itself) is synthesized per function, holding every site
--   of that function. `v` is grouped: [var, [sites...]]; a var in `top` SATURATED (past CAP): any site — the taint
--   carries what it lost. Only variables the IR names are listed. `htop` [site, field] a field past CAP; `htaint`
--   [site, field | null] a field the taint reached (null: `[]`) — closedness is required except at tainted ports.
--   `taint.escaped` [sites] the ESCAPED objects (a saturated port's, a lost store's value, unknown code's), and
--   `taint.fields_hit` [field | null]: a store of that field through a tainted base reached it on every escaped object —
--   each cell (escaped site, hit field) is TAINTED, whether or not it has a port (CART-1744).
--   `hkeys` [site, [sites]]: flowtype's KEY SET of a table (what `pairs` yields as keys) — no core field; a load of it
--   is a gap (`table-keys`).
-- * Errors are PER FUNCTION (Core/Errors.lean, FLOW C.E): err.fn [fn, [sites]] is `E.port fn` (err.top: a port past
--   CAP — any site; err.taint: a port the taint reached); a file chunk's port is
--   module-level code's (one, shared by every chunk); err.cerr the coroutine channel. `error(y)` is emitted where code
--   raises; a call's port-to-port flow is the call's own constraint (EEntry), never a copy.
-- * TAGS name an instruction's known divergence from the core, so a checker failure there is named, not noise:
--   `contract:strict-global` (a global read does not see a dynamic-key `_G[k] = v` — flowtype's header, CART-1707),
--   `divergence:coroutine` (flowtype binds a resume's arguments to that coroutine's function only; the core's `rin` is
--   one channel). (Since CART-1689 / 1715 a call's callee is the callee expression's flow, never the name join's
--   claim: no call is synthesized.)
-- * GAPS: constructs with no core opcode, or modelled outside the IR — rawget / rawset, getfenv / setfenv,
--   hooksecurefunc, getmetatable, newproxy, coroutine.wrap, xpcall's handler, unknown code (load ... : the `ext`
--   sites and the EXTCALL call in `init`). `weak`: every site a store that MAY set __mode reaches — a named __mode store,
--   or any dynamic-key store (k may be "__mode"), or a saturated or TAINTED such field (CART-1723, CART-1756); weak
--   semantics (what the collector may drop) are not modelled beyond naming them. `rin_top` / `rout_top` / `cerr_top`
--   (present as 1, else absent): that coroutine channel is saturated or tainted, so it holds any escaped value
--   (CART-1757).
local M = {}

-- (the assumptions a whole answer rests on that the core does not state — flowtype's header, THE CONTRACT; a checker
-- exempts a constraint only by one of these names)
M.CONTRACTS = {
    ['C1'] = 'open mode: outside code does not replace FUNCTION members of what it can reach from the exports (it may write their data fields — modelled, O2)',
    ['C3'] = 'open mode: outside code does not set metatables on what it can reach, nor write their handlers',
    ['C2'] = 'open mode: outside code does not patch the string library or the host API methods',
    ['outside-raises-strings'] = 'a function outside the tree raises strings (pcall second values)',
    ['host'] = 'a host site of kind prim or members (sites[i].host, from the environment profile) has no fields: a store to it is not followed, a load from it is its declared type; an open host site is an ordinary object',
    ['strict-global'] = 'a named global read does not see a dynamic-key write `_G[k] = v` (tag contract:strict-global)',
    ['computed-global'] = 'a read `_G[k]` with k unknown, or next / pairs over _G, sees dynamic-key writes and EXT, not the named globals',
    ['globals-never-escape'] = 'the globals site never escapes: a write through a cap-cut value that may be _G is not followed',
    ['unknown-receiver'] = 'a call on a member of an ext value runs no tree code and hands its arguments nowhere; a call whose callee the flow cannot resolve runs nothing',
    ['unknown-code'] = 'a call whose callee holds an ext site hands its arguments to the unknown-code channel (contracts.ext_channel), which calls the functions among them with ext',
    ['function-no-metatable'] = 'a function has no metatable of its own (setmetatable raises): a setmeta on a closure site writes nothing (the core\'s setmeta writes any reference)',
    ['hidden-fields'] = 'a dynamic key never reads or writes the metatable slot (Lua; the core\'s loadDyn / storeDyn range over it)',
}

local RESERVED = { ['\1mt'] = 100, __index = 101, __newindex = 102, __call = 103, __gc = 105, __mode = 106 }

function M.recorder()
    local R = { fns = {}, forder = {}, tags = {}, gaps = {}, objvar = {}, errp = {}, rerr = {} }
    -- (the current function's instruction list: a function's own id, a file chunk's `chunk:<file>`)
    function R.list(key)
        local l = R.fns[key]
        if not l then l = {}; R.fns[key] = l; R.forder[#R.forder + 1] = key end
        return l
    end
    function R.ins(key, ins, tag)
        local l = R.list(key)
        l[#l + 1] = ins
        if tag then local t = R.tags[key]; if not t then t = {}; R.tags[key] = t end; t[#t + 1] = { #l - 1, tag } end
    end
    function R.gap(key, kind, vars, at) R.gaps[#R.gaps + 1] = { fn = key, kind = kind, vars = vars or {}, at = at } end
    return R
end

--- the git HEAD of `dir`'s repository, or nil; `own`: only when dir IS that repository's top level (a snapshot without
--- .git inside another repo is not that repo's commit — CART-1721)
function M.head(dir, own)
    if type(dir) ~= 'string' or dir == '' then return nil end
    if own then
        local top = vim.fn.systemlist({ 'git', '-C', dir, 'rev-parse', '--show-toplevel' })[1]
        if vim.v.shell_error ~= 0 or vim.fn.resolve(vim.fn.fnamemodify(top, ':p')) ~= vim.fn.resolve(vim.fn.fnamemodify(dir, ':p')) then return nil end
    end
    local sha = vim.fn.systemlist({ 'git', '-C', dir, 'rev-parse', 'HEAD' })[1]
    return vim.v.shell_error == 0 and sha or nil
end

-- ── the writer: JSON by hand (the dump of a large tree is tens of MB; vim.json.encode of one table doubles it) ──
-- (a string is written as JSON text, which must be UTF-8: a byte string that is not — a Latin-1 "N\xfake" in a WoW
-- addon's table, CART-1735 — is read as LATIN-1, each byte >= 0x80 the code point U+00XX: lossless, and the Lean reader's
-- own fallback. ASCII and valid UTF-8 pass as they are)
local function utf8_ok(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len = c < 0x80 and 1 or (c >= 0xC2 and c <= 0xDF) and 2 or (c >= 0xE0 and c <= 0xEF) and 3 or (c >= 0xF0 and c <= 0xF4) and 4 or nil
        if not len then return false end
        for k = i + 1, i + len - 1 do
            local b = s:byte(k)
            if not b or b < 0x80 or b > 0xBF then return false end
        end
        i = i + len
    end
    return true
end
local function jstr(s)
    if type(s) == 'string' and s:find('[\128-\255]') and not utf8_ok(s) then
        s = s:gsub('[\128-\255]', function (ch)
            local b = ch:byte()
            return string.char(0xC0 + math.floor(b / 64), 0x80 + b % 64)
        end)
    end
    return vim.json.encode(s)
end
M._jstr = jstr
local function jarr(t)
    local o = {}
    for i, x in ipairs(t) do o[i] = type(x) == 'number' and tostring(x) or (type(x) == 'string' and jstr(x)) or (type(x) == 'table' and jarr(x)) or 'null' end
    return '[' .. table.concat(o, ',') .. ']'
end

--- X: the solve's internals (flowtype passes them): N, each, top, tainted, tfrom, obinfo, fnports, ofield, okeys, TNAME,
--- GOBJ, GPORT, EXT, GERR, GYIELD, GRESARG, FENVP, EXTCALL, XA, verdicts, calls, callrec, sha
function M.build(rec, X)
    local out = {}
    local function put(s) out[#out + 1] = s end
    -- field ids
    local fid, fnames, nextf = {}, {}, 0
    for nm, id in pairs(RESERVED) do fid[nm] = id; fnames[id] = nm == '\1mt' and '<meta>' or nm end
    local function F(nm)
        local id = fid[nm]
        if id then return id end
        if nextf == 100 then nextf = 110 end
        id = nextf; nextf = nextf + 1
        fid[nm] = id; fnames[id] = nm
        return id
    end
    -- function ids: every function with code first, then names an answer or a site mentions
    local fnid, fnlist = {}, {}
    local function FN(name)
        local id = fnid[name]
        if id then return id end
        id = #fnlist; fnlist[#fnlist + 1] = name; fnid[name] = id
        return id
    end
    -- functions: flowtype's (not an instance), each file chunk, and `init`
    local byname = {}
    for o, fp in pairs(X.fnports) do if not fp.inst and fp.id and not byname[fp.id] then byname[fp.id] = fp end end
    local sitesof = {} -- function name -> its sites
    for o, fp in pairs(X.fnports) do
        if fp.id then local l = sitesof[fp.id]; if not l then l = {}; sitesof[fp.id] = l end; l[#l + 1] = o end
    end
    -- variables
    local nextv = X.N
    local function newvar() nextv = nextv + 1; return nextv end
    local used = {}
    local function V(p) if p then used[p] = true end; return p end
    -- init: what the solve itself starts with
    local init = { { 'new', V(X.GPORT), X.GOBJ } }
    if X.FENVP then init[#init + 1] = { 'new', V(X.FENVP), X.GOBJ } end
    -- (every further PROGRAM's globals table, CART-1737: its port and its getfenv port hold it)
    local ISG = { [X.GOBJ] = true }
    for i, e in ipairs(X.ENVL or {}) do
        if i > 1 then
            ISG[e.GOBJ] = true
            init[#init + 1] = { 'new', V(e.GPORT), e.GOBJ }
            if e.FENVP then init[#init + 1] = { 'new', V(e.FENVP), e.GOBJ } end
        end
    end
    if X.XA then
        init[#init + 1] = { 'new', V(X.XA), X.EXT }
        init[#init + 1] = { 'call', { V(X.XRES) }, V(X.EXTCALL), { X.XA, X.XA, X.XA, X.XA } }
    end
    local inittags = { { #init - 1, 'gap:unknown-code' } }
    -- instruction operands to JSON, naming every variable they use
    local function vars(l) for _, p in ipairs(l) do V(p) end; return l end
    local function enc(ins)
        local op = ins[1]
        if op == 'new' then return { 'new', V(ins[2]), ins[3] }
        elseif op == 'copy' then return { 'copy', V(ins[2]), V(ins[3]) }
        elseif op == 'load' then
            if ins[4] == '[]' then return { 'loadDyn', V(ins[2]), V(ins[3]), ins[5] and V(ins[5]) or vim.NIL } end
            return { 'load', V(ins[2]), V(ins[3]), F(ins[4]) }
        elseif op == 'store' then
            if ins[3] == '[]' then return { 'storeDyn', V(ins[2]), ins[5] and V(ins[5]) or vim.NIL, V(ins[4]) } end
            return { 'store', V(ins[2]), F(ins[3]), V(ins[4]) }
        elseif op == 'call' or op == 'pcall' then
            return { op, vars(ins[2]), V(ins[3]), vars(ins[4]) }
        elseif op == 'keys' then return { 'keys', V(ins[2]), V(ins[3]) }
        -- (RAW accesses, FLOW-0090: a constructor's field, pairs' / next's value)
        elseif op == 'storeRaw' then return { 'storeRaw', V(ins[2]), F(ins[3]), V(ins[4]) }
        elseif op == 'loadRaw' then return { 'loadRaw', V(ins[2]), V(ins[3]), ins[4] and V(ins[4]) or vim.NIL }
        elseif op == 'error' then return { 'error', V(ins[2]) }
        elseif op == 'op' then return { 'op', V(ins[2]), vars(ins[3]), F(ins[4]) }
        elseif op == 'setmeta' then return { 'setmeta', V(ins[2]), V(ins[3]) }
        elseif op == 'cocreate' then return { 'cocreate', V(ins[2]), ins[3], V(ins[4]) }
        elseif op == 'resume' then return { 'resume', vars(ins[2]), V(ins[3]), vars(ins[4]) }
        elseif op == 'yield' then return { 'yield', vars(ins[2]), vars(ins[3]) }
        end
        return nil
    end
    -- functions
    local fjson = {}
    local function emitfn(name, params, self, body, tags)
        fjson[#fjson + 1] = ('{"id":%d,"params":%s,"self":%d,"body":%s,"tags":%s}'):format(FN(name), jarr(vars(params)),
            V(self), jarr(body), jarr(tags))
    end
    local keys = {}
    for _, k in ipairs(rec.forder) do keys[#keys + 1] = k end
    for name in pairs(byname) do if not rec.fns[name] then keys[#keys + 1] = name end end
    table.sort(keys)
    local maps = {} -- (a function's recorder index -> its DUMPED body index: what an answer's `ins` names, CART-1725)
    for _, name in ipairs(keys) do
        local body, tags, map = {}, {}, {}
        maps[name] = map
        for i, ins in ipairs(rec.fns[name] or {}) do
            local e = enc(ins)
            if e then body[#body + 1] = e; map[i - 1] = #body - 1 end
        end
        for _, t in ipairs(rec.tags[name] or {}) do if map[t[1]] then tags[#tags + 1] = { map[t[1]], t[2] } end end
        -- (a store / setmeta through a SATURATED base: the solve follows it into no object, and the escape rule covers
        -- every object such a base may hold but _G, which never escapes — the contract, named so the checker can say
        -- so: AceLibrary's crawlReplace `setmetatable(t, getmetatable(t))` over every reachable table, CART-1736)
        if X.top then
            for i, ins in ipairs(rec.fns[name] or {}) do
                if (ins[1] == 'store' or ins[1] == 'setmeta') and X.top[ins[2]] and map[i - 1] then
                    tags[#tags + 1] = { map[i - 1], 'contract:globals-never-escape' }
                end
            end
        end
        -- (a NAMED load whose base may hold a globals table is a global read — strict there, as flowtype reads it:
        -- `local G = _G; G.q`, `_G[MAJOR]` with a constant key. The identifier read is tagged as it is recorded; this
        -- one only once the solution says what the base holds)
        do
            local tagged = {}
            for _, t in ipairs(tags) do tagged[t[1]] = true end
            for i, ins in ipairs(rec.fns[name] or {}) do
                local j = map[i - 1]
                if ins[1] == 'load' and ins[4] ~= '[]' and ins[4] ~= '{k}' and j and not tagged[j] and not X.top[ins[3]] then
                    for o in X.each(ins[3]) do if ISG[o] then tags[#tags + 1] = { j, 'contract:strict-global' }; tagged[j] = true; break end end
                end
            end
        end
        local fp = byname[name]
        local params = {}
        if fp then
            for i, p in ipairs(fp.params) do params[i] = p end
            if fp.vararg then params[#params + 1] = fp.vararg end
            body[#body + 1] = { 'ret', vars(fp.rets or { fp.ret }) }
        end
        local self = newvar()
        emitfn(name, params, self, body, tags)
        if fp then fp._dumpself = self end
        byname[name] = byname[name] or false
        sitesof[name] = sitesof[name] or {}
        rec._self = rec._self or {}
        rec._self[self] = sitesof[name]
    end
    local iself = newvar()
    rec._self[iself] = {}
    local ij = {}
    for i, ins in ipairs(init) do ij[i] = ins end
    emitfn('init', {}, iself, ij, inittags)
    -- sites
    local sj = {}
    for o = 1, X.NO do
        local info = tostring(X.obinfo[o])
        local kind, fn = 'other', 'null'
        if X.fnports[o] then kind = 'function'; fn = X.fnports[o].id and tostring(FN(X.fnports[o].id)) or 'null'
        elseif info:find('^tbl:') then kind = 'table'
        elseif X.TNAME[o] then kind = 'type'
        elseif o == X.EXT then kind = 'ext'
        elseif ISG[o] then kind = 'globals'
        elseif info:find('^thread:') then kind = 'thread'
        elseif info:find('^proxy') then kind = 'proxy' end
        -- (a HOST site carries its kind, the profile's — prim / open / members: the certificate's supplied premise, CART-1761)
        local hk = kind == 'type' and X.hostkind and X.hostkind(X.TNAME[o]) or nil
        sj[#sj + 1] = ('{"id":%d,"kind":"%s","label":%s,"fn":%s%s}'):format(o, kind, jstr(info), fn, hk and (',"host":"' .. hk .. '"') or '')
    end
    -- the solution
    local vj, topj = {}, {}
    local vlist = {}
    for p in pairs(used) do vlist[#vlist + 1] = p end
    table.sort(vlist)
    for _, p in ipairs(vlist) do
        if X.top[p] then topj[#topj + 1] = tostring(p)
        else
            local ss = rec._self[p]
            if not ss then ss = {}; for o in X.each(p) do ss[#ss + 1] = o end end
            if #ss > 0 then table.sort(ss); vj[#vj + 1] = '[' .. p .. ',' .. jarr(ss) .. ']' end
        end
    end
    local hj, hdj, htj, hxj, hkj = {}, {}, {}, {}, {}
    local weak = {} -- (the sites a store that may set __mode reaches, CART-1723)
    local hktop = {}
    for o = 1, X.NO do
        local m = X.ofield[o]
        if m and not (X.TNAME[o] and not (X.hostkind and X.hostkind(X.TNAME[o]) == 'open')) and o ~= X.EXT then
            for _, f in ipairs { '__mode', '[]' } do
                local fp = m[f]
                -- (saturated, or TAINTED — a dynamic store with a lost key may write "__mode": CART-1756)
                local held = fp and (X.top[fp] or X.tainted[fp])
                if fp and not held then for _ in X.each(fp) do held = true; break end end
                if held then weak[#weak + 1] = o; break end
            end
        end
        -- (a HOST value — a profile-typed one, EXT — has no fields in the analysed heap: a load from it is its declared
        -- type, what a walk stored on it is never read)
        if m and not (X.TNAME[o] and not (X.hostkind and X.hostkind(X.TNAME[o]) == 'open')) and o ~= X.EXT then
            for _, f in ipairs(X.okeys(o)) do
                local fp = m[f]
                local ss = {}
                if f == '{k}' then -- (flowtype's KEY SET of a table — what `pairs` yields as keys: not a field)
                    local ks = {}
                    for b in X.each(fp) do ks[#ks + 1] = b end
                    table.sort(ks)
                    if #ks > 0 then hkj[#hkj + 1] = ('[%d,%s]'):format(o, jarr(ks)) end
                    -- (a SATURATED key set: any key, CART-1739 — and a TAINTED one, a dynamic store with a lost key: under the
                    -- taint reading it may hold any key too; dumped as closed, the checker failed 182 vimruntime stores, CART-1752)
                    if X.top[fp] or X.tainted[fp] then hktop[#hktop + 1] = o end
                    goto nextf
                end
                if X.tainted[fp] then hxj[#hxj + 1] = ('[%d,%s]'):format(o, f == '[]' and 'null' or tostring(F(f))) end
                if X.top[fp] then
                    if f ~= '[]' then htj[#htj + 1] = ('[%d,%d]'):format(o, F(f)) end
                else
                    for b in X.each(fp) do ss[#ss + 1] = b end
                    if #ss > 0 then
                        table.sort(ss)
                        if f == '[]' then hdj[#hdj + 1] = ('[%d,%s]'):format(o, jarr(ss))
                        else hj[#hj + 1] = ('[%d,%d,%s]'):format(o, F(f), jarr(ss)) end
                    end
                end
                ::nextf::
            end
        end
    end
    local function sites(p) local ss = {}; if p then for o in X.each(p) do ss[#ss + 1] = o end end; table.sort(ss); return ss end
    local ej, etop, etaint = {}, {}, {}
    for _, name in ipairs(keys) do
        local fp = byname[name]
        local p = fp and fp.err or (name:find('^chunk:') and X.GERR) or nil
        if p and X.top[p] then etop[#etop + 1] = tostring(FN(name))
        else
            local ss = sites(p)
            if #ss > 0 then ej[#ej + 1] = ('[%d,%s]'):format(FN(name), jarr(ss)) end
        end
        if p and X.tainted[p] then etaint[#etaint + 1] = tostring(FN(name)) end
    end
    -- (init CALLS UNKNOWN CODE — the EXTCALL call — which may raise anything: its error port is tainted. Nothing
    -- catches an error leaving init, but unstated, it was the last E-reading failure on vimruntime and WoW, CART-1760)
    if X.XA then etaint[#etaint + 1] = tostring(FN('init')) end
    local cerr = {}
    -- (a coroutine CHANNEL that is saturated or TAINTED holds any escaped value: rin_top / rout_top / cerr_top. Dumped
    -- as site lists alone, every lost value passed to resume or yielded failed the channel checks, CART-1757)
    local function chtop(p) return p ~= nil and (X.top[p] or X.tainted[p]) and true or false end
    local cerrtop = false
    for _, p in ipairs(rec.rerr) do for o in X.each(p) do cerr[o] = true end; if chtop(p) then cerrtop = true end end
    local cl = {}
    for o in pairs(cerr) do cl[#cl + 1] = o end
    table.sort(cl)
    -- the taint and its seeds
    local tj, sdj = {}, {}
    for _, p in ipairs(vlist) do
        if X.tainted[p] then
            tj[#tj + 1] = tostring(p)
            local w = X.tfrom and X.tfrom[p]
            if type(w) == 'string' then sdj[#sdj + 1] = ('[%d,%s]'):format(p, jstr(w)) end
        end
    end
    -- answers
    local aj = {}
    for _, c in ipairs(X.calls) do
        local v = X.verdicts[c]
        if v then
            local tg = {}
            for _, t in ipairs(v.targets or {}) do tg[#tg + 1] = FN(tostring(t)) end
            local ia = X.insat and X.insat[c]
            local ci = ia and maps[ia[1]] and maps[ia[1]][ia[2]]
            aj[#aj + 1] = ('{"call":[%s,%d,%d],"kind":%s,"targets":%s,"partial":%s,"contracts":%s,"ins":%s}'):format(jstr(tostring(X.callrec.file(c))),
                X.callrec.line(c) or 0, c.at and X.at.sc(c.at) or 0, jstr(v.kind), jarr(tg), v.partial and 'true' or 'false', jarr(v.contracts or {}),
                ci and ('[%d,%d]'):format(FN(ia[1]), ci) or 'null')
        end
    end
    -- gaps
    local gj = {}
    for _, g in ipairs(rec.gaps) do
        gj[#gj + 1] = ('{"fn":%d,"kind":%s,"vars":%s,"at":%s}'):format(FN(g.fn), jstr(g.kind), jarr(g.vars), g.at and jstr(g.at) or 'null')
    end
    -- (the STORE RULE's reach, CART-1744: a store — or keyed copy — of `.f` through a tainted base taints field f of
    -- EVERY escaped object, the cells no port holds too: a cell nothing reads has no port, and htaint lists ports.
    -- vimruntime: 2,770 cells of the tables in Version's `[]`, written through `__newindex`, looked untainted)
    local escl, fhj = {}, {}
    for o in pairs(X.escaped or {}) do if type(o) == 'number' and not ISG[o] then escl[#escl + 1] = o end end
    table.sort(escl)
    -- (interned in NAME order: F numbers a field by first use, and pairs over these string keys varies by process —
    -- the dump's field table came out in another order on every run)
    local fhn = {}
    for f in pairs(X.fields_hit or {}) do fhn[#fhn + 1] = f end
    table.sort(fhn)
    for _, f in ipairs(fhn) do fhj[#fhj + 1] = f == '[]' and 'null' or tostring(F(f)) end
    table.sort(fhj)
    -- names (last: everything above interned)
    local fields = {}
    local maxf = 0
    for id in pairs(fnames) do if id > maxf then maxf = id end end
    for id = 0, maxf do fields[id + 1] = fnames[id] and jstr(fnames[id]) or 'null' end
    local fns = {}
    for i, n in ipairs(fnlist) do fns[i] = jstr(n) end
    put(('{"format":1,"lang":"lua","ver":51,"cartograph":%s,"corpus":{"root":%s,"sha":%s},"mode":"closed","instances":false,'):format(
        X.sha and jstr(X.sha) or 'null', type(X.corpus) == 'string' and jstr(X.corpus) or 'null', X.corpus_sha and jstr(X.corpus_sha) or 'null'))
    put('"names":{"fields":[' .. table.concat(fields, ',') .. '],"functions":[' .. table.concat(fns, ',') .. ']},')
    put('"sites":[' .. table.concat(sj, ',') .. '],')
    put('"functions":[' .. table.concat(fjson, ',') .. '],')
    put('"solution":{"v":[' .. table.concat(vj, ',') .. '],"top":[' .. table.concat(topj, ',') .. '],"h":[' .. table.concat(hj, ',')
        .. '],"hdyn":[' .. table.concat(hdj, ',') .. '],"htop":[' .. table.concat(htj, ',') .. '],"htaint":[' .. table.concat(hxj, ',') .. '],"hkeys":[' .. table.concat(hkj, ',') .. '],"hkeystop":' .. jarr(hktop) .. ',"err":{"fn":[' .. table.concat(ej, ',')
        .. '],"top":[' .. table.concat(etop, ',') .. '],"taint":[' .. table.concat(etaint, ',') .. '],"cerr":' .. jarr(cl)
        .. '},"weak":' .. jarr(weak) .. ',"rin":' .. jarr(sites(X.GRESARG)) .. ',"rout":' .. jarr(sites(X.GYIELD))
        .. (chtop(X.GRESARG) and ',"rin_top":1' or '') .. (chtop(X.GYIELD) and ',"rout_top":1' or '') .. (cerrtop and ',"cerr_top":1' or '')
        .. ',"ctx":null,"live":null,"taint":{"ports":[' .. table.concat(tj, ',') .. '],"seeds":[' .. table.concat(sdj, ',') .. ']'
        .. ',"escaped":' .. jarr(escl) .. ',"fields_hit":[' .. table.concat(fhj, ',') .. ']}},')
    put('"gaps":[' .. table.concat(gj, ',') .. '],')
    local gs = { tostring(X.GOBJ) }
    for i, e in ipairs(X.ENVL or {}) do if i > 1 then gs[#gs + 1] = tostring(e.GOBJ) end end
    put('"contracts":{"host_kinds":["type","ext"],"globals_site":' .. tostring(X.GOBJ) .. ',"globals_sites":[' .. table.concat(gs, ',') .. '],"dyn_keys":true,"strlib_site":' .. tostring(X.STRLIB or 'null') .. ',"ext_channel":' .. tostring(X.EXTCALL or 'null')
        .. ',"clauses":' .. (function () -- (by name: the dump is compared byte for byte, pairs order varies by process)
            local ks, kv = vim.tbl_keys(M.CONTRACTS), {}
            table.sort(ks)
            for i, k in ipairs(ks) do kv[i] = jstr(k) .. ':' .. jstr(M.CONTRACTS[k]) end
            return '{' .. table.concat(kv, ',') .. '}'
        end)() .. '},')
    put('"answers":[' .. table.concat(aj, ',') .. ']}')
    return table.concat(out)
end

return M
