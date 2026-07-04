#include "util.h"

int counter = 0;

int helper(int a) {
    int t = a + counter;
    return t;
}

static int unused_static(void) {
    return 1;
}
