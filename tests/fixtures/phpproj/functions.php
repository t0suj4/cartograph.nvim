<?php

function compute($n) {
    return scale($n) + 1;
}

function scale($x) {
    return $x * 2;
}

function on_boot() {
    do_action('boot');
}

add_action('boot', 'compute');
add_action('boot', 'scale');
add_action('boot', function () { return 1; });
