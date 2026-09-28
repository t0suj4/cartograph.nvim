-- DEPLOY (write, CART-0154): a DEPLOYMENT PLAN as a tactic over worlds — release (an immutable, content-addressed value
-- written into the target world) -> switch (COMPENSABLE: CURRENT moves; its inverse switches back) -> the health
-- PREMISE (automated review). The manual review gates are DECISIONS: writing the target world (`target-write`) and
-- the deploy itself (`approve-deploy`) — `approve = yes` answers both for this run (or a remembered decision does).
-- Run it with on_stop = 'rollback' (the CLI: rollback=1) and a failed health check COMPENSATES the switch and UNDOES
-- the release: the target is back where it was. Re-running a deployed source is empty (the same content, the same id).
local T = require('cartograph.tactic').T

local GOOD = { ['app/index.txt'] = 'v2\n', ['app/health'] = 'ok\n' }
local BAD = { ['app/index.txt'] = 'v3\n', ['app/health'] = 'failing\n' }
local function seed(target) -- a target already running release `v1`
    vim.fn.mkdir(target .. '/releases/v1', 'p')
    local fd = io.open(target .. '/releases/v1/health', 'w'); fd:write('ok\n'); fd:close()
    fd = io.open(target .. '/CURRENT', 'w'); fd:write('v1\n'); fd:close()
end
local function params(approve)
    return function (store)
        local target = vim.fn.tempname() .. '-deploy'
        seed(target)
        return { from = 'app', target = target, approve = approve }
    end
end

return {
    name = 'deploy',
    kind = 'write',
    summary = 'a deployment plan: from = the source tree to release, target = the deployment world (a directory: releases/<id>/, CURRENT); approve = yes answers the target-write and approve-deploy gates; a failed health check under rollback compensates the switch and undoes the release',
    params = { from = 'string', target = 'string', approve = 'string?' },
    build = function (p)
        local acc = p.approve == 'yes' and { 'target-write', 'approve-deploy' } or nil
        return T.seq(
            T.step('release', { from = p.from, target = p.target }, acc),
            T.step('switch', { target = p.target, release = 'LATEST' }, acc),
            T.use('deploy-health', { target = p.target }))
    end,
    examples = {
        {
            name = 'without approval the plan STOPS at the first gate — nothing is written to the target',
            files = GOOD, params = params(nil),
            expect = { status = 'stopped', applied = 0 },
        },
        {
            name = 'approved, a healthy release is deployed: CURRENT names the new content id',
            files = GOOD, params = params('yes'),
            expect = { status = 'done', applied = 2 },
        },
    },
}