package app.owner;

import app.model.Owner;

public class OwnerController {

    // owner is a typed parameter: owner.addPet()/label() resolve to Owner's
    // methods ACROSS the package boundary (app.owner -> app.model), via the
    // declared receiver type — the win static Java hands us over php.
    // @GetMapping registers the handler (cbarg), so it is not dead.
    @GetMapping("/owners/{id}")
    public String show(Owner owner) {
        owner.addPet();
        return owner.label();
    }
}
