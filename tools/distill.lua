-- tools/distill.lua — distill a runtime's stdlib surface into an L2 environment
-- profile ([[cartograph-stdlib-profile]], the P2 layering artifact). Runs the
-- EXISTING extractor over the std tree ONCE, compacts the public defs into a
-- type→member profile, writes an mpack artifact + prints a coverage report.
--
--   nvim --headless -u NONE -l tools/distill.lua <runtime> [--measure]
--     <runtime>   a key in RUNTIMES below (default: zig)
--     --measure   also extract the runtime's CORPUS and size the ROI: how many
--                 currently-UNRESOLVED corpus calls the profile would reclaim
--                 (measure-first — the design gates the build on this).
--
-- INCREMENT 1 (this artifact): member SETS + ctor names + derived vocab, PUBLIC
-- surface only (exported defs). Return-type enrichment (init→Self, the chaining
-- rung) and free-fn namespacing are the next rungs; ret stays ABSENT = honest.
-- No engine behaviour change — nothing consumes the profile yet; this ships the
-- artifact + the ROI number that gates wiring the L2 resolver face.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/distill%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'

local RUNTIMES = {
    zig = {
        runtime = 'zig-std', lang = 'zig',
        std_root = vim.fn.expand('~/git/zig/lib/std'),
        version_root = vim.fn.expand('~/git/zig'),
        corpus = 'zig', -- the ROI-measurement corpus (bench.corpus key)
    },
}

local function iso() return os.date('!%Y-%m-%dT%H:%M:%SZ') end
local function git_rev(root)
    return vim.fn.systemlist({ 'git', '-C', root, 'rev-parse', '--short', 'HEAD' })[1]
        or '?'
end

-- generic-erase a keyed name: `Managed(u8).append` -> `Managed.append`
local function erase(name) return (name:gsub('%b()', '')) end
-- a member name that constructs the type (best-effort, ret unread in v1)
local function is_ctor(m)
    return m == 'init' or m == 'create' or m:match('^init%u') ~= nil
        or m:match('^from%u') ~= nil
end

-- ── signature distillation (nav-time hover enrichment, READ-SIDE) ────────────
-- Zig: a `std.<module>.<fn>` -> {sig,file,line} map for the free top-level public
-- fns of std's directly-reexported modules, keyed to MATCH the minted
-- `zig-std::std.<module>.<fn>` node id ([[cartograph-stdlib-profile]]). The raw
-- native signature `(params) RET` + source location come straight from source.
-- HOVER-ONLY (lsp.profile_sig): the disposition/vocab surface (types/free/vocab)
-- is untouched, so NO extraction/version change — the gate corpora stay identical.
-- Deep type-method chains + type constructors stay uncovered = honest frontier.
local function zig_module_map(root) -- 'mem.zig' -> module 'mem'  (=> std.mem)
    local map, fd = {}, io.open(root .. '/std.zig', 'r')
    if not fd then return map end
    for line in fd:lines() do
        local mod, file = line:match('^pub const ([%w_]+) = @import%("([%w_/%.]+%.zig)"%)')
        if mod and file then map[file] = mod end
    end
    fd:close(); return map
end
local function zig_read_sig(root, relfile, startline0, name) -- native "(params) RET"
    local fd = io.open(root .. '/' .. relfile, 'r'); if not fd then return nil end
    local lines = {}; for l in fd:lines() do lines[#lines + 1] = l end; fd:close()
    local from, esc, buf = (startline0 or 0) + 1, name:gsub('(%W)', '%%%1'), {}
    for j = from, math.min(#lines, from + 60) do
        buf[#buf + 1] = lines[j]
        if lines[j]:find('{') and table.concat(buf):find('fn%s+' .. esc) then break end
    end
    local text = table.concat(buf, ' '):gsub('%s+', ' ')
    local params, tail = text:match('fn%s+' .. esc .. '%s*(%b())%s*([^{]*)')
    if not params then return nil end
    local ret = (tail or ''):gsub('%s+$', '')
    return params .. (ret ~= '' and (' ' .. ret) or '')
end
local function zig_sigs(rt, data)
    local mmap = zig_module_map(rt.std_root)
    local sigs, n = {}, 0
    for _, nd in ipairs(data.nodes) do
        if nd.kind == 'function' and nd.exported and mmap[nd.file] then
            local base = nd.name:gsub('%b()', '') -- generic-erase
            if not base:find('%.') then           -- free top-level fn (no type owner)
                local sl = nd.range and nd.range.start and nd.range.start.line
                local sig = zig_read_sig(rt.std_root, nd.file, sl, base)
                if sig then
                    sigs['std.' .. mmap[nd.file] .. '.' .. base] =
                        { sig = sig, file = nd.file, line = (sl or 0) + 1 }
                    n = n + 1
                end
            end
        end
    end
    return sigs, n
end

local function distill(rt)
    io.write(('distill %s: extracting %s ...\n'):format(rt.runtime, rt.std_root))
    local t0 = vim.loop.hrtime()
    local data = ts.extract(rt.std_root)
    io.write(('  %d nodes in %.0fs\n'):format(#data.nodes,
        (vim.loop.hrtime() - t0) / 1e9))

    local types, free, vocab = {}, {}, {}
    local n_members, n_ctors = 0, 0
    for _, n in ipairs(data.nodes) do
        if n.kind == 'function' and n.exported then
            local nm = erase(n.name)
            local T, m = nm:match('^(.+)%.([^.]+)$')
            if T then
                local t = types[T]
                if not t then t = { members = {}, ctors = {} }; types[T] = t end
                if not t.members[m] then t.members[m] = {}; n_members = n_members + 1 end
                if is_ctor(m) and not t.ctors[m] then
                    t.ctors[m] = {}; n_ctors = n_ctors + 1
                end
                vocab[m] = true
            else
                free[nm] = true -- bare exported fn (namespacing = v2)
                vocab[nm] = true
            end
        end
    end

    local n_types, n_free, n_vocab = 0, 0, 0
    for _ in pairs(types) do n_types = n_types + 1 end
    for _ in pairs(free) do n_free = n_free + 1 end
    for _ in pairs(vocab) do n_vocab = n_vocab + 1 end

    -- nav-time hover signatures (read-side; does NOT touch the disposition surface)
    local sigs, n_sig = nil, 0
    if rt.lang == 'zig' then sigs, n_sig = zig_sigs(rt, data) end

    local profile = {
        schema = 1, runtime = rt.runtime, lang = rt.lang,
        version = git_rev(rt.version_root), stamp = iso(),
        types = types, free = free, namespaces = {}, vocab = vocab,
        sigs = sigs, sig_root = sigs and rt.std_root or nil,
        sig_kind = sigs and 'zig' or nil,
    }
    return profile, {
        types = n_types, members = n_members, ctors = n_ctors,
        free = n_free, vocab = n_vocab, sigs = n_sig,
    }
end

local function write_profile(profile)
    local dir = here .. '/../lua/cartograph/spec/profile'
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/' .. profile.runtime .. '.mpack'
    local tmp = path .. '.tmp.' .. vim.fn.getpid()
    local fd = assert(io.open(tmp, 'wb'), 'distill: cannot write ' .. tmp)
    fd:write(vim.mpack.encode(profile)); fd:close()
    assert(os.rename(tmp, path))
    return path
end

-- ROI: of the corpus's UNRESOLVED calls, how many does the profile cover?
--   vocab hit  = the call's leaf name is in the profile vocab (loose upper bound)
--   type hit   = the call's keyed form T.m has T in types and m in members[T]
--                (what the L2 resolver would actually mint — the real number)
local function measure(rt, profile)
    io.write(('\nmeasure ROI on corpus %s ...\n'):format(rt.corpus))
    local data = ts.extract(bench.corpus(rt.corpus).root)
    local calls = data.calls or {}
    local unresolved, vocab_hit, type_hit = 0, 0, 0
    for _, c in ipairs(calls) do
        if not c.to then
            unresolved = unresolved + 1
            local full = c.full or c.callee or ''
            local leaf = full:match('([^.]+)$') or full
            if profile.vocab[leaf] then vocab_hit = vocab_hit + 1 end
            local T, m = erase(full):match('^(.+)%.([^.]+)$')
            if T and profile.types[T] and profile.types[T].members[m] then
                type_hit = type_hit + 1
            end
        end
    end
    return { total = #calls, unresolved = unresolved,
        vocab_hit = vocab_hit, type_hit = type_hit }
end

-- ── main ──────────────────────────────────────────────────────────────────
local name = (arg and arg[1]) or 'zig'
local do_measure = false
for _, a in ipairs(arg or {}) do if a == '--measure' then do_measure = true end end
local rt = RUNTIMES[name]
if not rt then io.write('unknown runtime: ' .. name .. '\n'); os.exit(2) end

local profile, stats = distill(rt)
local path = write_profile(profile)

io.write('\n=== profile coverage ===\n')
io.write(('  runtime=%s version=%s lang=%s\n'):format(
    profile.runtime, profile.version, profile.lang))
io.write(('  types=%d  members=%d  ctors=%d  free=%d  vocab=%d  sigs=%d\n'):format(
    stats.types, stats.members, stats.ctors, stats.free, stats.vocab, stats.sigs or 0))
-- top types by member count
local ranked = {}
for T, t in pairs(profile.types) do
    local c = 0; for _ in pairs(t.members) do c = c + 1 end
    ranked[#ranked + 1] = { T = T, n = c }
end
table.sort(ranked, function (a, b) return a.n > b.n end)
io.write('  top types by member count:\n')
for i = 1, math.min(15, #ranked) do
    io.write(('    %-28s %d\n'):format(ranked[i].T, ranked[i].n))
end
io.write('  wrote ' .. path .. '\n')

if do_measure then
    local m = measure(rt, profile)
    io.write('\n=== ROI (measure-first gate) ===\n')
    io.write(('  corpus calls=%d  unresolved=%d\n'):format(m.total, m.unresolved))
    io.write(('  vocab hits   = %d (%.1f%% of unresolved) — loose upper bound\n'):format(
        m.vocab_hit, m.unresolved > 0 and 100 * m.vocab_hit / m.unresolved or 0))
    io.write(('  TYPE hits    = %d (%.1f%% of unresolved) — the real L2-resolvable set\n'):format(
        m.type_hit, m.unresolved > 0 and 100 * m.type_hit / m.unresolved or 0))
end
