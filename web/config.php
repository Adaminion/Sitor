<?php // 2026-09-25
// Sitor settings, read by api.php in this folder. Any setting left out falls
// back to the default shown here.

// Password the client types to open the editor. REQUIRED -- Adam: set it
// before uploading, e.g. $SITOR_PASSWORD = 'a-long-phrase-only-he-knows';
// While it is empty the editor refuses to do anything.
$SITOR_PASSWORD = '';

// The website's root folder (default: the folder that contains sitor/).
$SITOR_SITE_DIR = dirname(__DIR__);

// URL of the website root, relative to the sitor/ folder.
$SITOR_SITE_BASE = '../';

// The page the client edits, relative to the website root.
$SITOR_PAGE = 'index.html';

// Where backup ZIPs are kept (made unreachable from the web via .htaccess).
$SITOR_BACKUP_DIR = __DIR__ . '/backups';

// 0 = keep every backup; otherwise only the newest N are kept.
$SITOR_KEEP_BACKUPS = 0;
