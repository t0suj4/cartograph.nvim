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
call_user_func('scale', 2);
$op = 'compute';
$op(3);
add_action('boot', 'scale');
add_action('boot', function () { return 1; });
