class V8_EXPORT_PRIVATE InstructionBlock final
    : public NON_EXPORTED_BASE(ZoneObject) {
 public:
  InstructionBlock(int n) : n_(n) {}
  int& successors() { return n_; }
 private:
  int n_;
};
int freefn(int x) { return x; }
int Blk2::meth() { return 2; }
#define TMAC(a) ((a) * 2)
int withmac() {
#define INNERMAC(x) ((x) + 7)
  return INNERMAC(1);
}
int bodyerr(int x) {
  int y = ;
  return x;
}
int headbad(int x,, int y) { return x; }
#define PHANTOM_MUL(w1, w0, u, v)					\
  do {									\
    mp_limb_t __x0, __x1, __x2, __x3;					\
    unsigned __ul, __vl, __uh, __vh;					\
    mp_limb_t __u = (u), __v = (v);					\
									\
    __ul = __u & GMP_LLIMB_MASK;					\
    __uh = __u >> (GMP_LIMB_BITS / 2);					\
    __vl = __v & GMP_LLIMB_MASK;					\
    __vh = __v >> (GMP_LIMB_BITS / 2);					\
									\
    __x0 = (mp_limb_t) __ul * __vl;					\
    __x1 = (mp_limb_t) __ul * __vh;					\
    __x2 = (mp_limb_t) __uh * __vl;					\
    __x3 = (mp_limb_t) __uh * __vh;					\
									\
    __x1 += __x0 >> (GMP_LIMB_BITS / 2);/* this can't give carry */	\
    __x1 += __x2;		/* but this indeed can */		\
    if (__x1 < __x2)		/* did we get it? */			\
      __x3 += GMP_HLIMB_BIT;	/* yes, add it in the proper pos. */	\
									\
    (w1) = __x3 + (__x1 >> (GMP_LIMB_BITS / 2));			\
    (w0) = (__x1 << (GMP_LIMB_BITS / 2)) + (__x0 & GMP_LLIMB_MASK);	\
  } while (0)

