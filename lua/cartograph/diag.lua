-- IN-BUFFER SURFACE (the A1 discovery surface). Findings the graph produces are
-- published to a vim.diagnostic namespace, so they show as signs + virtual text
-- on the affected lines of open buffers — the graph's verdicts land where the
-- code is, not only in a scratch report. Findings for files not yet loaded are
-- held and flushed when their buffer appears, so opening a file lights up its
-- findings.
--
-- MULTI-PRODUCER: each producer publishes under its own KEY (its own namespace +
-- held set), so independent surfaces COEXIST instead of clobbering — the lint
-- rules ('lint') and escalation ('escalate') light up the same buffer together.
-- publish(findings, key) REPLACES only that key's diagnostics.
--
-- Generic on purpose: any finding list of { file=abs, line=1based, col?, sev,
-- message, source? } publishes here.

local M = {}

local SEV = {
    error = vim.diagnostic.severity.ERROR,
    warn  = vim.diagnostic.severity.WARN,
    info  = vim.diagnostic.severity.INFO,
    hint  = vim.diagnostic.severity.HINT,
}

-- key -> { ns, held = { [abs file] = { diag, ... } } }. A not-yet-loaded
-- buffer's diagnostics wait in `held` and flush on BufReadPost.
M.groups = {}
local wired = false

local function group(key)
    key = key or 'default'
    local g = M.groups[key]
    if not g then
        g = { ns = vim.api.nvim_create_namespace('cartograph-diag-' .. key), held = {} }
        M.groups[key] = g
    end
    return g
end

local function to_diag(f)
    return {
        lnum = math.max((f.line or 1) - 1, 0),
        col = math.max((f.col or 1) - 1, 0),
        severity = SEV[f.severity] or SEV.warn,
        message = f.message or '',
        source = f.source or 'cartograph',
    }
end

-- set every key's held diagnostics for this buffer (each in its own namespace)
local function flush(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == '' then return end
    for _, g in pairs(M.groups) do
        local held = g.held[name]
        if held then vim.diagnostic.set(g.ns, bufnr, held) end
    end
end

local function wire()
    if wired then return end
    wired = true
    vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
        group = vim.api.nvim_create_augroup('cartograph-diag', { clear = true }),
        callback = function (ev) flush(ev.buf) end,
    })
end

--- Publish a finding list to the in-buffer surface under `key`, REPLACING any
--- previous cartograph diagnostics for that key (other keys untouched).
--- `findings` = { { file, line, col?, severity, message, source? }, ... }
--- (file absolute, line 1-based). Returns the count PUBLISHED, which is not
--- always the count submitted: a finding with no `file` has nowhere to land on
--- an in-buffer surface, so it is skipped and not counted. Callers format this
--- as "N finding(s) on in-buffer signs", so it has to be what is really there.
function M.publish(findings, key)
    wire()
    local g = group(key)
    vim.diagnostic.reset(g.ns) -- clear this key's previous set from every buffer
    g.held = {}
    local n = 0
    for _, f in ipairs(findings or {}) do
        if f.file and f.file ~= '' then
            local d = g.held[f.file] or {}
            d[#d + 1] = to_diag(f)
            g.held[f.file] = d
            n = n + 1
        end
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then flush(b) end
    end
    return n
end

--- Clear the surface for `key` (or every key when nil).
function M.clear(key)
    if key then
        local g = M.groups[key]
        if g then vim.diagnostic.reset(g.ns); g.held = {} end
    else
        for _, g in pairs(M.groups) do vim.diagnostic.reset(g.ns); g.held = {} end
    end
end

return M
