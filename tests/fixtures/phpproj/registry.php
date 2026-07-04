<?php
require_once 'functions.php';

register_thing('alpha', array('Worker', 'work'));
register_thing('beta', [$w, 'log']);
register_thing('save_post', array('Worker', 'work'));
register_thing('save_page', [$w, 'log']);
register_thing('zeta', [$w, 'log']);

fire_thing('alpha');
fire_thing('beta');
fire_thing('save_' . $type);
