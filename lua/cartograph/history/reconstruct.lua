-- Driver for ledger reconstruction (orchestration, not pure). Walks a git commit
-- range, extracts the symbol graph at each commit (in a throwaway worktree,
-- in-process via the tree-sitter provider — the lua-ls --graph CLI this used
-- to shell out to is retired), and feeds the sequence to ledger.reconstruct.
--
-- Extracted graphs are cached by commit sha, so re-runs (and resuming an
-- interrupted run) are cheap. This layer needs git + the extractor on disk and
-- so is validated by running it, not by unit tests; the diff logic it drives
-- lives in ledger.lua and is unit-tested there.

local ledger = require 'cartograph.history.ledger'

local M = {}

local function sh(cmd)
    -- bounded: :wait(timeout) kills the process on expiry and returns a
    -- non-zero code, so a hung git can never block nvim indefinitely
    local r = vim.system(cmd, { text = true }):wait(30000)
    if r.code ~= 0 then
        error(('command failed (%d): %s\n%s'):format(r.code, table.concat(cmd, ' '), r.stderr or ''))
    end
    return r.stdout or ''
end

local function lines_of(s)
    local out = {}
    for l in s:gmatch('[^\n]+') do out[#out + 1] = l end
    return out
end

local function read_json(path)
    local f = io.open(path, 'r'); if not f then return nil end
    local t = f:read('a'); f:close()
    local ok, g = pcall(vim.json.decode, t)
    return ok and g or nil
end

--- Reconstruct the ledger for `repo` across the range `from`..`to` (inclusive of
--- `from` as the baseline snapshot).
---@param opts { repo:string, from:string, to:string, cache:string?, progress:boolean? }
---@return { steps:table, lines:string[] }
function M.run(opts)
    local repo  = assert(opts.repo, 'reconstruct: repo required')
    local cache = opts.cache or (vim.fn.stdpath('cache') .. '/cartograph-ledger')
    vim.fn.mkdir(cache, 'p')

    -- revs oldest→newest: the baseline `from`, then each commit up to `to`
    -- (assign gsub to a local first: in a table literal it would also splat its
    -- substitution count as a second element)
    local base = (sh { 'git', '-C', repo, 'rev-parse', opts.from }):gsub('%s+$', '')
    local revs = { base }
    for _, r in ipairs(lines_of(sh { 'git', '-C', repo, 'rev-list', '--reverse', opts.from .. '..' .. opts.to })) do
        revs[#revs + 1] = r
    end

    -- commit subjects (labels), parallel to revs
    local labels = {}
    for i, rev in ipairs(revs) do
        labels[i] = (sh { 'git', '-C', repo, 'log', '-1', '--format=%s', rev }):gsub('%s+$', '')
    end

    local graphs = M.extract_graphs(repo, revs, { cache = cache, progress = opts.progress })
    local steps = ledger.reconstruct(graphs, labels)
    return { steps = steps, lines = ledger.render(steps) }
end

--- Extract the symbol graph at each of `revs` (in a throwaway worktree, sha-cached).
--- Shared by the ledger and the coupling miner. Returns a graph per rev (parallel).
---@param repo string
---@param revs string[]
---@param opts { cache:string?, progress:boolean?, subdir:string? }
---@return table[] graphs
function M.extract_graphs(repo, revs, opts)
    opts = opts or {}
    local cache = opts.cache or (vim.fn.stdpath('cache') .. '/cartograph-ledger')
    vim.fn.mkdir(cache, 'p')
    local wt = cache .. '/wt'
    sh { 'git', '-C', repo, 'worktree', 'add', '-q', '--force', '--detach', wt, revs[1] }
    local graphs = {}
    local okrun, err = pcall(function ()
        for i, rev in ipairs(revs) do
            local json = cache .. '/' .. rev .. '.json'
            local g = read_json(json)
            if not g then
                sh { 'git', '-C', wt, 'checkout', '-q', '--detach', rev }
                -- scope extraction to a subdir when given (faster, focused); node
                -- files are then relative to that subdir — the caller reconciles.
                local graphdir = opts.subdir and (wt .. '/' .. opts.subdir) or wt
                -- tolerate a failed extraction (broken commit): empty, skipped
                local okx, data = pcall(
                    require('cartograph.providers.treesitter').extract, graphdir)
                g = okx and { nodes = data.nodes, edges = data.edges }
                    or { nodes = {}, edges = {} }
                local f = io.open(json, 'w')
                if f then
                    f:write(vim.json.encode(g))
                    f:close()
                end
            end
            graphs[i] = g
            if opts.progress then io.write(('\r  extracted %d/%d'):format(i, #revs)); io.flush() end
        end
    end)
    sh { 'git', '-C', repo, 'worktree', 'remove', '--force', wt }
    if opts.progress then io.write('\n') end
    if not okrun then error(err) end
    return graphs
end

return M
