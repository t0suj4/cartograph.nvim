-- refusalcensus — WHICH OF OUR PROMISES HAS ANY TEST EVER TRIGGERED?
--
-- USER (CART-0990): "exposing unknown promises we have made".
--
--   COVER=/tmp/cov.txt bash tests/run.sh           # record executed lines
--   nvim --headless -u NONE -l tools/refusalcensus.lua /tmp/cov.txt
--
-- ★★★ EVERY REFUSAL IS A PROMISE. `return nil, "<reason>"` says: IN THIS CASE I WILL
-- REFUSE, AND THIS IS WHY. A `return` line executes ONLY when it returns, so a line hook
-- answers "did any test ever make this promise fire?" exactly — no sampling, no
-- inference. This is the cheap half of CART-0990: it partitions the promises without
-- synthesizing a single input.
--
--   REACHED  a test made it fire. The promise is live and checked.
--   NEVER    no test ever did. ⚠ AND THIS IS TWO DIFFERENT THINGS WEARING ONE LABEL:
--            an UNTESTED promise (reachable, nobody wrote the case) and a VACUOUS one
--            (no input can reach it — CART-0985 shipped exactly that, a guard that
--            passed the suite by never running). The census cannot tell them apart and
--            does not pretend to; it hands you the list to go and read.
--
-- ⚠ IT MEASURES THE SUITE, NOT THE TRUTH. A promise the suite never triggers may be
-- fired constantly in real use, and one the suite triggers may be unreachable by any
-- caller that is not a test. CART-0751's rule is the one that applies: "a corpus with
-- zero instances of a form cannot fail on that form, ever, however carefully the gate is
-- calibrated" — read this as a statement about our TESTS.
--
-- ⚠ A PASS-THROUGH IS NOT A PROMISE OF ITS OWN. `return nil, why` re-raises someone
-- else's reason; only a return carrying a STRING LITERAL states a case and a why. Both
-- are counted, separately, because conflating them would inflate the denominator with
-- lines that promise nothing.

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')

local cov_path = (arg and arg[1]) or nil
if not cov_path then
    print('usage: COVER=/tmp/cov.txt bash tests/run.sh'
        .. ' && nvim --headless -u NONE -l tools/refusalcensus.lua /tmp/cov.txt')
    os.exit(2)
end

-- the WRITE PATH: everything that can refuse a change to someone's source
local MODULES = {
    'txn', 'planguards', 'cloneextract', 'clonemerge', 'moveapply', 'replace',
    'declare', 'annotate', 'optapply', 'extractapply', 'hoistclosure', 'reorder',
    'characterize',
}

local covered = {}
do
    local fd = io.open(cov_path, 'r')
    if not fd then print('cannot read ' .. cov_path); os.exit(2) end
    for line in fd:lines() do covered[line] = true end
    fd:close()
end

--- is this line a refusal, and does it NAME its reason?
--- ⚠ DERIVED FROM THE SHAPE IN THE TREE, not assumed: a refusal is `return nil,` or
--- `return false,` (optapply alone used the second until CART-0982 normalised its apply,
--- and its planners still use it), and the reason may start on the same line or be a
--- parenthesised format string continued onto the next.
local function refusal_of(line)
    local at1 = line:find('return%s+nil%s*,') or line:find('return%s+false%s*,')
    if not at1 then return nil end
    -- ⚠⚠ A `return nil,` INSIDE A STRING IS NOT A REFUSAL. `characterize` EMITS Lua as
    -- text — its sandbox stubs are `['os.execute'] = 'function () return nil, "…" end'`
    -- — and the first run of this census counted three of those plus a spec line as
    -- promises, inflating one module's denominator with code that never runs as code.
    -- Found by reading the NEVER list instead of trusting the count: the entries named
    -- `os.execute`/`os.remove`/`os.rename`, which are not refusals of ours at all.
    -- ★ THE TEST IS QUOTE PARITY BEFORE THE MATCH: an odd number of `'` or `"` means the
    -- `return` is inside a literal. Crude, and it is the right kind of crude — it can
    -- only ever DROP a site, never invent one, so the census stays a lower bound on
    -- promises rather than an inflated claim about them.
    local before = line:sub(1, at1 - 1)
    local _, sq = before:gsub("'", '')
    local _, dq = before:gsub('"', '')
    if sq % 2 == 1 or dq % 2 == 1 then return nil end
    local tail = line:gsub('^.*return%s+%w+%s*,%s*', '')
    -- a literal reason: a quote or a `(` opening a format string
    if tail:find("^['\"]") or tail:find('^%(') then return 'named' end
    return 'passthrough'
end

local rows, tot = {}, { named = 0, named_hit = 0, pass = 0, pass_hit = 0 }
for _, m in ipairs(MODULES) do
    local rel = 'lua/cartograph/' .. m .. '.lua'
    local n, hit, never = 0, 0, {}
    local i = 0
    for line in io.lines(repo .. '/' .. rel) do
        i = i + 1
        local kind = refusal_of(line)
        if kind then
            local key = rel .. ':' .. i
            local was = covered[key] and true or false
            if kind == 'named' then
                tot.named = tot.named + 1
                if was then tot.named_hit = tot.named_hit + 1 end
                n = n + 1
                if was then hit = hit + 1
                else
                    never[#never + 1] = { line = i,
                        text = line:gsub('^%s+', ''):sub(1, 76) }
                end
            else
                tot.pass = tot.pass + 1
                if was then tot.pass_hit = tot.pass_hit + 1 end
            end
        end
    end
    rows[#rows + 1] = { mod = m, n = n, hit = hit, never = never }
end

print('refusal census — which NAMED promises did the suite ever make fire?\n')
print(('  %-16s %6s %6s %6s'):format('module', 'named', 'fired', 'never'))
table.sort(rows, function (a, b) return (a.n - a.hit) > (b.n - b.hit) end)
for _, r in ipairs(rows) do
    print(('  %-16s %6d %6d %6d'):format(r.mod, r.n, r.hit, r.n - r.hit))
end
print(('\n  %-16s %6d %6d %6d'):format('TOTAL', tot.named, tot.named_hit,
    tot.named - tot.named_hit))
print(('  pass-through returns (someone else\'s reason): %d, %d fired')
    :format(tot.pass, tot.pass_hit))

print('\nNEVER FIRED — each is either an untested promise or a vacuous one:')
for _, r in ipairs(rows) do
    if #r.never > 0 then
        print(('\n  %s'):format(r.mod))
        for _, x in ipairs(r.never) do
            print(('    %4d  %s'):format(x.line, x.text))
        end
    end
end
print(('\n⚠ %d of %d named promises in the write path have never fired in the suite.')
    :format(tot.named - tot.named_hit, tot.named))
print('⚠ NEVER is not a verdict. Read the predicate: a promise no input can reach is'
    .. ' vacuous (CART-0985 shipped one); one nobody wrote a case for is merely untested.')
