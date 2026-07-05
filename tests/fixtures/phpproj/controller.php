<?php

namespace App\Controller;

use App\Service\Renderer;

class ProductController extends Base_Handler
{
    public function __construct()
    {
        parent::__construct();
    }

    #[Route('/products', name: 'product_index')]
    public function goAction(): int
    {
        return $this->buildBody() + self::statCount() + parent::boot()
            + parent::rootMethod();
    }

    #[\Override]
    public function buildBody(): int
    {
        return 1;
    }

    private static function statCount(): int
    {
        return 2;
    }
}
