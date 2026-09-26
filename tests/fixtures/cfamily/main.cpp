#include "lib.h"
#include "raw.h"
int cppmain() {
  int a = cfun(2);
  int b = hidden(3);
  int r = craw(4);
  int q = ns2::craw(5);
  int m = Reg::make();
  return a + b + r + q + m;
}
