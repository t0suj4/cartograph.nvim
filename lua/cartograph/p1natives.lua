-- p1natives — THE NATIVE FUNCTIONS of ProcessOne's libraries (xmpp, p1_stringprep), MODELLED on the domain the
-- running runtime was asked about (CART-1138: the grammar's JIDs).
--
-- A NIF has no Erlang meaning: jid:string_to_usr/1's source is erlang:nif_error, stringprep ships no source at all.
-- erlterms reads each as a hole — so every JID an xmpp decoder reads stays unknown. These models answer instead, and
-- ONLY where they were accepted against the runtime (tools/p1natives.lua, every string up to a length over the bytes
-- that matter, application:ensure_all_started(xmpp)):
--   * a ground binary of PRINTABLE ASCII (32..126). Any other byte — a control, UTF-8 — returns nil: the hole stays.
--     stringprep's Unicode tables are not modelled, and a certain wrong answer is worse than the hole it replaces.
--   * the rules below are the OBSERVED ones, not RFC 3491/3920 recalled: nameprep prohibits nothing in ASCII (not even
--     a space), resourceprep keeps case and a space, nodeprep lowercases and refuses space and "&'/:<>@.
-- `string_to_usr` is xmpp's c_src/jid.rl, a ragel machine:
--   node     = (idbyte+ '@')?            idbyte     = any but space " & ' / : < > @
--   domain   = (domainbyte+ '.')* domainbyte+ '.'?   domainbyte = any but space . @ /
--   resource = ('/' any+)?
-- read here as its one parse: the node is what precedes the first '@' when that '@' comes before any '/'.
local M = {}

local function A() return require('cartograph.algebra').load() end
local function bin(s) local l = A().lit(s); l.lk = 'bin'; return l end
local function atom(s) local l = A().lit(s); l.lk = 'atom'; return l end

-- the argument's text when it is a known binary inside the modelled domain, else nil
local function text(t)
    if not (t and t.k == 'lit' and (t.lk == 'bin' or t.lk == nil)) then return nil end
    local s = tostring(t.v)
    if s:find('[^\32-\126]') then return nil end
    return s
end

local NODE_BAD = '[ "&\'/:<>@]'

local function usr(s)
    if s == '' then return nil end
    local at, sl = s:find('@', 1, true), s:find('/', 1, true)
    local node, rest = '', s
    if at and (not sl or at < sl) then
        node, rest = s:sub(1, at - 1), s:sub(at + 1)
        if node == '' or node:find(NODE_BAD) then return nil end
    end
    local domain, resource = rest, ''
    local sl2 = rest:find('/', 1, true)
    if sl2 then
        domain, resource = rest:sub(1, sl2 - 1), rest:sub(sl2 + 1)
        if resource == '' then return nil end
    end
    local labels = domain:gsub('%.$', '')
    if labels == '' or labels:find('[ @/]') then return nil end
    for label in (labels .. '.'):gmatch('([^.]*)%.') do if label == '' then return nil end end
    return node, domain, resource
end

M.models = {
    ['jid:string_to_usr/1'] = function (a)
        local s = text(a[1])
        if not s then return nil end
        if s == '' then return atom('error') end
        local u, d, r = usr(s)
        if not u then return atom('error') end
        return A().node('tuple', bin(u), bin(d), bin(r))
    end,
    ['stringprep:nodeprep/1'] = function (a)
        local s = text(a[1])
        if not s then return nil end
        if s:find(NODE_BAD) then return atom('error') end
        return bin(s:lower())
    end,
    ['stringprep:nameprep/1'] = function (a)
        local s = text(a[1])
        return s and bin(s:lower()) or nil
    end,
    ['stringprep:resourceprep/1'] = function (a)
        local s = text(a[1])
        return s and bin(s) or nil
    end,
}

return M
