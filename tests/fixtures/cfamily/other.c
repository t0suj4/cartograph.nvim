#include "lib.h"
int other(void) {
  int a = hidden(2);
  int b = LOCALMAC(3);
  int c = inl(4);
  return a + b + c;
}
