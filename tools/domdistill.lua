-- domdistill — distil the BROWSER surface into an L2 environment profile
-- ([[cartograph-stdlib-profile]]), CART-0805.
--
--   nvim --headless -u NONE -l tools/domdistill.lua [--from <lib dir>] [--out P]
--
-- ★★★ WHY, MEASURED (CART-0805). `spec/profile/node.lua` is distilled from the
-- installed ENGINE, so its surface is node's globalThis plus builtinModules. It
-- has no `document`, no `window`, no `Element` — and two of the three JS corpora
-- are BROWSER code. Once a shape bug was fixed and the node profile actually
-- activated on them, jquery moved 36.1% -> 37.3% and converse.js 23.3% -> 23.9%,
-- against ghost's +12.6. The reading is not "the profile lever is exhausted"; it
-- is "the environment is wrong".
--
-- ★★ THE ORACLE IS TypeScript's OWN `lib.dom.d.ts`, not a curated name list and
-- not a scrape of MDN. It ships inside the `typescript` package that
-- tools/harvest_ts.lua already depends on, it is a declaration file so
-- tools/dtsread.lua reads it unchanged, and it is maintained against the living
-- web platform by people who are not us. A hand-written DOM list would start
-- wrong and rot; this cannot rot faster than the browsers do.
--
-- ⚠ AND IT IS READ FROM DISK BY DEFAULT. A local `node_modules/typescript/lib` is
-- preferred over the network for the same reason npmdistill never installs: the
-- fewer moving parts between an oracle and an artifact, the more the artifact
-- means. The fetch is the fallback, and it pins a MAJOR so the artifact does not
-- change under us on a Tuesday.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')

local out = repo .. '/lua/cartograph/spec/profile/dom-api.mpack'
local from, i = nil, 1
while arg and arg[i] do
    if arg[i] == '--out' then out = arg[i + 1]; i = i + 2
    elseif arg[i] == '--from' then from = arg[i + 1]; i = i + 2
    else i = i + 1 end
end

-- the declaration files that describe a BROWSER, and only those. lib.es*.d.ts is
-- the LANGUAGE and node already answers for it from the running engine, where the
-- answer is a fact rather than a declaration.
local WANT = { 'lib.dom.d.ts', 'lib.dom.iterable.d.ts' }

local function read(p)
    local fd = io.open(p, 'r'); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s
end

--- an installed typescript's lib directory, searched in the places one lands
local function find_lib()
    if from then return from end
    local seen = {}
    local roots = { repo, vim.fn.expand('~/git'), vim.fn.expand('~/work') }
    for _, r in ipairs(roots) do
        local hits = vim.fn.glob(r .. '/*/node_modules/typescript/lib/lib.dom.d.ts', false, true)
        for _, h in ipairs(vim.fn.glob(r .. '/node_modules/typescript/lib/lib.dom.d.ts', false, true)) do
            hits[#hits + 1] = h
        end
        for _, h in ipairs(hits) do
            local dir = h:match('^(.*)/lib%.dom%.d%.ts$')
            if dir and not seen[dir] then return dir end
        end
    end
    return nil
end

local sources, origin = {}, nil
local libdir = find_lib()
if libdir then
    -- ⚠ RECORD THE VERSION, NOT THE PATH. The artifact is committed, and the lib
    -- it was read from may be an unrelated project's node_modules that happens to
    -- be on this machine — so "where" is not a fact anyone else can check while
    -- "typescript 5.6.3" is. An artifact whose provenance cannot be audited is one
    -- nobody can attribute a measurement to.
    local tsver
    local mf = read(libdir:gsub('/lib$', '') .. '/package.json')
    if mf then tsver = mf:match('"version"%s*:%s*"([^"]+)"') end
    origin = 'typescript@' .. (tsver or 'unknown')
    for _, f in ipairs(WANT) do
        local s = read(libdir .. '/' .. f)
        if s then sources[#sources + 1] = { name = f, src = s } end
    end
end
if #sources == 0 then
    -- ⚠ A BARE `typescript/lib/...` PATH 404s ON unpkg; the version range is not
    -- optional. Pinning the MAJOR is deliberate: an artifact that changes because
    -- a patch shipped is an artifact nobody can attribute a measurement to.
    if vim.fn.executable('curl') ~= 1 then
        print('domdistill: no local typescript lib and no curl to fetch one.')
        os.exit(2)
    end
    origin = 'unpkg:typescript@5'  -- the major is pinned; the exact patch is not
    for _, f in ipairs(WANT) do
        local r = vim.fn.system({ 'curl', '-fsSL', '--max-time', '30',
            'https://unpkg.com/typescript@5/lib/' .. f })
        if vim.v.shell_error == 0 and r and r ~= '' then
            sources[#sources + 1] = { name = f, src = r }
        end
    end
end
if #sources == 0 then
    print('domdistill: could not read lib.dom.d.ts from disk or from unpkg.')
    os.exit(2)
end

bench.bootstrap()
pcall(vim.treesitter.language.add, 'typescript')
local dts = dofile(repo .. '/tools/dtsread.lua')

local acc = dts.new()
for _, s in ipairs(sources) do dts.absorb(acc, s.src, { ambient = true }) end
local rep = dts.finish(acc)

if rep.globals == 0 then
    print('domdistill: the declarations named no global — refusing to write an'
        .. ' empty profile, which would activate and disposition NOTHING while'
        .. ' looking installed.')
    os.exit(2)
end

local namespaces = {}
for k in pairs(acc.nsset) do namespaces[#namespaces + 1] = k end
table.sort(namespaces) -- an artifact field: order is output (CART-0790)

local nsig = 0
for _ in pairs(acc.sigs) do nsig = nsig + 1 end

local fd = assert(io.open(out, 'wb'))
fd:write(vim.mpack.encode({
    schema = 1, runtime = 'dom-api', lang = 'javascript',
    version = origin,
    -- not a wall clock: the artifact is checked in, and a timestamp would make it
    -- differ on every run for no content reason (the erldistill lesson)
    stamp = ('dom-%dg-%dm'):format(rep.globals, nsig),
    sig_kind = 'javascript', sig_root = origin,
    types = {}, namespaces = namespaces, nsset = acc.nsset,
    free = acc.free, vocab = acc.vocab, sigs = acc.sigs,
}))
fd:close()
print(('domdistill: %s — %d globals, %d keys (%d global members, %d flattened),'
    .. ' %d free functions -> %s'):format(origin, rep.globals, nsig, rep.gmembers,
    rep.flat, (function () local n = 0; for _ in pairs(acc.free) do n = n + 1 end; return n end)(),
    out:gsub('^' .. vim.pesc(repo) .. '/', '')))
