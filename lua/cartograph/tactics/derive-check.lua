-- DERIVE-CHECK (discovery, CART-1368): is algebra verb OP derivable from the basis? REDERIVE.md's method as a tactic:
-- the vendored algebra suite runs twice — as it is, and with DERIVE=<op> (core.lua's hook swaps the operator for its
-- re-derivation from the basis, cartograph.algebra.derive) — and the EXTRA failures over the baseline are the verdict.
-- The verb audit (CART-1360) runs it per operator: on 2026-10-03, 22 of the 29 derived operators derived cleanly and
-- 7 had drifted (trace +28, migrate_one +5, generalize +4, instance_of +4, classify +4, rewrite +2, dig +1); on
-- 2026-10-04 every one derives clean and DERIVE=all fails nothing the native run does (358/0 over algebra + donor + kvterm).
-- ⚠ An operator with NO derivation is refused by name before anything runs (DERIVE would raise while loading the
-- algebra and fail EVERY test — a count that would read as a verdict).
-- CLAIM: derivable — the derived run fails nothing the baseline does not.
local SF = require 'cartograph.tactics.spec-fails'

local function repo_of_toolbelt()
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

local E = {
    name = 'derive-check',
    kind = 'discovery',
    tags = { 'accept', 'algebra' },
    measures = 'CART-1368',
    summary = 'is algebra verb `op` (or a,b) derivable from the basis? runs `spec` (default algebradonor_spec) as it is and with DERIVE=<op>; the extra failures are the verdict. repo = the tree (default this cartograph), timeout = seconds per run',
    params = { op = 'string', spec = 'string?', repo = 'string?', timeout = 'string?' },
    measure = function (_, p)
        local D = require 'cartograph.algebra.derive'
        for o in p.op:gmatch('[^,]+') do
            if not D[o] then return { error = ('no derivation for `%s` in cartograph.algebra.derive (its OPERATORS: %s)'):format(o, table.concat(D.OPERATORS, ', ')) } end
        end
        local root, spec = p.repo or repo_of_toolbelt(), p.spec or 'algebradonor_spec'
        local t = p.timeout and tonumber(p.timeout) * 1000 or nil
        local base, bwhy = SF.run(root, spec, t)
        if not base then return { error = 'baseline: ' .. tostring(bwhy) } end
        local der, dwhy = SF.run(root, spec, t, { DERIVE = p.op })
        if not der then return { error = 'derived run: ' .. tostring(dwhy) } end
        return { op = p.op, baseline = base.summary, derived = der.summary, extra = der.failed - base.failed,
            base_failed = base.failed, derived_failed = der.failed }
    end,
    claim = function (v)
        if v.error then return false, v.error end
        if v.extra <= 0 then return true, ('`%s` derives: %s, as the baseline %s'):format(v.op, v.derived, v.baseline) end
        return false, ('`%s` does not derive here: %d extra failure(s) — derived %s, baseline %s'):format(v.op, v.extra, v.derived, v.baseline)
    end,
}

-- the fixture: spec-fails' mini repo, with a spec that fails only when `trace` is swapped for its derivation
local FX = {}
for k, v in pairs(SF.FIXTURE) do FX[k] = v end
FX['tests/derivefix_spec.lua'] = "local check = ...\ncheck(true)\ncheck(os.getenv('DERIVE') ~= 'trace')\n"

E.examples = {
    {
        name = 'an operator whose derivation fails nothing extra DERIVES',
        files = FX, params = function (store) return { op = 'sites', spec = 'derivefix_spec', repo = store.data.root } end,
        expect = { holds = true, check = function (v) return v.extra == 0, tostring(v.derived) end },
    },
    {
        name = 'an operator whose derivation fails a test the baseline passes does NOT derive — the count is the verdict',
        files = FX, params = function (store) return { op = 'trace', spec = 'derivefix_spec', repo = store.data.root } end,
        expect = { holds = false, check = function (v) return v.extra == 1 and v.base_failed == 0, tostring(v.derived) end },
    },
    {
        name = 'an operator with NO derivation is refused by name before anything runs',
        files = FX, params = function (store) return { op = 'no_such_op', spec = 'derivefix_spec', repo = store.data.root } end,
        expect = { holds = false, check = function (v) return (v.error or ''):find('no derivation for `no_such_op`', 1, true) ~= nil, tostring(v.error) end },
    },
}

return E
