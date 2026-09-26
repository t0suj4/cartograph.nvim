int cfun(int x) { return x + 1; }
static int hidden(int x) { return x; }
#define LOCALMAC(a) ((a) + 1)
int usehidden(void) { return hidden(1) + LOCALMAC(2); }
