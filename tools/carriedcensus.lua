-- carriedcensus — THE CARRIED-ARGUMENT CENSUS (CART-1037, CART-1136): for every self-recursive erlang function, each
-- argument position across its back edges (every self-call, the worst class wins) is
--   invariant · decreasing (a proper part of the head's pattern, or N - K) · constant · accumulating (prepend, append,
--   counter N + K, a record/map update, an element of the traversed argument) · rebuilt from head parts (a
--   constructor, no call: usually a one-step RE-DISPATCH) · other (through a call, a case/receive-bound value, moved
--   from another argument, unrecognized)
-- and per function: closed form (no 'other') / a constructor re-dispatch / needs the fixpoint. The instrument the
-- recursion revisit (CART-1136) re-measures with; erlterms.carried is the runtime twin, with fewer classes.
--
--   nvim --headless -u NONE -l tools/carriedcensus.lua [ONLY=<label substring>]
--
-- Populations (read-only): ejabberd hand-written, ejabberd's asn1-generated ELDAPv3, xmpp (generated codecs), OTP 25
-- stdlib (~/git/otp_src_25.3.2.8). ⚠ SYNTACTIC: one binding hop for body matches; self-calls inside funs are not
-- back edges here; whether an exit depends on carried state is not classified.
-- Measured 2026-09-27 (hand-written ejabberd): 420 functions, 1150 positions — invariant 46%, decreasing 15%,
-- accumulating+constant 11%, rebuilt 6%, other 22%; per function closed 137 / re-dispatch 59 / fixpoint 224.
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local sets = {
  { 'ejabberd (hand-written)', os.getenv('HOME') .. '/work/brotardcast/ejabberd/src', function (f) return not f:match('ELDAPv3') end },
  { 'ejabberd ELDAPv3 (asn1-generated)', os.getenv('HOME') .. '/work/brotardcast/ejabberd/src', function (f) return f:match('ELDAPv3') end },
  { 'xmpp (mostly generated codecs)', os.getenv('HOME') .. '/git/xmpp/src', function () return true end },
  { 'OTP 25 stdlib', os.getenv('HOME') .. '/git/otp_src_25.3.2.8/lib/stdlib/src', function () return true end },
}
local only = os.getenv('ONLY')
for _, a in ipairs(arg or {}) do local v = a:match('^ONLY=(.+)$'); if v then only = v end end
local function txt(n, src) return vim.treesitter.get_node_text(n, src) end
local function named(x) local o = {}; if x then for c in x:iter_children() do if c:named() then o[#o + 1] = c end end end return o end
local RANK = { invariant = 1, decreasing = 2, ['decreasing (counter)'] = 2, constant = 3, ['accumulating: prepend'] = 4,
  ['accumulating: append'] = 4, ['accumulating: counter'] = 4, ['accumulating: record/map update'] = 4,
  ['accumulating: an element of the traversed argument'] = 4, ['rebuilt from head parts (a constructor, no call)'] = 6,
  ['other: through a call'] = 9, ['other: moved from another argument'] = 8, ['other: a value bound by a case/receive'] = 9, ['other'] = 9 }
local function worst(a, b) if not a then return b end if (RANK[b] or 9) > (RANK[a] or 9) then return b end return a end

for _, set in ipairs(sets) do
  if not only or set[1]:find(only, 1, true) then
  local label, dir, keep = set[1], set[2], set[3]
  local pos, fns, fnclass, examples = {}, 0, {}, {}
  for _, f in ipairs(vim.fn.glob(dir .. '/*.erl', false, true)) do
    if keep(vim.fn.fnamemodify(f, ':t')) then
    local fd = io.open(f); local src = fd:read('a'); fd:close()
    local root = vim.treesitter.get_string_parser(src, 'erlang'):parse()[1]:root()
    local groups = {}
    for decl in root:iter_children() do
      if decl:type() == 'fun_decl' then
        for _, cl in ipairs(decl:field('clause')) do
          local nn = cl:field('name')[1]
          if nn then
            local key = txt(nn, src) .. '/' .. #named(cl:field('args')[1])
            groups[key] = groups[key] or {}; table.insert(groups[key], cl)
          end
        end
      end
    end
    for key, cls in pairs(groups) do
      local name, ar = key:match('^(.+)/(%d+)$'); ar = tonumber(ar)
      local classes, any = {}, false
      for _, cl in ipairs(cls) do
        local heads = named(cl:field('args')[1])
        -- the variables each head position binds: whole (the argument itself, or its alias) vs a proper part
        local whole, part = {}, {}
        for i, p in ipairs(heads) do
          local function scan(n, depth)
            local t = n:type()
            if t == 'var' then
              local v = txt(n, src)
              if v ~= '_' then
                if depth == 0 then whole[v] = i elseif not whole[v] then part[v] = part[v] or i end
              end
              return
            end
            if t == 'match_expr' then
              scan(n:field('lhs')[1], depth); scan(n:field('rhs')[1], depth); return
            end
            for c in n:iter_children() do if c:named() then scan(c, depth + 1) end end
          end
          scan(p, 0)
        end
        -- body matches `V = Rhs` (one binding step) and case/receive-bound variables
        local bound, casebound = {}, {}
        local function body_scan(n)
          for c in n:iter_children() do
            if c:type() == 'match_expr' then
              local l = c:field('lhs')[1]
              if l and l:type() == 'var' then bound[txt(l, src)] = c:field('rhs')[1] end
            elseif c:type() == 'cr_clause' then
              local pat = c:field('pat')[1]
              local function vs(x) if x:type() == 'var' then casebound[txt(x, src)] = true end for y in x:iter_children() do if y:named() then vs(y) end end end
              if pat then vs(pat) end
            end
            if c:type() ~= 'anonymous_fun' then body_scan(c) end
          end
        end
        body_scan(cl:field('body')[1] or cl)
        local function classify(a, i, hops)
          local t = a:type()
          if t == 'paren_expr' then return classify(a:named_child(0), i, hops) end
          if t == 'var' then
            local v = txt(a, src)
            if whole[v] == i then return 'invariant' end
            if part[v] == i then return 'decreasing' end
            if part[v] and part[v] ~= i then return 'accumulating: an element of the traversed argument' end
            if whole[v] then return 'other: moved from another argument' end
            if bound[v] and hops < 3 then return classify(bound[v], i, hops + 1) end
            if casebound[v] then return 'other: a value bound by a case/receive' end
            return 'other'
          end
          if t == 'binary_op_expr' then
            local op = a:child(1) and txt(a:child(1), src)
            local l, r = a:field('lhs')[1], a:field('rhs')[1]
            local lv = l and l:type() == 'var' and txt(l, src)
            if lv and whole[lv] == i and r and r:type() == 'integer' then
              if op == '-' then return 'decreasing (counter)' end
              if op == '+' then return 'accumulating: counter' end
            end
            if op == '++' and lv and whole[lv] == i then return 'accumulating: append' end
            if op == '++' then
              local rv = r and r:type() == 'var' and txt(r, src)
              if rv and whole[rv] == i then return 'accumulating: prepend' end
            end
            return 'other'
          end
          if t == 'list' then
            for _, c in ipairs(a:field('exprs')) do
              if c:type() == 'pipe' then
                local rr = c:field('rhs')[1]
                if rr and rr:type() == 'var' and whole[txt(rr, src)] == i then return 'accumulating: prepend' end
              end
            end
            if #a:field('exprs') == 0 then return 'constant' end
            return 'other'
          end
          if t == 'record_update_expr' or t == 'map_expr' then
            local b = a:field('expr')[1]
            if b and b:type() == 'var' and whole[txt(b, src)] == i then return 'accumulating: record/map update' end
            return 'other'
          end
          if t == 'atom' or t == 'integer' or t == 'string' or t == 'binary' then
            local h = heads[i]
            if h and txt(h, src) == txt(a, src) then return 'invariant' end
            return 'constant'
          end
          if t == 'call' or t == 'remote' then return 'other: through a call' end
          return 'other'
        end
        local function constructor(a)
          -- only head variables, literals and constructors (no call, no body-bound variable) below
          local ok = true
          local function go(n)
            local t = n:type()
            if t == 'call' or t == 'remote' or t == 'anonymous_fun' then ok = false; return end
            if t == 'var' then local v = txt(n, src); if not (whole[v] or part[v] or v == '_') then ok = false end return end
            for c in n:iter_children() do if c:named() then go(c) end end
          end
          go(a)
          return ok
        end
        local base_classify = classify
        classify = function (a, i, hops)
          local k = base_classify(a, i, hops)
          if k == 'other' and constructor(a) then return 'rebuilt from head parts (a constructor, no call)' end
          return k
        end
        local function walk(x)
          for c in x:iter_children() do
            if c:type() == 'call' and c:parent():type() ~= 'remote' then
              local e = c:field('expr')[1]
              local args = named(c:field('args')[1])
              if e and txt(e, src) == name and #args == ar then
                any = true
                for i, a in ipairs(args) do classes[i] = worst(classes[i], classify(a, i, 0)) end
              end
            end
            if c:type() ~= 'anonymous_fun' then walk(c) end
          end
        end
        walk(cl)
      end
      if any then
        fns = fns + 1
        local fworst
        for i = 1, ar do
          local k = classes[i] or 'invariant'
          pos[k] = (pos[k] or 0) + 1
          fworst = worst(fworst, k)
          examples[k] = examples[k] or {}
          if #examples[k] < 2 then table.insert(examples[k], vim.fn.fnamemodify(f, ':t') .. ' ' .. key .. '#' .. i) end
        end
        local r = RANK[fworst or 'invariant'] or 9
        local fc = r >= 8 and 'needs the fixpoint' or (r == 6 and 'bounded re-dispatch (check)' or 'closed form')
        fnclass[fc] = (fnclass[fc] or 0) + 1
      end
    end
    end
  end
  local np = 0
  for _, n in pairs(pos) do np = np + n end
  io.write(('\n== %s: %d self-recursive functions, %d argument positions\n'):format(label, fns, np))
  local ks = vim.tbl_keys(pos); table.sort(ks, function (a, b) return (RANK[a] or 9) < (RANK[b] or 9) or (RANK[a] == RANK[b] and pos[a] > pos[b]) end)
  for _, k in ipairs(ks) do io.write(('  %5d %4.0f%%  %-40s %s\n'):format(pos[k], 100 * pos[k] / np, k, table.concat(examples[k], ' | '))) end
  io.write(('  per function: closed form %d, a constructor re-dispatch %d, needs the fixpoint %d\n'):format(
      fnclass['closed form'] or 0, fnclass['bounded re-dispatch (check)'] or 0, fnclass['needs the fixpoint'] or 0))
  end
end
