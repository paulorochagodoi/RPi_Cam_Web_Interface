<?php
// USB Camera configuration handler
// Saves settings to config.txt and provides device listing.

define('BASE_DIR', dirname(__FILE__));
require_once(BASE_DIR . '/config.php');

header('Content-Type: application/json');

$config_file = dirname(BASE_DIR) . '/config.txt';

$allowed_keys = ['usb_cam', 'usb_cam_device', 'usb_cam_width', 'usb_cam_height', 'usb_cam_fps'];

$action = isset($_GET['action']) ? $_GET['action'] : '';

if ($action === 'list_devices') {
    $devices = glob('/dev/video*');
    if ($devices === false) $devices = [];
    echo json_encode(['devices' => array_values($devices)]);
    exit;
}

$key   = isset($_GET['key'])   ? trim($_GET['key'])   : '';
$value = isset($_GET['value']) ? trim($_GET['value']) : '';

if (!in_array($key, $allowed_keys, true)) {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Invalid key']);
    exit;
}

// Sanitize value: allow alphanumeric, /, _, -, .
if (!preg_match('/^[a-zA-Z0-9\/_.:-]*$/', $value)) {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Invalid value']);
    exit;
}

if (!file_exists($config_file)) {
    echo json_encode(['status' => 'error', 'message' => 'config.txt not found']);
    exit;
}

$lines = file($config_file, FILE_IGNORE_NEW_LINES);
$found = false;
foreach ($lines as &$line) {
    if (preg_match('/^' . preg_quote($key, '/') . '=/', $line)) {
        $line = $key . '="' . $value . '"';
        $found = true;
        break;
    }
}
unset($line);

if (!$found) {
    $lines[] = $key . '="' . $value . '"';
}

file_put_contents($config_file, implode("\n", $lines) . "\n");

echo json_encode(['status' => 'ok', 'key' => $key, 'value' => $value]);
