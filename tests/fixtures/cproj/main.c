#include "util.h"

static int dispatched(void) {
    return 2;
}

static int (*table[])(void) = { dispatched };

int main(void) {
    return helper(1);
}

struct cmd { const char *name; int (*run)(void); };
static const struct cmd cmds[] = {
    { "build", dispatched },
    { "check", helper },
};
