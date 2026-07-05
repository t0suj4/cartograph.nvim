<?php

// parent:: with NO extends clause: qualify_call finds no base_clause and
// declines. Invalid php, but must not crash — the call stays a frontier.
class Orphan
{
    public function h(): int
    {
        return parent::missing();
    }
}

// parent:: inside a TRAIT: the parent is the using class, unknown here.
// No base_clause -> declined -> not wrongly resolved.
trait Mixin
{
    public function fromTrait(): int
    {
        return parent::whoKnows();
    }
}
