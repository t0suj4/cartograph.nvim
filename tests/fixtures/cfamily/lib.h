#ifdef __cplusplus
extern "C" {
#endif
int cfun(int x);
int cppfree(int x);
int cpp2(int x);
#ifdef __cplusplus
}
#endif
static inline int inl(int x) { return x; }
