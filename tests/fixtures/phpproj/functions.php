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

function dispatch_static() {
    $handler = 'scale';
    return $handler(4);
}

function dispatch_branchy($c) {
    $h = 'compute';
    if ($c) { $h = 'scale'; }
    return $h(5);
}

function dispatch_param($cb) {
    return $cb(6);
}

dispatch_param('scale');
dispatch_param('compute');
