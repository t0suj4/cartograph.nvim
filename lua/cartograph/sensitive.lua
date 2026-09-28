-- cartograph.sensitive — WHAT MAY LEAVE THE MACHINE (CART-1192, first leaf CART-1193).
--
-- A record that TRAVELS (the ledger note pushed with the repo, and later a token store, an invocation log, an MCP
-- answer) must never carry the bytes of a file the repository does not publish. Sensitivity is DERIVED, never
-- declared value by value:
--   the repo decides    a file git TRACKS is public — the repository already publishes it. Untracked or ignored
--                       (a `.env`) is sensitive. A world with no git has nothing deciding: every file is sensitive.
--   the user overrides  config.at(<abs path>, 'sensitive') = true | false (policy over views, CART-1160 step 6) —
--                       USER config only; the analysed tree never supplies it (a tree that could declare itself
--                       public would exfiltrate by configuration).
-- A sensitive value travels as a REFERENCE (a content hash), never as bytes.
-- ★ THE EGRESS CHECK IS INDEPENDENT OF THE REDACTION: `leaks` walks every string of the outgoing record and looks for
-- the sensitive files' own lines (disk and journal images). A redaction bug is caught at the boundary rather than
-- trusted — the refusal names the file, never the bytes.
local M = {}

local function git(root, args)
    local cmd = { 'git', '-C', root }
    vim.list_extend(cmd, args)
    local r = vim.system(cmd, { text = true }):wait()
    return r.code == 0 and r.stdout or nil
end

--- which of `rels` (relative to `root`) are sensitive -> { [rel] = why }
function M.classify(root, rels)
    local config = require 'cartograph.config'
    local out, ask = {}, {}
    for _, rel in ipairs(rels) do
        local v = config.at(root .. '/' .. rel, 'sensitive')
        if v == true then out[rel] = 'marked sensitive by config'
        elseif v ~= false then ask[#ask + 1] = rel end
    end
    if #ask == 0 then return out end
    local inside = git(root, { 'rev-parse', '--is-inside-work-tree' })
    if not inside or vim.trim(inside) ~= 'true' then
        for _, rel in ipairs(ask) do out[rel] = 'no repository decides what is public here' end
        return out
    end
    local args = { 'ls-files', '-z', '--' }
    vim.list_extend(args, ask)
    local tracked = {}
    for f in (git(root, args) or ''):gmatch('[^%z]+') do tracked[f] = true end
    for _, rel in ipairs(ask) do
        if not tracked[rel] then out[rel] = 'git does not track it' end
    end
    return out
end

--- a value as the reference that travels in its place
function M.reference(v)
    return { ref = 'sha256:' .. vim.fn.sha256(require('cartograph.decisions').canon(v)), sensitive = true }
end

--- the lines of a text worth looking for (short lines — `end`, `}` — occur everywhere and prove nothing)
local function probes(text, out)
    for line in tostring(text or ''):gmatch('[^\n]+') do
        local t = vim.trim(line)
        if #t >= 12 then out[t] = true end
    end
end

--- does `record` carry any line of a sensitive file? `images` = { [rel] = { text, … } } (the disk text, the journal's
--- before/after). -> { { file, why } } (empty = clean). Names the file, never the bytes.
function M.leaks(record, images)
    local want = {}
    for rel, texts in pairs(images) do
        local p = {}
        for _, t in ipairs(texts) do probes(t, p) end
        want[rel] = p
    end
    local hits, seen = {}, {}
    local function walk(v)
        if type(v) == 'string' then
            for rel, p in pairs(want) do
                if not seen[rel] then
                    for line in pairs(p) do
                        if v:find(line, 1, true) then
                            seen[rel] = true
                            hits[#hits + 1] = { file = rel, why = 'a line of the sensitive file occurs in the record' }
                            break
                        end
                    end
                end
            end
        elseif type(v) == 'table' then
            for k, x in pairs(v) do walk(k); walk(x) end
        end
    end
    walk(record)
    table.sort(hits, function (a, b) return a.file < b.file end)
    return hits
end

return M
