package p;

public class Gen {
  private static final org.lib.SchemeFactory STANDARD_SCHEME_FACTORY = new GenStandardSchemeFactory();
  private static final org.lib.SchemeFactory TUPLE_SCHEME_FACTORY = new GenTupleSchemeFactory();
  private static final Object ONLY = new OnlyFactory();
  private static Base shared;
  private static org.lib.SchemeFactory libf;

  public void read(Object iprot) {
    scheme(iprot).read(iprot, this);
    pick().run();
    anyBase().run();
    lib().read(iprot, this);
    partial().read(iprot, this);
  }

  private static class GenStandardSchemeFactory implements org.lib.SchemeFactory {
    public GenStandardScheme getScheme() { return new GenStandardScheme(); }
  }
  private static class GenStandardScheme extends org.lib.StandardScheme<Gen> {
    public void read(Object iprot, Gen struct) { }
  }
  private static class GenTupleSchemeFactory implements org.lib.SchemeFactory {
    public GenTupleScheme getScheme() { return new GenTupleScheme(); }
  }
  private static class GenTupleScheme extends org.lib.TupleScheme<Gen> {
    public void read(Object iprot, Gen struct) { }
  }

  private static <S extends org.lib.IScheme> S scheme(Object proto) {
    return (proto == null ? STANDARD_SCHEME_FACTORY : TUPLE_SCHEME_FACTORY).getScheme();
  }
  private static <T extends Runnable> T pick() {
    return ((OnlyFactory) ONLY).make();
  }
  private static <T extends Base> T anyBase() {
    return shared;
  }
  private static <S extends org.lib.IScheme> S lib() {
    return new LibKid().getScheme();
  }
  private static class LibKid extends org.lib.SchemeBase { }
  private static <S extends org.lib.IScheme> S partial() {
    return new Partial();
  }
  private static class Partial extends org.lib.StandardScheme<Gen> { }
}
