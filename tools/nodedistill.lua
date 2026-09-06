-- nodedistill — distil the JavaScript LANGUAGE + NODE surface into an L2
-- environment profile ([[cartograph-stdlib-profile]]), from the INSTALLED ENGINE.
--
--   nvim --headless -u NONE -l tools/nodedistill.lua [--out <path>]
--
-- ★★ THE SOURCE IS AN ORACLE, exactly as tools/erldistill.lua asks `erl` what OTP
-- contains. `node` is asked what the language and the runtime contain:
--   Object.getOwnPropertyNames(globalThis)      the global surface
--   require('module').builtinModules            the node module list
--   Object.getOwnPropertyNames(require(m))      each module's exports
--   Object.getOwnPropertyNames(X) / X.prototype the members of each global object
-- Nothing here is authored, so nothing here can rot the way a hand-maintained
-- name list rots.
--
-- ★★★ WHY, SIZED ACROSS FOUR CORPORA BEFORE A LINE WAS WRITTEN (CART-0800):
--     corpus        resolution   top lever
--     converse.js      23.3%     stdlib-profile  +31.0
--     ghost            29.7%     stdlib-profile  +35.7
--     jquery           36.1%     stdlib-profile  +19.8
--     mootools         28.1%     stdlib-profile  +24.5
-- On ghost, `assert` ALONE is 13182 unresolved calls — 10% of the corpus's entire
-- call population, from one import.
--
-- ⚠⚠ THE EPISTEMICS DIFFER FROM ERLANG AND THE DESIGN ACCOUNTS FOR IT.
-- `lists:foldl` names its module IN THE SYNTAX; erlang's nsset is therefore a
-- statement about the language. JavaScript's `assert.equal()` names a LOCAL
-- BINDING that some import happened to call `assert`, and `const _ =
-- require('lodash')` names it `_`. So a node module name in nsset is a
-- CONVENTION, not a syntactic fact.
-- Two things make that safe enough to ship:
--   · `prof_ext` is consulted ONLY IN NODEF POSITION — project resolution has
--     already failed, so a real local `assert` would have answered first.
--   · MINTING IS GATED ON THE MEMBER EXISTING (see spec/profile/node.lua). A
--     local object that merely shares the name `assert` will not have node's
--     `deepStrictEqual` on it, so nothing is minted for it. The verification does
--     the work the name cannot.
-- GLOBALS (Array, Math, JSON, Promise, console) carry no such caveat: they ARE
-- global, and a shadowing local would have resolved before this is reached.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local out = repo .. '/lua/cartograph/spec/profile/node-api.mpack'
local i = 1
while arg and arg[i] do
    if arg[i] == '--out' then out = arg[i + 1]; i = i + 2 else i = i + 1 end
end

if vim.fn.executable('node') ~= 1 then
    print('nodedistill: no `node` on PATH — this tool distils from the INSTALLED'
        .. ' engine, so there is nothing to read.')
    os.exit(2)
end

local tmp = vim.fn.tempname()
-- ⚠ SORTED INSIDE THE ORACLE. The artifact is checked in, so its bytes must not
-- depend on a hash walk (CART-0795 records that every distilled .mpack is
-- byte-unstable for exactly that reason; this at least does not add to it).
local js = ([[
const fs = require('fs'), mod = require('module');
const out = [];
// ⚠ READ THE DESCRIPTOR, NEVER THE VALUE. `typeof o[k]` INVOKES a getter, and
// several web-shim globals throw ERR_INVALID_THIS when their accessors are read
// off anything but a live instance — the first cut of this exited 1 on node 18.
// A descriptor answers without running any of the object's code, which is also
// the right posture for a tool whose whole security argument is that it executes
// nothing. An accessor property is simply not claimed callable.
const callable = (o, k) => {
  try {
    const d = Object.getOwnPropertyDescriptor(o, k);
    return !!d && typeof d.value === 'function';
  } catch (e) { return false; }
};
out.push('@version ' + process.version);
const names = Object.getOwnPropertyNames(globalThis).sort();
for (const n of names) {
  let v; try { v = globalThis[n]; } catch (e) { continue; }
  if (v === undefined || v === null) continue;
  const t = typeof v;
  // a CALLABLE global with no receiver (parseInt, setTimeout, fetch): a `free`
  // name. Constructors are callable too but are used as namespaces far more
  // often, so they are emitted as namespaces below and not as free names.
  const isCtor = t === 'function' && /^[A-Z]/.test(n);
  if (t === 'function' && !isCtor) out.push('@free ' + n + ' ' + (v.length|0));
  if (t === 'function' || t === 'object') {
    const ms = new Set();
    let proto; try { proto = v.prototype; } catch (e) {}
    try { for (const k of Object.getOwnPropertyNames(v)) ms.add(k); } catch (e) {}
    try { if (proto) for (const k of Object.getOwnPropertyNames(proto)) ms.add(k); } catch (e) {}
    const keep = [...ms].filter(k => /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(k)).sort();
    if (keep.length) { out.push('@ns ' + n);
      // ★ WHETHER THE MEMBER IS CALLABLE (CART-0806): the engine knows, and a
      // surface that does not say so lets a CALL resolve to a boolean —
      // `AddEventListenerOptions.once` was the unique owner of the name `once`.
      for (const k of keep) out.push('@m ' + n + ' ' + k + ' '
        + ((callable(v, k) || callable(proto, k)) ? 1 : 0)); }
  }
}
for (const m of mod.builtinModules.slice().sort()) {
  if (m.startsWith('_')) continue;            // private internals are not a surface
  let v; try { v = require(m); } catch (e) { continue; }
  if (!v || (typeof v !== 'object' && typeof v !== 'function')) continue;
  const ms = Object.getOwnPropertyNames(v)
    .filter(k => /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(k)).sort();
  if (!ms.length) continue;
  out.push('@ns ' + m);
  for (const k of ms) out.push('@m ' + m + ' ' + k + ' ' + (callable(v, k) ? 1 : 0));
}
fs.writeFileSync(%s, out.join('\n') + '\n');
]]):format(('%q'):format(tmp))

local _out = vim.fn.system({ 'node', '-e', js })
if vim.v.shell_error ~= 0 then print(_out) end
if vim.v.shell_error ~= 0 then
    print('nodedistill: node exited ' .. vim.v.shell_error); os.exit(2)
end

local nsset, namespaces, free, vocab, sigs = {}, {}, {}, {}, {}
local version, nns, nmem, nfree = 'unknown', 0, 0, 0
for line in io.lines(tmp) do
    local kind, rest = line:match('^@(%w+)%s+(.*)$')
    if kind == 'version' then version = rest
    elseif kind == 'free' then
        local n, ar = rest:match('^(%S+)%s+(%d+)$')
        if n then
            nfree = nfree + 1
            free[n] = { tonumber(ar) }
            vocab[n] = true
        end
    elseif kind == 'ns' then
        if not nsset[rest] then
            nsset[rest] = true
            namespaces[#namespaces + 1] = rest
            nns = nns + 1
        end
    elseif kind == 'm' then
        local ns, m, fnflag = rest:match('^(%S+)%s+(%S+)%s+(%d)$')
        if not ns then ns, m = rest:match('^(%S+)%s+(%S+)$') end
        if ns and m then
            nmem = nmem + 1
            vocab[m] = true
            sigs[ns .. '.' .. m] = sigs[ns .. '.' .. m]
                or { arities = {}, fn = fnflag == '1' or nil }
        end
    end
end
os.remove(tmp)

if nns == 0 then
    print('nodedistill: the engine answered with no namespaces — refusing to write'
        .. ' an empty profile, which would activate and disposition NOTHING while'
        .. ' looking installed.')
    os.exit(2)
end
table.sort(namespaces)

local prof = {
    schema = 1,
    runtime = 'node-api',
    lang = 'javascript',
    version = version,
    -- not a wall clock: the artifact is checked in, and a timestamp would make it
    -- differ on every run for no content reason (the erldistill lesson)
    stamp = ('node-%s-%dns-%dm'):format(version, nns, nmem),
    sig_kind = 'javascript',
    sig_root = 'node:' .. version,
    types = {},
    namespaces = namespaces,
    nsset = nsset,
    free = free,
    vocab = vocab,
    sigs = sigs,
}

local fd = assert(io.open(out, 'wb'))
fd:write(vim.mpack.encode(prof))
fd:close()
print(('nodedistill: node %s — %d namespaces, %d members, %d free globals -> %s')
    :format(version, nns, nmem, nfree, out:gsub('^' .. vim.pesc(repo) .. '/', '')))
