-- CHARACTERIZE: one function → a RUNNABLE SPEC WITH HOLES (CART-0262, step 1 of the
-- CART-0260 arc). cartograph never executes user code, so it cannot know an expected
-- value — and rather than guess one, the expected value is a HOLE. That is the
-- never-draw invariant applied to a new medium: the blocker becomes structural.
--
-- TWO STANDING GATES, both more important than any feature here:
--  1. AN UNFILLED HOLE MUST FAIL. Every hole emits `HOLE(...)`, which errors. Never a
--     commented-out assert, never assert(true). A suite that goes green because its
--     assertions are missing is absence-rendered-as-silence at its most dangerous: it
--     LOOKS like coverage.
--  2. GENERATED SPECS STAY OUT OF THE PUSH FENCE. The suite globs `tests/*_spec.lua`;
--     these land under `characterized/` with a `_char.lua` suffix and are refused if
--     aimed at the fence (see M.plan). A characterization test is SUPPOSED to fail when
--     behaviour changes, so wiring it into pre-commit would block every legitimate
--     refactor. A tool you invoke, not a ratchet.
--
-- WHAT THE ENVIRONMENT ALREADY SUPPLIES IS NOT A HOLE, and getting this wrong would
-- have emitted thousands of spurious ones. The spec runs IN a Lua runtime, so a
-- dependency hole for `table.concat` is satisfied by the runtime itself; and it
-- `dofile`s the subject module, so a `derived` fixture hole (a same-file definition) is
-- satisfied by that load. Both are recorded as SATISFIED with the mechanism named —
-- disclosed, not silently dropped, because "no hole" and "a hole the environment fills"
-- are different claims.
--
-- A STUB IS A SUPPLIED PREMISE ([[cartograph-hedge-resolution-writes]]). The test is
-- HEDGED on its environment; a stub DISCHARGES the hedge; so the header carries every
-- premise it assumed, with the TIER of each. Without that we have fabricated an
-- environment and labelled the result a test — and it would look exactly like a real one.
--
-- AGENT-DRIVABLE IS A REQUIREMENT, NOT A LATER SURFACE (user, 2026-08-04). Use headless
-- ([[cartograph-apply-for-agent]]):
--   local ch = require 'cartograph.characterize'
--   local plan, why = ch.plan(store, ch.at(store, 'lua/foo.lua', 42))
--   if not plan then return why end               -- the refusal, verbatim
--   print(table.concat(ch.emit(plan), '\n'))      -- the spec, holes and all
--   ch.fill(plan, { ['input:a'] = { value = '7', basis = 'the caller passes 7',
--                                   by = 'agent' } })
--   local entry, err = ch.apply(store, plan)      -- journalled; parse-verified
-- Every row is DATA (plan.holes), never prose to parse.

local M = {}
local at = require 'cartograph.at'
local txn = require 'cartograph.txn'
local holes = require 'cartograph.holes'

-- Where generated specs land, and the fence they must never cross. The suite globs
-- `tests/*_spec.lua`; nothing here may match that.
M.DIR = 'characterized'
M.SUFFIX = '_char.lua'

--- The innermost function enclosing `line` — the TARGETED entry point every apply verb
--- in this codebase shares (optapply.at's shape, deliberately identical).
function M.at(store, file, line)
    if not (store.data and store.data.nodes and file and line) then return nil end
    local best, bestspan
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.range and n.file
            and (n.file == file or n.file:sub(-(#file + 1)) == '/' .. file) then
            local sl, el = at.sl(n.range) + 1, at.el(n.range) + 1
            if sl <= line and line <= el then
                local span = el - sl
                if not bestspan or span < bestspan then best, bestspan = n.id, span end
            end
        end
    end
    return best
end

--- THE FUNCTION NODES OF ONE FILE, innermost-last, so an enclosure test is a range
--- containment test. Built from the graph rather than re-parsed: the ranges are the
--- extractor's, so "nested" here means what it means everywhere else in the codebase.
local function file_fns(store, rel)
    local out = {}
    for _, x in ipairs(store.by_file and store.by_file[rel] or {}) do
        local n = type(x) == 'table' and x or store.node(x)
        if n and (n.kind == 'function' or n.kind == 'method') and n.range then
            out[#out + 1] = n
        end
    end
    return out
end

local function encloses(outer, inner)
    local os_, oe = at.sl(outer.range), at.el(outer.range)
    local is_, ie = at.sl(inner.range), at.el(inner.range)
    return os_ <= is_ and oe >= ie and not (os_ == is_ and oe == ie)
end

--- The innermost function node strictly containing `node`, or nil at file level.
local function enclosing_fn(fns, node)
    local best
    for _, n in ipairs(fns) do
        if n.id ~= node.id and encloses(n, node) then
            if not best or encloses(best, n) then best = n end
        end
    end
    return best
end

--- WHICH EXPORTED FUNCTION CLOSES OVER THIS FILE-LEVEL LOCAL (CART-0286). A file-level
--- `local function helper()` is unreachable through the module's PUBLIC SURFACE, and the
--- old refusal stopped there — but it is an UPVALUE of whichever exported function
--- references it, so `debug.getupvalue` hands back the REAL function object with no
--- source rewriting, no stub and no guess.
---
--- THIS IS THE STATIC HALF, and it exists so the spec is not emitted on a hope: we
--- DERIVE that some exported function mentions the name (transitively through other
--- file-level locals), and the emitted spec then CHECKS it by walking upvalues for real.
--- Two channels on one question, which is the arc's standing rule — the channel that
--- supplies an answer must not be the channel that checks it. A disagreement between the
--- two is a real bug on one side.
---
--- IT UNDER-CLAIMS ON PURPOSE. A mention at MODULE level (`M.TEMPLATES = { holds = holds }`)
--- also makes the local reachable, through the table rather than through a closure, and
--- this does not count it: deciding whether that table ends up on the returned root is a
--- separate derivation. Under-claiming costs coverage; over-claiming would emit a spec
--- whose subject is nil, and the arc's failure direction is fixed.
local function upvalue_chain(store, node, lines)
    local fns = file_fns(store, node.file)
    -- name -> the innermost function whose body mentions it, other than its own def
    local function carriers_of(name)
        local pat = '%f[%w_]' .. name:gsub('%W', '%%%0') .. '%f[^%w_]'
        local out, seen = {}, {}
        for i, l in ipairs(lines) do
            if l:find(pat) then
                local host
                for _, n in ipairs(fns) do
                    if at.sl(n.range) <= i - 1 and at.el(n.range) >= i - 1 then
                        if not host or encloses(host, n) then host = n end
                    end
                end
                -- a self-mention inside the subject's own body carries it nowhere
                if host and host.name and not seen[host.name]
                    and not (at.sl(host.range) == at.sl(node.range)
                        and at.el(host.range) == at.el(node.range)) then
                    seen[host.name] = true
                    out[#out + 1] = host
                end
            end
        end
        return out
    end
    -- BFS from the subject OUTWARD, mirroring the runtime walk's direction in reverse:
    -- the subject is an upvalue of a carrier, which is an upvalue of ITS carrier, and the
    -- chain has to terminate at something the module actually exports.
    local queue, visited = { { name = node.name, chain = {} } }, { [node.name] = true }
    local head = 1
    while head <= #queue and head <= 64 do
        local cur = queue[head]; head = head + 1
        for _, c in ipairs(carriers_of(cur.name)) do
            local root, member = (c.name or ''):match('^([%w_]+)%.([%w_]+)$')
            local chain = {}
            for _, x in ipairs(cur.chain) do chain[#chain + 1] = x end
            chain[#chain + 1] = c.name
            if root then
                return { carrier = c.name, module = root, member = member, chain = chain }
            end
            if not visited[c.name] and enclosing_fn(fns, c) == nil then
                visited[c.name] = true
                queue[#queue + 1] = { name = c.name, chain = chain }
            end
        end
    end
    return nil
end

--- Squash a source fragment into something a one-line refusal can carry.
local function oneline_trim(s)
    return (tostring(s or ''):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''))
end

--- THE DECLARATION'S SIGNATURE — its line up to and including the parameter list — which is
--- what a reconstruction anchors on. NOT the whole line, and a test caught why: a one-liner
--- like `local function helper(x) return x * 2 end` carries its BODY on the anchor line, so
--- editing the body would stop the anchor matching and the spec would report "the
--- declaration is gone" instead of `CHANGED`. That is exactly backwards — noticing a body
--- edit is the entire job. Anchoring on the signature keeps the subject FINDABLE, recompiles
--- the edited body, and lets the behaviour change be reported as one.
local function anchor_of(line)
    return line:match('^(.-%b())') or line
end

--- HOW A DECLARATION IS WRAPPED SO THAT IT BINDS THE SUBJECT'S NAME — as SOURCE, because
--- this rule has to hold in two places at once: here, when the plan checks that the
--- reconstruction compiles, and inside the emitted spec, when it rebuilds the closure for
--- real. Two hand-written copies of a three-branch rule is precisely the parity bug this
--- codebase has already paid for twice (holes.lua's extraction, the census's hole set), so
--- there is ONE string and both sides run the same bytes.
M.WRAP_SRC = [[
local function WRAP(text, name, wrap)
    if wrap == 'local' then return 'local ' .. text end
    if wrap == 'assign' then return ('local %s = %s'):format(name, text) end
    return text
end]]
local WRAP = assert(((loadstring or load))(M.WRAP_SRC .. '\nreturn WRAP'))()

--- CAN WE REBUILD THE SUBJECT FROM ITS OWN SOURCE (CART-0289)? The upvalue walk needs a
--- module to walk from, so it refuses a SCRIPT's file-level local and a NESTED closure —
--- and neither refusal is about the language. A declaration compiles on its own, and
--- compiling it yields a function with the SAME BYTES as the one the file would build.
---
--- WHAT IT IS NOT: the object the module built. Its free names resolve as GLOBALS rather
--- than as the enclosing scope's locals, so its captured state is what the SPEC supplies.
--- That makes it `derived` and never `measured`, and it makes a same-file definition a
--- real HOLE instead of something the module load answers — see satisfied_by. A function
--- that shares mutable state with its enclosing scope will NOT behave identically here,
--- which is a premise the spec has to print rather than a caveat we keep to ourselves.
---
--- WE COMPILE BUT NEVER RUN, and that line matters: `plan()` must not execute user code
--- (only :CartographCharacterizeRun does). Compiling is a pure syntax check, so the
--- derivation is self-checking — a declaration that does not compile standalone cannot be
--- reconstructed and the compiler says so exactly.
---
--- BUT COMPILING IS NOT ENOUGH, and this cost a real plan/run disagreement to learn.
--- `local NIL = setmetatable({}, { __tostring = function () return 'nil' end })` compiles
--- perfectly, and `return __tostring` then reads a nil GLOBAL: the text was a statement
--- that binds something else entirely. Compiling proves SYNTAX; it says nothing about
--- WHICH NAME the text binds, and only running would settle that. So the form is chosen
--- SYNTACTICALLY, from three shapes that bind the subject BY CONSTRUCTION:
---   `local function f()`   the statement already binds it        (wrap = 'none')
---   `function f()`         a global fn decl, localised            (wrap = 'local')
---   `function(...)`        an anonymous expression, named         (wrap = 'assign')
--- Anything else is refused rather than hoped about.
---
--- AND THE DECLARATION MUST OWN ITS LINES. The spec re-reads whole lines, so a function
--- sharing a line with other code (the `NIL` case above: `local NIL = setmetatable({}, {`
--- before it and ` })` after) would drag that code in. Refusing here is what keeps the
--- run-time mechanism simple enough to trust: whole lines, grown until they compile.
local function reconstruct(node, lines)
    local sl, el = at.sl(node.range) + 1, at.el(node.range) + 1
    local name = node.name
    if not (name and lines[sl] and lines[el] and sl <= el) then return nil end
    local before = lines[sl]:sub(1, at.sc(node.range))
    local after = lines[el]:sub(at.ec(node.range) + 1)
    if before:match('%S') or after:match('%S') then
        return nil, ('the declaration shares its line with other code (`%s` before it,'
            .. ' `%s` after), so extracting whole lines would carry that code along')
            :format(oneline_trim(before), oneline_trim(after))
    end
    local text = table.concat(lines, '\n', sl, el)
    local head = text:gsub('^%s+', '')
    local esc = name:gsub('%W', '%%%0')
    local wrap
    if head:match('^local%s+function%s+' .. esc .. '%f[^%w_]') then wrap = 'none'
    elseif head:match('^function%s+' .. esc .. '%f[^%w_]') then wrap = 'local'
    elseif head:match('^function%s*%(') then wrap = 'assign'
    else
        return nil, ('the declaration does not begin with a shape that BINDS `%s`'
            .. ' (starts `%s`) — compiling it would prove syntax and bind something else')
            :format(name, oneline_trim(head:sub(1, 40)))
    end
    local ld = loadstring or load
    local chunk, err = ld(('%s\nreturn %s'):format(WRAP(text, name, wrap), name),
        'reconstruct')
    if not chunk then
        return nil, ('the declaration at %s:%d does not compile on its own (%s)')
            :format(node.file, sl, tostring(err))
    end
    -- THE ANCHOR IS THE DECLARATION'S OWN FIRST LINE, not its line NUMBER: the spec
    -- re-reads the file when it runs (never a snapshot — an embedded copy would pass
    -- forever after an edit, which is the silence this codebase keeps paying for), and a
    -- line number goes stale the moment anything above it moves. It must be UNIQUE in the
    -- file or the spec cannot know which of them is its subject.
    local anchor = anchor_of(lines[sl])
    local hits = 0
    for _, l in ipairs(lines) do
        if l:sub(1, #anchor) == anchor then hits = hits + 1 end
    end
    if hits ~= 1 then
        return nil, ('the declaration\'s signature `%s` is not unique in %s (%d'
            .. ' occurrences), so a spec re-reading the file could not tell which one is'
            .. ' the subject'):format(oneline_trim(anchor), node.file, hits)
    end
    return { anchor = anchor, lines = el - sl + 1, wrap = wrap }
end

--- HOW THE SPEC REACHES THE SUBJECT, which is a hole of its own when it cannot. Four
--- kinds, and the split between the last two is the whole of CART-0286:
---   member     `function M.add()` — a member of whatever the module returns
---   upvalue    a FILE-LEVEL `local function`, reached as an upvalue of an exported fn
---   nested     a `local function` INSIDE another function — not an OBJECT until the
---              enclosing call runs, so THIS mechanism cannot reach it
---   unreturned the module does not end in `return <root>`, so the reach is unverified
---
--- A REFUSAL HERE IS ABOUT THIS MECHANISM, NOT ABOUT THE CODE, and the first version of
--- this comment got that wrong (user, 2026-08-05: "they're only unreachable because we
--- don't have anything to reach in and make it run"). Walking a module's exports needs a
--- module — so a SCRIPT's file-level local and a NESTED closure both refuse, and neither
--- is unreachable in general: a declaration compiles from its own source text with its
--- free names supplied exactly as the fixture holes already supply them. That is a
--- RECONSTRUCTION (`derived`) rather than the object the module built (`measured`) —
--- same bytes, captured state that WE supplied — and conflating the two would report a
--- fact about our own closure as a fact about theirs. CART-0289 builds it; this comment
--- exists so the refusal below is never read as a statement about the language.
---
--- THE MODULE-TABLE ASSUMPTION IS CHECKED, not assumed: the file must actually
--- `return <root>` at module level, where <root> is the name the definition hangs off.
--- Guessing here would emit a spec that dies with "attempt to index nil", which reads
--- as a broken tool rather than as the missing premise it is.
---
--- MEASURED, and it is why this is two kinds rather than one (self, lua/ only): 1887
--- file-level locals against 618 nested closures, counted as ONE hole class with ONE
--- refusal. Their ceilings are opposite — one is mechanically reachable, the other never
--- can be — so one sentence for both was a number that described neither.
--- A FUNCTION THAT IS A FIELD OF THE MODULE'S OWN TABLE (CART-0367). The `member` branch
--- below answers `function M.f()` by reading the node's NAME, but a function written as a
--- constructor field is named BARE — the extractor calls it `is_method`, never
--- `M.is_method` — so that branch never saw it and every one fell through to reconstruction
--- or refusal. Same reach, same proof obligation, different spelling.
---
--- ★ THE FORMS WERE ENUMERATED BEFORE THIS WAS BUILT, AND IT DECIDED THE SHAPE. Measured:
--- `return { f = function () end }` 87 · one level of nesting 17 · `M.sub = {…}` 2 ·
--- `local M = { f = fn }` ZERO — the form CART-0288 assumed does not occur on this tree at
--- all. 95 of 133 refusals are reachable this way; building for the assumed shape would have
--- shipped a no-op.
---
--- ★ KEYED BY POSITION, NEVER BY NAME. panes/concerns.lua holds EIGHT `ascend` closures in
--- eight sub-tables, and keying on the name mapped all eight to one path. That is exactly
--- the impostor `upvalue_chain`'s identity check exists to reject.
---
--- SOUNDNESS: the file must actually end in `return <root>` (or return the constructor
--- itself), the key must be a literal, and the value must BE the closure at this node's
--- line. Over-claiming here emits a spec whose SUBJECT is nil, which reads as a broken tool
--- rather than the missing premise it is — so every step is checked, none assumed.
--- ★ CACHED BY store.generation, THE EXISTING IDIOM (clones.lua build_index). `store` is a
--- SINGLETON re-ingested in place, so a cache keyed on the store object alone survives the
--- next ingest and answers about the PREVIOUS tree. It cost this build a debugging round:
--- every test fixture is written to `m.lua`, so the first proj() cached an empty table for
--- that path and every later fixture inherited it — a stale-cache miss that looks exactly
--- like a derivation that does not fire.
local field_reach_cache = nil
local function field_reach(store, node)
    -- LAZY, like every other cross-module require in this file: holes -> synth -> runoracle
    -- -> characterize -> holes is a load cycle, and a top-level require re-enters mid-load
    -- (the CART-0326 lesson, recorded in holes.lua).
    local expr = require 'cartograph.expr'
    if not field_reach_cache or field_reach_cache.gen ~= store.generation then
        -- ★ THE MODULE NODE IS NOT IN store.by_file — that index holds functions and regions
        -- only, which is why the first cut of this silently answered nil for every file. The
        -- file -> module map is built ONCE per generation here rather than rescanned per file.
        local mods = {}
        for _, n in ipairs(store.data.nodes or {}) do
            if n.kind == 'module' and n.file then mods[n.file] = n.id end
        end
        field_reach_cache = { gen = store.generation, byfile = {}, mods = mods }
    end
    local byfile = field_reach_cache.byfile
    local t = byfile[node.file]
    if t == nil then
        t = {}
        byfile[node.file] = t
        local mid = field_reach_cache.mods[node.file]
        local okm, mo = false, nil
        if mid then okm, mo = pcall(expr.of_module, store, mid) end
        local stmts = okm and mo and mo.fl and mo.fl.stmts or {}
        -- what the file hands back: a NAME, or the constructor itself
        local returns
        for i = #stmts, 1, -1 do
            if (stmts[i].t or ''):find('return') then
                local e = stmts[i].expr and stmts[i].expr.rhs and stmts[i].expr.rhs[1]
                if e then
                    returns = (e.k == 'name' and e.n) or (e.k == 'table' and '\1tbl') or nil
                end
                break
            end
        end
        if returns then
            local function harvest(e, path, depth)
                if depth > 4 then return end -- a stated bound, not a belief: deeper is unmeasured
                for _, kid in ipairs(e.kids or {}) do
                    if kid.k == 'pair' and kid.key and kid.key.k == 'lit' and kid.val then
                        local sub = path .. '.' .. tostring(kid.key.v)
                        if kid.val.k == 'fn' then
                            local a = kid.val.at
                            local ln = a and at.sl(a)
                            if ln then t[ln] = sub end
                        elseif kid.val.k == 'table' then
                            harvest(kid.val, sub, depth + 1)
                        end
                    end
                end
            end
            for _, s in ipairs(stmts) do
                local lhs = (s.expr and s.expr.lhs) or {}
                local e = (s.expr and s.expr.rhs) and s.expr.rhs[1]
                if e and e.k == 'table' then
                    if s.def and #s.def == 1 and s.def[1] == returns then
                        harvest(e, 'SUBJECT', 1)
                    elseif #lhs == 1 and lhs[1].k == 'field' then
                        local dotted = expr.dotted(lhs[1])
                        local root = dotted and dotted:match('^([^.]+)')
                        if root and root == returns then
                            harvest(e, 'SUBJECT' .. dotted:sub(#root + 1), 1)
                        end
                    elseif returns == '\1tbl' and (s.t or ''):find('return') then
                        harvest(e, 'SUBJECT', 1)
                    end
                end
            end
        end
    end
    return t[at.sl(node.range)]
end

local function reach_of(store, node, lines)
    local root, member = (node.name or ''):match('^([%w_]+)%.([%w_]+)$')
    local returns_root = false
    if root then
        for i = #lines, 1, -1 do
            local l = lines[i]
            if l and l:match('%S') then
                returns_root = l:match('^%s*return%s+' .. root .. '%s*$') ~= nil
                break
            end
        end
    end
    if root and returns_root then
        return { kind = 'member', module = root, member = member,
            expr = 'SUBJECT.' .. member }
    end
    if root then
        return { kind = 'unreturned', module = root, member = member,
            why = ('%s does not end in `return %s`, so what dofile hands back may not'
                .. ' hold `%s` — the reach is unverified'):format(node.file, root,
                tostring(node.name)) }
    end
    -- NESTED IS A DIFFERENT REFUSAL, and it is a DOOR rather than a dead end: the thing
    -- to characterize is the enclosing function, and the message says which one.
    local fns = file_fns(store, node.file)
    local host = enclosing_fn(fns, node)
    if host then
        local rc, rcwhy = reconstruct(node, lines)
        if rc then
            return { kind = 'reconstructed', name = node.name, expr = 'SUBJECT',
                host = host.name, host_id = host.id,
                anchor = rc.anchor, decl_lines = rc.lines, wrap = rc.wrap,
                why = ('`%s` is nested inside `%s` so it is not an OBJECT until `%s` runs'
                    .. ' — RECONSTRUCTED from its own %d-line declaration instead. Same'
                    .. ' bytes, but the enclosing locals it closes over are whatever this'
                    .. ' spec supplies, NOT what `%s` would have built'):format(
                    tostring(node.name), tostring(host.name), tostring(host.name),
                    rc.lines, tostring(host.name)) }
        end
        return { kind = 'nested', name = node.name, host = host.name,
            host_id = host.id,
            why = ('`%s` is nested inside `%s`: it is not an OBJECT until `%s` runs, so'
                .. ' the upvalue walk cannot reach it, and it cannot be reconstructed'
                .. ' either (%s) — characterize `%s` instead'):format(
                tostring(node.name), tostring(host.name), tostring(host.name),
                tostring(rcwhy or 'no declaration text'), tostring(host.name)) }
    end
    local up = upvalue_chain(store, node, lines)
    if up then
        return { kind = 'upvalue', name = node.name, expr = 'SUBJECT',
            carrier = up.carrier, module = up.module, chain = up.chain,
            -- the IDENTITY check's two halves: a name match alone would accept an
            -- impostor of the same name defined elsewhere
            src = node.file, line = at.sl(node.range) + 1,
            why = ('`%s` is file-level-local, reached as an upvalue of `%s`%s — the real'
                .. ' function object, NOT the public surface'):format(
                tostring(node.name), up.carrier,
                #up.chain > 1 and (' via ' .. table.concat(up.chain, ' <- ')) or '') }
    end
    -- A FIELD OF THE MODULE'S OWN TABLE (CART-0367) — the real object the module built,
    -- so it outranks a reconstruction (same bytes, but state WE supplied) and is checked
    -- before it. Not before the upvalue walk: both hand back the real function, and that
    -- one is already proven.
    local fpath = field_reach(store, node)
    if fpath then
        return { kind = 'member', module = node.file, member = fpath:match('([^.]+)$'),
            expr = fpath,
            why = ('`%s` is a function-valued field of the table %s returns, reached at %s'
                .. ' — the real object the module built, not a rebuild')
                :format(tostring(node.name), node.file, fpath) }
    end
    -- NOTHING EXPORTED MENTIONS IT — which for a SCRIPT (tools/, tests/: no `return M` at
    -- all) is the normal case, not an anomaly. Reconstruction does not need an export.
    local rc, rcwhy = reconstruct(node, lines)
    if rc then
        return { kind = 'reconstructed', name = node.name, expr = 'SUBJECT',
            anchor = rc.anchor, decl_lines = rc.lines, wrap = rc.wrap,
            why = ('`%s` is file-level-local in %s and nothing exported mentions it (a'
                .. ' SCRIPT has no module table to walk), so it is RECONSTRUCTED from its'
                .. ' own %d-line declaration. Same bytes; every free name it reads is'
                .. ' whatever this spec supplies'):format(
                tostring(node.name), node.file, rc.lines) }
    end
    return { kind = 'file-local', name = node.name,
        why = ('`%s` is file-level-local in %s, nothing exported mentions it, and it'
            .. ' cannot be reconstructed either (%s)'):format(
            tostring(node.name), node.file, tostring(rcwhy or 'no declaration text')) }
end

--- CAN THE SPEC LOAD THE SUBJECT MODULE AT ALL? Returns (package_path_lines, nil) or
--- (nil, why). Found by DRIVING the verb on a real module rather than a fixture: the
--- fixture required nothing, so `dofile` worked; every real module opens with
--- `require 'cartograph.annot'`, and a bare dofile dies with "module 'x' not found".
---
--- THAT CRASH IS THE FAILURE MODE TO KILL. A spec that dies inside its own preamble
--- reads as a broken TOOL, while the truth is a missing PREMISE — the module needs a
--- package path we have not supplied. So the load is a premise like any other: derived
--- when we can align it, a HOLE when we cannot, never a crash.
---
--- THE ALIGNMENT IS THE DERIVATION: a `require 'a.b.c'` resolves to `a/b/c.lua`, so if
--- the graph holds a file whose path ends that way, the package root is the prefix that
--- remains. Nothing is guessed — a modname we cannot align is named in the refusal.
--- Can the graph align a module NAME to a file it holds? `a.b.c` -> `a/b/c.lua` or
--- `a/b/c/init.lua` — BOTH package forms, because checking only the first reports every
--- directory-with-an-init as absent. Returns the path PREFIX (what package.path needs) or
--- nil. ★ ONE OWNER: load_premise needs it to build the preamble and the require fill needs
--- it to decide whether a stub asserts something we can see. A second copy of a rule this
--- fiddly is a disagreement waiting to be found by whoever trusts the wrong one.
local function module_aligns(store, m)
    local want = (m:gsub('%.', '/')):gsub('%-', '%%-')
    for rel in pairs(store.by_file or {}) do
        if type(rel) == 'string' then
            local pre = rel:match('^(.*)' .. want .. '%.lua$')
                or rel:match('^(.*)' .. want .. '/init%.lua$')
            if pre then return pre end
        end
    end
    return nil
end
M.module_aligns = module_aligns

local function load_premise(store, node, lines)
    local mods, order = {}, {}
    for _, l in ipairs(lines) do
        -- module level only: an indented require runs when its function is CALLED, and
        -- the spec's own call is what would trigger it
        if l:match('^%s*local%s') or l:match('^%s*require') or l:match('^[%w_]') then
            for m in l:gmatch("require%s*%(?%s*['\"]([%w%._%-/]+)['\"]") do
                if not mods[m] then mods[m] = true; order[#order + 1] = m end
            end
        end
    end
    if #order == 0 then return {}, nil end          -- requires nothing: dofile is enough
    local root = store.data.root
    local roots, missing = {}, {}
    for _, m in ipairs(order) do
        local hit = module_aligns(store, m)
        if hit then roots[hit] = true else missing[#missing + 1] = m end
    end
    if #missing > 0 then
        return nil, ('%s requires %s, which this graph cannot align to a file — a spec'
            .. ' that dofiles it would die inside its own preamble with "module not'
            .. ' found", so the LOAD is the hole'):format(node.file,
            table.concat(missing, ', ', 1, math.min(3, #missing))
                .. (#missing > 3 and (' (+' .. (#missing - 3) .. ')') or ''))
    end
    local out, seen = {}, {}
    for pre in pairs(roots) do
        local abs = root and (root .. '/' .. pre) or pre
        abs = abs:gsub('/+$', '')
        if not seen[abs] then
            seen[abs] = true
            out[#out + 1] = ('package.path = %q .. package.path')
                :format(abs .. '/?.lua;' .. abs .. '/?/init.lua;')
        end
    end
    table.sort(out)
    return out, nil
end

--- Is this hole already answered by the spec's own environment? Returns the MECHANISM
--- or nil. Two cases, both measured rather than assumed:
---  · a stdlib dependency (rule='stdlib') — the spec runs in a Lua runtime that HAS
---    `table.concat`; nothing needs injecting.
---  · a `derived` fixture (a same-file definition) — the spec dofiles the module, so
---    the definition is in the function's own closure by the time it is called.
--- A HEDGED stdlib signature is deliberately NOT satisfied here: `s:match` was signed
--- by the only stdlib owner of the name with the receiver unverified (CART-0266), so
--- the RUNTIME may hold something else entirely under that name.
local function satisfied_by(h, reach)
    if h.kind == 'dependency' and h.rule == 'stdlib' then
        -- A HEDGED signature is satisfied TOO, and this changed after driving it: a
        -- receiver-unverified match like `("x"):rep(n)` → string#rep was BLOCKING the run
        -- of any function using the idiom, even though the interpreter plainly holds
        -- string.rep. Over-strict, and in the one direction that costs coverage for
        -- nothing: if the receiver is NOT what we guessed, the subject fails when it runs
        -- and the probe reports that failure verbatim — the hedge cannot hide a wrong
        -- answer here, it can only be wrong about who supplies the name. So it is
        -- satisfied WITH THE HEDGE NAMED, which is what a premise line is for.
        return h.hedged
            and 'the runtime, HEDGED: the only stdlib owner of this member name, receiver'
                .. ' unverified — if the receiver is something else, the run will say so'
            or 'the runtime: a Lua interpreter holds this'
    end
    if h.kind == 'dependency' and h.owners then
        -- AN AMBIGUOUS STDLIB NAME IS STILL SUPPLIED BY THE RUNTIME. The SET is about
        -- which OWNER declares the member (`write` is file's and io's), not about whether
        -- the name exists — the interpreter holds every candidate. Blocking here stopped
        -- any subject using `f:write(...)` from running at all, for a question that does
        -- not affect availability. Disclosed with the set named, per usual.
        return ('the runtime, which holds every candidate owner (%s) — the SET is about'
            .. ' which one declares it, not about whether it exists'):format(
            table.concat(h.owners, ', '))
    end
    if h.kind == 'fixture' and h.tier == 'derived' then
        -- A RECONSTRUCTION DOES NOT LOAD THE MODULE, so the module load cannot answer
        -- this (CART-0289). The subject is compiled from its own text, and its free names
        -- resolve as GLOBALS — so a same-file definition is a REAL hole here, and saying
        -- otherwise would emit a spec that dies on a nil global while its premise list
        -- claimed the environment had it covered. The tier stays `derived` (our analysis
        -- did find the definition); what changes is whether anything SUPPLIES it.
        if reach and reach.kind == 'reconstructed' then return nil end
        return 'loading the module: a same-file definition carries this name'
    end
    if h.kind == 'reach' and h.tier == 'derived' then
        if reach and reach.kind == 'reconstructed' then
            -- CART-0289. The loudest premise this file emits, and deliberately: what runs
            -- is OUR closure over the subject's bytes, not the one the file builds.
            return ('RECOMPILING the declaration from the file at run time — same bytes,'
                .. ' but every free name resolves to what this spec supplies, so it is an'
                .. ' EQUIVALENT closure and not the object %s builds'):format(
                reach.host and ('`' .. reach.host .. '`') or 'the file')
        end
        -- CART-0286: the spec walks upvalues and gets the REAL function object, so the
        -- environment does answer this — but the premise is loud, because a subject
        -- reached this way is one the module never promised.
        return ('the transitive UPVALUE walk from the module\'s exports (`%s`) — the real'
            .. ' function object, reached PAST the public surface'):format(
            tostring(h.carrier))
    end
    return nil
end


-- ── THE SANDBOX (CART-0277, user steer: "can't we just inject our own functions?") ──
-- An `io` subject was REFUSED outright, which is the safe answer and a poor one: the
-- population it excludes is exactly the population a refactor most needs a witness for.
-- So instead of refusing, INJECT — the CART-0261 injection frame turned on the DANGEROUS
-- case instead of the ABSENT one. A fake `io.open` records the call and touches nothing.
--
-- AND THE REAL PRIZE IS NOT RUNNING io FUNCTIONS. It is functions that return NOTHING,
-- whose behaviour IS their effects: this used to emit "no oracle … which this spec does
-- not observe", i.e. silence where a hole belongs. With a sandbox the CALL LOG is the
-- oracle, and a population that was 100% uncharacterizable becomes characterizable.
--
-- A FAKE IS A SUPPLIED PREMISE, NOT THE TRUTH, and that governs everything here. With a
-- fake that fails, `io.open(p) ~= nil` records false; with one that succeeds, true. BOTH
-- are facts about OUR STUB. So every injected name is disclosed as a premise, the basis
-- says the value was measured UNDER this environment, and THE SPEC INSTALLS THE SAME
-- SANDBOX — a spec that ran against a different world could not reproduce the value it
-- was handed, and the mismatch would read as a behaviour change in the subject.
--
-- The formatter is deliberately small: a call LOG needs argument text, not a faithful
-- round-trippable value (that is runoracle.serialize's job for the RETURN). Both the
-- probe and the spec emit this same block, from here, for the usual reason.
-- ── THE OPAQUE SENTINEL (CART-0280, user: "if the return value is only passed around, we
--    never need to know what it is") ─────────────────────────────────────────
-- A fake that returns `nil` TRUNCATES THE TRACE, and that shipped as a fabrication: for
--     function M.save(p, s) local f = io.open(p,"w") if f then f:write(s) f:close() end return p end
-- the recorded log was `io.open("/tmp/zz","w")` AND NOTHING ELSE, because `if f then` was
-- false. A characterization that claims to describe what a function DOES, omitting the two
-- calls that actually save anything, while LOOKING complete.
--
-- `f` is only PASSED AROUND — receiver of `:write` and `:close`, never inspected — so the
-- fake does not need to return a FILE HANDLE. It needs to return an OPAQUE SENTINEL THAT
-- RECORDS ITS OWN USE. A value nobody inspects needs an IDENTITY, not a value, and the
-- sentinel's recorded uses ARE its identity ([[cartograph-anonymous-types]] one layer down).
--
-- WHAT THE PROXY CAN AND CANNOT SEE IS MEASURED, not assumed (LuaJIT 2.1):
--   if f then        truthy, no metamethod    -> THE BODY RUNS. This is the whole fix.
--   f == nil         no __eq (table vs nil)   -> reads as not-nil, correctly
--   f.size, f:m(x)   __index then __call      -> observable
--   "x"..f, f.n+1    __concat, __add          -> observable
--   #f               __len NEVER FIRES        -> silently 0 (5.1 semantics). A BLIND SPOT.
--   f.size > 0       __lt NEVER FIRES         -> RAISES (5.1 compares mixed types directly)
-- The last two are why the static side matters: a `#` inspection would let the run answer 0
-- and never say so, and a comparison aborts the run. Both are caught from the expression IR
-- as BLOCKING holes instead (see inspect_holes), so the proxy is used only where it works.
local SANDBOX_SRC = {
    -- __ins is SEPARATE from __log: an inspection is not something the subject DID to the
    -- world, it is something it ASKED of a value — a different kind of row, and folding the
    -- two would make the effect trace unstable under a change that observes nothing.
    'local __log, __restore, __seen, __ins = {}, {}, {}, {}',
    'local __nsent = 0',
    'local function __fmt(v)',
    '    local t = type(v)',
    '    if t == "string" then return string.format("%q", v) end',
    '    if t == "number" or t == "boolean" or v == nil then return tostring(v) end',
    '    if t == "table" then return __seen[v] or "{table}" end',
    '    return "<" .. t .. ">"',
    'end',
    -- WHATEVER WE REPLACE, WE PUT BACK (a sandbox that outlives its subject has escaped).
    'local function __patch(path, fake)',
    '    local t = _G',
    '    for i = 1, #path - 1 do',
    '        t = t and t[path[i]]',
    '        if type(t) ~= "table" then return false end',
    '    end',
    '    local key = path[#path]',
    '    local old = t[key]',
    '    __restore[#__restore + 1] = function () t[key] = old end',
    '    t[key] = fake',
    '    return true',
    'end',
    'local function __unsandbox()',
    '    for i = #__restore, 1, -1 do __restore[i]() end',
    '    __restore = {}',
    'end',
    -- THE SENTINEL. Numbered, so the log shows IDENTITY: one handle used twice is a different
    -- trace from two handles used once, and a characterization that cannot tell them apart is
    -- describing a different program.
    'local __mt',
    'local function __sentinel(label)',
    '    __nsent = __nsent + 1',
    '    local name = label or ("<h" .. __nsent .. ">")',
    '    local p = setmetatable({}, __mt)',
    '    __seen[p] = name',
    '    return p, name',
    'end',
    '__mt = {',
    '    __index = function (t, k)',
    -- A read is NOT logged here: `f:write(x)` is an index followed by a call, and logging
    -- the index too would double-report one event. The DERIVED sentinel remembers where it
    -- came from, and whatever happens to it next is what gets recorded.
    '        local d = select(1, __sentinel((__seen[t] or "?") .. "." .. tostring(k)))',
    '        return d',
    '    end,',
    '    __call = function (t, ...)',
    '        local n, a = select("#", ...), {}',
    '        for i = 1, n do a[i] = __fmt((select(i, ...))) end',
    '        local nm = __seen[t] or "?"',
    -- METHOD FORM when the first argument IS the receiver: `<h1>:write("hi")` rather than
    -- `<h1>.write(<h1>, "hi")`. The same event, rendered the way it was written.
    '        local recv, meth = nm:match("^(.*)%.([%w_]+)$")',
    '        if recv and n > 0 and __seen[(select(1, ...))] == recv then',
    '            table.remove(a, 1)',
    '            __log[#__log + 1] = recv .. ":" .. meth .. "(" .. table.concat(a, ", ") .. ")"',
    '        else',
    '            __log[#__log + 1] = nm .. "(" .. table.concat(a, ", ") .. ")"',
    '        end',
    '        return (__sentinel(nm .. "()"))',
    '    end,',
    -- INSPECTIONS. Each is a DERIVED HOLE with a relation, recorded with the operator that
    -- observed it, because how the value is USED is evidence about what it must be.
    '    __concat = function (a, b)',
    '        local nm = __seen[a] or __seen[b] or "?"',
    '        __ins[#__ins + 1] = nm .. " concat"',
    '        return tostring(nm)',
    '    end,',
    '    __add = function (a, b)',
    '        local nm = __seen[a] or __seen[b] or "?"',
    '        __ins[#__ins + 1] = nm .. " arith"',
    '        return 0',
    '    end,',
    '    __tostring = function (t)',
    '        __ins[#__ins + 1] = (__seen[t] or "?") .. " tostring"',
    '        return __seen[t] or "<opaque>"',
    '    end,',
    '}',
    -- EVERY RETURN VALUE OF THE FAKE, and this is the second time this exact truncation has
    -- shipped: `local r = fake(...)` keeps the FIRST and drops the rest, so `os.execute`'s
    -- `nil, "sandboxed…"` became a bare `nil`. The suite caught it — a test written for
    -- CART-0263's truncation catching the same class in the code that fixed it. Multi-value
    -- returns need select('#') EVERY time they cross a boundary.
    'local function __pack(...) return select("#", ...), { ... } end',
    'local function __rec(name, fake)',
    '    return function (...)',
    '        local n, a = select("#", ...), {}',
    '        for i = 1, n do a[i] = __fmt((select(i, ...))) end',
    '        local call = name .. "(" .. table.concat(a, ", ") .. ")"',
    '        if fake then',
    '            local rn, rv = __pack(fake(...))',
    '            local r = rv[1]',
    -- AN OPAQUE RETURN IS A SENTINEL, so the trace CONTINUES instead of dying at the guard.
    '            if r == "__CARTOGRAPH_OPAQUE__" then',
    '                local p, nm = __sentinel()',
    '                __log[#__log + 1] = call .. " -> " .. nm',
    '                return p',
    '            end',
    '            __log[#__log + 1] = call',
    '            return (unpack or table.unpack)(rv, 1, rn)',
    '        end',
    '        __log[#__log + 1] = call',
    '    end',
    'end',
}

--- A STUB SYNTHESIZED FROM A DECLARED SIGNATURE (CART-0287), or nil to keep refusing.
---
--- The hole's own `why` already said this: "the profile declares (modname: string) -> unknown,
--- so a stub of that shape would fill it". 294 of the 304 such holes on this tree are `require`.
---
--- ★ THE RULE IS "NO VALUE IS INVENTED", NOT A LIST OF TYPES, which is why it is this short.
--- Exactly two shapes can be honoured without fabricating something:
---   · `-> unknown` — the caller gets an IDENTITY, not a value: the OPAQUE SENTINEL, whose
---     recorded uses ARE its identity (invariant 5). A stub returning `nil` here would
---     TRUNCATE the trace at the first `if mod then` or index — precisely the defect io.open
---     shipped and CART-0280 was written to fix. The sentinel continues and records instead.
---   · a declared VOID — nothing to return, so nothing to invent.
--- Everything else REFUSES, `any` included: a declared `string` gives the shape and not the
--- string, and picking one is the fabrication this arc exists to make structurally impossible.
---@param sig string|nil  the declared signature, e.g. `(modname: string) -> unknown`
---@return string|nil source
function M.stub_of(sig)
    if type(sig) ~= 'string' then return nil end
    local ret = sig:match('%->%s*(.+)$')
    if not ret then return 'function () end' end          -- declared, returns nothing
    if ret:match('^unknown%s*$') then                     -- an identity, not a value
        return 'function () return ' .. M.OPAQUE .. ' end'
    end
    return nil                                            -- a shape is not a value
end

--- THE TIER OF AN INJECTED FAKE. `claim`, uniformly and deliberately: a fake is something we
--- DECLARED, exactly like an annotation, and CART-0240 established that a declaration is the
--- weakest evidence there is. A future fill could be stronger — a value RECORDED from a real
--- unsandboxed run would be `measured`, and a profile-supplied one is still a `claim` — which
--- is the whole point of treating the environment as a hole: the fill has a tier, and better
--- sources can replace ours without any of this machinery changing.
M.SANDBOX_TIER = 'claim'

--- The injectable roster: name → the FAKE's return, as Lua source. Every entry is a
--- DECLARED answer rather than a plausible one, and each is chosen to be the least
--- surprising failure: an unopened file is `nil, reason`, which is what real `io.open`
--- returns when it cannot open — so a subject that checks for nil takes its own error
--- path instead of dying inside our stub.
---
--- `os.exit` IS THE ONE THAT MUST BE HERE. A subject calling it would kill the probe
--- before it could report, and the run would surface as "produced no value" — a tool
--- failure where the truth is "the subject exited". Faked into an error, it is a finding.
-- A fake returning this SENTINEL STRING gets an opaque handle instead (see __rec). It is a
-- string rather than a flag on the roster because the roster's values are SOURCE, and the
-- probe is the only place that can mint a sentinel.
M.OPAQUE = '"__CARTOGRAPH_OPAQUE__"'
M.SANDBOX = {
    -- io.open USED TO RETURN nil, AND THAT TRUNCATED EVERY TRACE THROUGH IT: `if f then
    -- f:write(s) end` never ran, so the log recorded the open and none of the writing. An
    -- OPAQUE HANDLE lets the subject continue and records what it does with it, which is the
    -- behaviour we were trying to characterize in the first place.
    ['io.open'] = 'function () return ' .. M.OPAQUE .. ' end',
    ['io.lines'] = 'function () return function () return nil end end',
    ['io.read'] = 'function () return nil end',
    ['io.write'] = 'function () return ' .. M.OPAQUE .. ' end',
    ['io.popen'] = 'function () return ' .. M.OPAQUE .. ' end',
    ['os.execute'] = 'function () return nil, "sandboxed: nothing was executed" end',
    ['os.remove'] = 'function () return nil, "sandboxed: nothing was removed" end',
    ['os.rename'] = 'function () return nil, "sandboxed: nothing was renamed" end',
    ['os.getenv'] = 'function () return nil end',
    ['os.tmpname'] = 'function () return "/sandboxed/tmpname" end',
    ['os.time'] = 'function () return 0 end',
    ['os.clock'] = 'function () return 0 end',
    ['os.date'] = 'function () return "sandboxed" end',
    ['os.exit'] = 'function (c) error("sandboxed: the subject called os.exit("'
        .. ' .. tostring(c) .. ")", 0) end',
    print = 'function () return nil end',
    collectgarbage = 'function () return 0 end',
}

--- WHICH ENV FILLS ARE INSTALLED — a VIEW over the holes, never stored state. This was a
--- `plan.sandbox` field computed once at plan time, and it made a filled hole a lie: an agent
--- filling `env:vim.fn.tempname` AFTER planning was accepted, never installed, and the run
--- then went through the REAL nondeterministic call while the oracle was tiered `measured`.
--- Two things wrong at once, both from a cached copy of state that had moved.
--- ONE SOURCE OF TRUTH, and the holes are it.
function M.sandbox_of(plan)
    local out, any = {}, false
    for _, h in ipairs(plan.holes or {}) do
        if h.kind == 'env' and h.value then out[h.name] = h.value; any = true end
    end
    return any and out or nil
end

--- The WEAKEST tier among the installed env fills, or nil when nothing is installed. A run
--- through an agent-invented stub is `agent-supplied` evidence, not `claim` and certainly not
--- `measured`: the environment's tier travels into everything observed through it.
function M.env_tier(plan)
    local t
    for _, h in ipairs(plan.holes or {}) do
        if h.kind == 'env' and h.value then t = M.weakest(t or h.filled_tier, h.filled_tier) end
    end
    return t
end

--- The sandbox as spec lines: the recorder, then one patch per injected name.
local function sandbox_lines(names)
    local L = {}
    for _, l in ipairs(SANDBOX_SRC) do L[#L + 1] = l end
    local sorted = {}
    for n in pairs(names or {}) do sorted[#sorted + 1] = n end
    table.sort(sorted)          -- deterministic: the spec must not churn between runs
    for _, n in ipairs(sorted) do
        local fake = names[n]
        if fake then
            local segs = {}
            for seg in n:gmatch('[%w_]+') do segs[#segs + 1] = ('%q'):format(seg) end
            -- AND IT MUST NOT FAIL SILENTLY: a path we cannot walk (the host is absent in
            -- this interpreter) is an ERROR, because a spec that ran unsandboxed while
            -- believing itself contained is the failure mode this whole layer exists to
            -- prevent.
            L[#L + 1] = ('if not __patch({ %s }, __rec("%s", %s)) then'):format(
                table.concat(segs, ', '), n, fake)
            L[#L + 1] = ('    error("sandbox: cannot install %s — the path does not exist'
                .. ' in this interpreter, so this spec would run UNSANDBOXED", 0)'):format(n)
            L[#L + 1] = 'end'
        end
    end
    return L
end
M.sandbox_lines = sandbox_lines

--- WHAT THIS FUNCTION NEEDS FROM ITS ENVIRONMENT, as HOLE ROWS (CART-0279, user: "why not
--- treat the environment as a hole to fill?"). Derived from the effect vocabulary, per callee.
---
--- THIS RETIRED THREE MECHANISMS THAT WERE ONE QUESTION. A hand-maintained sandbox roster, a
--- categorical io REFUSAL, and (a layer up) the VM's host problem were all enumerating the
--- same names for different reasons — and all three ask "what does this code need from its
--- environment, and who supplies it?", which is a HOLE. The hole machinery already had
--- everything: an id, an owning rule, a tier, a mandatory basis, prediction refused, a premise
--- line in the header, and an unfilled hole that ERRORS instead of passing.
---
--- WHEN THREE MECHANISMS KEEP NEEDING THE SAME LIST, THE LIST IS A FIRST-CLASS THING YOU HAVE
--- NOT NAMED YET.
---
--- SO THE REFUSAL IS GONE. A channel we have no fake for is no longer a reason to refuse the
--- whole subject — it is one more named, addressable hole, and the run's existing precondition
--- ("every hole but the oracle must be filled") blocks it for free. Strictly more coverage at
--- identical honesty: before this, ONE unmodelled call made a function uncharacterizable.
---
--- NONDET COUNTS, NOT JUST IO. Measured while building the sandbox: the vocabulary calls
--- `os.getenv` pure-but-NONDETERMINISTIC, so an io-only filter passed it through and a run
--- recorded this machine's real $HOME — a value that fails on anyone else's machine, and one
--- the purity LABEL cannot see either.
local function env_holes(store, node)
    local effects = require 'cartograph.effects'
    local callrec = require 'cartograph.callrec'
    local pm = require 'cartograph.spec.profile'
    local stdprof = pm.load(pm.base_for('lua'))
    local sites = (store.topo and store.topo().sites) and store.topo():sites(node.id) or {}
    -- ── THE require DECISION (CART-0365), decided by evidence, overridable by the user ──
    -- DEFAULT: a require the graph can ALIGN to a file it holds is stubbed; one it cannot is
    -- REFUSED, and the refusal names the module so the premise that discharges it is obvious.
    -- Measured: 1352 of 1356 require sites on this tree align, so the refusal costs one hole
    -- and KEEPS the guard tests/raise_spec earns — an unresolvable require is a PREMISE
    -- failure, and stubbing it characterizes a function as though the module existed.
    -- ★ WEAKEST LINK ACROSS THE FUNCTION: one env row covers every require in the body, so a
    -- single unalignable module refuses the row. Stubbing the others would emit a spec that
    -- runs past the one we cannot see.
    -- ★ THE OVERRIDE NEEDS NO NEW MACHINERY: ch.fill(plan, {['env:require'] = {…, by='agent'}})
    -- lands at tier `agent-supplied` (BY_TIER), the weakest rank, and env_tier carries it into
    -- everything the run observed through it. That is the house pattern —
    -- [[cartograph-hedge-resolution-writes]], and CART-0227's premise-dischargeable survey.
    local req_missing
    do
        local argvm = require 'cartograph.argv'
        for _, c in ipairs(sites) do
            if callrec.callee(c) == 'require' then
                local a = argvm.at(c, 1)
                local m = a and a.k == 'lit' and a.v or nil
                if type(m) ~= 'string' or m == '' then
                    req_missing = req_missing or '<a computed module name>'
                elseif not module_aligns(store, m) then
                    req_missing = req_missing or m
                end
            end
        end
    end
    local rows, seen = {}, {}
    for _, c in ipairs(sites) do
        for _, nm in ipairs({ callrec.full(c) or callrec.callee(c), callrec.callee(c) }) do
            if nm and not seen[nm] then
                seen[nm] = true
                local sig = effects.sig_of and effects.sig_of('lua', nm, false)
                if sig and (sig.io or sig.nondet) then
                    local fake = M.SANDBOX[nm]
                    -- A PROFILE SIGNATURE IS EVIDENCE, NOT A FILL. It gives the RETURN TYPE,
                    -- and a type is not a value — the same reason an `@param` annotation does
                    -- not fill an input hole. So it rides as an EDGE to what would fill this
                    -- ([[cartograph-explaining-a-finding]]), never as an invented value.
                    local declared = pm.member_sig and select(1, pm.member_sig(stdprof, nm:match('([%w_]+)$'), nm))
                    -- A DECLARED SHAPE WE CAN HONOUR WITHOUT INVENTING A VALUE IS A FILL
                    -- (CART-0287). The sentence below used to end "so a stub of that shape
                    -- would fill it" and then not build one — the fix was sitting in our own
                    -- explanation. M.stub_of decides; it refuses every shape whose honouring
                    -- would require picking a value, so the frontier sentence still gets used.
                    --
                    -- ★ `require` IS HELD BACK, AND IT IS 294 OF THE 304 (CART-0365). The stub
                    -- works and the sentinel behaves — but tests/raise_spec pins the OPPOSITE,
                    -- with evidence: an unresolvable require is a PREMISE failure, and
                    -- characterizing it freezes our incomplete premise into a test (it produced
                    -- a false CHANGED on 2 corpus functions, because the "module not found"
                    -- text embeds per-process search paths). A stub makes that raise vanish and
                    -- the subject characterizes as though the module existed. MEASURED: a
                    -- resolvable require and an absent one produce an IDENTICAL env hole here —
                    -- no `hard`, no dependency row — so the safe case cannot be told from the
                    -- unsafe one at this seam. Two hole KINDS claim `require` (env says isolate
                    -- it, dependency says its absence is an injection point) and they disagree.
                    -- That is a decision about what a characterization MEANS, not one to take
                    -- silently inside a fill.
                    local stub = not fake and declared
                        and (nm ~= 'require' or not req_missing)
                        and M.stub_of(declared.sig) or nil
                    local fill = fake or stub
                    rows[#rows + 1] = {
                        kind = 'env', name = nm, rule = 'profile',
                        -- OUR DEFAULT FILL, at the tier a DECLARATION deserves. It is data,
                        -- replaceable by a better source, which is the whole argument for the
                        -- reframe: the same hole can be filled better later and nothing here
                        -- changes.
                        value = fill or nil,
                        by = fill and 'sandbox' or nil,
                        filled_tier = fill and M.SANDBOX_TIER or nil,
                        basis = fake and ("cartograph's own declared fake — the call is"
                                .. ' RECORDED and the world is untouched')
                            or (stub and ('stub synthesized from the profile-declared %s —'
                                .. ' an opaque identity, no value invented'):format(declared.sig))
                            or nil,
                        declared = declared and declared.sig or nil,
                        why = fill and 'injected: the call is recorded, not performed'
                            or (nm == 'require' and req_missing and ('this graph cannot align'
                                .. ' `%s` to a file it holds, and stubbing it would'
                                .. ' characterize this function as though that module existed.'
                                .. ' Supply the premise to discharge it: fill env:require with'
                                .. " by='agent' (tier agent-supplied)"):format(req_missing))
                            or ((declared and ('the environment supplies this and we have no'
                                .. ' fake for it. The profile declares %s, and no stub of that'
                                .. ' shape can be built without inventing a return value')
                                :format(declared.sig)
                            or 'the environment supplies this and we have no fake for it —'
                                .. ' nothing we hold can say what it returns')),
                    }
                end
            end
        end
    end
    table.sort(rows, function (a, b) return a.name < b.name end)
    return rows
end
M.env_holes = env_holes

--- THE TWO BLIND SPOTS A SENTINEL CANNOT COVER, found statically because the run cannot see
--- them. MEASURED under LuaJIT: `#f` does NOT fire `__len` (5.1 semantics) and silently answers
--- 0, and `f.size > 0` does NOT fire `__lt` (5.1 compares mixed types directly) — it RAISES.
--- The second is at least loud; THE FIRST IS A SILENT LIE, and a sentinel that answers 0 for a
--- length has fabricated a value while looking opaque.
---
--- So a `#` applied to a value bound from an opaque channel is a BLOCKING hole with the
--- constraint stated: fill it with a real value, because the sentinel cannot stand in here.
--- The static answer is a LOWER BOUND (an alias we did not follow escapes it), which is why the
--- run's own failure message covers the comparison case rather than this walk trying to.
local function opaque_length_holes(store, node, opaque)
    if not next(opaque or {}) then return {} end
    local expr = require 'cartograph.expr'
    local eo = expr.of(store, node.id)
    local fl = eo and eo.fl
    if not fl then return {} end
    -- names bound from a call to an opaque channel
    local bound = {}
    for _, st in ipairs(fl.stmts or {}) do
        if st.expr and st.def and #st.def > 0 then
            local hit = false
            -- A ROW IS NOT AN EXPRESSION. `st.expr` carries { lhs, rhs, cond } lists (see
            -- expr.names), so walking the row itself traverses NOTHING — which is exactly how
            -- the length blind spot stayed undetected on its first outing: the check ran, saw
            -- no nodes, and reported nothing. A walker handed the wrong shape is silent.
            local function each(row, fn)
                for _, e in ipairs(row.rhs or {}) do expr.walk(e, fn) end
                for _, e in ipairs(row.lhs or {}) do expr.walk(e, fn) end
                if row.cond then expr.walk(row.cond, fn) end
            end
            each(st.expr, function (e)
                if e.k == 'call' and e.f then
                    local nm = expr.dotted(e.f) or e.f.n
                    if nm and (opaque[nm] or opaque[tostring(nm):match('([%w_]+)$') or '']) then
                        hit = true
                    end
                end
            end)
            if hit then for _, d in ipairs(st.def) do bound[d] = true end end
            st.__each = each
        end
    end
    if not next(bound) then return {} end
    local out, seen = {}, {}
    local function each(row, fn)
        for _, e in ipairs(row.rhs or {}) do expr.walk(e, fn) end
        for _, e in ipairs(row.lhs or {}) do expr.walk(e, fn) end
        if row.cond then expr.walk(row.cond, fn) end
    end
    for _, st in ipairs(fl.stmts or {}) do
        if st.expr then
            each(st.expr, function (e)
                if e.k == 'un' and e.op == '#' and e.e and e.e.k == 'name' and bound[e.e.n]
                    and not seen[e.e.n] then
                    seen[e.e.n] = true
                    out[#out + 1] = { kind = 'inspect', name = '#' .. e.e.n,
                        rule = 'execution', constraint = 'length',
                        relation = ('length of `%s`, which holds an opaque value')
                            :format(e.e.n),
                        why = ('the subject takes the LENGTH of `%s`, and a sentinel cannot'
                            .. ' stand in: LuaJIT does not fire __len on a table, so the run'
                            .. ' would SILENTLY answer 0. Supply a real value for it')
                            :format(e.e.n) }
                end
            end)
        end
    end
    return out
end

local function hole_id(h) return ('%s:%s'):format(h.kind, h.name or '?') end

--- One COMMENT line's worth of text. A control character here is not cosmetic: Lua treats
--- CR as a line terminator, so a value carrying one would end the comment early and the
--- remainder of the provenance line would parse as code. Belt to runoracle's braces —
--- the value's own CONTENT must not be able to break the file that quotes it.
local function oneline(s)
    return (tostring(s or ''):gsub('[\r\n\t]', ' '):gsub('%s+', ' '))
end

--- Stage a characterization plan for ONE function. Returns (plan, nil) or (nil, why).
--- `opts.path` overrides the output file; `opts.dir` overrides the directory.
function M.plan(store, fn_id, opts)
    opts = opts or {}
    local node = fn_id and store.node(fn_id)
    if not node then return nil, 'no such function' end
    if node.kind ~= 'function' and node.kind ~= 'method' then
        return nil, ('%s is a %s, not a function'):format(tostring(node.name),
            tostring(node.kind))
    end
    local lines = store.content(node)
    if not lines then return nil, 'no source for ' .. tostring(node.file) end
    local ts = require 'cartograph.providers.treesitter'
    local ctx = holes.ctx_for(store, node, lines,
        ts.annot_tag and ts.annot_tag(node.file),
        ts.attach_pats and ts.attach_pats(node.file))
    local H, why = holes.of(store, node, ctx)
    if not H then return nil, why or 'no holes computed' end

    -- REACH IS A HOLE ROW LIKE ANY OTHER, and it must be, because it is the one hole
    -- that makes every other one moot: a spec that cannot call its subject is not a
    -- spec. Keeping it only in `plan.subject` let the header report "2 unfilled" for a
    -- file-local function whose real answer is "3, and one of them is fatal".
    -- THE ENVIRONMENT AS HOLES (CART-0279), and the EFFECTS hole that exists because we can
    -- inject at all (CART-0277). `sandbox` is now DERIVED from the env holes that carry a
    -- fill, so the emitter installs exactly what is filled and nothing else.
    local envrows = env_holes(store, node)
    local inject, unfilled_env = {}, {}
    -- AN ENV HOLE SUBSUMES THE DEPENDENCY HOLE FOR THE SAME CALL. `vim.fn.tempname` arrived
    -- twice — once as `dependency:tempname` (an unresolved callee) and once as
    -- `env:vim.fn.tempname` (a channel the vocabulary names) — which is one NEED counted
    -- TWICE, inflating `unfilled` and giving a filler two ids for one thing. Exactly the
    -- duplication this reframe exists to remove, so the env row owns it: it carries the full
    -- path, the profile evidence and the fill mechanism, while the dependency row carries a
    -- bare segment and no way to answer. Matching on the last segment is sound HERE because
    -- both rows were derived from the same function's call sites.
    -- and the blind spots the sentinel cannot cover, from the static side
    local opaque = {}
    for _, e in ipairs(envrows) do
        if e.value and e.value:find('__CARTOGRAPH_OPAQUE__', 1, true) then
            opaque[e.name] = true
            opaque[e.name:match('([%w_]+)$') or e.name] = true
        end
    end
    for _, h in ipairs(opaque_length_holes(store, node, opaque)) do H[#H + 1] = h end
    local covered = {}
    for _, e in ipairs(envrows) do
        H[#H + 1] = e
        covered[e.name:match('([%w_]+)$') or e.name] = e.name
        if e.value then inject[e.name] = true else unfilled_env[#unfilled_env + 1] = e.name end
    end
    if next(covered) then
        local kept = {}
        for _, h in ipairs(H) do
            local sub = h.kind == 'dependency' and covered[h.name or '']
            if sub then
                -- recorded on the surviving row, never dropped in silence
                for _, e in ipairs(envrows) do
                    if e.name == sub then
                        e.subsumes = (e.subsumes or '') .. 'dependency:' .. h.name
                    end
                end
            else
                kept[#kept + 1] = h
            end
        end
        H = kept
    end
    local sandboxed = next(inject) ~= nil
    -- AN EFFECT-ONLY FUNCTION HAS A HOLE, not a shrug. This used to emit "no oracle …
    -- which this spec does not observe": true, and silence where a hole belongs. With a
    -- sandbox its behaviour IS the recorded call log, so the log is the thing to observe.
    local has_oracle = false
    for _, h in ipairs(H) do if h.kind == 'oracle' then has_oracle = true end end
    if sandboxed then
        H[#H + 1] = { kind = 'effects', name = '<calls>', rule = 'execution',
            why = ('what this function DOES: the sandboxed call log (%s). One RUN fills'
                .. ' it; no static tier can'):format(
                table.concat((function ()
                    local t = {}
                    for n in pairs(inject) do t[#t + 1] = n end
                    table.sort(t); return t
                end)(), ' ')) }
    end

    local reach = reach_of(store, node, lines)
    -- THE LOAD IS A PREMISE TOO, and when it cannot be derived it is a HOLE rather
    -- than a crash inside the spec's own preamble (see load_premise).
    local pathlines, loadwhy = load_premise(store, node, lines)
    if loadwhy then
        H[#H + 1] = { kind = 'load', name = node.file, rule = 'linker', why = loadwhy }
    end
    if reach.kind ~= 'member' then
        -- AN UPVALUE OR RECONSTRUCTED REACH IS A DERIVED PREMISE, NOT A WALL (CART-0286 /
        -- CART-0289). The row stays — reaching past a module's public surface, or
        -- rebuilding the subject from its own bytes, is exactly the kind of thing a reader
        -- must be able to see — but it carries a tier, so it does not block, and
        -- `satisfied_by` names the mechanism that answers it.
        H[#H + 1] = { kind = 'reach', name = node.name or '?', rule = 'linker',
            tier = (reach.kind == 'upvalue' or reach.kind == 'reconstructed')
                and 'derived' or nil,
            carrier = reach.carrier, chain = reach.chain,
            host = reach.host, decl_lines = reach.decl_lines,
            why = reach.why }
    end

    local rows, unfilled, premises = {}, 0, {}
    for _, h in ipairs(H) do
        local sat = satisfied_by(h, reach)
        -- COPY THE WHOLE ROW, then add what only this loop can compute. This was a WHITELIST
        -- of field names, and it lost a field THREE TIMES: the pre-supplied `value` of an env
        -- hole (so every env hole read as unfilled), then `owners`, then `constraint` and
        -- `relation` on an inspect hole (so the constraint a run had just learned vanished
        -- between the hole and the report). A whitelist copy is a list you must remember to
        -- update, in a file where new hole kinds are the whole direction of travel — so it is
        -- the wrong shape, not a list with three bugs in it.
        local row = {}
        for k, v in pairs(h) do row[k] = v end
        row.id, row.satisfied_by = hole_id(h), sat
        row.blocking = holes.blocking(h) or nil
        -- a MEASURED input is already an answer: the code itself demonstrates it
        if h.kind == 'input' and h.tier == 'measured' then
            local lit = h.why:match('passes the string (.*)$')
            local sca = h.why:match('passes the scalar (.*)$')
            if lit then row.value, row.filled_tier, row.by = ('%q'):format(lit),
                'measured', 'observed'
            elseif sca then row.value, row.filled_tier, row.by = sca, 'measured',
                'observed' end
        end
        if sat then
            premises[#premises + 1] = ('%s %s — satisfied by %s'):format(h.kind,
                tostring(h.name), sat)
        elseif not row.value then
            unfilled = unfilled + 1
        end
        rows[#rows + 1] = row
    end

    local root = store.data.root
    local base = (node.name or 'fn'):gsub('[^%w_]', '_')
    local dir = opts.dir or M.DIR
    local path = opts.path or (dir .. '/' .. base .. M.SUFFIX)
    -- GATE 2, enforced rather than documented: the suite globs tests/*_spec.lua, and a
    -- characterization spec is SUPPOSED to fail when behaviour changes. Landing one in
    -- the fence would block every legitimate refactor, so the path is refused here —
    -- the one place every entry point passes through.
    if path:match('^tests/') or path:match('_spec%.lua$') then
        return nil, ('%s is inside the push fence (tests/*_spec.lua) — a'
            .. ' characterization spec must not gate a commit; it is a tool you invoke')
            :format(path)
    end
    local plan = {
        verb = 'characterize', generation = store.generation,
        file = node.file, fn = node.name or '?', fn_id = node.id,
        ref = store.ref_of(node.id),
        subject = reach,
        package_path = pathlines or {},
        sandbox = sandboxed and inject or nil,
        -- the FORKABLE CONDITIONS, computed once and carried, so the report, an agent and a
        -- future fork all read the same list rather than three recomputations of it
        conditions = M.conditions(store, node, lines),
        -- kept as a LIST for the report and the refusal text; the authority is the hole rows
        unfilled_env = (#unfilled_env > 0) and unfilled_env or nil,
        has_oracle = has_oracle,
        abspath = root and (root .. '/' .. node.file) or node.file,
        params = node.params or {},
        holes = rows, premises = premises, unfilled = unfilled,
        path = path,
        touched = { path },
        -- A CREATE, declared as one (txn.creates) — the same contract the extract-module
        -- verb uses for its new destination module. Without it txn refuses with "cannot
        -- read", which is correct behaviour for an EDIT and the wrong question here.
        -- Re-characterizing overwrites our own previous output, so the stamp still CASes
        -- when the file already exists: a spec someone has since hand-edited must not be
        -- silently clobbered.
        creates = { [path] = true },
        stamps = { [path] = root and txn.disk_stamp(root, path) or nil },
    }
    -- THE PROLOGUE SUPPLY IS AUTOMATIC, and that is a deliberate line (CART-0296). Every
    -- other value-supplying step here is explicit, because it involves a CHOICE — an agent's
    -- guess, an asserted premise, a synthesized minimal value. Re-emitting a same-file
    -- declaration involves none: it is the FILE'S OWN SOURCE answering a name from that same
    -- file, which is exactly the claim `satisfied_by` makes automatically when the module
    -- load answers it. A reconstruction does not load the module, so the same claim has to be
    -- honoured a different way — and leaving it to a command would mean the honest answer
    -- (the code says so) needed asking for, while the guesses did not.
    if plan.subject and plan.subject.kind == 'reconstructed' then
        local prologue = require 'cartograph.prologue'
        local nsup = prologue.supply(store, plan)
        if nsup and nsup > 0 then
            local left = 0
            for _, h in ipairs(plan.holes) do
                local sat = h.satisfied_by
                if not sat and not h.value and not h.decl then left = left + 1 end
            end
            plan.unfilled = left
            for _, h in ipairs(plan.holes) do
                if h.decl then
                    plan.premises[#plan.premises + 1] = ('fixture %s — %s'):format(
                        tostring(h.name), h.basis or 'a re-emitted declaration')
                end
            end
        end
    end
    return txn.protocol(plan, M.edits_for)
end

--- SUPPLY A PREMISE for one or more holes — the agent-facing half, and the same
--- protocol as the decline ledger's `assume = {[line] = id}`: filling a hole is
--- DISCHARGING A HEDGE, so it needs a BASIS and the tier records WHO supplied it.
---
--- fills = { ['<hole id>'] = { value = <lua source>, basis = <why>, by = <channel> } }
--- Returns (n_filled, nil) or (nil, why) — and it refuses rather than warns:
---  · NO BASIS IS A REFUSAL. A value with no stated basis is a guess wearing an
---    answer's clothes, and once written into a spec it is indistinguishable from an
---    observed literal.
---  · THE ORACLE IS NEVER FILLABLE BY PREDICTION. `by` must be 'run' (a recorded
---    behaviour — CART-0263) or 'spec' (a declared contract). A predicted expected
---    value produces a test that passes because the prediction matched the prediction,
---    and it looks exactly like a real characterization test. Worse than no test.
---  · a MEASURED hole is not overwritten: the code already demonstrates that input.
M.BY_TIER = { run = 'measured', spec = 'claim', observed = 'measured',
    agent = 'agent-supplied',
    -- ASSERTED: the user declared a PREDICATE and we derived the value from it. A `claim`,
    -- because the premise is declared and (weakest-link) a value derived from a claim is one.
    asserted = 'claim',
    -- SANDBOX: our own declared fake standing in for a channel.
    sandbox = 'claim',
    -- SYNTHESIZED (CART-0290): we built the value from what the BODY requires of the
    -- parameter. That is our own analysis reading the code, which is exactly `derived` —
    -- and never `measured`, which belongs to a value the code DEMONSTRATED at a call site.
    -- The unconstrained case (nothing in the body inspects the parameter, so any value
    -- runs) needs no special channel: the filler passes tier='claim' and the weakest-link
    -- rule below takes it down, because "the code told us the shape" and "we picked
    -- something harmless" are different strengths and must not share a word.
    synthesized = 'derived',
    -- ★ VM (CART-0278): a value our own INTERPRETER computed by walking the function.
    -- `derived`, NEVER `measured`, and settling that before any interpreter exists is
    -- deliberate — a contract written after the engine gets bent to fit it.
    --
    -- The distinction the tier ladder is FOR: `measured` means the code DEMONSTRATED
    -- this, by running. A VM result is our own computation about what the code would
    -- do. Usually those agree, which is exactly why letting a VM fill at `measured`
    -- is dangerous rather than merely wrong: it would turn a computation into an
    -- observation invisibly, in the one place the arc exists to keep them apart, and
    -- the value would almost always look right. Same fabrication the whole arc
    -- prevents, one layer up.
    --
    -- NOTE `by` stays 'vm' regardless of how good the interpreter gets. The channel
    -- records HOW and the tier records HOW STRONG (invariant 3): a VM that never
    -- disagreed with a real run still computed rather than observed.
    vm = 'derived' }

--- Channels admissible for the ORACLE hole specifically. A VM is deliberately NOT
--- here: invariant 4 says the oracle takes a RUN or a SPEC and never a prediction,
--- and a computation of what the code would return is a prediction — a very good one,
--- made by us, about the very thing the assertion is supposed to check. Admitting it
--- would fuse the supply channel and the check channel, which is the failure the rule
--- names. A VM may fill INPUTS, FIXTURES and ENV; the expected value stays observed.
M.ORACLE_CHANNELS = { run = true, spec = true }

--- THE LADDER, so a tier can be COMPARED rather than only printed. Strongest first.
M.TIER_RANK = { measured = 1, derived = 2, claim = 3, ['agent-supplied'] = 4 }

--- THE WEAKEST LINK (user, 2026-08-04: "why not treat the environment as a hole to fill?").
--- An observation made THROUGH a supplied premise is only as strong as that premise: a value
--- observed by running the subject against our DECLARED fake `os.getenv` is not `measured`
--- evidence about anything, it is a `claim` — and it shipped as `measured` with the sandbox
--- mentioned only in prose, which is the tier field saying one thing and the sentence beside
--- it saying another. THE CHANNEL RECORDS HOW, THE TIER RECORDS HOW STRONG, and they are
--- separate fields for exactly this reason: `by` stays 'run' because it WAS a run.
function M.weakest(...)
    local worst, rank = nil, 0
    for i = 1, select('#', ...) do
        local t = (select(i, ...))
        local r = t and M.TIER_RANK[t]
        if r and r > rank then worst, rank = t, r end
    end
    return worst
end

function M.fill(plan, fills)
    if not (plan and type(fills) == 'table') then return nil, 'no fills' end
    local byid = {}
    for _, h in ipairs(plan.holes or {}) do byid[h.id] = h end
    local n = 0
    for id, f in pairs(fills) do
        local h = byid[id]
        if not h then
            return nil, ('no hole %q in this plan (ids are <kind>:<name>)'):format(id)
        end
        if type(f) ~= 'table' or f.value == nil then
            return nil, ('fill for %s carries no value'):format(id)
        end
        if type(f.basis) ~= 'string' or f.basis == '' then
            return nil, ('fill for %s carries no BASIS — a value with no stated basis'
                .. ' is a guess wearing an answer\'s clothes, and a spec cannot tell'
                .. ' the two apart afterwards'):format(id)
        end
        local by = f.by or 'agent'
        if not M.BY_TIER[by] then
            return nil, ('fill for %s names an unknown channel %q (run|spec|agent)')
                :format(id, tostring(by))
        end
        -- THE EFFECTS HOLE IS AN OBSERVATION TOO, and takes the same channel rule as the
        -- oracle: a PREDICTED call log makes a spec that passes because the prediction
        -- matched the prediction, which is the same fabrication one field over.
        if (h.kind == 'oracle' or h.kind == 'effects') and not M.ORACLE_CHANNELS[by] then
            return nil, ('the ORACLE hole %s may be filled by RUNNING (by=\'run\') or'
                .. ' by a SPEC (by=\'spec\'), never by prediction: a predicted expected'
                .. ' value makes a test that passes because the prediction matched the'
                .. ' prediction'):format(id)
        end
        if h.filled_tier == 'measured' and h.by == 'observed' then
            return nil, ('%s is already MEASURED (the code demonstrates this input) —'
                .. ' refusing to overwrite evidence with a supplied value'):format(id)
        end
        h.basis, h.by = f.basis, by
        -- an explicit tier WEAKENS (never strengthens): a caller may say "this run went
        -- through a claim-tier stub", and may not promote a claim to a measurement
        h.filled_tier = M.weakest(M.BY_TIER[by], f.tier)
        if h.kind == 'oracle' and f.raises then
            -- A RAISE IS NOT A TUPLE (CART-0295). The observation is the MESSAGE, so it is
            -- stored as one and flagged: wrapping it in `n, { … }` would make a raise
            -- indistinguishable from a function that RETURNED that string, which is a
            -- different program.
            h.raises, h.n = true, 0
            h.raw_value = tostring(f.value)
            h.value = h.raw_value
        elseif h.kind == 'oracle' then
            -- THE ORACLE IS A TUPLE, always, because a function returning `nil, err` is
            -- characterized on half its behaviour otherwise. `n` is the arity and it is
            -- SEPARATE from the list: select('#') keeps a trailing nil that `#t` cannot
            -- see, and `return nil` vs `return` are different behaviours.
            h.n = f.n or 1
            h.raw_value = tostring(f.value)
            h.value = ('%d, { %s }'):format(h.n, h.raw_value)
        else
            h.value = tostring(f.value)
        end
        n = n + 1
    end
    local left = 0
    for _, h in ipairs(plan.holes or {}) do
        if not (h.value or h.satisfied_by) then left = left + 1 end
    end
    plan.unfilled = left
    return n
end


-- ── ASSERTED CONDITIONS (CART-0282, user: "we can let user force assert it true which would
--    have ripple effect on the info we know") ────────────────────────────────
-- An input hole says "choose a value" and offers no way to choose one. But what a person
-- actually knows is not the value, it is THE CONDITION: "the file is non-empty", "the list
-- has more than one element". So let them assert the PREDICATE and DERIVE the value from it.
--
-- THAT IS THE `derived` RUNG THE LADDER WAS MISSING. The assertion is a `claim` (someone
-- DECLARED it), the value we compute from it is our own analysis — and by the weakest-link
-- rule a value derived from a claim IS a claim, so the whole thing lands at `claim` with a
-- basis naming both halves. Legitimate, because CART-0263's prohibition is on PREDICTING AN
-- OBSERVATION; supplying a premise is the sanctioned move.
--
-- NO SOLVER, and that is measured rather than hoped: CART-0256 found conjunctions in real code
-- are tiny, so this is INVERSION OF A SMALL CLOSED SET of comparison shapes, not satisfiability.
-- A shape outside the set is REFUSED by name — the honest frontier, not a guess.
--
-- SCOPE: conditions on a PARAMETER, which is the population measured at ~45% of functions and
-- whose hole (`input:<param>`) always exists at plan time. A condition on a field of an opaque
-- value wants a static inspect hole first (CART-0280 discovers those at RUN time only).

--- The FORKABLE conditions of a function: guards whose truth hinges on an unknown. Rows carry
--- { id, line, text, leaf, leaf_hole }. This is what a user names to assert, and it is also
--- exactly the input a FORK needs (CART-0283), so it lives here rather than in either.
function M.conditions(store, node, lines)
    local expr = require 'cartograph.expr'
    local eo = expr.of(store, node.id)
    local fl = eo and eo.fl
    if not (fl and fl.params) then return {} end
    local param = {}
    for _, p in ipairs(fl.params) do param[p] = true end
    local out, seen = {}, {}
    for _, st in ipairs(fl.stmts or {}) do
        local c = st.expr and st.expr.cond
        if c then
            -- THE UNKNOWN LEAF, and only a PARAMETER counts here: it is the one unknown whose
            -- hole is guaranteed to exist before anything runs.
            local leaf
            expr.walk(c, function (e)
                if not leaf and e.k == 'name' and param[e.n] then leaf = e.n end
            end)
            -- `st.l` IS 1-BASED (measured, not assumed: lines[st.l] is the guard itself), so
            -- there is no +1 here. The first cut added one and reported the line BELOW the
            -- condition — a row pointing at the wrong line is worse than no row, because it
            -- reads as precise.
            local ln = st.l or 1
            local id = ('condition:L%d'):format(ln)
            if leaf and not seen[id] then
                seen[id] = true
                out[#out + 1] = { id = id, line = ln, leaf = leaf,
                    leaf_hole = 'input:' .. leaf,
                    text = ((lines and lines[ln]) or ''):gsub('^%s+', ''):gsub('%s+$', ''),
                    cond = c }
            end
        end
    end
    return out
end

--- INVERT a comparison: a value for `leaf` making the condition `want`. Returns (source, why)
--- or (nil, why-not). The shapes are a CLOSED SET and anything else is refused by name — a
--- value that satisfies a condition we only half-understood would be the worst kind of fill,
--- since it looks derived and is a guess.
local function satisfy(cond, leaf, want)
    local expr = require 'cartograph.expr'
    local function isleaf(e) return e and e.k == 'name' and e.n == leaf end
    local function lit(e)
        if e and e.k == 'lit' then return e end
        return nil
    end
    -- `not <inner>` flips the target
    if cond.k == 'un' and (cond.op == 'not' or cond.op == '!') then
        return satisfy(cond.e, leaf, not want)
    end
    -- bare truthiness: `if x then`
    if isleaf(cond) then
        return want and 'true' or 'false',
            ('%s is %s, so the guard is %s'):format(leaf, want and 'truthy' or 'false',
                tostring(want))
    end
    if cond.k ~= 'bin' then
        return nil, ('the condition is not a comparison this version can invert (%s)')
            :format(cond.k)
    end
    -- normalise so the leaf is on the left
    local op, l, r = cond.op, cond.l, cond.r
    if not isleaf(l) and isleaf(r) then
        l, r = r, l
        op = ({ ['<'] = '>', ['>'] = '<', ['<='] = '>=', ['>='] = '<=' })[op] or op
    end
    if not isleaf(l) then
        return nil, ('the condition does not compare `%s` directly (it may be a field or a'
            .. ' call, which this version does not invert)'):format(leaf)
    end
    local rl = lit(r)
    if op == '==' or op == '~=' or op == '!=' then
        local eq = (op == '==') == want
        if not rl then
            if r and r.k == 'lit' then rl = r end
        end
        if rl and rl.ty == 'nil' then
            return eq and 'nil' or 'true',
                ('%s %s nil'):format(leaf, eq and 'is' or 'is not')
        end
        if not rl then
            return nil, 'the compared value is not a literal, so nothing can be derived'
        end
        -- A LITERAL'S `v` IS ALREADY LUA SOURCE, quotes and all (measured: a str lit's v is
        -- `"fast"`, seven characters). So %q on it produces `"\"fast\""` — a DIFFERENT string
        -- that of course fails the comparison, which is how the first cut asserted `mode ==
        -- "fast"` true and watched the run take the false branch. Use it verbatim.
        local v = tostring(rl.v)
        if eq then return v, ('%s equals %s'):format(leaf, v) end
        -- DIFFERENT, and it must be different in a way the same comparison agrees with
        if rl.ty == 'num' then return tostring((tonumber(rl.v) or 0) + 1),
            ('%s differs from %s'):format(leaf, v) end
        if rl.ty == 'str' then
            local raw = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v
            return ('%q'):format(raw .. '~'), ('%s differs from %s'):format(leaf, v)
        end
        return nil, 'cannot construct a value DIFFERENT from ' .. v
    end
    local n = rl and rl.ty == 'num' and tonumber(rl.v)
    if not n then
        return nil, ('`%s` is compared with something that is not a number literal, so no'
            .. ' value can be derived'):format(leaf)
    end
    local pick = ({
        ['>'] = want and (n + 1) or n,
        ['>='] = want and n or (n - 1),
        ['<'] = want and (n - 1) or n,
        ['<='] = want and n or (n + 1),
    })[op]
    if not pick then
        return nil, ('the operator `%s` is not one this version inverts'):format(tostring(op))
    end
    return tostring(pick), ('%s %s %s holds'):format(leaf, op, tostring(n))
end
M.satisfy = satisfy

--- WHY AN ASSERTED INPUT DOES NOT WEAKEN THE ORACLE, stated so nobody "fixes" it later. The
--- weakest-link rule weakens an observation made THROUGH A FICTION — a sandboxed run, where the
--- value came from our own fake. An asserted input is not a fiction: `mode = "fast"` is a real
--- value and the run really returned 1, so the pair (input, output) WAS observed and the oracle
--- is `measured`. What the assertion weakens is GENERALITY, not the observation: it is a claim
--- about which input is worth characterizing, and the premise line carries exactly that.
--- Conflating the two would tier every measurement by the reason someone chose its input.
---
--- ASSERT a condition's outcome and fill the value it hinges on. Returns (n_filled, nil) or
--- (nil, why). The fill DISCLOSES which branch it selected, because a spec that quietly picked
--- a side reads as characterizing the function when it characterized one path.
function M.assert_condition(store, plan, cond_id, want)
    local node = store.node(plan.fn_id)
    local lines = node and store.content(node)
    local rows = M.conditions(store, node, lines)
    local row
    for _, r in ipairs(rows) do if r.id == cond_id then row = r end end
    if not row then
        local ids = {}
        for _, r in ipairs(rows) do ids[#ids + 1] = r.id end
        return nil, ('no forkable condition %q in %s (have: %s)'):format(cond_id, plan.fn,
            #ids > 0 and table.concat(ids, ', ') or 'none — nothing here hinges on a parameter')
    end
    local value, why = satisfy(row.cond, row.leaf, want and true or false)
    if not value then
        return nil, ('cannot derive a value making `%s` %s: %s'):format(row.text,
            tostring(want), why)
    end
    local n, ferr = M.fill(plan, { [row.leaf_hole] = {
        value = value, by = 'asserted',
        basis = ('ASSERTED `%s` is %s (%s), so %s = %s. The premise is yours; the value is'
            .. ' derived from it'):format(row.text, tostring(want), why, row.leaf, value),
    } })
    if not n then return nil, ferr end
    plan.asserted = plan.asserted or {}
    plan.asserted[#plan.asserted + 1] = { id = row.id, line = row.line, text = row.text,
        want = want and true or false, leaf = row.leaf, value = value,
        selects = want and 'the TRUE branch' or 'the FALSE branch' }
    return n
end

-- ── THE SPEC TEXT ───────────────────────────────────────────────────────────
-- Self-contained by design: no test framework, no rtp, no harness. It runs with
-- `nvim --headless -l <spec>` or any Lua, because the point is that the SUBJECT's
-- behaviour is characterized, not that our suite can host it.

-- THE REFUSAL A READER ACTUALLY SEES, so it goes through holes.refusal rather than
-- reading `why` raw: a constrained hole says what would satisfy it (CART-0321).
local function hole_call(h)
    return ('HOLE(%q, %q)'):format(h.id, holes.refusal(h):gsub('"', "'"))
end

--- THE UPVALUE WALK (CART-0286), emitted into the spec so it is self-contained. A
--- file-level `local function` is an upvalue of whichever exported function references
--- it, so this reaches the REAL function object — no stub, no source rewriting, and
--- nothing performed.
---
--- A NAME MATCH IS NOT AN IDENTITY MATCH, which is why the location is checked. Two
--- distinct locals can share a name (a `local sort = table.sort` alongside a `local
--- function sort`), and returning the wrong one would characterize a different function
--- entirely while the spec read as a success. `debug.getinfo` says where the object it
--- found was actually defined; if that disagrees with the subject's own line, the walk
--- reports NOTHING rather than a plausible impostor. Under-return is recoverable, a
--- confident wrong answer is not.
--- THE RECONSTRUCTION (CART-0289), emitted into the spec. It RE-READS THE FILE, and that
--- is the whole design rather than an implementation detail: a spec carrying an embedded
--- COPY of the declaration would keep passing after the function was edited, reporting
--- "unchanged" about source it no longer describes. A characterization test whose job is
--- to fail on a behaviour change, silently succeeding forever, is the worst failure this
--- codebase has — so the text is fetched at run time, every time.
---
--- ANCHORED ON THE DECLARATION'S FIRST LINE, NOT ITS LINE NUMBER, because a line number
--- goes stale the instant anything above it moves and would then extract a DIFFERENT
--- function while reading as a success. The anchor must be unique (checked when the plan
--- is made, re-checked here) — two identical declaration lines and the spec cannot know
--- which one is its subject, so it refuses.
---
--- THE END OF THE DECLARATION IS FOUND BY COMPILING, not by counting lines or matching
--- `end`: grow the text a line at a time and stop at the first prefix that compiles AND
--- binds the name to a function defined at the chunk's own first line. A body edit that
--- adds or removes lines is handled for free, and re-implementing a parser here would be
--- the wrong kind of clever.
local RECONSTRUCT = {
    -- THE WRAP RULE, verbatim from M.WRAP_SRC: the spec applies the SAME bytes the plan
    -- checked, so the two cannot drift into disagreeing about what the declaration is.
    M.WRAP_SRC,
    'local function RECONSTRUCT(path, anchor, name, wrap)',
    '    local fh = io.open(path, "r")',
    '    if not fh then return nil, "cannot read " .. path end',
    '    local src = fh:read("*a"); fh:close()',
    '    local lines, at, hits = {}, nil, 0',
    '    for l in (src .. "\\n"):gmatch("([^\\n]*)\\n") do lines[#lines + 1] = l end',
    '    for i, l in ipairs(lines) do',
    '        if l:sub(1, #anchor) == anchor then at = at or i; hits = hits + 1 end',
    '    end',
    '    if hits == 0 then',
    '        return nil, "the declaration " .. anchor .. " is no longer in " .. path',
    '    elseif hits > 1 then',
    '        return nil, ("the declaration %s occurs %d times in %s")',
    '            :format(anchor, hits, path)',
    '    end',
    '    local ld = loadstring or load',
    '    for n = 1, 2000 do',
    '        if not lines[at + n - 1] then break end',
    '        local text = WRAP(table.concat(lines, "\\n", at, at + n - 1), name, wrap)',
    '        local chunk = ld(("%s\\nreturn %s"):format(text, name), "@" .. path)',
    '        if chunk then',
    '            local ok, fn = pcall(chunk)',
    '            local i = ok and type(fn) == "function"',
    '                and debug.getinfo(fn, "S") or nil',
    '            if i and i.linedefined == 1 then return fn end',
    '        end',
    '    end',
    '    return nil, "no prefix of the declaration compiles to a function"',
    'end',
}

local UPVALUE = {
    'local function UPVALUE(root, name, wantsrc, wantline)',
    '    local seen = {}',
    '    local function ok(f)',
    '        if type(f) ~= "function" then return false end',
    '        if not (wantsrc and wantline) then return true end',
    '        local i = debug.getinfo(f, "S")',
    '        return i and i.linedefined == wantline',
    '            and (i.short_src or ""):sub(-#wantsrc) == wantsrc',
    '    end',
    '    local function walk(v, d)',
    '        if d > 8 or seen[v] then return nil end',
    '        seen[v] = true',
    '        if type(v) == "function" then',
    '            local i = 1',
    '            while true do',
    '                local n, uv = debug.getupvalue(v, i)',
    '                if not n then break end',
    '                if n == name and ok(uv) then return uv end',
    '                if type(uv) == "function" or type(uv) == "table" then',
    '                    local hit = walk(uv, d + 1)',
    '                    if hit then return hit end',
    '                end',
    '                i = i + 1',
    '            end',
    '        elseif type(v) == "table" then',
    '            for k, vv in pairs(v) do',
    '                if k == name and ok(vv) then return vv end',
    '                if type(vv) == "function" or type(vv) == "table" then',
    '                    local hit = walk(vv, d + 1)',
    '                    if hit then return hit end',
    '                end',
    '            end',
    '        end',
    '        return nil',
    '    end',
    '    return walk(root, 0)',
    'end',
}

--- The plan as spec lines. PURE — no disk, so the dry-run diff, the applied bytes and
--- the tests all read the same function.
--- The spec's PREAMBLE — everything up to and including the call — shared verbatim with
--- the RUN probe (cartograph.oracle). One builder, two consumers, for the reason
--- portflow.lua exists: a probe that set the subject up DIFFERENTLY from the spec would
--- record a value the spec then fails to reproduce, and the disagreement would look like
--- a behaviour change.
function M.preamble(plan)
    local L = {}
    local function add(s) L[#L + 1] = s end
    -- OUR OWN OUTPUT CHANNEL, CAPTURED BEFORE ANYTHING CAN BE INJECTED. Found by driving
    -- it: `print` is in the effect vocabulary as io, so the sandbox faked it — and the
    -- PROBE reports through print, so it silenced itself and the run failed with "produced
    -- no value". A tool that injects into a shared namespace has to hold its own handles
    -- first; whatever we replace, we may be a user of too.
    add 'local __out = print'
    add(('-- CHARACTERIZATION SPEC for `%s` (%s)'):format(plan.fn, plan.file))
    add '-- Generated by cartograph. NOT a hand-written test, and NOT in the push fence:'
    add '-- a characterization spec is SUPPOSED to fail when behaviour changes.'
    -- NOTHING SESSION-SPECIFIC IN THE HEADER. This carried the graph GENERATION until a
    -- test caught it: applying bumps the generation, so a re-characterization of an
    -- unchanged function emitted different bytes and the idempotent write was not
    -- idempotent. A generated file that changes when nothing it describes has changed
    -- shows up as a diff in every review and trains its reader to stop reading it. The
    -- provenance that matters — the premises and their tiers — is below, and it is a fact
    -- about the SUBJECT rather than about our session.
    add ''
    if #(plan.premises or {}) > 0 then
        add '-- PREMISES THIS SPEC ASSUMES (a stub is a supplied premise, not a fact):'
        for _, p in ipairs(plan.premises) do add('--   · ' .. oneline(p)) end
        add ''
    end
    local supplied = {}
    for _, h in ipairs(plan.holes) do
        if h.basis then
            supplied[#supplied + 1] = oneline(('%s = %s  [%s, by %s] %s'):format(h.id,
                h.raw_value or h.value, h.filled_tier or '?', h.by or '?', h.basis))
        end
    end
    if #supplied > 0 then
        add '-- SUPPLIED PREMISES — who answered, on what basis, and at which tier:'
        for _, s in ipairs(supplied) do add('--   · ' .. s) end
        add ''
    end
    -- A SYNTHESIZED INPUT CHANGES WHAT THIS SPEC IS, so it is stated at the top rather than
    -- left implied by a tier three lines up (CART-0290). A minimal value picks a PATH — `{}`
    -- for a parameter the body loops over characterizes the EMPTY case — and a reader who
    -- takes this for "what the function does" has been misled by our silence, not by a wrong
    -- value. The value is real, the behaviour is real; the GENERALITY is what we chose.
    local nsynth = 0
    for _, h in ipairs(plan.holes) do
        if h.by == 'synthesized' then nsynth = nsynth + 1 end
    end
    if nsynth > 0 then
        add(('-- ⚠ %d INPUT(S) WERE SYNTHESIZED BY US, not observed at any call site. Each is'):
            format(nsynth))
        add '-- a MINIMAL value of the shape the body requires, so this spec characterizes ONE'
        add '-- PATH — the path OUR choice of input selects, which is not necessarily the one'
        add '-- any caller takes. The behaviour recorded below is real; its GENERALITY is ours.'
        add '-- :CartographCharacterizeFork shows the branches this input did not take.'
        add ''
    end
    add(('-- %d hole(s) UNFILLED. This spec MUST fail until they are filled: a hole'):format(
        plan.unfilled or 0))
    add '-- errors, it never silently passes.'
    add ''
    add 'local function HOLE(id, why)'
    add "    error(('HOLE: %s — %s'):format(id, why), 2)"
    add 'end'
    add ''
    -- THE SANDBOX GOES IN BEFORE THE SUBJECT IS LOADED, because a module can call io at
    -- LOAD time and an injection that arrives after the dofile would have missed it.
    local sandbox = M.sandbox_of(plan)
    if sandbox then
        add '-- SANDBOX: our own functions, injected. Every call is RECORDED and the world'
        add '-- is untouched. A fake is a SUPPLIED PREMISE, not the truth — the values below'
        add '-- are what this subject does UNDER THIS ENVIRONMENT, which is a real fact and'
        add '-- a different one from what it does against the real io.'
        for _, l in ipairs(M.sandbox_lines(sandbox)) do add(l) end
        add ''
    end
    for _, l in ipairs(plan.package_path or {}) do
        add('-- DERIVED premise: the module requires siblings, so the spec supplies the')
        add('-- package path the graph aligned them to (a require it could NOT align is')
        add('-- a hole, never a silent "module not found").')
        add(l)
    end
    -- a LOAD hole fires BEFORE the dofile, so the reader sees the premise that is
    -- missing instead of Lua's own message about a module it never heard of
    for _, h in ipairs(plan.holes) do
        if h.kind == 'load' and not h.value then
            add(('HOLE(%q, %q)'):format(h.id, holes.refusal(h):gsub('"', "'")))
        end
    end
    if plan.subject.kind == 'member' then
        add(('local SUBJECT = dofile(%q)'):format(plan.abspath))
    elseif plan.subject.kind == 'upvalue' then
        -- THE RUNTIME HALF OF THE TWO-CHANNEL CHECK (CART-0286). The plan DERIVED, from
        -- source, that an exported function mentions this local; this walk goes and gets
        -- it. If the walk comes back empty the derivation was wrong, and that is a HOLE
        -- firing — never a nil SUBJECT and an "attempt to call a nil value" three lines
        -- later, which would read as a broken tool instead of a wrong premise.
        add(('-- REACH: %s'):format(plan.subject.why or 'reached as an upvalue'))
        add '-- This spec reaches PAST the module\'s public surface. That is a real fact'
        add '-- about a real function object, and a different fact from what a consumer of'
        add '-- the module can observe — which is why it is stated here rather than assumed.'
        for _, l in ipairs(UPVALUE) do add(l) end
        add(('local MODULE = dofile(%q)'):format(plan.abspath))
        add(('local SUBJECT = UPVALUE(MODULE, %q, %q, %d)'):format(
            plan.subject.name or '?', plan.subject.src or '?',
            plan.subject.line or -1))
        add(('if not SUBJECT then HOLE(%q, %q) end'):format('reach:' .. plan.fn,
            ('the upvalue walk found no `%s` reachable from this module\'s exports, so'
                .. ' the derivation that `%s` closes over it was WRONG — a real'
                .. ' disagreement between our source analysis and the runtime')
            :format(tostring(plan.subject.name), tostring(plan.subject.carrier))))
    elseif plan.subject.kind == 'reconstructed' then
        -- THE LOUDEST PREMISE IN THIS FILE, and it earns the space: what runs below is OUR
        -- closure over the subject's bytes. Same source, different captured state.
        add(('-- REACH: %s'):format(plan.subject.why or 'reconstructed from source'))
        add '-- THIS IS A RECONSTRUCTION, NOT THE OBJECT THE FILE BUILDS. The declaration is'
        add '-- recompiled from its own source, so every free name it reads resolves to what'
        add '-- THIS SPEC supplies (the fixtures below) rather than to the enclosing scope.'
        add '-- A subject that shares MUTABLE state with that scope will not behave the same'
        add '-- way here, and that is a real difference rather than a formality.'
        add '-- The file is re-read on every run: an embedded copy would keep passing after'
        add '-- the function was edited, which is the one failure a characterization test'
        add '-- must never have.'
        for _, l in ipairs(RECONSTRUCT) do add(l) end
        add(('local SUBJECT, __rcwhy = RECONSTRUCT(%q, %q, %q, %q)'):format(
            plan.abspath, plan.subject.anchor or '?', plan.subject.name or '?',
            plan.subject.wrap or 'none'))
        add(('if not SUBJECT then HOLE(%q, "reconstruction failed: " ..'
            .. ' tostring(__rcwhy)) end'):format('reach:' .. plan.fn))
    else
        add(('-- REACH: %s'):format(plan.subject.why or 'the subject is not reachable'))
        add(('local SUBJECT = HOLE(%q, %q)'):format('reach:' .. plan.fn,
            (plan.subject.why or 'unreachable'):gsub('"', "'")))
    end
    add ''
    -- INPUTS, in parameter order, so the call reads like the signature
    local byname = {}
    for _, h in ipairs(plan.holes) do
        if h.kind == 'input' then byname[h.name] = h end
    end
    local args = {}
    for _, p in ipairs(plan.params) do
        local h = byname[p]
        args[#args + 1] = p
        if h and h.value then
            add(('local %s = %s  -- %s: %s'):format(p, h.value,
                h.filled_tier or 'filled', h.basis or h.why or ''))
        elseif h then
            add(('local %s = %s'):format(p, hole_call(h)))
        else
            add(('local %s = HOLE(%q, %q)'):format(p, 'input:' .. p,
                'no hole row for this parameter'))
        end
    end
    add ''
    -- DEPENDENCY stubs that the environment does NOT supply
    for _, h in ipairs(plan.holes) do
        if h.kind == 'dependency' and not h.satisfied_by then
            if h.value then
                add(('-- stub %s — %s'):format(h.name, h.basis or ''))
                add(('_G[%q] = %s'):format(h.name, h.value))
            else
                add(('-- an absent dependency this spec cannot inject%s'):format(
                    h.stub and (' (declared ' .. h.stub .. ')') or ''))
                add(('HOLE(%q, %q)'):format(h.id, holes.refusal(h):gsub('"', "'")))
            end
        end
    end
    -- FIXTURE holes the module load does not answer
    --
    -- A RE-EMITTED DECLARATION COMES FIRST AND AS A GLOBAL (CART-0296). A reconstruction
    -- compiles the subject as its own chunk, so its free names resolve as GLOBALS — the same
    -- property that lets a fixture be injected at all. So the declaration is re-emitted and
    -- then published under its own name: the spec evaluates the SAME SOURCE the file does,
    -- which needs no serializer (a function value has no literal form) and cannot fabricate.
    -- Order matters: a declaration may read an earlier one, so they land in plan order,
    -- which is source order.
    for _, h in ipairs(plan.holes) do
        if h.kind == 'fixture' and not h.satisfied_by and h.decl then
            add(('-- fixture %s — %s'):format(h.name, oneline(h.basis or '')))
            add(h.decl)
            add(('_G[%q] = %s'):format(h.name, h.name))
        end
    end
    for _, h in ipairs(plan.holes) do
        if h.kind == 'fixture' and not h.satisfied_by and not h.decl then
            if h.value then
                add(('_G[%q] = %s  -- fixture: %s'):format(h.name, h.value,
                    h.basis or ''))
            else
                add(('HOLE(%q, %q)'):format(h.id, holes.refusal(h):gsub('"', "'")))
            end
        end
    end
    add ''
    -- EVERY RETURN VALUE, and this matters: `local got = f(x)` keeps the FIRST and
    -- silently drops the rest, so a function returning `nil, err` was characterized on
    -- half its behaviour while the spec read as complete. select('#') also keeps a
    -- trailing nil, which `#t` cannot see — `return nil` and `return` are different
    -- behaviours and a characterization spec has to be able to tell them apart.
    add 'local function CAPTURE(...) return select("#", ...), { ... } end'
    -- ── A RAISE IS A BEHAVIOUR, SO THE CALL IS GUARDED (CART-0295) ──────────
    -- The call used to be bare, so a subject that RAISES took the whole probe down and the
    -- run reported "produced no value" — a function whose behaviour on a given input is TO
    -- FAIL got no spec at all. Measured: 366 of 399 no-value cases were the subject raising.
    -- `f({}) raises "attempt to index a nil value"` is a real, reproducible fact, and exactly
    -- the kind of thing a refactor breaks silently.
    --
    -- THE MESSAGE IS PART OF THE OBSERVATION, and it carries a `file:line` prefix. Comparing
    -- the raw message would fail on any edit ABOVE the raising line — a false CHANGED, which
    -- teaches its reader to ignore failures, and this arc already refuses that for values. So
    -- the prefix is stripped HERE, in the one place both consumers share, and the strip is
    -- disclosed wherever the expectation is printed.
    add 'local function UNPREFIX(m)'
    add '    m = tostring(m)'
    -- ONE leading `<chunk>:<line>: ` and only one: the rest is the subject's own words and
    -- must survive intact, including any colon-number it contains itself.
    add '    return (m:gsub("^[^\\n]-:%d+: ", "", 1))'
    add 'end'
    add 'local __ok, __err, gotn, got'
    add 'do'
    add(('    local __r = { pcall(function () return CAPTURE(%s(%s)) end) }')
        :format(plan.subject.expr or 'SUBJECT', table.concat(args, ', ')))
    add '    __ok = __r[1]'
    add '    if __ok then gotn, got = __r[2], __r[3]'
    add '    else __err = UNPREFIX(__r[2]); gotn, got = 0, {} end'
    add 'end'
    if sandbox then
        add 'local gotcalls = table.concat(__log, " | ")'
        -- RESTORED BEFORE THE ASSERTIONS, so a FAILING spec still leaves the process clean
        add '__unsandbox()'
    end
    return L, args
end

--- Deep VALUE equality, emitted into the spec because `got ~= want` on tables compares
--- IDENTITY: a subject returning a fresh table would report CHANGED on every run, which
--- is a false alarm indistinguishable from a real one.
local SAME = {
    'local function SAME(a, b)',
    '    if a == b then return true end',
    '    if type(a) ~= "table" or type(b) ~= "table" then return false end',
    '    for k, v in pairs(a) do if not SAME(v, b[k]) then return false end end',
    '    for k in pairs(b) do if a[k] == nil then return false end end',
    '    return true',
    'end',
    'local function SHOW(n, t)',
    '    local p = {}',
    '    for i = 1, n do p[i] = type(t[i]) == "table" and "{table}" or tostring(t[i]) end',
    '    return "(" .. table.concat(p, ", ") .. ")"',
    'end',
}

--- The plan as spec lines. PURE — no disk, so the dry-run diff, the applied bytes and
--- the tests all read the same function.
function M.emit(plan)
    local L = M.preamble(plan)
    local function add(s) L[#L + 1] = s end
    for _, l in ipairs(SAME) do add(l) end
    local oracle
    for _, h in ipairs(plan.holes) do
        if h.kind == 'oracle' then oracle = h end
    end
    if oracle and oracle.raises then
        -- CHARACTERIZING A RAISE (CART-0295), and it asserts in BOTH directions: a subject
        -- that stops raising has changed just as much as one that starts, and a spec checking
        -- only the message would pass silently the day the function starts returning.
        add(oneline(('-- %s, by %s: %s'):format(oracle.filled_tier or '?',
            oracle.by or '?', oracle.basis or '')))
        add(('local wanterr = %s'):format(oracle.value))
        add 'if __ok then'
        add ("    error(('CHANGED: %s no longer raises — it returned %s, characterized as"
            .. " raising %q'):format(" .. ('%q, SHOW(gotn, got), wanterr))'):format(plan.fn))
        add 'elseif __err ~= wanterr then'
        add ("    error(('CHANGED: %s raised %q, characterized as raising %q'):format("
            .. ('%q, __err, wanterr))'):format(plan.fn))
        add 'end'
    elseif oracle then
        if oracle.value then
            add(oneline(('-- %s, by %s: %s'):format(oracle.filled_tier or '?',
                oracle.by or '?', oracle.basis or '')))
            add(('local wantn, want = %s'):format(oracle.value))
        else
            add(('local wantn, want = %s'):format(hole_call(oracle)))
        end
        -- A RAISE WHERE A VALUE WAS CHARACTERIZED IS ALSO A CHANGE, and it used to surface as
        -- the subject's own error escaping the spec — which reads as a broken spec rather
        -- than as the behaviour change it is.
        add 'if not __ok then'
        add ("    error(('CHANGED: %s RAISED %q, characterized as returning %s'):format("
            .. ('%q, __err, SHOW(wantn, want)))'):format(plan.fn))
        add 'end'
        add 'if gotn ~= wantn or not SAME(got, want) then'
        add ("    error(('CHANGED: %s returned %s, characterized as %s'):format("
            .. ('%q, SHOW(gotn, got), SHOW(wantn, want)))'):format(plan.fn))
        add 'end'
    else
        add '-- no oracle: this function returns nothing, so behaviour is its EFFECTS,'
        add '-- which this spec does not observe. Nothing is asserted about the result.'
    end
    -- THE EFFECT LOG, asserted separately from the return tuple because they are separate
    -- claims: a function can keep its return value and change what it DOES, and a spec
    -- that folded them would report one as the other.
    local eff
    for _, h in ipairs(plan.holes) do
        if h.kind == 'effects' then eff = h end
    end
    if eff and M.sandbox_of(plan) then
        if eff.value then
            add(oneline(('-- %s, by %s: %s'):format(eff.filled_tier or '?',
                eff.by or '?', eff.basis or '')))
            add(('local wantcalls = %s'):format(eff.value))
        else
            add(('local wantcalls = %s'):format(hole_call(eff)))
        end
        add 'if gotcalls ~= wantcalls then'
        add(('    error(("CHANGED (effects): %s did [%%s], characterized as [%%s]")'
            .. ':format(gotcalls, wantcalls))'):format(plan.fn))
        add 'end'
    end
    add(('__out(%q)'):format('ok  ' .. plan.fn .. ' characterized'))
    return L
end

--- The txn edit set: one whole-file write (a create, or a replace of our own output).
function M.edits_for(plan)
    return function (file)
        if file ~= plan.path then return nil end
        return table.concat(M.emit(plan), '\n') .. '\n'
    end
end

--- Dry run: (before, after) keyed by file, exactly as every other verb previews.
function M.preview(store, plan)
    return txn.dryrun(store, plan)
end

--- Write it, verified. The spec must LOAD (a syntax gate on our own output — an
--- emitter that writes a file Lua cannot parse has failed at its one job) and the
--- subject function must be unchanged since the plan was staged.
function M.apply(store, plan)
    local bad = txn.verify(store, plan,
        { { id = plan.fn_id, name = plan.fn, ref = plan.ref, what = 'function' } })
    if bad then return nil, bad end
    local text = table.concat(M.emit(plan), '\n') .. '\n'
    local chunk, lerr = loadstring(text, plan.path)
    if not chunk then
        return nil, ('the emitted spec does not parse — refusing: ' .. tostring(lerr))
    end
    -- IDEMPOTENCE (CART-0263). The spec is a pure function of the subject and the filled
    -- holes, so re-characterizing writes identical bytes — and a journal entry per
    -- no-op run would fill :CartographUndo with steps that undo nothing, which is how an
    -- undo stack stops being trustworthy. A CHANGED file still writes, because that is a
    -- real difference; only byte-identity short-circuits.
    local disk = store.data.root and txn.read_file(store.data.root, plan.path)
    if disk == text then
        return { unchanged = true, path = plan.path,
            desc = { name = plan.path, from = plan.fn } }
    end
    return txn.execute(store, plan,
        { name = plan.path, from = plan.fn })
end

--- Every function a STAGED plan touches, characterized — the arc's first customer.
--- neutrality.lua certifies a refactor changed nothing by hashing the df shape, a
--- PROXY; running these before and after is the same check with real assertions.
--- Returns (plans, refusals) — both, because a refusal per symbol is the honest
--- answer for a move-set where only some members are reachable.
function M.plan_for_txn(store, staged, opts)
    local plans, refused = {}, {}
    local ids = {}
    if staged then
        if staged.fn_id then ids[#ids + 1] = staged.fn_id end
        for _, m in ipairs(staged.moves or {}) do
            if m.id then ids[#ids + 1] = m.id end
        end
    end
    for _, id in ipairs(ids) do
        local p, why = M.plan(store, id, opts)
        if p then plans[#plans + 1] = p
        else refused[#refused + 1] = { id = id, why = why } end
    end
    return plans, refused
end

--- The plan as report ROWS — (lines, at) so a pane can wire <CR> to the site, and so
--- an agent reads structure rather than parsing prose. plan.holes IS the data; this is
--- only its display.
function M.report(plan)
    local L, A = {}, {}
    local function add(s, a) L[#L + 1] = s; A[#A + 1] = a end
    add(('characterize %s (%s) — %d hole(s), %d unfilled'):format(plan.fn, plan.file,
        #plan.holes, plan.unfilled or 0), { file = plan.file, id = plan.fn_id })
    add(('  subject: %s%s'):format(plan.subject.kind,
        plan.subject.expr and (' via ' .. plan.subject.expr) or ''), nil)
    add(('  writes:  %s'):format(plan.path), nil)
    add('', nil)
    for _, h in ipairs(plan.holes) do
        local mark = h.value and '+' or (h.satisfied_by and '=' or '?')
        -- THE EFFECTIVE TIER, not the static one. This printed the STATIC tier, so a
        -- hole the run had just answered read `FRONTIER` on the same line as a basis
        -- saying it was observed — a row contradicting itself teaches a reader to trust
        -- neither half. `filled_tier` is what the evidence actually is now.
        -- A SATISFIED ROW IS NOT FRONTIER. The tier column answers "what evidence could
        -- FILL this", and a hole the environment already answers is not waiting for
        -- evidence at all — printing FRONTIER beside a `=` mark was the same
        -- self-contradiction the filled rows had.
        add(('  %s %-22s %-9s %s'):format(mark, h.id,
            h.satisfied_by and 'env' or h.filled_tier or h.tier or 'FRONTIER',
            h.satisfied_by or h.basis or holes.refusal(h)), nil)
    end
    add('', nil)
    add('  + supplied or measured · = satisfied by the environment · ? a HOLE that'
        .. ' will error', nil)
    -- WHAT WAS ASSERTED, and which branch it selected. A spec built on an assertion that does
    -- not say so reads as characterizing the FUNCTION when it characterized one PATH.
    for _, a in ipairs(plan.asserted or {}) do
        add(('  ! %s = %s  ASSERTED %s at L%d — selects %s'):format(a.leaf, a.value,
            tostring(a.want), a.line, a.selects), { file = plan.file, line = a.line })
    end
    -- AND WHAT IS ASSERTABLE BUT UNASSERTED, because an input hole that says only "choose a
    -- value" hides the fact that a CONDITION is what the value is for.
    local left = {}
    for _, c in ipairs(plan.conditions or {}) do
        local done = false
        for _, a in ipairs(plan.asserted or {}) do if a.id == c.id then done = true end end
        if not done then left[#left + 1] = c end
    end
    if #left > 0 then
        add('', nil)
        add(('  %d forkable condition(s) — assert one to DERIVE the value it hinges on:')
            :format(#left), nil)
        for _, c in ipairs(left) do
            add(('    %-16s %s   (hinges on `%s`)'):format(c.id, c.text, c.leaf),
                { file = plan.file, line = c.line })
        end
    end
    return L, A
end

return M
