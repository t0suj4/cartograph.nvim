package app;

import app.VisitService;

public class PetController {

    private final VisitService visits = new VisitService();

    @GetMapping("/pets")
    public String listPets() {
        return render(visits.count());
    }

    private String render(int n) {
        return "pets: " + n;
    }

    public int tally() {
        VisitService svc = new VisitService();
        return svc.count();
    }

    // the local's scoped-generic type has an un-nameable base (Map.Entry<...>);
    // the receiver lookup must walk past it to the typed `visits` field
    public int shadowedTally() {
        Map.Entry<String, Integer> visits = null;
        return visits.count() + 1;
    }

    // same shadow shape, but the field's class lives in THIS file — the
    // name-match would be same-file CONFIDENT; the hedged qualification
    // must cap the edge at ~ anyway (resolve-but-mark)
    public int shadowedSameFile() {
        Map.Entry<String, Integer> counter = null;
        return counter.count() + 1;
    }

    private final Counter counter = new Counter();

    public VisitService service() {
        return new VisitService();
    }

    // the receiver is another call: g's class is service()'s declared
    // return — resolvable only by the return-type rounds
    public int chained() {
        return service().count();
    }

    // a var local typed by its initializer's return (init provenance)
    public int viaVar() {
        var svc2 = service();
        return svc2.count();
    }

    // a var local typed by `new` — nameable right at the declarator
    public int viaNew() {
        var v = new VisitService();
        return v.count();
    }

    private void neverCalled() {
    }
}

class Counter {
    public int count() {
        return 1;
    }
}
