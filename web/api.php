<?php // 2026-09-25
// Sitor server API (docs/CONTRACT.md). Deployed as <site>/sitor/api.php.
// PHP 7.0+. Every response is either the JSON shape below or a zip download;
// nothing else may reach the output.

ob_start();
@ini_set('display_errors', '0');
@ini_set('zlib.output_compression', '0');
@date_default_timezone_set(@date_default_timezone_get());

define('SITOR_API_VERSION', 1);
define('SITOR_MAX_UPLOAD', 20 * 1024 * 1024);
define('SITOR_CONFLICT', 'The website was changed by someone else since you opened the editor. Reload the editor.');
define('SITOR_DAMAGED', 'The backup file is damaged or is not a ZIP file.');
define('SITOR_NOT_CONFIGURED', 'Sitor is not configured yet: set $SITOR_PASSWORD in sitor/config.php');

$GLOBALS['sitor_sent'] = false;

/** An expected failure: HTTP [code] + human readable message. */
class SitorError extends Exception
{
}

function sitor_fail($status, $message)
{
    throw new SitorError($message, $status);
}

function sitor_error_handler($severity, $message, $file, $line)
{
    if (!(error_reporting() & $severity)) {
        return false; // silenced with @
    }
    if ($severity & (E_DEPRECATED | E_USER_DEPRECATED | 2048)) {
        return true; // 2048 = E_STRICT (constant deprecated in PHP 8.4)
    }
    throw new ErrorException($message, 0, $severity, $file, $line);
}

function sitor_exception_handler($e)
{
    if ($e instanceof SitorError) {
        sitor_send_json($e->getCode(), array('ok' => false, 'error' => $e->getMessage()));
    }
    sitor_send_json(500, array('ok' => false, 'error' => 'Server error: ' . $e->getMessage()));
}

function sitor_shutdown()
{
    if ($GLOBALS['sitor_sent']) {
        return;
    }
    $err = error_get_last();
    $fatal = E_ERROR | E_PARSE | E_CORE_ERROR | E_COMPILE_ERROR | E_USER_ERROR;
    if ($err !== null && ($err['type'] & $fatal) && !headers_sent()) {
        sitor_send_json(500, array('ok' => false, 'error' => 'Server error: ' . $err['message']));
    }
}

set_error_handler('sitor_error_handler');
set_exception_handler('sitor_exception_handler');
register_shutdown_function('sitor_shutdown');

function sitor_discard_output()
{
    while (ob_get_level() > 0) {
        @ob_end_clean();
    }
}

function sitor_send_json($status, $data)
{
    $GLOBALS['sitor_sent'] = true;
    sitor_discard_output();
    if (!headers_sent()) {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: no-store');
        header('X-Content-Type-Options: nosniff');
    }
    $json = json_encode($data, JSON_UNESCAPED_SLASHES | JSON_PARTIAL_OUTPUT_ON_ERROR);
    if (!is_string($json)) {
        $json = '{"ok":false,"error":"Server error: could not encode the response"}';
    }
    echo $json;
    exit;
}

function sitor_send_zip($path, $downloadName, $deleteAfter)
{
    $GLOBALS['sitor_sent'] = true;
    sitor_discard_output();
    clearstatcache();
    http_response_code(200);
    header('Content-Type: application/zip');
    header('Content-Length: ' . filesize($path));
    header('Content-Disposition: attachment; filename="' . $downloadName . '"');
    header('Cache-Control: no-store');
    header('X-Content-Type-Options: nosniff');
    @readfile($path);
    if ($deleteAfter) {
        @unlink($path);
    }
    exit;
}

// ---------------------------------------------------------------- config

$SITOR_PASSWORD = '';
$SITOR_SITE_DIR = dirname(__DIR__);
$SITOR_SITE_BASE = '../';
$SITOR_PAGE = 'index.html';
$SITOR_BACKUP_DIR = __DIR__ . '/backups';
$SITOR_KEEP_BACKUPS = 0;
if (is_file(__DIR__ . '/config.php')) {
    require __DIR__ . '/config.php';
}

$sitor_cfg = array(
    'password' => is_string($SITOR_PASSWORD) ? $SITOR_PASSWORD : '',
    'site_dir' => (string) $SITOR_SITE_DIR,
    'site_base' => (string) $SITOR_SITE_BASE,
    'page' => (string) $SITOR_PAGE,
    'backup_dir' => rtrim((string) $SITOR_BACKUP_DIR, '/\\'),
    'keep_backups' => (int) $SITOR_KEEP_BACKUPS,
);

// ---------------------------------------------------------------- helpers

function sitor_uniq()
{
    return substr(md5(uniqid((string) mt_rand(), true)), 0, 16);
}

function sitor_norm($path)
{
    return rtrim(str_replace('\\', '/', $path), '/');
}

function sitor_site_dir($cfg)
{
    $real = @realpath($cfg['site_dir']);
    if ($real === false || !@is_dir($real)) {
        sitor_fail(500, 'The website folder was not found (' . $cfg['site_dir'] . '). Check $SITOR_SITE_DIR in sitor/config.php.');
    }
    return sitor_norm($real);
}

/** Absolute path of the editable page; fails if it is missing. */
function sitor_page_file($cfg)
{
    if (!preg_match('/^[A-Za-z0-9_-][A-Za-z0-9_.-]*$/', $cfg['page'])) {
        sitor_fail(500, 'Invalid $SITOR_PAGE in sitor/config.php.');
    }
    $path = sitor_site_dir($cfg) . '/' . $cfg['page'];
    if (!@is_file($path)) {
        sitor_fail(500, 'The page ' . $cfg['page'] . ' was not found in the website folder.');
    }
    return $path;
}

function sitor_zip_engine()
{
    if (class_exists('ZipArchive')) {
        return 'ZipArchive';
    }
    if (class_exists('PharData')) {
        return 'PharData';
    }
    return '';
}

function sitor_require_zip()
{
    if (sitor_zip_engine() === '') {
        sitor_fail(500, 'PHP on this server has no ZIP support (ZipArchive or Phar). Ask the hosting provider to enable the "zip" extension.');
    }
}

function sitor_json_body()
{
    $data = json_decode((string) file_get_contents('php://input'));
    if (!is_object($data)) {
        sitor_fail(400, 'Invalid request (expected a JSON object).');
    }
    return get_object_vars($data);
}

function sitor_request_key()
{
    foreach (array('HTTP_X_SITOR_KEY', 'REDIRECT_HTTP_X_SITOR_KEY') as $k) {
        if (isset($_SERVER[$k]) && is_string($_SERVER[$k])) {
            return $_SERVER[$k];
        }
    }
    if (function_exists('getallheaders')) {
        $headers = getallheaders();
        if (is_array($headers)) {
            foreach ($headers as $name => $value) {
                if (strtolower($name) === 'x-sitor-key') {
                    return (string) $value;
                }
            }
        }
    }
    return '';
}

function sitor_check_auth($cfg)
{
    if (trim($cfg['password']) === '' || $cfg['password'] === 'CHANGE-ME') {
        sitor_fail(500, SITOR_NOT_CONFIGURED);
    }
    if (!hash_equals($cfg['password'], sitor_request_key())) {
        sleep(1);
        sitor_fail(401, 'Wrong password');
    }
}

/** Writes via temp file + rename; falls back to a direct locked write. */
function sitor_write_file($path, $data)
{
    $perms = @fileperms($path);
    $tmp = dirname($path) . '/.sitor-tmp-' . sitor_uniq();
    if (@file_put_contents($tmp, $data) === strlen($data)) {
        @chmod($tmp, $perms !== false ? ($perms & 0777) : 0644);
        if (@rename($tmp, $path)) {
            return;
        }
    }
    @unlink($tmp);
    if (@file_put_contents($path, $data, LOCK_EX) !== strlen($data)) {
        sitor_fail(500, 'Could not write ' . basename($path) . '. Check that the website folder is writable by PHP.');
    }
}

function sitor_mkdir($dir)
{
    if (!@is_dir($dir) && !@mkdir($dir, 0755, true) && !@is_dir($dir)) {
        sitor_fail(500, 'Could not create the folder ' . $dir . '. Check folder permissions.');
    }
}

// ---------------------------------------------------------------- backups

function sitor_backup_dir($cfg)
{
    $dir = $cfg['backup_dir'];
    sitor_mkdir($dir);
    if (!@is_file($dir . '/.htaccess')) {
        @file_put_contents($dir . '/.htaccess',
            "<IfModule mod_authz_core.c>\n  Require all denied\n</IfModule>\n" .
            "<IfModule !mod_authz_core.c>\n  Order allow,deny\n  Deny from all\n</IfModule>\n");
    }
    if (!@is_file($dir . '/index.html')) {
        @file_put_contents($dir . '/index.html', '');
    }
    if (!@is_writable($dir)) {
        sitor_fail(500, 'The backups folder is not writable by PHP (' . $dir . ').');
    }
    $real = @realpath($dir);
    return sitor_norm($real !== false ? $real : $dir);
}

/** Serializes changes between concurrent requests (held until exit). */
function sitor_lock($cfg)
{
    $fh = @fopen(sitor_backup_dir($cfg) . '/.lock', 'c');
    if ($fh) {
        @flock($fh, LOCK_EX);
        $GLOBALS['sitor_lock'] = $fh;
    }
}

function sitor_is_backup_name($name)
{
    return is_string($name) && preg_match('/^[A-Za-z0-9_.-]+\.zip$/', $name) === 1 && $name[0] !== '.';
}

function sitor_backup_reason($name)
{
    if (preg_match('/^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_([a-z]+(?:-[a-z]+)*)(?:-\d+)?\.zip$/', $name, $m)) {
        return $m[1];
    }
    return 'other';
}

function sitor_backup_seq($name)
{
    return preg_match('/-(\d+)\.zip$/', $name, $m) ? (int) $m[1] : 1;
}

function sitor_backup_info($dir, $name)
{
    $path = $dir . '/' . $name;
    return array(
        'name' => $name,
        'time' => (int) filemtime($path),
        'size' => (int) filesize($path),
        'reason' => sitor_backup_reason($name),
    );
}

function sitor_cmp_backups($a, $b)
{
    if ($a['time'] !== $b['time']) {
        return $b['time'] - $a['time'];
    }
    $sa = sitor_backup_seq($a['name']);
    $sb = sitor_backup_seq($b['name']);
    if ($sa !== $sb) {
        return $sb - $sa;
    }
    return strcmp($b['name'], $a['name']);
}

/** Newest first. [] if the folder does not exist yet. */
function sitor_list_backups($dir)
{
    $out = array();
    $names = @is_dir($dir) ? @scandir($dir) : false;
    if (!is_array($names)) {
        return $out;
    }
    clearstatcache();
    foreach ($names as $name) {
        if (sitor_is_backup_name($name) && strpos($name, 'tmp-') !== 0 && @is_file($dir . '/' . $name)) {
            $out[] = sitor_backup_info($dir, $name);
        }
    }
    usort($out, 'sitor_cmp_backups');
    return $out;
}

function sitor_prune_backups($cfg, $dir)
{
    $keep = $cfg['keep_backups'];
    if ($keep <= 0) {
        return;
    }
    $list = sitor_list_backups($dir);
    for ($i = $keep; $i < count($list); $i++) {
        @unlink($dir . '/' . $list[$i]['name']);
    }
}

/** Real paths of folders never zipped: the editor and the backups. */
function sitor_skip_dirs($cfg)
{
    $skip = array(sitor_norm(realpath(__DIR__)));
    $b = @realpath($cfg['backup_dir']);
    if ($b !== false) {
        $skip[] = sitor_norm($b);
    }
    return $skip;
}

/** Lower-case site-relative paths a restore must never write into. */
function sitor_blocked_paths($cfg, $site)
{
    $out = array();
    foreach (sitor_skip_dirs($cfg) as $dir) {
        if (strpos($dir . '/', $site . '/') === 0 && $dir !== $site) {
            $out[] = strtolower(substr($dir, strlen($site) + 1));
        }
    }
    return $out;
}

/** Appends array(relative name, absolute path) for every file to back up. */
function sitor_collect_files($root, $skipDirs, $rel, &$out)
{
    $abs = $rel === '' ? $root : $root . '/' . $rel;
    $names = @scandir($abs);
    if (!is_array($names)) {
        return;
    }
    sort($names, SORT_STRING);
    foreach ($names as $name) {
        if ($name === '' || $name[0] === '.' || $name === 'cgi-bin') {
            continue;
        }
        $childRel = $rel === '' ? $name : $rel . '/' . $name;
        $childAbs = $root . '/' . $childRel;
        if (@is_dir($childAbs)) {
            if (@is_link($childAbs)) {
                continue;
            }
            $real = @realpath($childAbs);
            if ($real === false || in_array(sitor_norm($real), $skipDirs, true)) {
                continue;
            }
            sitor_collect_files($root, $skipDirs, $childRel, $out);
        } elseif (@is_file($childAbs) && @is_readable($childAbs)) {
            $out[] = array($childRel, $childAbs);
        }
    }
}

function sitor_site_files($cfg)
{
    $files = array();
    sitor_collect_files(sitor_site_dir($cfg), sitor_skip_dirs($cfg), '', $files);
    return $files;
}

function sitor_zip_write($path, $files)
{
    if (sitor_zip_engine() === 'ZipArchive') {
        $zip = new ZipArchive();
        $rc = $zip->open($path, ZipArchive::CREATE | ZipArchive::OVERWRITE);
        if ($rc !== true) {
            sitor_fail(500, 'Could not create a ZIP file (error ' . $rc . ').');
        }
        foreach ($files as $f) {
            if (!$zip->addFile($f[1], $f[0])) {
                $zip->close();
                sitor_fail(500, 'Could not add ' . $f[0] . ' to the ZIP file.');
            }
        }
        if (!$zip->close()) {
            sitor_fail(500, 'Could not write the ZIP file.');
        }
    } else {
        $phar = new PharData($path, 0, null, Phar::ZIP);
        $phar->startBuffering();
        foreach ($files as $f) {
            $phar->addFile($f[1], $f[0]);
        }
        $phar->stopBuffering();
        unset($phar);
    }
    clearstatcache();
    if (!@is_file($path) || filesize($path) === 0) {
        // Both engines skip writing an archive without entries.
        file_put_contents($path, "PK\x05\x06" . str_repeat("\0", 18));
    }
}

/**
 * Calls $fn($name, $read) for every entry; directory names end with '/' and
 * get $read = null, files get a closure returning their bytes.
 */
function sitor_zip_walk($zipPath, $fn)
{
    if (sitor_zip_engine() === 'ZipArchive') {
        $zip = new ZipArchive();
        if ($zip->open($zipPath) !== true) {
            sitor_fail(400, SITOR_DAMAGED);
        }
        try {
            for ($i = 0; $i < $zip->numFiles; $i++) {
                $name = $zip->getNameIndex($i);
                if (!is_string($name)) {
                    sitor_fail(400, SITOR_DAMAGED);
                }
                if (substr($name, -1) === '/') {
                    $fn($name, null);
                    continue;
                }
                $fn($name, function () use ($zip, $i) {
                    $data = $zip->getFromIndex($i);
                    if (!is_string($data)) {
                        sitor_fail(400, SITOR_DAMAGED);
                    }
                    return $data;
                });
            }
        } finally {
            $zip->close();
        }
        return;
    }
    try {
        $phar = new PharData($zipPath);
    } catch (Exception $e) {
        sitor_fail(400, SITOR_DAMAGED);
    }
    $prefix = 'phar://' . str_replace('\\', '/', $phar->getPath()) . '/';
    $needle = '/' . basename($zipPath) . '/';
    $it = new RecursiveIteratorIterator($phar, RecursiveIteratorIterator::SELF_FIRST);
    foreach ($it as $path => $info) {
        $path = str_replace('\\', '/', $path);
        if (strpos($path, $prefix) === 0) {
            $name = substr($path, strlen($prefix));
        } elseif (($pos = strpos($path, $needle)) !== false) {
            $name = substr($path, $pos + strlen($needle));
        } else {
            sitor_fail(400, SITOR_DAMAGED);
        }
        if ($info->isDir()) {
            $fn($name . '/', null);
            continue;
        }
        $fn($name, function () use ($path) {
            return file_get_contents($path);
        });
    }
}

/** Safe relative entry name that does not land in a blocked folder. */
function sitor_entry_ok($name, $blocked)
{
    if (!is_string($name) || $name === '' || $name[0] === '/' || strpos($name, '\\') !== false
        || preg_match('/[\x00-\x1f\x7f]/', $name) || preg_match('/^[A-Za-z]:/', $name)) {
        return false;
    }
    $path = substr($name, -1) === '/' ? substr($name, 0, -1) : $name;
    if ($path === '') {
        return false;
    }
    foreach (explode('/', $path) as $seg) {
        if ($seg === '' || $seg[0] === '.') {
            return false; // also catches '.' and '..'
        }
    }
    $lower = strtolower($path);
    foreach ($blocked as $b) {
        if ($lower === $b || strpos($lower, $b . '/') === 0) {
            return false;
        }
    }
    return true;
}

/** Zips the whole site into the backups folder. Caller holds the lock. */
function sitor_create_backup($cfg, $reason, $prune)
{
    sitor_require_zip();
    $dir = sitor_backup_dir($cfg);
    $files = sitor_site_files($cfg);
    $base = date('Y-m-d_H-i-s') . '_' . $reason;
    $name = $base . '.zip';
    for ($i = 2; file_exists($dir . '/' . $name); $i++) {
        $name = $base . '-' . $i . '.zip';
    }
    $tmp = $dir . '/tmp-' . sitor_uniq() . '.zip';
    $done = false;
    try {
        sitor_zip_write($tmp, $files);
        if (!@rename($tmp, $dir . '/' . $name)) {
            sitor_fail(500, 'Could not save the backup file.');
        }
        $done = true;
    } finally {
        if (!$done) {
            @unlink($tmp);
        }
    }
    clearstatcache();
    if ($prune) {
        sitor_prune_backups($cfg, $dir);
    }
    return sitor_backup_info($dir, $name);
}

// ---------------------------------------------------------------- actions

function sitor_action_login($cfg)
{
    sitor_require_zip();
    sitor_page_file($cfg);
    return array('ok' => true, 'page' => $cfg['page'], 'zip' => sitor_zip_engine());
}

function sitor_action_load($cfg)
{
    $data = file_get_contents(sitor_page_file($cfg));
    return array(
        'ok' => true,
        'page' => $cfg['page'],
        'html_b64' => base64_encode($data),
        'version' => md5($data),
        'site_base' => $cfg['site_base'],
    );
}

function sitor_image_type($data)
{
    if (strncmp($data, "\xFF\xD8\xFF", 3) === 0) {
        return 'jpg';
    }
    if (strncmp($data, "\x89PNG", 4) === 0) {
        return 'png';
    }
    if (strncmp($data, 'GIF8', 4) === 0) {
        return 'gif';
    }
    if (strlen($data) >= 12 && substr($data, 0, 4) === 'RIFF' && substr($data, 8, 4) === 'WEBP') {
        return 'webp';
    }
    return '';
}

function sitor_action_upload($cfg)
{
    $name = isset($_GET['name']) && is_string($_GET['name']) ? $_GET['name'] : '';
    $name = preg_replace('~^.*[/\\\\]~', '', $name);
    if (trim($name) === '') {
        sitor_fail(400, 'Missing file name.');
    }
    $dot = strrpos($name, '.');
    $ext = $dot === false ? '' : strtolower(substr($name, $dot + 1));
    $stem = $dot === false ? $name : substr($name, 0, $dot);
    if (!in_array($ext, array('jpg', 'jpeg', 'png', 'gif', 'webp'), true)) {
        sitor_fail(400, 'Only JPG, PNG, GIF and WEBP pictures can be uploaded.');
    }
    $declared = isset($_SERVER['CONTENT_LENGTH']) ? (int) $_SERVER['CONTENT_LENGTH'] : 0;
    if ($declared > SITOR_MAX_UPLOAD) {
        sitor_fail(400, 'The picture is too big (max 20 MB).');
    }
    $data = (string) file_get_contents('php://input', false, null, 0, SITOR_MAX_UPLOAD + 1);
    if ($data === '') {
        sitor_fail(400, $declared > 0 ? 'The picture is too big for this server.' : 'The uploaded file is empty.');
    }
    if (strlen($data) > SITOR_MAX_UPLOAD) {
        sitor_fail(400, 'The picture is too big (max 20 MB).');
    }
    // The stored extension follows the actual content (jpeg -> jpg).
    $type = sitor_image_type($data);
    if ($type === '') {
        sitor_fail(400, 'This file is not a JPG, PNG, GIF or WEBP picture.');
    }
    $stem = trim(preg_replace('/[^a-z0-9]+/', '-', strtolower($stem)), '-');
    if (strlen($stem) > 40) {
        $stem = rtrim(substr($stem, 0, 40), '-');
    }
    if ($stem === '') {
        $stem = 'picture';
    }
    sitor_lock($cfg);
    $media = sitor_site_dir($cfg) . '/media';
    sitor_mkdir($media);
    $base = $stem . '-' . date('Ymd-His');
    $file = $base . '.' . $type;
    for ($i = 2; file_exists($media . '/' . $file); $i++) {
        $file = $base . '-' . $i . '.' . $type;
    }
    sitor_write_file($media . '/' . $file, $data);
    return array('ok' => true, 'path' => 'media/' . $file);
}

function sitor_action_publish($cfg)
{
    $req = sitor_json_body();
    if (!isset($req['html_b64']) || !is_string($req['html_b64'])) {
        sitor_fail(400, 'Missing page data (html_b64).');
    }
    $html = base64_decode($req['html_b64'], true);
    if (!is_string($html)) {
        sitor_fail(400, 'The page data is not valid base64.');
    }
    if ($html === '') {
        sitor_fail(400, 'Refusing to save an empty page.');
    }
    if (!isset($req['base_version']) || !is_string($req['base_version'])) {
        sitor_fail(400, 'Missing base_version.');
    }
    sitor_lock($cfg);
    $path = sitor_page_file($cfg);
    if (md5_file($path) !== $req['base_version']) {
        sitor_fail(409, SITOR_CONFLICT);
    }
    $backup = sitor_create_backup($cfg, 'before-publish', true);
    sitor_write_file($path, $html);
    clearstatcache();
    return array('ok' => true, 'version' => md5($html), 'backup' => $backup);
}

function sitor_action_backups($cfg)
{
    return array('ok' => true, 'backups' => sitor_list_backups($cfg['backup_dir']));
}

function sitor_action_backup($cfg)
{
    sitor_lock($cfg);
    return array('ok' => true, 'backup' => sitor_create_backup($cfg, 'manual', true));
}

/** Absolute path of an existing backup named in $name (400/404 otherwise). */
function sitor_backup_file($cfg, $name)
{
    if (!sitor_is_backup_name($name)) {
        sitor_fail(400, 'Invalid backup name.');
    }
    $path = $cfg['backup_dir'] . '/' . $name;
    if (!@is_file($path)) {
        sitor_fail(404, 'Backup not found.');
    }
    return $path;
}

function sitor_action_restore($cfg)
{
    $req = sitor_json_body();
    $zipPath = sitor_backup_file($cfg, isset($req['name']) ? $req['name'] : '');
    sitor_require_zip();
    sitor_lock($cfg);
    $site = sitor_site_dir($cfg);
    $blocked = sitor_blocked_paths($cfg, $site);

    // Validate every entry before touching anything.
    $fileCount = 0;
    sitor_zip_walk($zipPath, function ($name, $read) use ($blocked, &$fileCount) {
        if (!sitor_entry_ok($name, $blocked)) {
            sitor_fail(400, 'The backup contains an unsafe file name (' . $name . '). Nothing was restored.');
        }
        if ($read !== null) {
            $fileCount++;
        }
    });
    if ($fileCount === 0) {
        sitor_fail(400, 'The backup is empty. Nothing was restored.');
    }

    $backup = sitor_create_backup($cfg, 'before-restore', false);
    sitor_zip_walk($zipPath, function ($name, $read) use ($site, $blocked) {
        if (!sitor_entry_ok($name, $blocked)) {
            sitor_fail(400, 'The backup contains an unsafe file name (' . $name . ').');
        }
        if ($read === null) {
            sitor_mkdir($site . '/' . substr($name, 0, -1));
            return;
        }
        $target = $site . '/' . $name;
        sitor_mkdir(dirname($target));
        sitor_write_file($target, $read());
    });
    clearstatcache();
    sitor_prune_backups($cfg, sitor_backup_dir($cfg));

    $page = sitor_site_dir($cfg) . '/' . $cfg['page'];
    return array(
        'ok' => true,
        'version' => @is_file($page) ? md5_file($page) : '',
        'backup' => $backup,
    );
}

function sitor_action_download($cfg)
{
    $name = isset($_GET['name']) ? $_GET['name'] : '';
    sitor_send_zip(sitor_backup_file($cfg, $name), $name, false);
}

function sitor_action_download_current($cfg)
{
    sitor_require_zip();
    $files = sitor_site_files($cfg);
    $tmpDir = sitor_norm(sys_get_temp_dir());
    if ($tmpDir === '' || !@is_dir($tmpDir) || !@is_writable($tmpDir)) {
        $tmpDir = sitor_backup_dir($cfg);
    }
    $tmp = $tmpDir . '/tmp-' . sitor_uniq() . '.zip';
    $done = false;
    try {
        sitor_zip_write($tmp, $files);
        $done = true;
    } finally {
        if (!$done) {
            @unlink($tmp);
        }
    }
    sitor_send_zip($tmp, 'website-' . date('Y-m-d_H-i-s') . '.zip', true);
}

// ---------------------------------------------------------------- dispatch

function sitor_main($cfg)
{
    $methods = array(
        'ping' => 'GET',
        'login' => 'GET',
        'load' => 'GET',
        'upload' => 'POST',
        'publish' => 'POST',
        'backups' => 'GET',
        'backup' => 'POST',
        'restore' => 'POST',
        'download' => 'GET',
        'download_current' => 'GET',
    );
    $action = isset($_GET['action']) && is_string($_GET['action']) ? $_GET['action'] : '';
    if (!isset($methods[$action])) {
        sitor_fail(400, 'Unknown action.');
    }
    $method = isset($_SERVER['REQUEST_METHOD']) ? strtoupper($_SERVER['REQUEST_METHOD']) : 'GET';
    if ($method !== $methods[$action]) {
        header('Allow: ' . $methods[$action]);
        sitor_fail(405, 'Method not allowed.');
    }
    if ($action === 'ping') {
        return array('ok' => true, 'app' => 'sitor', 'version' => SITOR_API_VERSION);
    }
    sitor_check_auth($cfg);
    @set_time_limit(300);
    if ($method === 'POST' || $action === 'download_current') {
        @ignore_user_abort(true);
    }
    $fn = 'sitor_action_' . $action;
    return $fn($cfg);
}

header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
try {
    $sitor_result = sitor_main($sitor_cfg);
} catch (SitorError $e) {
    sitor_send_json($e->getCode(), array('ok' => false, 'error' => $e->getMessage()));
}
sitor_send_json(200, $sitor_result);
