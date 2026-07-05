<?php

// a class that extends itself: super[Self_Loop] = Self_Loop. The walk seeds
// its start in the visited set, so the first hop is already seen -> break.
class Self_Loop extends Self_Loop
{
    public function g(): int
    {
        return parent::nope();
    }
}
