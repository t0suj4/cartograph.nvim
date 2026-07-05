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

    private void neverCalled() {
    }
}
