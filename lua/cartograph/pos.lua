-- cartograph.pos — A SOURCE POSITION THAT CARRIES ITS OWN BASE AND UNIT (CART-2086, the user-approved design in kb
-- typed-position-design-proposal).
--
-- Positions were bare integers whose base was implicit and differed table by table (and inside one table: the unread
-- altitude stored a 1-based line where every other wrote 0-based, CART-2087), and every consumer guessed. Storage
-- keeps its packed integers under ONE declared base (at.BASE: 0-based line, 0-based byte column); a position that
-- LEAVES storage — a pane row, the agent wire, an LSP message, a finding — is a value made through a named PROFILE and
-- converted only through `M.to`, which REFUSES (nil, reason) rather than guess.
--
--   { line = n, col = n|nil, lb = 0|1, cb = 0|1|nil, unit = 'byte'|'char'|'utf16'|'utf32'|nil }
--
-- ★ THERE IS NO DEFAULT BASE. `M.new` requires a profile; that is the whole point.
local M = {}

local at = require 'cartograph.at'

--- THE NAMED PROFILES — one table, data. GRAPH is at.BASE by construction; the others are the boundaries' own
--- conventions (nvim API docs, the LSP spec, the agent's published contract).
M.PROFILES = {
    GRAPH       = { lb = at.BASE.line, cb = at.BASE.col, unit = at.BASE.unit },
    NVIM_CURSOR = { lb = 1, cb = 0, unit = 'byte' },   -- nvim_win_get_cursor / set_cursor
    DIAGNOSTIC  = { lb = 0, cb = 0, unit = 'byte' },   -- vim.diagnostic lnum / col, extmarks
    QUICKFIX    = { lb = 1, cb = 1, unit = 'byte' },   -- setqflist lnum / col
    AGENT       = { lb = 1, cb = 1, unit = 'char' },   -- the MCP agent surface (user's decision 2026-11-15, CART-2086)
    FLOW_ROW    = { lb = 1, cb = 1, unit = 'byte' },   -- flow / df statement rows (s.l, s.c)
    HUMAN       = { lb = 1 },                          -- labels a person reads (vnums): a line only
}
--- LSP's profile depends on the NEGOTIATED positionEncoding; never assumed.
function M.lsp(encoding)
    local unit = ({ ['utf-8'] = 'byte', ['utf-16'] = 'utf16', ['utf-32'] = 'utf32' })[encoding or '']
    if not unit then return nil, 'unknown-encoding' end
    return { lb = 0, cb = 0, unit = unit }
end

local function prof(p)
    if type(p) == 'string' then return M.PROFILES[p] end
    return p
end

--- A position in a named profile. `col` may be nil (a line-only position, e.g. a finding).
--- Returns nil, reason when the profile is missing — there is no default.
function M.new(line, col, profile)
    local P = prof(profile)
    if not P then return nil, 'no-profile' end
    if type(line) ~= 'number' then return nil, 'no-line' end
    return { line = line, col = col, lb = P.lb, cb = col ~= nil and P.cb or nil, unit = col ~= nil and P.unit or nil }
end

--- The start (or end) of a stored range, as a GRAPH position.
function M.of_range(r, which)
    if not r then return nil, 'no-range' end
    if which == 'end' then return M.new(at.el(r), at.ec(r), 'GRAPH') end
    return M.new(at.sl(r), at.sc(r), 'GRAPH')
end

-- the encoding name vim.str_byteindex / str_utfindex take for a unit (a CHARACTER is a code point: utf-32)
local ENC = { char = 'utf-32', utf16 = 'utf-16', utf32 = 'utf-32' }
-- the byte offset (0-based) of a column in `unit` (0-based) on `text`, or nil, reason
local function to_byte(text, col0, unit)
    if unit == 'byte' then
        if col0 > #text then return nil, 'out-of-line' end
        return col0
    end
    local enc = ENC[unit]
    if not enc then return nil, 'unknown-unit' end
    -- (str_byteindex with strict=false CLAMPS an index past the end to the line's length — exactly the silent guess
    -- this module refuses, so the length in this unit is checked first)
    local okn, len = pcall(vim.str_utfindex, text, enc)
    if not okn or len == nil or col0 > len then return nil, 'out-of-line' end
    local ok, b = pcall(vim.str_byteindex, text, enc, col0, false)
    if not ok or b == nil or b > #text then return nil, 'out-of-line' end
    -- a UTF-16 index inside a surrogate pair maps onto the start of its code point: refuse instead
    if unit == 'utf16' then
        local okb, back = pcall(vim.str_utfindex, text, enc, b, false)
        if not okb or back ~= col0 then return nil, 'mid-character' end
    end
    return b
end
-- a 0-based byte offset on `text` in `unit` (0-based), or nil, reason
local function from_byte(text, b0, unit)
    if b0 > #text then return nil, 'out-of-line' end
    if unit == 'byte' then return b0 end
    -- a byte offset inside a multi-byte character is no character position
    if b0 < #text then
        local c = text:byte(b0 + 1)
        if c and c >= 0x80 and c < 0xC0 then return nil, 'mid-character' end
    end
    local enc = ENC[unit]
    if not enc then return nil, 'unknown-unit' end
    local ok, u = pcall(vim.str_utfindex, text, enc, b0, false)
    if not ok or u == nil then return nil, 'out-of-line' end
    return u
end

--- THE ONLY CONVERSION. `profile` names the target; `line_text` is the position's line, needed only when the UNIT
--- changes. Refusals (nil, reason): 'unknown-base' / 'unknown-unit' (a position without them), 'no-profile',
--- 'needs-line-text', 'mid-character', 'out-of-line', 'no-column' (asking a line-only position for its column is
--- `M.col`'s refusal; `to` keeps such a position col-less).
function M.to(p, profile, line_text)
    local P = prof(profile)
    if not P then return nil, 'no-profile' end
    if type(p) ~= 'table' or p.lb == nil then return nil, 'unknown-base' end
    local line = p.line - p.lb + P.lb
    if p.col == nil or P.cb == nil then return { line = line, lb = P.lb } end
    if p.cb == nil then return nil, 'unknown-base' end
    if p.unit == nil then return nil, 'unknown-unit' end
    local col0 = p.col - p.cb
    if p.unit ~= P.unit then
        if type(line_text) ~= 'string' then return nil, 'needs-line-text' end
        local b, why = to_byte(line_text, col0, p.unit)
        if not b then return nil, why end
        local u, why2 = from_byte(line_text, b, P.unit)
        if not u then return nil, why2 end
        col0 = u
    end
    return { line = line, col = col0 + P.cb, lb = P.lb, cb = P.cb, unit = P.unit }
end

--- One LINE number of `p` in `base` (0 or 1).
function M.line(p, base)
    if type(p) ~= 'table' or p.lb == nil then return nil, 'unknown-base' end
    return p.line - p.lb + base
end

--- One COLUMN of `p` in profile `profile` (unit and base), `line_text` when the unit changes.
function M.col(p, profile, line_text)
    if type(p) ~= 'table' then return nil, 'unknown-base' end
    if p.col == nil then return nil, 'no-column' end
    local q, why = M.to(p, profile, line_text)
    if not q then return nil, why end
    return q.col
end

return M
