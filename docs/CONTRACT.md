# Sitor — build contract (2026-09-25)

Sitor = SITe editOR. A Flutter **web** app the client uses to edit his static
site (`website/current/index.html` + JPGs) and publish it. Deployed on his own
host next to the site:

```
public_html/                 <- site root (index.html, *.jpg, media/)
public_html/index.html       <- the ONE editable page
public_html/media/           <- pictures uploaded through Sitor (created on demand)
public_html/sitor/           <- flutter build web output + api.php + config.php
public_html/sitor/backups/   <- backup zips (created on demand, .htaccess deny)
```

The host is shared Apache with **mod_security** (blocks curl UA with 406). So:
HTML is always sent base64-encoded, never raw, in request bodies. PHP code must
run on PHP 7.0+ (no arrow fns, no typed props, no str_contains, no match).

Browsers cannot speak FTP; `api.php` does all server-side work.

## HTTP API — `sitor/api.php?action=<name>`

Auth: every action except `ping` requires header `X-Sitor-Key: <password>`.
Password lives in `sitor/config.php` (`$SITOR_PASSWORD`). Wrong/missing key →
HTTP 401 + `{"ok":false,"error":"Wrong password"}` (sleep 1s first).

All JSON responses: `Content-Type: application/json; charset=utf-8`,
`Cache-Control: no-store`. Success `{"ok":true,...}`. Failure: HTTP 4xx/5xx +
`{"ok":false,"error":"<human readable message>"}`. Any PHP error/exception
must still produce this JSON shape (set_exception_handler / error handler).

| action | method | request | response |
|---|---|---|---|
| `ping` | GET | – | `{ok, app:"sitor", version:1}` (no auth) |
| `login` | GET | – | `{ok, page:"index.html", zip:"ZipArchive"\|"PharData"}` |
| `load` | GET | – | `{ok, page, html_b64, version, site_base}` |
| `upload` | POST | query `name=<original file name>`; raw body = image bytes (`Content-Type: application/octet-stream`) | `{ok, path:"media/<file>"}` |
| `publish` | POST | JSON `{html_b64, base_version}` | `{ok, version, backup:Backup}` |
| `backups` | GET | – | `{ok, backups:[Backup...]}` newest first |
| `backup` | POST | JSON `{}` | `{ok, backup:Backup}` (manual backup) |
| `restore` | POST | JSON `{name}` | `{ok, version, backup:Backup}` (backup = safety backup made *before* restoring) |
| `download` | GET | query `name=<backup file>` | the zip bytes, `Content-Type: application/zip`, `Content-Disposition: attachment` |
| `download_current` | GET | – | zip of the live site made on the fly (not stored) |

`Backup` = `{name:"2026-09-25_14-12-03_before-publish.zip", time:<unix seconds>, size:<bytes>, reason:"before-publish"|"before-restore"|"manual"}`

Details:
- `version` = `md5` of the page file bytes. `publish` with `base_version` that
  doesn't match the current file → HTTP 409 `{"ok":false,"error":"The website was changed by someone else since you opened the editor. Reload the editor."}`.
- `site_base` = URL of site root relative to the editor directory, from config
  (default `"../"`). The app resolves it against the api.php URL.
- `publish`: 1) backup current site (reason before-publish) 2) write page
  atomically (temp file + rename) 3) return new version.
- `upload`: allowed extensions jpg/jpeg/png/gif/webp only; verify magic bytes
  (JPEG FF D8 FF, PNG 89 50 4E 47, GIF 47 49 46 38, WEBP RIFF....WEBP); max
  20 MB; sanitize name to `[a-z0-9-]`, append `-YYYYMMDD-HHMMSS` (+`-2`, `-3`
  if taken) + lowercase ext (jpeg→jpg). Stored in `<site>/media/`.
- Backup zip = every file under site root, recursively, EXCEPT the editor
  directory itself, dot-entries (`.htaccess`, `.well-known`, …) and
  `cgi-bin`. Entry names relative to site root with `/`.
- `restore`: validate name matches `^[A-Za-z0-9_.-]+\.zip$` and exists; make
  a before-restore backup; extract over the site root, rejecting entries with
  `..`, absolute paths, backslashes, or that land inside the editor dir.
- Zip engine: `ZipArchive` if available, else `PharData` (zip format).
- `backups/` gets an `.htaccess` with `Require all denied` + `Deny from all`
  (inside IfModule blocks) on first creation.

## Dart side

Files and owners (don't change another owner's public signatures):

- `lib/site/site_document.dart` — HTML model (pure Dart, VM-testable).
- `lib/api/sitor_api.dart` — API client (package:http).
- `lib/web/browser.dart` — all browser/JS interop (package:web, dart:ui_web).
- `lib/main.dart`, `lib/ui/**` — screens.
- `tool/dev_server.dart` — local Dart server implementing the same HTTP API
  (there is no PHP on the dev machine) and serving the built app + site.

The stubs in those files are the contract; doc comments there are normative.
