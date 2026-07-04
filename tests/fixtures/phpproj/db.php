<?php

function load_items($db) {
    return $db->query("SELECT id, name FROM items WHERE active = 1");
}

function save_item($db) {
    $db->query("INSERT INTO items (name) VALUES ('x')");
    $db->query("UPDATE settings SET v = 1 WHERE k = 'y'");
}

function report($db) {
    return $db->query("SELECT i.id FROM items i JOIN settings s ON s.k = i.name");
}
