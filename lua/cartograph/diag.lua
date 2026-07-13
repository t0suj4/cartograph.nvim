-- IN-BUFFER SURFACE (the A1 discovery surface). Findings the graph produces are
-- published to a vim.diagnostic namespace, so they show as signs + virtual text
-- on the affected lines of open buffers — the graph's verdicts land where the
-- code is, not only in a scratch report. Escalation is the first consumer: a
-- CONFLICT (static vs lua-ls disagree) is an ERROR — a real bug on one side; a
-- REFUTED name-match is a WARN. Findings for files not yet loaded are held and
-- flushed when their buffer appears, so opening a file lights up its findings.
--
-- Generic on purpose: any finding list of { file=abs, line=1based, col?, sev,
-- message } publishes here, so the lint rules can adopt the same surface later.

local M = {}

local ns = vim.api.nvim_create_namespace('cartograph-diag')
local SEV = {
    error = vim.diagnostic.severity.ERROR,
    warn  = vim.diagnostic.severity.WARN,
    info  = vim.diagnostic.severity.INFO,
    hint  = vim.diagnostic.severity.HINT,
}

-- diagnostics per absolute file path, waiting for their buffer (an already-open
-- buffer is set immediately; a not-yet-loaded one is flushed on BufReadPost).
M.pending = {}
local wired = false

local function to_diag(f)
    return {
        lnum = math.max((f.line or 1) - 1, 0),
        col = math.max((f.col or 1) - 1, 0),
        severity = SEV[f.severity] or SEV.warn,
        message = f.message or '',
        source = f.source or 'cartograph',
    }
end

local function flush(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local held = name ~= '' and M.pending[name]
    if held then vim.diagnostic.set(ns, bufnr, held) end
end

local function wire()
    if wired then return end
    wired = true
    vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
        group = vim.api.nvim_create_augroup('cartograph-diag', { clear = true }),
        callback = function (ev) flush(ev.buf) end,
    })
end

--- Publish a finding list to the in-buffer surface, REPLACING any previous
--- cartograph diagnostics. `findings` = { { file, line, col?, severity, message,
--- source? }, ... } (file absolute, line 1-based). Returns the count published.
function M.publish(findings)
    wire()
    vim.diagnostic.reset(ns)       -- clear the previous set from every buffer
    M.pending = {}
    for _, f in ipairs(findings or {}) do
        if f.file and f.file ~= '' then
            local d = M.pending[f.file] or {}
            d[#d + 1] = to_diag(f)
            M.pending[f.file] = d
        end
    end
    -- light up every buffer already open
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then flush(b) end
    end
    return #(findings or {})
end

--- Clear the surface.
function M.clear()
    vim.diagnostic.reset(ns)
    M.pending = {}
end

return M
