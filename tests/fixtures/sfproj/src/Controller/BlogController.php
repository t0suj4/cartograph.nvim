<?php

namespace App\Controller;

class BlogController
{
    public function index(): int
    {
        return 1;
    }

    public function __invoke(): int
    {
        return 2;
    }

    public function archive(): int
    {
        return 3;
    }

    public function orphan(): int
    {
        return 4;
    }
}
