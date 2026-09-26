#include "lib.h"
extern "C" int cppfree(int x) { return x * 2; }
int cpp2(int x) { return x; }
int cppplain(int x) { return x; }
namespace ns { int nsfun(int x) { return x; } }
class Reg {
public:
  static int make() { return 1; }
};
class Widget {
public:
  int draw(int x) { return x; }
};
