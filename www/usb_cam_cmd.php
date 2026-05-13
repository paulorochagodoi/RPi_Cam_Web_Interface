<?php
// USB Camera command handler
// Receives commands from the web interface and executes usb_cam.sh actions.
// Commands are restricted to a whitelist to prevent injection.

define('BASE_DIR', dirname(__FILE__));
require_once(BASE_DIR . '/config.php');

header('Content-Type: application/json');

$allowed_commands = ['start', 'stop', 'restart', 'capture_image', 'start_video', 'stop_video', 'log'];

$cmd = isset($_GET['cmd']) ? trim($_GET['cmd']) : '';

if (!in_array($cmd, $allowed_commands, true)) {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Invalid command']);
    exit;
}

$script = escapeshellarg(dirname(BASE_DIR) . '/usb_cam.sh');
$safe_cmd = escapeshellarg($cmd);

$output = shell_exec("sudo bash $script $safe_cmd 2>&1");

echo json_encode(['status' => 'ok', 'command' => $cmd, 'output' => $output]);
