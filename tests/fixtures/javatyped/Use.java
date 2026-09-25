package p;
import org.lib.Proto;
public class Use {
    public enum _Fields { A; public static _Fields find(int id) { return A; } }
    void loop(java.util.List<Item> xs) {
        for (Item it : xs) {
            it.name();
        }
    }
    void guard() {
        try {
            run();
        } catch (MyErr e) {
            e.detail();
        }
    }
    void lib(Proto p) {
        p.getScheme();
    }
    void statics() {
        _Fields.find(1);
        org.lib.Helper.detail(1);
    }
    void run() throws MyErr {}
}
