<?php

namespace App\Controller;

class HomeController
{
    public function home(): int
    {
        return 1;
    }

    public function redirect(): string
    {
        // names routes from code — the reverse() analog
        $u = $this->generateUrl('blog_index');
        return $this->redirectToRoute('blog_home');
    }
}
