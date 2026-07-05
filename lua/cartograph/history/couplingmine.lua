-- Temporal-coupling miner (driver). Walks a commit range, attributes each
-- commit's changed lines to the functions they fall in (using that commit's
-- graph, sha-cached via reconstruct.extract_graphs), and accumulates co-change.
-- Needs git + the extractor; the counting logic it drives is in coupling.lua.

local coupling    = require 'cartograph.history.coupling'
local reconstruct = require 'cartograph.history.reconstruct'

local M = {}

local function sh(cmd)
    -- bounded (kills on expiry); a failed or timed-out git degrades to an
    -- empty result rather than blocking or erroring the coupling analysis
    local r = vim.system(cmd, { text = true }):wait(30000)
    if r.code ~= 0 then return '' end
    return r.stdout or ''
end

-- changed NEW-side lines per file for one commit (vs its parent), from a
-- zero-context diff. { [file] = { [lineNo] = true } }.
local function changed_lines(repo, rev)
    local out = sh { 'git', '-C', repo, 'diff', '--unified=0', '--no-color', rev .. '^', rev }
    local files, cur = {}, nil
    for line in out:gmatch('[^\n]+') do
        local f = line:match('^%+%+%+ b/(.+)$')
        if f then
            cur = f
            files[cur] = files[cur] or {}
        else
            local c, d = line:match('^@@ %-%d+,?%d* %+(%d+),?(%d*) @@')
            if c and cur then
                c = tonumber(c)
                local n = (d == '') and 1 or tonumber(d)
                for i = 0, n - 1 do files[cur][c + i] = true end  -- n==0 (pure deletion) adds nothing
            end
        end
    end
    return files
end

--- Mine change coupling for `repo` across `from`..`to`.
---@param opts { repo:string, from:string, to:string, cache:string?, progress:boolean? }
---@return { coupling:table, commits:integer }
function M.run(opts)
    local repo = assert(opts.repo, 'couplingmine: repo required')
    -- commit list, optionally filtered to commits that touch given paths
    local revcmd = { 'git', '-C', repo, 'rev-list', '--reverse', opts.from .. '..' .. opts.to }
    if opts.paths then
        revcmd[#revcmd + 1] = '--'
        for _, p in ipairs(opts.paths) do revcmd[#revcmd + 1] = p end
    end
    local revs = {}
    for line in sh(revcmd):gmatch('[^\n]+') do revs[#revs + 1] = line end
    local graphs = reconstruct.extract_graphs(repo, revs, opts)

    local sets = {}
    for i, rev in ipairs(revs) do
        local nodes = graphs[i].nodes
        -- when extraction was scoped to a subdir, node files are subdir-relative;
        -- prefix it back so they match the repo-relative paths in the diff.
        if opts.subdir then
            local remapped = {}
            for _, n in ipairs(nodes) do
                remapped[#remapped + 1] = { file = opts.subdir .. '/' .. n.file,
                    name = n.name, kind = n.kind, range = n.range }
            end
            nodes = remapped
        end
        sets[#sets + 1] = coupling.attribute(nodes, changed_lines(repo, rev))
    end
    return { coupling = coupling.accumulate(sets), commits = #revs }
end

return M
