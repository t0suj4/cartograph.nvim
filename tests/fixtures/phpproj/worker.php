<?php
require_once 'functions.php';

class Worker {
    private $opts = array('mode' => 'fast', 'retries' => 3);

    public function work($job) {
        $this->log($job);
        return compute($job);
    }

    private function log($m) {}
}
