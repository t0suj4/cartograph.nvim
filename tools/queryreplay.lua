-- queryreplay — RE-ASK THE LOGGED READ QUERIES against this build and diff the answers (F20, CART-1387).
--
--   nvim --headless -u NONE -l tools/queryreplay.lua <queries.jsonl> [--gate]
--
-- The log is what `mcpserve --query-log` wrote (lua/cartograph/querylog.lua): each record holds the request, the
-- answer's envelope and the stamp it was answered under (cartograph commit, roots, host flags). Every group of records
-- that shares roots + flags is piped through ONE fresh host started the same way — so the graph is opened exactly as
-- the logged host opened it — and each new envelope is compared with the logged one on what the answer CLAIMS:
-- status, absence, premise, tier, row count, refusal rule (graph.generation is a session counter and never compared).
-- This is the before/after pair the replay discipline asks for, as one command: the logged answers are BEFORE, this
-- build's are AFTER, and both commits are printed. `--gate` exits 1 when any answer changed.
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local repo = vim.fn.fnamemodify(here, ':h')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local Q = require 'cartograph.querylog'

local logf, gate = nil, false
for _, a in ipairs(arg) do if a == '--gate' then gate = true else logf = logf or a end end
if not logf then io.stderr:write('usage: queryreplay <queries.jsonl> [--gate]\n'); os.exit(2) end
local recs, bad = Q.read(logf)
if not recs then io.stderr:write('queryreplay: ' .. tostring(bad) .. '\n'); os.exit(2) end

local groups, order = {}, {}
for i, r in ipairs(recs) do
    local key = vim.json.encode({ r.roots or {}, r.flags or {} })
    if not groups[key] then groups[key] = { roots = r.roots or {}, flags = r.flags or {}, items = {} }; order[#order + 1] = key end
    table.insert(groups[key].items, { i = i, rec = r })
end

local after_commit = Q.commit(repo)
local same, changed, failed, before_commits = 0, 0, 0, {}
for _, key in ipairs(order) do
    local g = groups[key]
    local lines = { vim.json.encode({ jsonrpc = '2.0', id = 0, method = 'initialize', params = vim.empty_dict() }) }
    for _, it in ipairs(g.items) do
        local args = it.rec.args
        if type(args) ~= 'table' or vim.tbl_isempty(args) then args = vim.empty_dict() end
        lines[#lines + 1] = vim.json.encode({ jsonrpc = '2.0', id = it.i, method = 'tools/call', params = { name = it.rec.verb, arguments = args } })
    end
    local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-l', here .. '/mcpserve.lua' }
    for _, r in ipairs(g.roots) do cmd[#cmd + 1] = r end
    for _, f in ipairs(g.flags) do cmd[#cmd + 1] = f end
    local res = vim.system(cmd, { stdin = table.concat(lines, '\n') .. '\n', text = true }):wait(1800000)
    local got = {}
    for line in ((res and res.stdout) or ''):gmatch('[^\n]+') do
        local ok, m = pcall(vim.json.decode, line)
        if ok and type(m) == 'table' and m.id and m.id ~= 0 then got[m.id] = m end
    end
    for _, it in ipairs(g.items) do
        local r, m = it.rec, got[it.i]
        before_commits[r.commit or 'unknown'] = true
        local label = ('#%d %s %s'):format(it.i, r.verb, vim.json.encode(r.args or {}))
        if not m or not m.result then
            failed = failed + 1
            io.write(('%s\n    FAILED: %s\n'):format(label, m and m.error and m.error.message or 'no answer from the host'))
        else
            local c = m.result.content and m.result.content[1]
            local okd, doc = pcall(vim.json.decode, c and c.text or '')
            if not okd or type(doc) ~= 'table' then doc = {} end
            local status = m.result.isError and 'error' or (type(doc.refusal) == 'table' and 'refusal' or 'ok')
            local d = Q.diff(r.answer, Q.envelope(doc, status))
            if #d == 0 then same = same + 1; io.write(('%s\n    SAME\n'):format(label))
            else
                changed = changed + 1
                io.write(('%s\n    CHANGED\n'):format(label))
                for _, x in ipairs(d) do io.write(('      %-8s %s -> %s\n'):format(x.field, tostring(x.before), tostring(x.after))) end
            end
        end
    end
end
io.write(('queryreplay %s: %d record(s) (%d unreadable line(s)) — %d same, %d changed, %d failed\n'):format(logf, #recs, bad, same, changed, failed))
io.write(('  before: %s\n  after:  %s\n'):format(table.concat(vim.tbl_keys(before_commits), ', '), after_commit))
if gate and (changed > 0 or failed > 0) then os.exit(1) end
