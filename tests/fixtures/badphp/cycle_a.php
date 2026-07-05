<?php

// cyclic inheritance: A extends B extends A. parent::ghost() must NOT hang
// (the walk's visited-set breaks the loop) and must stay refused.
class Cyc_A extends Cyc_B
{
    public function fromA(): int
    {
        return parent::ghost();
    }
}
