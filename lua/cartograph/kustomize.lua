-- cartograph.kustomize — KUSTOMIZE OVERLAYS READ THROUGH KUSTOMIZE ITSELF (CART-1300): the helm move for kustomize. An
-- overlay is a directory whose kustomization declares `kind: Kustomization` (or no kind); it composes bases, patches
-- and COMPONENTS (`kind: Component` — not releases on their own: k8s.lua counts their unresolved edges as `composed`),
-- and the manifests it declares exist only once BUILT. So each overlay is rendered by `kubectl kustomize` (offline:
-- kubectl built from the local kubernetes checkout) and the output read by cartograph.k8s as one release named by the
-- overlay's directory — a component's NetworkPolicy then resolves against the pods of the base it is composed with.
-- Refused BY NAME: no kubectl/kustomize on PATH; a build error (a remote resource — it needs the network, which this
-- never touches — or a broken patch).
local M = {}

local KFILES = { 'kustomization.yaml', 'kustomization.yml', 'Kustomization' }

--- the kustomize binary invocation: { kubectl, 'kustomize' } | { kustomize, 'build' } | nil
function M.binary()
    local k = vim.fn.exepath('kubectl')
    if k ~= '' then return { k, 'kustomize' } end
    local z = vim.fn.exepath('kustomize')
    if z ~= '' then return { z, 'build' } end
    return nil
end

--- a kustomization directory's kind -> 'Kustomization' | 'Component' | nil (not a kustomization directory)
function M.kind(dir)
    for _, f in ipairs(KFILES) do
        local fd = io.open(dir .. '/' .. f, 'r')
        if fd then
            local txt = fd:read('a'); fd:close()
            return (txt:match('\nkind:%s*Component%s') or txt:match('^kind:%s*Component%s')) and 'Component' or 'Kustomization'
        end
    end
    return nil
end

--- every OVERLAY (a Kustomization, not a Component) among the repo's tracked files -> { rel dir … }
function M.overlays(root, files)
    local dirs, seen = {}, {}
    for _, rel in ipairs(files) do
        local base = rel:match('([^/]+)$')
        for _, f in ipairs(KFILES) do
            if base == f then
                local dir = rel:match('^(.*)/[^/]+$') or '.'
                if not seen[dir] and M.kind(root .. '/' .. dir) == 'Kustomization' then seen[dir] = true; dirs[#dirs + 1] = dir end
            end
        end
    end
    table.sort(dirs)
    return dirs
end

--- BUILD one overlay into `out/<dir>/rendered.yaml` -> rel path | nil, why
function M.render(root, dir, out)
    local bin = M.binary()
    if not bin then return nil, 'no kubectl or kustomize on PATH: an overlay is read through its builder' end
    local r = vim.system({ bin[1], bin[2], root .. '/' .. dir }, { text = true }):wait(120000)
    if not r or r.code ~= 0 then
        local err = vim.trim(((r and r.stderr) or 'kustomize did not finish'):gsub('\n.*', ''))
        if err:find('://', 1, true) or err:find('git', 1, true) and err:find('clone', 1, true) then
            return nil, 'a remote resource (it needs the network, which this never touches): ' .. err
        end
        return nil, 'kustomize build failed: ' .. err
    end
    local rel = dir .. '/rendered.yaml'
    vim.fn.mkdir(out .. '/' .. dir, 'p')
    local fd = assert(io.open(out .. '/' .. rel, 'w')); fd:write(r.stdout or ''); fd:close()
    return rel
end

--- render every overlay and READ the renders as releases -> stats (k8s.attach's, .kustomize = { overlays, rendered,
--- refused = { "<dir>: why" } }), data
function M.attach(root, files, opts)
    opts = opts or {}
    local out = opts.out or vim.fn.tempname()
    local overlays = M.overlays(root, files)
    local rendered, refused = {}, {}
    for _, dir in ipairs(overlays) do
        local rel, why = M.render(root, dir, out)
        if rel then rendered[#rendered + 1] = rel else refused[#refused + 1] = dir .. ': ' .. why end
    end
    local data = { root = out, nodes = {}, edges = {} }
    local s = require('cartograph.k8s').attach(data, { files = rendered, rendered = true })
    s.kustomize = { overlays = #overlays, rendered = #rendered, refused = refused, dir = out }
    return s, data
end

return M
