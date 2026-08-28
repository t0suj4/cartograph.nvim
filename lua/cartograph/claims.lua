-- CLAIMS: the pure core behind two of tools/docaudit.lua's oracles — the ones
-- that fence a CLAIM ABOUT THIS TREE'S OWN INVENTORY. Pure over text plus the
-- registries it is checked against; the globbing and the report live in the
-- tool, the same split lua/cartograph/preflight.lua has from tools/preflight.lua
-- (and for the same reason: a script that sources plugin/ and calls os.exit
-- cannot be driven from a spec, so the logic a spec must FAIL against lives
-- here).
--
-- WHY THIS EXISTS (CART-0595). Two stale inventory claims cost one session:
--   1. portability.lua's header said "no shipped pair qualifies today … the move
--      report cannot be demonstrated on the artifacts in the tree". False since
--      1 August. A session believed it and filed three tickets routing around a
--      working mechanism, one a P1 whose premise was simply wrong.
--   2. .claude/skills/cartograph/SKILL.md said "21 verbs" while agent.ORDER had
--      24. Nothing caught it: docaudit audited :Cartograph* commands, and the
--      agent surface is a different registry in a file it never opened.
--
-- ★ THE DIRECTION MATTERS. A stale POSITIVE claim ("this does X") makes you try
-- it and fail fast. A stale NEGATIVE claim ("no X exists") stops you trying at
-- all, and nothing ever contradicts it. The second is the expensive one, and it
-- is the one no test can find on its own.
--
-- WHAT WAS MEASURED AND REJECTED, so nobody rebuilds it: a general fence over
-- "stale header prose" is a NOISE MACHINE. Across lua/cartograph/, 853 header
-- lines match negative-existence phrasing (no / nothing / cannot / none) and
-- almost all are legitimate SEMANTIC prose — "resolves to nothing in the
-- corpus", "nothing in the body inspects it" — claims about USER CODE, not
-- about our tree. Another 14 are count-shaped ("148 classes", "29 corpora"),
-- and most of those are DATED RECORDS OF A PAST MEASUREMENT: flagging a record
-- of what WAS as a stale claim about what IS would be wrong. So prose matching
-- is out, in both directions, and what is left is the two checkable things:
--
--   AGENT SURFACE (proof) — agent.ORDER is the registry tools/mcpserve.lua
--     actually serves (its tools/list iterates it), so it cannot be wrong about
--     what an agent can call. SKILL.md's verb count and verb table are claims
--     about that registry and are checked against it, both directions.
--   TAGGED CLAIMS (opt-in proof) — a load-bearing assertion in a header can
--     carry its own executable check, and then the suite re-reads it for you.
--     OPT-IN IS THE HONEST LIMIT and it is stated in the report: an UNtagged
--     claim is invisible here. That is not a gap to close by guessing — see the
--     853 above. What the mechanism converts is "someone must remember to
--     re-read this paragraph" into "the fence says so".
--
-- THE TAG SHAPE (written in a comment, two lines, the second optional only in
-- the sense that leaving it off is itself a finding):
--   the opening line is a comment carrying  @claim <id>: <the sentence>
--   a later comment line in the same block  check: <a Lua expression>
-- The expression is evaluated in the ordinary global environment (require and
-- vim are reachable) and must return a truthy value. It should call the
-- MECHANISM'S OWN predicate rather than reimplement it — a check that
-- reimplements what it checks drifts from it, which is the failure class this
-- whole file exists to fence.

local M = {}

--- Where the agent-facing skill claim lives, relative to the repo root. Tracked
--- in git, so a checkout that lacks it is a finding rather than a skip.
M.SKILL = '.claude/skills/cartograph/SKILL.md'

--- Which files the tag scan reads. lua/ and tools/, plus the markdown at the
--- REPO ROOT — CHARTER.md states the project's goals and invariants, which is
--- exactly the load-bearing-prose class this mechanism exists for, and
--- README.md sits beside it so a tagged claim there is fenced without needing a
--- second decision. tests/ is excluded so that a spec's SYNTHETIC tags (there
--- to prove the checker fails when it should) are not evaluated as real claims
--- about the tree; .claude/ is excluded because SKILL.md already has the
--- stronger oracle above, and this tool audits that file without editing it.
M.SCAN = { 'lua/**/*.lua', 'tools/*.lua', '*.md' }

-- ── the agent surface ───────────────────────────────────────────────────────

--- Every verb-count claim in the skill text, as { n, line }. Two phrasings,
--- because the file states the number twice and they can rot apart: the
--- frontmatter description ("… 24 verbs …") and the table's lead-in ("24, in
--- the order they may be trusted in").
---
--- THIS IS A SHAPE THE FILE MUST KEEP, the same bargain the helpdoc's KEYS table
--- makes with docaudit. Every "<N> verbs" in that file is read as a claim about
--- the WHOLE roster, so a sentence about a subset must spell the number as a word
--- or name the band ("the write verbs"), and a digit-comma line start is read as
--- the table's lead-in. The cost of the broad pattern is a false drift, which is
--- loud and fixable in one edit; the cost of a narrow one is a claim that quietly
--- stops being checked, which is the failure this whole file is about. The spec
--- pins that BOTH claims are still found at HEAD, so a rephrasing that hides one
--- from this pattern fails the suite rather than passing silently.
local function count_claims(lines)
    local out = {}
    for i, line in ipairs(lines) do
        for n in line:gmatch('(%d+)%s+verbs') do
            out[#out + 1] = { n = tonumber(n), line = i }
        end
        local lead = line:match('^(%d+),%s')
        if lead then out[#out + 1] = { n = tonumber(lead), line = i } end
    end
    return out
end

--- The verb NAMES the skill publishes: the lowercase tokens of the first fenced
--- block under the "## The verbs" heading. A MACHINE-CHECKED TABLE, like the
--- helpdoc's KEYS section — the band labels are uppercase (READ, CATALOGUE,
--- VERSION, WRITE) precisely so every lowercase token in the block is a verb.
--- Prose inside that block would read as verb names, which is the cost of the
--- shape and the reason the block is a table and not a paragraph.
--- Returns (names-in-order, first-line) or nil when the block is not there.
local function verb_block(lines)
    local heading
    for i, line in ipairs(lines) do
        if line:match('^##%s+The verbs%s*$') then heading = i break end
    end
    if not heading then return nil end
    local open
    for i = heading + 1, #lines do
        if lines[i]:match('^```') then
            if open then
                local names = {}
                for j = open + 1, i - 1 do
                    for tok in lines[j]:gmatch('%l[%l%d_]*') do
                        names[#names + 1] = tok
                    end
                end
                return names, open + 1
            end
            open = i
        end
    end
    return nil
end

--- Audit the skill's claims about the agent surface against `order` — the live
--- agent.ORDER, which is the registry mcpserve serves. Returns (drifts, info):
--- drifts are sentences stating something FALSE, info is what the parse SAW, so
--- a caller can assert the check actually ran rather than trusting a clean
--- result. A CLAIM THAT CANNOT BE FOUND IS ITSELF A DRIFT: if the heading or the
--- fence markers move, this must say the check cannot run, never zero findings.
function M.agent_surface(order, lines, path)
    path = path or M.SKILL
    local drifts = {}
    local function drift(fmt, ...) drifts[#drifts + 1] = fmt:format(...) end

    local want, wantset = #order, {}
    for _, v in ipairs(order) do wantset[v] = true end

    local counts = count_claims(lines)
    if #counts == 0 then
        drift('%s: no "<N> verbs" claim found — the verb-count check cannot run', path)
    end
    for _, c in ipairs(counts) do
        if c.n ~= want then
            drift('%s:%d claims %d verbs — agent.ORDER serves %d', path, c.line, c.n, want)
        end
    end

    local names, at = verb_block(lines)
    if not names then
        drift('%s: no fenced verb table under "## The verbs" — the verb-name check cannot run',
            path)
        return drifts, { counts = counts, names = nil }
    end
    local have = {}
    for _, n in ipairs(names) do have[n] = true end
    for _, v in ipairs(order) do
        if not have[v] then
            drift('%s:%d verb table omits %s — agent.ORDER serves it and this file is how an agent learns the verbs',
                path, at, v)
        end
    end
    for _, n in ipairs(names) do
        if not wantset[n] then
            drift('%s:%d verb table names %s — agent.ORDER has no such verb', path, at, n)
        end
    end
    if #names ~= want then
        drift('%s:%d verb table lists %d names — agent.ORDER serves %d', path, at, #names, want)
    end
    return drifts, { counts = counts, names = names, at = at }
end

-- ── tagged claims ───────────────────────────────────────────────────────────

--- A line's own COMMENT OPENER, or nil when it is not a comment line. Two
--- syntaxes: Lua's `--` and markdown's `<!--`. The second exists because a
--- charter is prose, and prose about our own inventory is precisely what this
--- mechanism fences — so the tag shape has to be writable in the file the
--- claim actually lives in, rather than mirrored into a Lua header where it
--- would drift from the sentence it stands behind.
---
--- Note the two are not disjoint by accident: `<!--` CONTAINS `--`, so the
--- opener test is ordered, markdown first.
local function opens_comment(line)
    return line:match('^%s*<!%-%-') or line:match('^%s*%-%-')
end

--- Strip markdown's closing `-->` from a captured tail. Harmless on a Lua line,
--- which never has one — and doing it unconditionally is why the two syntaxes
--- need no separate code paths below.
local function unclose(s)
    return (s:gsub('%s*%-%->%s*$', ''))
end

--- Parse the tags out of one file's lines. A tag opens on a comment line
--- carrying `@claim <id>: <sentence>` and is closed by the first non-comment
--- line or the next tag; the `check:` comment line anywhere inside carries the
--- expression. A tag WITHOUT one is kept, not dropped — an unfenced tag claims
--- a fence it does not have, and verify() reports it.
---
--- Both comment syntaxes are accepted, in Lua and in markdown alike, because a
--- tag is a tag wherever it is written. The `@claim` opener is matched
--- UNANCHORED (a `--` anywhere in the line) as it always was, which is what
--- lets a trailing comment carry one; `check:` stays anchored, so a sentence
--- merely quoting the word cannot be mistaken for the expression.
function M.tags(lines, path)
    local out, cur = {}, nil
    for i, line in ipairs(lines) do
        local id, sentence = line:match('%-%-.*@claim%s+([%w%-_]+):%s*(.*)$')
        if id then
            cur = { id = id, sentence = vim.trim(unclose(sentence)), path = path, line = i }
            out[#out + 1] = cur
        elseif cur then
            local expr = line:match('^%s*%-%-%s*check:%s*(.+)$')
                or line:match('^%s*<!%-%-%s*check:%s*(.+)$')
            if expr then
                cur.expr, cur.expr_line = vim.trim(unclose(expr)), i
            elseif not opens_comment(line) then
                cur = nil
            end
        end
    end
    return out
end

--- Every tag in the tree. `root` is the repo root.
function M.scan(root)
    local tags = {}
    for _, pat in ipairs(M.SCAN) do
        for _, f in ipairs(vim.fn.globpath(root, pat, false, true)) do
            local rel = f:sub(#root + 2)
            for _, t in ipairs(M.tags(vim.fn.readfile(f), rel)) do
                tags[#tags + 1] = t
            end
        end
    end
    table.sort(tags, function (a, b)
        if a.path ~= b.path then return a.path < b.path end
        return a.line < b.line
    end)
    return tags
end

--- Run one tag's check. Returns (ok, reason). Every failure mode is the SAME
--- tier — the claim is not standing up — but the reasons are distinguished
--- because the fix differs: rewrite the sentence, or repair the check.
function M.verify(tag)
    if not tag.expr then
        return false, 'tagged but carries no `check:` line — a tag with no check advertises a fence it does not have'
    end
    local fn, err = load('return ' .. tag.expr, ('@%s:%d'):format(tag.path, tag.expr_line or tag.line))
    if not fn then
        return false, 'check does not compile: ' .. tostring(err)
    end
    local okc, res = pcall(fn)
    if not okc then
        return false, 'check errored: ' .. tostring(res)
    end
    if not res then
        return false, 'CHECK IS FALSE — the sentence no longer holds'
    end
    return true
end

return M
