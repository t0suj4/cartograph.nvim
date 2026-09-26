-- A USE WITH NO REQUIRE — the reverse of the `redundant-require` lint
-- ([[cartograph-bidirectional-instruments]]). That rule flags a require nothing
-- uses; this flags a file that uses what another file defines as a GLOBAL without
-- requiring that file. It works by accident: some other file loaded the definer
-- first (load order), a global leaked, or F's own requires happen to pull it in.
--
-- @langs lua
-- Lua only, because `require` + the global environment is lua's binding model: the
-- import edges it reads are lua's `require`, and "defined as a global" is decided by
-- the absence of a `local` binding, which is lua syntax. It compares no node types.
--
-- ── WHAT "RESOLVED INTO G WITHOUT IMPORTING G" MEANS, IN GRAPH TERMS ────────────
--   A USE of file G by file F is one of
--     · a call record c with c.file = F, c.to = d, d.file = G ~= F, NOT a method
--       call, whose callee is a pure identifier path `r` / `r.a.b` (root r); or
--     · a `use` edge (a read) from a node of F to a var node d of G ~= F (root = the
--       var's name).
--   NO REQUIRE: the graph has no `import` edge F -> G.
--   The resolver stage that bound it is the edge's tier (tier.of): for lua a
--   cross-file call lands `inferred` (the unique-name rung) — the linker GUESSED
--   G, it did not follow a binding — which is exactly why a use without a require
--   needs classifying before anyone calls it a defect.
--
-- ── EXCLUDED (counted, never reported) ─────────────────────────────────────────
--   param          r is a parameter of the enclosing function: the value was HANDED
--                  in, so no require is owed (a store passed to a verb)
--   import-bound   r is the local an import in F binds — fabcensus's territory
--   method         `x:m()` — the receiver is a value; nothing about it owes a require
--
-- ── CLASSIFIED ──────────────────────────────────────────────────────────────────
--   other-name     F spells a path that is not the def's name (`tostring` landing on
--                  `FUNCS.tostring`, `store.topo` on `M.topo`): the environment cannot
--                  carry F's name to that def. Sub `unseen-require` when F's text names
--                  G's module in a string (a require the extractor missed, the value
--                  reached F through it), else `unexplained` (a guessed resolution —
--                  fabcensus's population, not this rule's)
--   not-global     F spells the def's name but G binds its root `local`
--                  (exported == false, or `local r` somewhere in G); same subs
--   host-root      G defines `R.x` but nothing in the corpus defines R itself: G
--                  patches a HOST table (`vim.cmd = function …`), and `R.x` exists
--                  without G
--   caller-local   G defines r globally but F declares its own `local r`: the name
--                  in F is F's local; the edge is a guess
--   unseen-require G's def is global and F's text names G's module in a string
--                  literal — `pcall(require, 'x')`, `require(prefix .. 'x')`: F DOES
--                  require G, in a form that mints no import edge (an extractor
--                  omission, CART-0685's axis)
--   GLOBAL         the finding: G defines r as a global, F neither binds nor names
--                  G, and uses it. Sub-classed by what makes it work today:
--                    import-chain       F's own requires reach G transitively
--                    required-elsewhere some other file requires G
--                    required-by-none   nothing requires G (an entry point, or the
--                                       host loads it — a .toc, a mod manifest)
--   unread         F's or G's text could not be read: every `local` answer would be
--                  empty, so no verdict (never reported)
--                    via-global-alias   G's module table is LOCAL, but another file
--                                       publishes it globally (`Zone = require
--                                       "scripts/zone"`) and F reaches it by that name
--
-- ⚠ A WORK LIST WITH STRUCTURAL FALSE POSITIVES, NOT A VERDICT. The `local` test is a
-- text scan over the whole file (any scope), deliberately biased toward NOT
-- reporting: a `local r` anywhere in G makes the def not-global, anywhere in F makes
-- the use caller-local. What remains can still be a legitimate design — a manifest
-- loads files in order and globals are the API (WoW, Factorio's data stage). The
-- lint arm is `suggestive`, and it reports only the GLOBAL class.

local M = {}

local tier = require 'cartograph.tier'
local atr = require 'cartograph.at'
local callview = require 'cartograph.callview'

local function is_lua(f) return type(f) == 'string' and f:match('%.lua$') ~= nil end

--- every name a file binds with `local` (any scope), from its text. Over-inclusive
--- on purpose: a hit only ever suppresses a finding.
function M.local_names(text)
    local set = {}
    for line in (text or ''):gmatch('[^\n]+') do
        local rest = line:match('^%s*local%s+(.*)$')
        if rest then
            local fname = rest:match('^function%s+([%a_][%w_]*)')
            if fname then set[fname] = true
            else
                local list = rest:match('^([^=]*)') or ''
                for nm in list:gmatch('[%a_][%w_]*') do set[nm] = true end
            end
        end
        -- PARAMETERS AND LOOP VARIABLES BIND TOO, and an UPVALUE parameter is invisible
        -- to the enclosing-function check: the vendored algebra files are
        -- `return function (M, SHARED) … end`, so every `M.x` inside is the outer
        -- closure's parameter — and the graph resolved those reads into another
        -- algebra file's `M`. Counted as bound anywhere in the file (over-inclusive:
        -- a same-named global read elsewhere in the file is then not reported).
        for plist in line:gmatch('function%s*[%w_.:]*%s*%(([^)]*)%)') do
            for nm in plist:gmatch('[%a_][%w_]*') do set[nm] = true end
        end
        local fl = line:match('^%s*for%s+(.-)%s+in%s') or line:match('^%s*for%s+([%a_][%w_]*)%s*=')
        if fl then for nm in fl:gmatch('[%a_][%w_]*') do set[nm] = true end end
    end
    return set
end

--- does F's text name G's module in a string literal? The fabcensus fragment test:
--- `'a.b'` / `"a/b"` names a/b.lua or a/b/init.lua, matched at a path boundary.
local function names_module(text, gfile)
    for lit in (text or ''):gmatch('[\'"]([%w_%.%-/]+)[\'"]') do
        local frag = lit:gsub('%.lua$', ''):gsub('%.', '/')
        -- ⚠ A MULTI-SEGMENT literal only: a one-word string (`type == "zone"`) matched
        -- scripts/zone.lua and called 59 of SE's uses a missed require
        if frag:find('/', 1, true) then
            for _, fr in ipairs({ frag .. '.lua', frag .. '/init.lua' }) do
                if gfile == fr or gfile:sub(-#fr - 1) == '/' .. fr then return true end
            end
        end
    end
    return false
end

--- Classify every lua use-without-require in `data`.
--- @param data table   the graph (nodes, calls, edges)
--- @param read function(file) -> source text | nil
--- @return table { rows = {...}, census = {class -> n}, pairs = {F\31G -> row list} }
function M.classify(data, read)
    local byid = {}
    for _, n in ipairs(data.nodes or {}) do byid[n.id] = n end
    local imports, binds, importers = {}, {}, {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'import' and e.from and e.to then
            local t = imports[e.from]; if not t then t = {}; imports[e.from] = t end
            t[e.to] = true
            importers[e.to] = (importers[e.to] or 0) + 1
            if e.bind then
                local b = binds[e.from]; if not b then b = {}; binds[e.from] = b end
                b[e.bind] = true
            end
        end
    end
    -- every ROOT name the corpus itself defines: a var node, or a bare function. A
    -- dotted def whose root nobody here defines (`vim.cmd = function … end` in a test
    -- helper) PATCHES A HOST TABLE: the name `vim.cmd` exists without that file, so a
    -- use of it owes the patcher no require. Measured: 73 of the first 95 findings on
    -- our own tree were `vim.*` calls landing on two such stubs.
    -- ⚠ ONLY A GLOBAL definition counts: `local vim = vim` (panes/altitudes.lua) is a
    -- var node named `vim`, and counting it made the host's own table look defined here.
    local root_defs = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.name and n.file and (n.kind == 'var'
            or ((n.kind == 'function') and not n.name:find('[.:]'))) then
            local l = root_defs[n.name]; if not l then l = {}; root_defs[n.name] = l end
            l[#l + 1] = n
        end
    end
    local text_cache, locals_cache = {}, {}
    local function text(f)
        local t = text_cache[f]
        if t == nil then t = read(f) or false; text_cache[f] = t end
        return t or nil
    end
    local function locals(f)
        local s = locals_cache[f]
        if not s then s = M.local_names(text(f)); locals_cache[f] = s end
        return s
    end
    local lines_cache = {}
    local function lines_of(f)
        local l = lines_cache[f]
        if l == nil then
            local t = text(f)
            l = t and vim.split(t, '\n', { plain = true }) or false
            lines_cache[f] = l
        end
        return l or nil
    end
    -- THE GLOBAL MODULE ALIAS: `Zone = require("scripts/zone")` in control.lua makes
    -- zone.lua's LOCAL module table reachable everywhere by the global name `Zone`.
    -- SE's whole control stage is built this way (control.lua:14-60), so a use of
    -- `Zone.x` in spaceship.lua is a use of zone.lua without a require of it, through
    -- another file's global — the finding's own class, not a guess.
    -- alias[G][name] = { files that bind that name GLOBALLY to G }
    local alias = {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'import' and e.bind and e.from and e.to then
            local a = alias[e.to]; if not a then a = {}; alias[e.to] = a end
            local l = a[e.bind]; if not l then l = {}; a[e.bind] = l end
            l[#l + 1] = e.from
        end
    end
    local function global_alias(G, name, F)
        for _, h in ipairs((alias[G] or {})[name] or {}) do
            -- an UNREAD publisher cannot be shown to bind the name globally
            if h ~= F and text(h) and not locals(h)[name] then return h end
        end
        return nil
    end
    local root_memo = {}
    local function corpus_defines(r)
        if root_memo[r] ~= nil then return root_memo[r] end
        local hit = false
        for _, n in ipairs(root_defs[r] or {}) do
            if n.exported ~= false and text(n.file) and not locals(n.file)[r] then hit = true; break end
        end
        root_memo[r] = hit
        return hit
    end
    local reach_cache = {}
    local function reaches(from, to)
        local key = from .. '\31' .. to
        if reach_cache[key] ~= nil then return reach_cache[key] end
        local seen, stack, hit = { [from] = true }, { from }, false
        while #stack > 0 and not hit do
            local f = table.remove(stack)
            for g in pairs(imports[f] or {}) do
                if g == to then hit = true; break end
                if not seen[g] then seen[g] = true; stack[#stack + 1] = g end
            end
        end
        reach_cache[key] = hit
        return hit
    end

    local census, rows = {}, {}
    local function count(k) census[k] = (census[k] or 0) + 1 end

    local function consider(F, d, spelled, line, how, t)
        local G = d.file
        if not (is_lua(F) and is_lua(G)) or F == G then return end
        if imports[F] and imports[F][G] then count('required'); return end
        count('population')
        local root = spelled:match('^([%a_][%w_]*)')
        if binds[F] and binds[F][root] then count('excluded:import-bound'); return end
        local cls, sub, via
        -- ⚠ EVERY "is it local?" ANSWER BELOW IS READ FROM TEXT, and an unreadable file
        -- has an EMPTY local set — which would make every def in it look global, the
        -- reporting direction. No text, no verdict: its own class, never reported.
        if not (text(F) and text(G)) then
            count('unread')
            rows[#rows + 1] = { file = F, def = d, root = root, line = line, how = how,
                class = 'unread', tier = t }
            return
        end
        -- REACHABLE BY NAME means F spells exactly the path G defines: a bare
        -- `tostring(x)` that the linker landed on terraform.lua's `FUNCS.tostring`
        -- names no global G has, whatever G's visibility says (the first cut compared
        -- only roots and reported 4130 "globals" on our own tree, most of them this)
        local dname = (d.name or ''):gsub(':', '.')
        local droot = dname:match('^([%a_][%w_]*)') or ''
        if dname ~= spelled then
            cls = 'other-name'
            sub = names_module(text(F), G) and 'unseen-require' or 'unexplained'
        elseif (d.exported == false or locals(G)[droot]) and droot ~= dname
            and global_alias(G, droot, F) and not locals(F)[droot] then
            -- G's module table is local, but another file publishes it as a global
            cls, sub, via = 'global', 'via-global-alias', global_alias(G, droot, F)
        elseif d.exported == false or locals(G)[droot] then
            cls = 'not-global'
            sub = names_module(text(F), G) and 'unseen-require' or 'unexplained'
        elseif droot ~= dname and not corpus_defines(droot) then
            cls = 'host-root'
        elseif locals(F)[root] then
            cls = 'caller-local'
        elseif names_module(text(F), G) then
            cls = 'unseen-require'
        else
            cls = 'global'
            if reaches(F, G) then sub = 'import-chain'
            elseif (importers[G] or 0) > 0 then sub = 'required-elsewhere'
            else sub = 'required-by-none' end
        end
        count(cls)
        if sub then count(cls .. ':' .. sub) end
        rows[#rows + 1] = { file = F, def = d, root = root, line = line, how = how,
            class = cls, sub = sub, tier = t, via = via }
    end

    local cv = callview.of(data)
    for i = 1, cv.n do
        local to = cv.get(i, 'to')
        local d = to and byid[to]
        local F = cv.get(i, 'file')
        if d and d.file and F and d.file ~= F and is_lua(F) and is_lua(d.file) then
            local full = cv.get(i, 'full') or cv.get(i, 'callee')
            if cv.get(i, 'method') then
                if not (imports[F] and imports[F][d.file]) then count('excluded:method') end
            elseif type(full) == 'string' and full:match('^[%a_][%w_]*$')
                or type(full) == 'string' and full:match('^[%a_][%w_]*%.[%a_][%w_.]*$') then
                local root = full:match('^([%a_][%w_]*)')
                local fn = cv.get(i, 'fn') and byid[cv.get(i, 'fn')]
                local isparam = false
                for _, p in ipairs(fn and fn.params or {}) do
                    if p == root then isparam = true; break end
                end
                if isparam then
                    if not (imports[F] and imports[F][d.file]) then count('excluded:param') end
                else
                    local c = data.calls and data.calls[i]
                    consider(F, d, full, cv.get(i, 'line'), 'call',
                        tier.of(c or { inferred = cv.get(i, 'inferred') }))
                end
            end
        end
    end
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'use' then
            local d = byid[e.to]
            local src = byid[e.from]
            local F = src and src.file or (type(e.from) == 'string' and e.from:match('^(.-)::')) or e.from
            if d and d.kind == 'var' and d.name and is_lua(F) and is_lua(d.file) and d.file ~= F
                and not (imports[F] and imports[F][d.file]) then
                local root = d.name:match('^([%a_][%w_]*)')
                -- ★ A `use` EDGE IS KEYED ON THE BARE NAME, member reads included:
                -- SE's `Log.debug_log(…)` and `storage.x.space_collision_layer` carry
                -- use edges into data.lua's GLOBAL `debug_log` / `space_collision_layer`
                -- (tier `matched`), across Factorio's data/control stage boundary where
                -- no global is shared at all. So each site is read back from the text: a
                -- `.`/`:` right before the name is a MEMBER read and reaches no global.
                local line, member, unknown = nil, 0, false
                local lines = lines_of(F)
                for _, r in ipairs(e.at or {}) do
                    local sl, sc = atr.sl(r), atr.sc(r)
                    local lt = lines and sl and lines[sl + 1]
                    if not lt or not sc then unknown = true
                    else
                        local prev = sc > 0 and lt:sub(1, sc):match('([^%s])%s*$') or nil
                        if prev == '.' or prev == ':' then member = member + 1
                        elseif not line then line = sl end
                    end
                end
                local isparam = false
                for _, p in ipairs(src and src.params or {}) do
                    if p == root then isparam = true; break end
                end
                if isparam then
                    count('excluded:param')
                elseif not line then
                    -- every site a member read (or no site to read back): no free name
                    count(member > 0 and 'excluded:member-read' or 'excluded:no-site')
                elseif root then consider(F, d, d.name, line, 'read', tier.of(e)) end
            end
        end
    end
    table.sort(rows, function (a, b)
        if a.file ~= b.file then return a.file < b.file end
        if a.def.file ~= b.def.file then return a.def.file < b.def.file end
        return (a.line or 0) < (b.line or 0)
    end)
    return { rows = rows, census = census }
end

--- One finding per (F, G) pair of the GLOBAL class: the work-list grain — a file
--- owes one require per definer, however many names it uses from it.
function M.findings(result)
    local out, by = {}, {}
    for _, r in ipairs(result.rows) do
        if r.class == 'global' then
            local k = r.file .. '\31' .. r.def.file
            local g = by[k]
            if not g then
                g = { file = r.file, gfile = r.def.file, line = r.line, names = {},
                    seen = {}, sub = r.sub, n = 0, via = r.via }
                by[k] = g
                out[#out + 1] = g
            end
            g.n = g.n + 1
            if not g.seen[r.root] then g.seen[r.root] = true; g.names[#g.names + 1] = r.root end
        end
    end
    return out
end

return M
