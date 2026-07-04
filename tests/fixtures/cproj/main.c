#include "util.h"

static int dispatched(void) {
    return 2;
}

static int (*table[])(void) = { dispatched };

int main(void) {
    return helper(1);
}
