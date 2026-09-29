// tsbridge — tree-sitter for the JS transliteration (CART-1197): the SAME grammars nvim loads (their parser .so), the
// tree-sitter runtime built from its own source (lib/src/lib.c), and nothing reimplemented: this program only
// SERIALIZES what libtree-sitter answers.
//
//   tsbridge serve <request fifo> <response fifo>
//
// A PERSISTENT server: it keeps the loaded
// LANGUAGES, the compiled QUERIES and the parsed TREES (with their node index) by id, so a query never re-parses and
// the source crosses once. Every response is framed: `<byte length>\n<body>`. Requests, one line each (+ payload):
//
//   lang    <parser.so> <symbol>                   -> L <lang id> | ERR …
//   inspect <lang id>                              -> the language: abi, states, symbols, fields, supertypes
//   parse   <lang id> <srclen>\n<src>              -> T <tree id>, then the tree in PREORDER (a node id = its index)
//   qcompile <lang id> <qlen>\n<query>             -> Q <query id>, capture names, predicates | QERR <offset> <type>
//   query   <tree id> <query id> <node> <sr> <sc> <er> <ec> <max start depth> <match limit>
//                                                  -> the capture stream (K) and the matches (M) | MISS
//   sexpr   <tree id> <node>                       -> ts_node_string | MISS
//   desc    <tree id> <node> <sr> <sc> <er> <ec> <named> -> D <node> | MISS
//   free    <tree id>
// Trees are EVICTED least-recently-used past a cap; a request for an evicted tree answers MISS and the client
// re-parses from the source it holds. EOF on the request fifo (the client exited) ends the server.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "tree_sitter/api.h"

// ── the response buffer, sent framed ────────────────────────────────────────────────────────────────────────────
static char *ob; static size_t on, ocap;
static void out(const char *s, size_t n) { if (on + n > ocap) { while (on + n > ocap) ocap = ocap ? ocap * 2 : 65536; ob = realloc(ob, ocap); } memcpy(ob + on, s, n); on += n; }
static void outf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static void outf(const char *fmt, ...) { char buf[512]; va_list ap; va_start(ap, fmt); int n = vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap); if (n >= (int)sizeof buf) { char *big = malloc(n + 1); va_start(ap, fmt); vsnprintf(big, n + 1, fmt, ap); va_end(ap); out(big, n); free(big); } else out(buf, n); }
static void pstr(const char *s) { outf("%zu:", strlen(s)); out(s, strlen(s)); }
static FILE *fo;
static void flush_response(void) { fprintf(fo, "%zu\n", on); fwrite(ob, 1, on, fo); fflush(fo); on = 0; }

// ── registries ──────────────────────────────────────────────────────────────────────────────────────────────────
#define MAXLANG 256
static const TSLanguage *langs[MAXLANG]; static int nlang;
#define MAXQ 4096
static TSQuery *queries[MAXQ]; static int nq;
typedef struct { TSNode *v; size_t n, cap; size_t hcap; const void **hkey; uint32_t *hbyte; size_t *hval; } Nodes;
typedef struct { int live; TSTree *tree; Nodes ns; unsigned long used; } Tree;
#define MAXTREE 512
static Tree trees[MAXTREE]; static unsigned long tick;
static unsigned long next_tree_id = 1; static unsigned long tree_id_of[MAXTREE];

static void push(Nodes *ns, TSNode x) { if (ns->n == ns->cap) { ns->cap = ns->cap ? ns->cap * 2 : 1024; ns->v = realloc(ns->v, ns->cap * sizeof(TSNode)); } ns->v[ns->n++] = x; }
static size_t hslot(Nodes *ns, const void *k, uint32_t b) { size_t h = ((size_t)k * 2654435761u) ^ (b * 40503u); return h & (ns->hcap - 1); }
// node -> preorder id: an open-addressing hash on (subtree pointer, start byte) — unique in a fresh parse
static void index_nodes(Nodes *ns) {
  ns->hcap = 1; while (ns->hcap < ns->n * 2 + 2) ns->hcap <<= 1;
  ns->hkey = calloc(ns->hcap, sizeof(void *)); ns->hbyte = calloc(ns->hcap, sizeof(uint32_t)); ns->hval = calloc(ns->hcap, sizeof(size_t));
  for (size_t i = 0; i < ns->n; i++) {
    const void *k = ns->v[i].id; uint32_t b = ts_node_start_byte(ns->v[i]);
    size_t j = hslot(ns, k, b);
    while (ns->hkey[j] && !(ns->hkey[j] == k && ns->hbyte[j] == b)) j = (j + 1) & (ns->hcap - 1);
    ns->hkey[j] = k; ns->hbyte[j] = b; ns->hval[j] = i;
  }
}
static size_t id_of(Nodes *ns, TSNode x) {
  const void *k = x.id; uint32_t b = ts_node_start_byte(x);
  size_t j = hslot(ns, k, b);
  while (ns->hkey[j]) { if (ns->hkey[j] == k && ns->hbyte[j] == b) return ns->hval[j]; j = (j + 1) & (ns->hcap - 1); }
  return (size_t)-1;
}
// preorder with a cursor; with `emit`, each node's facts
static void walk(TSTree *tree, Nodes *ns, int emit) {
  TSTreeCursor c = ts_tree_cursor_new(ts_tree_root_node(tree));
  size_t *stack = malloc(sizeof(size_t) * 4096); size_t sp = 0, scap = 4096;
  for (;;) {
    TSNode n = ts_tree_cursor_current_node(&c);
    size_t id = ns->n;
    push(ns, n);
    if (emit) {
      TSPoint s = ts_node_start_point(n), e = ts_node_end_point(n);
      long parent = sp ? (long)stack[sp - 1] : -1;
      outf("N %zu %ld %u %u %d %d %d %d %u %u %u %u %u %u\n", id, parent, ts_tree_cursor_current_field_id(&c),
           ts_node_symbol(n), ts_node_is_named(n), ts_node_is_missing(n), ts_node_is_extra(n), ts_node_has_error(n),
           ts_node_start_byte(n), ts_node_end_byte(n), s.row, s.column, e.row, e.column);
    }
    if (ts_tree_cursor_goto_first_child(&c)) { if (sp == scap) { scap *= 2; stack = realloc(stack, sizeof(size_t) * scap); } stack[sp++] = id; continue; }
    for (;;) {
      if (ts_tree_cursor_goto_next_sibling(&c)) break;
      if (!ts_tree_cursor_goto_parent(&c)) { ts_tree_cursor_delete(&c); free(stack); return; }
      sp--;
    }
  }
}
static void drop(int slot) {
  Tree *t = &trees[slot];
  if (!t->live) return;
  ts_tree_delete(t->tree); free(t->ns.v); free(t->ns.hkey); free(t->ns.hbyte); free(t->ns.hval);
  memset(t, 0, sizeof *t); tree_id_of[slot] = 0;
}
static int slot_of(unsigned long id) {
  for (int i = 0; i < MAXTREE; i++) if (trees[i].live && tree_id_of[i] == id) { trees[i].used = ++tick; return i; }
  return -1;
}

static char *readn(FILE *fi, size_t n) {
  char *b = malloc(n + 1);
  size_t got = fread(b, 1, n, fi);
  if (got != n) { free(b); return NULL; }
  b[n] = 0;
  return b;
}

int main(int argc, char **argv) {
  if (argc != 4 || strcmp(argv[1], "serve")) { fprintf(stderr, "usage: tsbridge serve <request fifo> <response fifo>\n"); return 2; }
  FILE *fi = fopen(argv[2], "r");
  fo = fopen(argv[3], "w");
  if (!fi || !fo) { fprintf(stderr, "tsbridge: cannot open the fifos\n"); return 1; }
  char line[8192];
  while (fgets(line, sizeof line, fi)) {
    char cmd[32] = {0};
    sscanf(line, "%31s", cmd);
    if (!strcmp(cmd, "lang")) {
      char so[4096], sym[256], fname[300];
      if (sscanf(line, "%*s %4095s %255s", so, sym) != 2) { outf("ERR bad lang request\n"); flush_response(); continue; }
      void *h = dlopen(so, RTLD_NOW | RTLD_LOCAL);
      if (!h) { outf("ERR dlopen %s\n", dlerror()); flush_response(); continue; }
      snprintf(fname, sizeof fname, "tree_sitter_%s", sym);
      const TSLanguage *(*fn)(void) = (const TSLanguage *(*)(void))dlsym(h, fname);
      if (!fn) { outf("ERR no symbol %s\n", fname); flush_response(); continue; }
      if (nlang >= MAXLANG) { outf("ERR too many languages\n"); flush_response(); continue; }
      langs[nlang] = fn();
      outf("L %d\n", nlang++);
    } else if (!strcmp(cmd, "inspect")) {
      int li; sscanf(line, "%*s %d", &li);
      const TSLanguage *L = langs[li];
      outf("ABI %u\nSTATES %u\n", ts_language_abi_version(L), ts_language_state_count(L));
      const TSLanguageMetadata *md = ts_language_metadata(L);
      if (md) outf("META %u %u %u\n", md->major_version, md->minor_version, md->patch_version);
      uint32_t ns = ts_language_symbol_count(L);
      for (uint32_t i = 0; i < ns; i++) { outf("S %u %d ", i, (int)ts_language_symbol_type(L, (TSSymbol)i)); pstr(ts_language_symbol_name(L, (TSSymbol)i)); outf("\n"); }
      uint32_t nf = ts_language_field_count(L);
      for (uint32_t i = 1; i <= nf; i++) { outf("F %u ", i); pstr(ts_language_field_name_for_id(L, (TSFieldId)i)); outf("\n"); }
      uint32_t nst = 0; const TSSymbol *st = ts_language_supertypes(L, &nst);
      for (uint32_t i = 0; i < nst; i++) {
        uint32_t nsub = 0; const TSSymbol *sub = ts_language_subtypes(L, st[i], &nsub);
        outf("SUPER %u %u", st[i], nsub);
        for (uint32_t j = 0; j < nsub; j++) outf(" %u", sub[j]);
        outf("\n");
      }
    } else if (!strcmp(cmd, "parse")) {
      int li; size_t n; sscanf(line, "%*s %d %zu", &li, &n);
      char *src = readn(fi, n);
      if (!src) break;
      TSParser *p = ts_parser_new();
      if (!ts_parser_set_language(p, langs[li])) { outf("ERR incompatible language version %u\n", ts_language_abi_version(langs[li])); free(src); ts_parser_delete(p); flush_response(); continue; }
      TSTree *tree = ts_parser_parse_string(p, NULL, src, (uint32_t)n);
      ts_parser_delete(p); free(src);
      // a free slot, else evict the least recently used tree
      int slot = -1; unsigned long oldest = (unsigned long)-1;
      for (int i = 0; i < MAXTREE; i++) { if (!trees[i].live) { slot = i; break; } if (trees[i].used < oldest) { oldest = trees[i].used; slot = i; } }
      drop(slot);
      Tree *t = &trees[slot];
      t->live = 1; t->tree = tree; t->used = ++tick; tree_id_of[slot] = next_tree_id++;
      outf("T %lu\n", tree_id_of[slot]);
      walk(tree, &t->ns, 1);
      index_nodes(&t->ns);
      outf("END %zu\n", t->ns.n);
    } else if (!strcmp(cmd, "qcompile")) {
      int li; size_t n; sscanf(line, "%*s %d %zu", &li, &n);
      char *q = readn(fi, n);
      if (!q) break;
      uint32_t off = 0; TSQueryError err = TSQueryErrorNone;
      TSQuery *query = ts_query_new(langs[li], q, (uint32_t)n, &off, &err);
      free(q);
      if (!query) { outf("QERR %u %d\n", off, (int)err); flush_response(); continue; }
      if (nq >= MAXQ) { outf("ERR too many queries\n"); flush_response(); continue; }
      queries[nq] = query;
      outf("Q %d\n", nq++);
      uint32_t nc = ts_query_capture_count(query);
      for (uint32_t i = 0; i < nc; i++) { uint32_t len; const char *nm = ts_query_capture_name_for_id(query, i, &len); outf("C %u %u:", i, len); out(nm, len); outf("\n"); }
      uint32_t np = ts_query_pattern_count(query);
      outf("PATTERNS %u\n", np);
      for (uint32_t i = 0; i < np; i++) {
        uint32_t steps = 0; const TSQueryPredicateStep *s = ts_query_predicates_for_pattern(query, i, &steps);
        outf("P %u %u", i, steps);
        for (uint32_t j = 0; j < steps; j++) {
          if (s[j].type == TSQueryPredicateStepTypeCapture) outf(" c%u", s[j].value_id);
          else if (s[j].type == TSQueryPredicateStepTypeString) { uint32_t len; const char *v = ts_query_string_value_for_id(query, s[j].value_id, &len); outf(" s%u:", len); out(v, len); }
          else outf(" .");
        }
        outf("\n");
      }
    } else if (!strcmp(cmd, "query")) {
      unsigned long tid; int qi; size_t node; unsigned sr, sc, er, ec, depth, limit;
      sscanf(line, "%*s %lu %d %zu %u %u %u %u %u %u", &tid, &qi, &node, &sr, &sc, &er, &ec, &depth, &limit);
      int slot = slot_of(tid);
      if (slot < 0) { outf("MISS\n"); flush_response(); continue; }
      Nodes *ns = &trees[slot].ns;
      if (node >= ns->n) { outf("ERR node id %zu of %zu\n", node, ns->n); flush_response(); continue; }
      TSNode at = ns->v[node];
      for (int mode = 0; mode < 2; mode++) {
        TSQueryCursor *cur = ts_query_cursor_new();
        // the in-progress match LIMIT is part of the semantics (nvim's default 256 drops matches on large files)
        ts_query_cursor_set_match_limit(cur, limit);
        if (er != 0xffffffffu) ts_query_cursor_set_point_range(cur, (TSPoint){ sr, sc }, (TSPoint){ er, ec });
        if (depth != 0xffffffffu) ts_query_cursor_set_max_start_depth(cur, depth);
        ts_query_cursor_exec(cur, queries[qi], at);
        TSQueryMatch m; uint32_t ci;
        if (mode == 0) {
          while (ts_query_cursor_next_capture(cur, &m, &ci)) {
            outf("K %u %u %u %zu %u", m.id, m.pattern_index, m.captures[ci].index, id_of(ns, m.captures[ci].node), m.capture_count);
            for (uint32_t k = 0; k < m.capture_count; k++) outf(" %u %zu", m.captures[k].index, id_of(ns, m.captures[k].node));
            outf("\n");
          }
        } else {
          while (ts_query_cursor_next_match(cur, &m)) {
            outf("M %u %u %u", m.id, m.pattern_index, m.capture_count);
            for (uint32_t k = 0; k < m.capture_count; k++) outf(" %u %zu", m.captures[k].index, id_of(ns, m.captures[k].node));
            outf("\n");
          }
        }
        ts_query_cursor_delete(cur);
      }
      outf("END\n");
    } else if (!strcmp(cmd, "sexpr")) {
      unsigned long tid; size_t node; sscanf(line, "%*s %lu %zu", &tid, &node);
      int slot = slot_of(tid);
      if (slot < 0) { outf("MISS\n"); flush_response(); continue; }
      char *str = ts_node_string(trees[slot].ns.v[node]);
      outf("S "); out(str, strlen(str)); free(str);
    } else if (!strcmp(cmd, "desc")) {
      unsigned long tid; size_t node; unsigned sr, sc, er, ec; int named;
      sscanf(line, "%*s %lu %zu %u %u %u %u %d", &tid, &node, &sr, &sc, &er, &ec, &named);
      int slot = slot_of(tid);
      if (slot < 0) { outf("MISS\n"); flush_response(); continue; }
      Nodes *ns = &trees[slot].ns;
      TSPoint a = { sr, sc }, b = { er, ec };
      TSNode d = named ? ts_node_named_descendant_for_point_range(ns->v[node], a, b) : ts_node_descendant_for_point_range(ns->v[node], a, b);
      outf("D %zu\n", id_of(ns, d));
    } else if (!strcmp(cmd, "free")) {
      unsigned long tid; sscanf(line, "%*s %lu", &tid);
      int slot = slot_of(tid);
      if (slot >= 0) drop(slot);
      outf("OK\n");
    } else {
      outf("ERR unknown command %s\n", cmd);
    }
    flush_response();
  }
  return 0;
}
