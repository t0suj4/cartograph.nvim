// GENERATED — do not edit. LuaJIT's Lua-pattern matcher, TRANSLITERATED from C by cartograph.cjs (CART-1197):
//   source   src/lib_string.c + src/lj_char.c (lj_char_bits), LuaJIT git 9d145d2ca3db58493859c495489a0f08f627834f
//   command  nvim --headless -u NONE -l tools/cjs.lua lstrmatch <luajit src dir> lua/cartograph/luajs/lstrmatch.js
'use strict';
// C truthiness: nonzero and non-NULL (offset 0 is never a valid pointer)
const $T = x => x !== 0 && x !== null && x !== undefined;
const $crefuse = what => { throw new Error("[cjs] no faithful form: " + what); };
let H = null; // the byte heap, installed by the caller (setheap)
// the heap image: every static array the code reads, at its fixed offset (offset 0 reserved)
const IMAGE = [
  // lj_char_bits[257] at 1
  [1, [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 152, 152, 152, 152, 152, 152, 152, 152, 152, 152, 4, 4, 4, 4, 4, 4, 4, 176, 176, 176, 176, 176, 176, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 160, 4, 4, 4, 4, 132, 4, 208, 208, 208, 208, 208, 208, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 192, 4, 4, 4, 4, 1, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128]],
  // match_class_map[32] at 258
  [258, [0, ((0x40 | 0x20)), 0, 0x01, 0x08, 0, 0, ((((((0x40 | 0x20)) | 0x08)) | 0x04)), 0, 0, 0, 0, 0x40, 0, 0, 0, 0x04, 0, 0, 0x02, 0, 0x20, 0, ((((0x40 | 0x20)) | 0x08)), 0x10, 0, 0, 0, 0, 0, 0, 0]],
];
const IMAGE_END = 290;
function image() { const h = new Uint8Array(IMAGE_END); for (const [at, vals] of IMAGE) h.set(vals, at); return h; }
let $cerr, $memcmp, $push, $str;
function bind(env) { ({ $cerr, $memcmp, $push, $str } = env); }
function start_capture(ms, s, p, what) {
let res;
let level = ms.level;
if ($T((+(level >= 32)))) $cerr("too many captures");
ms.capture[level].init = s;
ms.capture[level].len = what;
ms.level = (level + 1);
if ($T((+((res = match(ms, s, p)) === (null))))) ms.level--;
return res;
}

function capture_to_close(ms) {
let level = ms.level;
for (level--; $T(+(level >= 0)); level--) if ($T((+(ms.capture[level].len === (-1))))) return level;
$cerr("invalid pattern capture");
return 0;
}

function end_capture(ms, s, p) {
let l = capture_to_close(ms);
let res;
ms.capture[l].len = (s - ms.capture[l].init);
if ($T((+((res = match(ms, s, p)) === (null))))) ms.capture[l].len = (-1);
return res;
}

function matchbalance(ms, s, p) {
if ($T((+($T(+((H[p] << 24 >> 24) === 0)) || $T(+((H[((p + 1))] << 24 >> 24) === 0)))))) $cerr("unbalanced pattern");
if ($T((+((H[s] << 24 >> 24) !== (H[p] << 24 >> 24))))) {
return (null);
} else {
let b = (H[p] << 24 >> 24);
let e = (H[((p + 1))] << 24 >> 24);
let cont = 1;
while ($T((+(++s < ms.src_end)))) {
if ($T((+((H[s] << 24 >> 24) === e)))) {
if ($T((+(--cont === 0)))) return (s + 1);
} else if ($T((+((H[s] << 24 >> 24) === b)))) {
cont++;
}
}
}
return (null);
}

function classend(ms, p) {
$sw1: switch (((H[p++] << 24 >> 24))) {
case 37:
if ($T((+((H[p] << 24 >> 24) === 0)))) $cerr("malformed pattern (ends with '%')");
return (p + 1);
case 91:
if ($T((+((H[p] << 24 >> 24) === 94)))) p++;
do {
if ($T((+((H[p] << 24 >> 24) === 0)))) $cerr("malformed pattern (missing ']')");
if ($T((+($T(+((H[(p++)] << 24 >> 24) === 37)) && $T(+((H[p] << 24 >> 24) !== 0)))))) p++;
} while ($T((+((H[p] << 24 >> 24) !== 93))));
return (p + 1);
default:
return p;
}
}

function match_class(c, cl) {
if ($T((+(((cl & 0xc0)) === 0x40)))) {
let t = H[258 + ((cl & 0x1f))];
if ($T((t))) {
t = ((H[((1 + 1)) + (c)] & t));
return ($T(((cl & 0x20))) ? t : +!$T(t));
}
if ($T((+(cl === 122)))) return +(c === 0);
if ($T((+(cl === 90)))) return +(c !== 0);
}
return (+(cl === c));
}

function matchbracketclass(c, p, ec) {
let sig = 1;
if ($T((+((H[((p + 1))] << 24 >> 24) === 94)))) {
sig = 0;
p++;
}
while ($T((+(++p < ec)))) {
if ($T((+((H[p] << 24 >> 24) === 37)))) {
p++;
if ($T((match_class(c, (((((H[p] << 24 >> 24))) & 255)))))) return sig;
} else if ($T((+($T((+((H[((p + 1))] << 24 >> 24) === 45))) && $T((+((p + 2) < ec))))))) {
p += 2;
if ($T((+($T(+((((((H[((p - 2))] << 24 >> 24))) & 255)) <= c)) && $T(+(c <= (((((H[p] << 24 >> 24))) & 255)))))))) return sig;
} else if ($T((+((((((H[p] << 24 >> 24))) & 255)) === c)))) return sig;
}
return +!$T(sig);
}

function check_capture(ms, l) {
l -= 49;
if ($T((+($T(+($T(+(l < 0)) || $T(+(l >= ms.level)))) || $T(+(ms.capture[l].len === (-1))))))) $cerr("invalid capture index");
return l;
}

function match_capture(ms, s, l) {
let len;
l = check_capture(ms, l);
len = ms.capture[l].len;
if ($T((+($T(+(((ms.src_end - s)) >= len)) && $T(+($memcmp(ms.capture[l].init, s, len) === 0)))))) return (s + len); else return (null);
}

function singlematch(c, p, ep) {
$sw2: switch (((H[p] << 24 >> 24))) {
case 46:
return 1;
case 37:
return match_class(c, (((((H[((p + 1))] << 24 >> 24))) & 255)));
case 91:
return matchbracketclass(c, p, (ep - 1));
default:
return (+((((((H[p] << 24 >> 24))) & 255)) === c));
}
}

function max_expand(ms, s, p, ep) {
let i = 0;
while ($T((+($T(+(((s + i)) < ms.src_end)) && $T(singlematch((((((H[((s + i))] << 24 >> 24))) & 255)), p, ep)))))) i++;
while ($T((+(i >= 0)))) {
let res = match(ms, ((s + i)), (ep + 1));
if ($T((res))) return res;
i--;
}
return (null);
}

function min_expand(ms, s, p, ep) {
for (; ; ) {
let res = match(ms, s, (ep + 1));
if ($T((+(res !== (null))))) return res; else if ($T((+($T(+(s < ms.src_end)) && $T(singlematch((((((H[s] << 24 >> 24))) & 255)), p, ep)))))) s++; else return (null);
}
}

function match(ms, s, p) {
if ($T((+(++ms.depth > 200)))) $cerr("pattern too complex");
init: for (;;) {
{ let $go3 = false;
$sw3: switch (((H[p] << 24 >> 24))) {
case 40:
if ($T((+((H[((p + 1))] << 24 >> 24) === 41)))) s = start_capture(ms, s, (p + 2), (-2)); else s = start_capture(ms, s, (p + 1), (-1));
break;
case 41:
s = end_capture(ms, s, (p + 1));
break;
case 37:
$sw4: switch (((H[((p + 1))] << 24 >> 24))) {
case 98:
s = matchbalance(ms, s, (p + 2));
if ($T((+(s === (null))))) break;
p += 4;
continue init;
case 102:
{
let ep;
let previous;
p += 2;
if ($T((+((H[p] << 24 >> 24) !== 91)))) $cerr("missing '[' after '%f' in pattern");
ep = classend(ms, p);
previous = ($T((+(s === ms.src_init))) ? 0 : (H[((s - 1))] << 24 >> 24));
if ($T((+($T(matchbracketclass(((((previous)) & 255)), p, (ep - 1))) || $T(+!$T(matchbracketclass((((((H[s] << 24 >> 24))) & 255)), p, (ep - 1)))))))) {
s = (null);
break;
}
p = ep;
continue init;
}
default:
if ($T((((H[((1 + 1)) + (((((((H[((p + 1))] << 24 >> 24))) & 255))))] & 0x08))))) {
s = match_capture(ms, s, (((((H[((p + 1))] << 24 >> 24))) & 255)));
if ($T((+(s === (null))))) break;
p += 2;
continue init;
}
{ $go3 = true; break $sw3; }
}
break;
case 0:
break;
case 36:
if ($T((+((H[((p + 1))] << 24 >> 24) !== 0)))) { $go3 = true; break $sw3; }
if ($T((+(s !== ms.src_end)))) s = (null);
break;
default:
$go3 = true;
}
if ($go3) $blk4: {
{
let ep = classend(ms, p);
let m = +($T(+(s < ms.src_end)) && $T(singlematch((((((H[s] << 24 >> 24))) & 255)), p, ep)));
$sw5: switch (((H[ep] << 24 >> 24))) {
case 63:
{
let res;
if ($T((+($T(m) && $T((+((res = match(ms, (s + 1), (ep + 1))) !== (null)))))))) {
s = res;
break;
}
p = (ep + 1);
continue init;
}
case 42:
s = max_expand(ms, s, p, ep);
break;
case 43:
s = (($T(m) ? max_expand(ms, (s + 1), p, ep) : (null)));
break;
case 45:
s = min_expand(ms, s, p, ep);
break;
default:
if ($T((m))) {
s++;
p = ep;
continue init;
}
s = (null);
break;
}
break $blk4;
}
} }
break;
}
ms.depth--;
return s;
}

function push_onecapture(ms, i, s, e) {
if ($T((+(i >= ms.level)))) {
if ($T((+(i === 0)))) $push(ms.L, $str(s, ((e - s)))); else $cerr("invalid capture index");
} else {
let l = ms.capture[i].len;
if ($T((+(l === (-1))))) $cerr("unfinished capture");
if ($T((+(l === (-2))))) $push(ms.L, ((ms.capture[i].init - ms.src_init) + 1)); else $push(ms.L, $str(ms.capture[i].init, l));
}
}

function push_captures(ms, s, e) {
let i;
let nlevels = ($T((+($T(+(ms.level === 0)) && $T(s)))) ? 1 : ms.level);
void 0;
for (i = 0; $T(+(i < nlevels)); i++) push_onecapture(ms, i, s, e);
return nlevels;
}
module.exports = { bind, setheap: h => { H = h; }, image, IMAGE_END, STRUCTS: {"*__locale_t":[],"BCInsLine":[],"FILE":[],"FormatState":[],"GCRef":[],"GCState":[],"GCcdata":[],"GCcdataVar":[],"GCfuncC":{"upvalue":1},"GCfuncL":{"uvptr":1},"GChead":[],"GCproto":[],"GCstr":[],"GCtab":[],"GCudata":[],"GCupval":[],"LexState":[],"MRef":[],"MatchState":{"capture":32},"Node":[],"PRNGState":{"u":4},"SBuf":[],"SBufExt":[],"StrInternState":[],"VarInfo":[],"__FILE":[],"__fpos64_t":[],"__fpos_t":[],"__fsid_t":{"__val":2},"__mbstate_t":[],"__once_flag":[],"__pthread_list_t":[],"__pthread_slist_t":[],"__sigset_t":[],"cookie_io_functions_t":[],"div_t":[],"fd_set":[],"global_State":[],"ldiv_t":[],"lldiv_t":[],"luaL_Buffer":[],"luaL_Reg":[],"lua_Debug":[],"lua_State":[],"max_align_t":[]}, start_capture, capture_to_close, end_capture, matchbalance, classend, match_class, matchbracketclass, check_capture, match_capture, singlematch, max_expand, min_expand, match, push_onecapture, push_captures };
