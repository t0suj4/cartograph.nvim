#ifndef API_H
#define API_H

#define API_VERSION 3
#define API_SQUARE(x) ((x) * (x))

struct point { int x; int y; };
enum color { RED, GREEN };
typedef struct point Point;

int api_compute(int n);

#endif
