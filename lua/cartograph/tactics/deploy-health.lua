-- DEPLOY-HEALTH (discovery, CART-0154): is the DEPLOYED release healthy? — the automated review gate of a deployment
-- plan. The local deployment world's health check: the release CURRENT names carries a `health` file saying `ok`
-- (a real target's check would be a probe; the gate's place in the plan is the same). CLAIM: healthy.
local D = require 'cartograph.deploy'
return {
    name = 'deploy-health',
    kind = 'discovery',
    summary = 'is the deployed release healthy? target = the deployment world; reads releases/<CURRENT>/health',
    params = { target = 'string' },
    measure = function (_, p)
        local id = D.current(p.target)
        local fd = id ~= '' and io.open(p.target .. '/releases/' .. id .. '/health')
        local h = fd and fd:read('a') or nil
        if fd then fd:close() end
        return { release = id, health = h and h:gsub('%s+$', '') or nil }
    end,
    claim = function (v)
        if v.release == '' then return false, 'nothing is deployed' end
        return v.health == 'ok', ('release %s reports health %s'):format(v.release, tostring(v.health))
    end,
    examples = {
        {
            name = 'a release whose health file says ok is healthy',
            files = { ['t/releases/r1/health'] = 'ok\n', ['t/CURRENT'] = 'r1\n' },
            params = function (store) return { target = store.data.root .. '/t' } end,
            expect = { holds = true },
        },
        {
            name = 'a failing release is not',
            files = { ['t/releases/r2/health'] = 'failing\n', ['t/CURRENT'] = 'r2\n' },
            params = function (store) return { target = store.data.root .. '/t' } end,
            expect = { holds = false },
        },
    },
}