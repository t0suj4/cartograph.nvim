#include "lib.h"
struct ops { int (*cppfree)(int); };
int cmain(struct ops *s) {
  int a = cppfree(1);
  int b = draw(2);
  int c = nsfun(3);
  int d = cpp2(4);
  int e = cppplain(5);
  int f = paint(6);
  int g = s->cppfree(7);
  return a + b + c + d + e + f + g;
}
