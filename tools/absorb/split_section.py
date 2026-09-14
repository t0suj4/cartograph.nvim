#!/usr/bin/env python3
"""Extract ONE section of the vendored algebra and adapt it into the PARTS
protocol — the driver that took `core.lua` from 6001 lines to ~1450 (CART-0912).

★★★ IT LIVED IN A SCRATCH DIRECTORY FOR SIXTEEN SECTIONS. Everything it knows was
learned by breaking something first, and none of that survives a `rm -rf /tmp`:

  THE THREE CONDITIONS for a binding — a name is bound only if it is (a) a core
  module-level local, (b) used in the moved part and (c) NOT defined there. The
  capture hazards OVER-report (they named `template` and `values`, which the parts
  reach as `M.template`) and the free-identifier scan UNDER-reports (it reads CALL
  targets, and `key` is passed as a value). Neither list alone is right.

  REFUSAL 1, AMBIGUITY (CART-0924). A name core defines TWICE cannot be bound at
  all: `local PARTS = {…}` is built at the BOTTOM of the file, where the name
  resolves to the LAST definition, while a section higher up meant the earlier
  one. Splitting `classify` that way turned a `value` edit into a `straddle`,
  silently; 17 donor tests caught it. Lua scoping is positional and this table is
  not, so the driver stops and asks for a rename.

  REFUSAL 2, SHAREDNESS (CART-0925). A local that PARTS hands round is shared with
  at least one part — but a part reaches it through `SHARED`, WHICH THE GRAPH
  CANNOT SEE, so `close_moveset` judges it private to whichever section still
  calls it directly and lets it travel. Extracting CONSTRAINED MAPPINGS took
  `is_strict_prefix` and handed `vertical` a nil. ⇒ EACH SPLIT MAKES THE NEXT ONE
  LESS SAFE, so the invariant is checked after every apply.

⚠ AND IT IS NOT SUFFICIENT. The capture rungs are blind below one level of
nesting (CART-0926): an anonymous closure RETURNED from a nested function is not
minted as a node, so nothing reads its body. `demandfam` needed four locals and
was told about one. The suite is what catches that, which is why
`run_sections.sh` runs it after EVERY section and stops on the first red.
"""
import io, re, subprocess, sys, os

W = '/home/t0suj4/git/cartograph-adapt'
SP = os.path.dirname(os.path.abspath(__file__))  # plan_section.lua sits beside this file
section, dest = sys.argv[1], sys.argv[2]
part = dest.split('/')[-1][:-4]

# ★★★ WHAT PARTS SUPPLIES BEFORE THE MOVE (CART-0925). A local that core hands
# round is SHARED WITH AT LEAST ONE PART — but a part reaches it through `SHARED`,
# which the graph cannot see, so `close_moveset` judges it PRIVATE to whichever
# section still calls it directly and lets it travel. MEASURED: extracting
# CONSTRAINED MAPPINGS took `is_strict_prefix` with it and handed `vertical` a
# nil; 20 donor tests and both parts fences fired.
# ⇒ EACH SPLIT MAKES THE NEXT ONE LESS SAFE, so the invariant is checked rather
#   than hoped for: PARTS IS THE DECLARATION OF SHAREDNESS.
core0 = io.open(W + '/lua/cartograph/algebra/core.lua', encoding='utf-8').read()
m0 = re.search(r'local PARTS = \{(.*?)\}\n', core0, re.S)
supplied0 = set(re.findall(r'([\w]+)\s*=', m0.group(1))) if m0 else set()

out = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-l', SP + '/plan_section.lua',
                      section, dest, 'apply'], cwd=W, capture_output=True, text=True)
blob = out.stdout + out.stderr
if 'applied=true' not in blob:
    print('APPLY FAILED\n' + '\n'.join(l for l in blob.splitlines()
                                       if 'step 1' in l or 'SECTION' in l))
    sys.exit(2)
print([l for l in blob.splitlines() if l.startswith('SECTION')][0][:78])

core_now = io.open(W + '/lua/cartograph/algebra/core.lua', encoding='utf-8').read()
stolen = [n for n in sorted(supplied0)
          if not re.search(r'^local (function )?%s\b' % n, core_now, re.M)
          and not re.search(r'^local [^=\n]*\b%s\b[^=\n]*=' % n, core_now, re.M)]
if stolen:
    print('  ⚠ STOPPED — this move took %d local(s) OUT of core that PARTS hands\n'
          '    round to other parts: %s\n'
          '    A part reaches them through SHARED, which the graph cannot see, so the\n'
          '    move-set judged them private. Put them back or the parts break.'
          % (len(stolen), ', '.join(stolen)))
    sys.exit(4)

caps = sorted(set(re.findall(r'capture: ([a-z_][\w]*)', blob)))
core = io.open(W + '/lua/cartograph/algebra/core.lua', encoding='utf-8').read()
src = io.open(W + '/' + dest, encoding='utf-8').read()
code = re.sub(r'--.*', '', src)

need, ambiguous = [], []
for n in caps:
    in_core = re.search(r'^local (function )?%s\b' % n, core, re.M) or \
              re.search(r'^local [^=\n]*\b%s\b[^=\n]*=' % n, core, re.M)
    used = re.search(r'\b%s\b' % n, code)
    defined = re.search(r'\blocal (function )?%s\b' % n, code)
    if in_core and used and not defined:
        # ⚠ AMBIGUOUS NAMES ARE REFUSED, NOT GUESSED (CART-0924). PARTS is built at
        # the BOTTOM of core, so a name declared twice resolves there to the LAST
        # definition — and a section higher up meant the earlier one. Binding it
        # silently swaps the function. Splitting `classify` that way turned a
        # `value` edit into a `straddle` and 17 donor tests caught it.
        ndecl = len(re.findall(r'^local function %s\b' % n, core, re.M))
        if ndecl > 1:
            ambiguous.append('%s (%d definitions)' % (n, ndecl))
        else:
            need.append(n)
print('  captures %-2d -> bindings %d: %s' % (len(caps), len(need), ' '.join(need) or '(none)'))
if ambiguous:
    print('  ⚠ REFUSED — ambiguous, core defines each more than once: '
          + ', '.join(ambiguous)
          + '\n    which definition this section meant is a fact about its POSITION,'
            ' and PARTS cannot express that. Rename in core first.')
    sys.exit(3)

head = ("-- A PART OF `cartograph.algebra.core`, which requires this file at its end and\n"
        "-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a\n"
        "-- load cycle — Lua says \"loop or previous error loading module\".\n")
if need:
    head += ("-- ★ %d shared file-local(s), each (a) a core module-level local, (b) used\n"
             "-- here and (c) not defined here — the three conditions, not a guess.\n"
             "return function (M, SHARED)\n"
             "local %s =\n    %s\n") % (len(need), ', '.join(need),
                                        ', '.join('SHARED.' + n for n in need))
else:
    head += ("-- ★ This part reaches back for NOTHING: a section boundary that is also a\n"
             "-- dependency boundary.\n"
             "return function (M, SHARED)\nlocal _ = SHARED\n")
assert src.startswith('local M = {}\n')
body = head + src[len('local M = {}\n'):]
assert body.rstrip().endswith('return M')
io.open(W + '/' + dest, 'w', encoding='utf-8').write(
    body.rstrip()[:-len('return M')].rstrip('\n') + '\nend\n')

# PARTS: add any binding core does not already hand round, then the require line
m = re.search(r'local PARTS = \{(.*?)\}\n', core, re.S)
supplied = set(re.findall(r'([\w]+)\s*=', m.group(1)))
missing = [n for n in need if n not in supplied]
if missing:
    core = core.replace(m.group(0),
        m.group(0).rstrip()[:-1].rstrip() + ',\n    '
        + ', '.join('%s = %s' % (n, n) for n in missing) + ' }\n', 1)
last = re.findall(r"require\('cartograph\.algebra\.[\w]+'\)\(M, PARTS\)", core)[-1]
core = core.replace(last, last + "\nrequire('cartograph.algebra.%s')(M, PARTS)" % part, 1)
io.open(W + '/lua/cartograph/algebra/core.lua', 'w', encoding='utf-8').write(core)
print('  adapted: +%d to PARTS, part wired' % len(missing))
