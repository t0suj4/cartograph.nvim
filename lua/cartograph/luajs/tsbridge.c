// tsbridge — tree-sitter for the JS transliteration (CART-1197): the SAME grammars nvim loads (their parser .so), the
// tree-sitter runtime built from its own source (lib/src/lib.c), and nothing reimplemented: this program only
// SERIALIZES what libtree-sitter answers. One request per run, on stdin:
//
//   inspect <parser.so> <lang>                          -> the language: abi, state count, symbols, fields, supertypes
//   parse   <parser.so> <lang> <srclen>\n<src>          -> the whole tree, in PREORDER (a node's id = its preorder index)
//   qinfo   <parser.so> <lang> <qlen>\n<query>          -> capture names, pattern count, each pattern's predicate steps
//   query   <parser.so> <lang> <srclen> <qlen> <node id> <sr> <sc> <er> <ec> <max start depth> <match limit>\n<src><query>
//                                                       -> the capture stream (next_capture order) and the matches
//                                                          (next_match order), each capture a (capture index, node id)
// Every answer is plain text, one record per line, integers and length-prefixed strings.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "tree_sitter/api.h"

static const TSLanguage *load(const char *so, const char *lang) {
  void *h = dlopen(so, RTLD_NOW | RTLD_LOCAL);
  if (!h) { printf("ERR dlopen %s\n", dlerror()); exit(0); }
  char sym[256];
  snprintf(sym, sizeof sym, "tree_sitter_%s", lang);
  const TSLanguage *(*fn)(void) = (const TSLanguage *(*)(void))dlsym(h, sym);
  if (!fn) { printf("ERR no symbol %s\n", sym); exit(0); }
  return fn();
}

static char *readn(size_t n) {
  char *b = malloc(n + 1);
  size_t got = fread(b, 1, n, stdin);
  if (got != n) { printf("ERR short read %zu of %zu\n", got, n); exit(0); }
  b[n] = 0;
  return b;
}

// a length-prefixed string: <len>:<bytes>
static void pstr(const char *s) { printf("%zu:%s", strlen(s), s); }

// ── the tree, in preorder ───────────────────────────────────────────────────────────────────────────────────────
typedef struct { TSNode *v; size_t n, cap; } Nodes;
static void push(Nodes *ns, TSNode x) { if (ns->n == ns->cap) { ns->cap = ns->cap ? ns->cap * 2 : 1024; ns->v = realloc(ns->v, ns->cap * sizeof(TSNode)); } ns->v[ns->n++] = x; }

// preorder with a cursor; for each node: id, parent id, field id (0 = none), and its facts
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
      printf("N %zu %ld %u %u %d %d %d %d %u %u %u %u %u %u\n", id, parent, ts_tree_cursor_current_field_id(&c),
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
// node -> preorder id: an open-addressing hash on (subtree pointer, start byte) — unique in a fresh (non-incremental)
// parse; a linear scan per capture would be O(nodes x captures)
static size_t hcap; static const void **hkey; static uint32_t *hbyte; static size_t *hval;
static size_t hslot(const void *k, uint32_t b) { size_t h = ((size_t)k * 2654435761u) ^ (b * 40503u); return h & (hcap - 1); }
static void index_nodes(Nodes *ns) {
  hcap = 1; while (hcap < ns->n * 2 + 2) hcap <<= 1;
  hkey = calloc(hcap, sizeof(void *)); hbyte = calloc(hcap, sizeof(uint32_t)); hval = calloc(hcap, sizeof(size_t));
  for (size_t i = 0; i < ns->n; i++) {
    const void *k = ns->v[i].id; uint32_t b = ts_node_start_byte(ns->v[i]);
    size_t j = hslot(k, b);
    while (hkey[j] && !(hkey[j] == k && hbyte[j] == b)) j = (j + 1) & (hcap - 1);
    hkey[j] = k; hbyte[j] = b; hval[j] = i;
  }
}
static size_t id_of(Nodes *ns, TSNode x) {
  (void)ns;
  const void *k = x.id; uint32_t b = ts_node_start_byte(x);
  size_t j = hslot(k, b);
  while (hkey[j]) { if (hkey[j] == k && hbyte[j] == b) return hval[j]; j = (j + 1) & (hcap - 1); }
  return (size_t)-1;
}

static TSTree *parse(const TSLanguage *L, const char *src, size_t n) {
  TSParser *p = ts_parser_new();
  if (!ts_parser_set_language(p, L)) { printf("ERR incompatible language version %u\n", ts_language_abi_version(L)); exit(0); }
  TSTree *t = ts_parser_parse_string(p, NULL, src, (uint32_t)n);
  ts_parser_delete(p);
  return t;
}

static TSQuery *compile(const TSLanguage *L, const char *q, size_t n) {
  uint32_t off = 0; TSQueryError err = TSQueryErrorNone;
  TSQuery *query = ts_query_new(L, q, (uint32_t)n, &off, &err);
  if (!query) { printf("QERR %u %d\n", off, (int)err); exit(0); }
  return query;
}

int main(int argc, char **argv) {
  char cmd[32], so[4096], lang[256];
  if (scanf("%31s %4095s %255s", cmd, so, lang) != 3) { printf("ERR bad request\n"); return 0; }
  const TSLanguage *L = load(so, lang);
  if (!strcmp(cmd, "inspect")) {
    printf("ABI %u\nSTATES %u\n", ts_language_abi_version(L), ts_language_state_count(L));
    const TSLanguageMetadata *md = ts_language_metadata(L);
    if (md) printf("META %u %u %u\n", md->major_version, md->minor_version, md->patch_version);
    uint32_t ns = ts_language_symbol_count(L);
    for (uint32_t i = 0; i < ns; i++) {
      TSSymbolType ty = ts_language_symbol_type(L, (TSSymbol)i);
      printf("S %u %d ", i, (int)ty); pstr(ts_language_symbol_name(L, (TSSymbol)i)); printf("\n");
    }
    uint32_t nf = ts_language_field_count(L);
    for (uint32_t i = 1; i <= nf; i++) { printf("F %u ", i); pstr(ts_language_field_name_for_id(L, (TSFieldId)i)); printf("\n"); }
    uint32_t nst = 0; const TSSymbol *st = ts_language_supertypes(L, &nst);
    for (uint32_t i = 0; i < nst; i++) {
      uint32_t nsub = 0; const TSSymbol *sub = ts_language_subtypes(L, st[i], &nsub);
      printf("SUPER %u %u", st[i], nsub);
      for (uint32_t j = 0; j < nsub; j++) printf(" %u", sub[j]);
      printf("\n");
    }
    return 0;
  }
  if (!strcmp(cmd, "parse")) {
    size_t n; if (scanf("%zu", &n) != 1) return 0; getchar();
    char *src = readn(n);
    TSTree *t = parse(L, src, n);
    Nodes ns = {0};
    walk(t, &ns, 1);
    printf("END %zu\n", ns.n);
    return 0;
  }
  if (!strcmp(cmd, "qinfo")) {
    size_t n; if (scanf("%zu", &n) != 1) return 0; getchar();
    char *q = readn(n);
    TSQuery *query = compile(L, q, n);
    uint32_t nc = ts_query_capture_count(query);
    for (uint32_t i = 0; i < nc; i++) { uint32_t len; const char *nm = ts_query_capture_name_for_id(query, i, &len); printf("C %u %u:%.*s\n", i, len, (int)len, nm); }
    uint32_t np = ts_query_pattern_count(query);
    printf("PATTERNS %u\n", np);
    for (uint32_t i = 0; i < np; i++) {
      uint32_t steps = 0; const TSQueryPredicateStep *s = ts_query_predicates_for_pattern(query, i, &steps);
      printf("P %u %u", i, steps);
      for (uint32_t j = 0; j < steps; j++) {
        if (s[j].type == TSQueryPredicateStepTypeCapture) printf(" c%u", s[j].value_id);
        else if (s[j].type == TSQueryPredicateStepTypeString) { uint32_t len; const char *v = ts_query_string_value_for_id(query, s[j].value_id, &len); printf(" s%u:%.*s", len, (int)len, v); }
        else printf(" .");
      }
      printf("\n");
    }
    return 0;
  }
  if (!strcmp(cmd, "query")) {
    size_t sn, qn, node; unsigned srow, scol, erow, ecol, depth, limit;
    if (scanf("%zu %zu %zu %u %u %u %u %u %u", &sn, &qn, &node, &srow, &scol, &erow, &ecol, &depth, &limit) != 9) return 0; getchar();
    char *src = readn(sn);
    char *q = readn(qn);
    TSQuery *query = compile(L, q, qn);
    TSTree *t = parse(L, src, sn);
    Nodes ns = {0};
    walk(t, &ns, 0);
    index_nodes(&ns);
    if (node >= ns.n) { printf("ERR node id %zu of %zu\n", node, ns.n); return 0; }
    TSNode at = ns.v[node];
    for (int mode = 0; mode < 2; mode++) {
      TSQueryCursor *cur = ts_query_cursor_new();
      // the in-progress match LIMIT is part of the semantics (nvim's default 256 drops matches on large files)
      ts_query_cursor_set_match_limit(cur, limit);
      if (erow != 0xffffffffu) ts_query_cursor_set_point_range(cur, (TSPoint){ srow, scol }, (TSPoint){ erow, ecol });
      if (depth != 0xffffffffu) ts_query_cursor_set_max_start_depth(cur, depth);
      ts_query_cursor_exec(cur, query, at);
      TSQueryMatch m; uint32_t ci;
      if (mode == 0) {
        while (ts_query_cursor_next_capture(cur, &m, &ci)) {
          // the capture that fired, then every capture of its match so far
          printf("K %u %u %u %zu %u", m.id, m.pattern_index, m.captures[ci].index, id_of(&ns, m.captures[ci].node), m.capture_count);
          for (uint32_t k = 0; k < m.capture_count; k++) printf(" %u %zu", m.captures[k].index, id_of(&ns, m.captures[k].node));
          printf("\n");
        }
      } else {
        while (ts_query_cursor_next_match(cur, &m)) {
          printf("M %u %u %u", m.id, m.pattern_index, m.capture_count);
          for (uint32_t k = 0; k < m.capture_count; k++) printf(" %u %zu", m.captures[k].index, id_of(&ns, m.captures[k].node));
          printf("\n");
        }
      }
      ts_query_cursor_delete(cur);
    }
    printf("END\n");
    return 0;
  }
  if (!strcmp(cmd, "sexpr")) {
    size_t n, node; if (scanf("%zu %zu", &n, &node) != 2) return 0; getchar();
    char *src = readn(n);
    TSTree *t = parse(L, src, n);
    Nodes ns = {0};
    walk(t, &ns, 0);
    if (node >= ns.n) { printf("ERR node id %zu of %zu\n", node, ns.n); return 0; }
    char *str = ts_node_string(ns.v[node]);
    printf("%s", str);
    return 0;
  }
  if (!strcmp(cmd, "desc")) {
    // descendant_for_range / named_descendant_for_range, by libtree-sitter itself (hidden nodes included in the descent)
    size_t n, node; unsigned sr, sc, er, ec; int named;
    if (scanf("%zu %zu %u %u %u %u %d", &n, &node, &sr, &sc, &er, &ec, &named) != 7) return 0; getchar();
    char *src = readn(n);
    TSTree *t = parse(L, src, n);
    Nodes ns = {0};
    walk(t, &ns, 0);
    index_nodes(&ns);
    if (node >= ns.n) { printf("ERR node id %zu of %zu\n", node, ns.n); return 0; }
    TSPoint a = { sr, sc }, b = { er, ec };
    TSNode d = named ? ts_node_named_descendant_for_point_range(ns.v[node], a, b) : ts_node_descendant_for_point_range(ns.v[node], a, b);
    printf("D %zu\n", id_of(&ns, d));
    return 0;
  }
  printf("ERR unknown command %s\n", cmd);
  return 0;
}
