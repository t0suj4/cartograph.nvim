<?php

// a class whose method signature is cut off mid-parameter-list: the parse
// ERRORs. Extraction must survive and never absorb name matches into torn
// defs (the Magento Layout.php lesson), not throw.
class Trunc extends Halfway
{
    public function boot(): int
    {
        return parent::init();
    }

    public function oops(
