package app.model;

public class Owner extends Person {

    String label() {
        // this.fullName() is inherited from Person (walk this->Owner->Person);
        // super.describe() is BaseEntity's, two hops up (Person->BaseEntity)
        return this.fullName() + " " + super.describe();
    }

    void addPet() {
    }
}
