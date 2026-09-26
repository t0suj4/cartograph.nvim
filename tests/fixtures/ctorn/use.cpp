#include "blk.h"
int use() {
  int a = freefn(1);
  int b = successors();
  int c = TMAC(3);
  int d = INNERMAC(4);
  int e = bodyerr(5);
  int f = headbad(6, 7);
  int w1, w0;
  PHANTOM_MUL(w1, w0, 2, 3);
  return a + b + c + d + e + f + w1;
}
