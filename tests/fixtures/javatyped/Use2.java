package p;
import java.lang.reflect.Field;
public class Use2 {
    void reflect(Field[] fs) {
        for (Field f : fs) {
            f.getName();
        }
    }
    void constant() {
        Ver.CURRENT.minimum();
    }
}
