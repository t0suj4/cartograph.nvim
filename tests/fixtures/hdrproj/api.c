#include "api.h"
#include <util.h>
#include <stdlib.h>

int api_compute(int n) {
    return API_SQUARE(n) + API_VERSION;
}

int main(void) {
    return api_compute(5);
}
