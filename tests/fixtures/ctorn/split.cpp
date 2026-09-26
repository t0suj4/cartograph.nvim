static int early_err = ) 1;
namespace v8 {
namespace internal {

void Early::split(int x, int mode) {
#if WITH_A
  if (mode == 1) {
    x++;
#else
  if (false) {
#endif
  } else {
    x--;
  }
}

void Qual::later() { }

int unqual_after() { return 0; }

}  // namespace internal
}  // namespace v8
