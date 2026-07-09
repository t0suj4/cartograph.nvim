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

    private void neverCalled() {
    }
}
