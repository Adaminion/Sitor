# Deploying Sitor

Sitor is a static Flutter web app plus one PHP file (`api.php`). It goes
into a `sitor/` folder inside the client's website root, next to the page it
edits:

```
<site root>/index.html        the page the client edits
<site root>/media/            pictures uploaded through Sitor (created on demand)
<site root>/sitor/            everything from build/web
<site root>/sitor/backups/    backup ZIPs (created on demand, blocked from the web)
```

## Steps

1. **Build** (from the project root):
   ```
   flutter build web --release
   ```
   `web/index.html` works out its base URL when the page loads, so the build
   runs from `/sitor/` without `--base-href`. Do not pass `--base-href`: the
   template has no placeholder for it, so the build would fail.
2. **Set the password** in `build/web/config.php`:
   `$SITOR_PASSWORD = 'something-long';`
   Edit the copy in `build/`, not `web/config.php`, so the password never
   lands in git. While the password is empty, the editor refuses every request.
3. **Upload** with FileZilla (or any FTP client):
   - Protocol: FTP, *Require explicit FTP over TLS*
   - Host: `ftp.predi.us`, port `21`, user `a@miautyzm.pl`
   - Create a `sitor` folder in the website root (the folder that holds
     `index.html` and the `.jpg` files). Upload the **contents** of
     `build/web/` into it, so `api.php` ends up at `<site root>/sitor/api.php`.
4. **Check the server side** by opening `https://<site>/sitor/api.php?action=ping`.
   It must show `{"ok":true,"app":"sitor","version":1}`.
5. **Open** `https://<site>/sitor/` and log in with the password.
   After the first **Publish**, `sitor/backups/` exists and holds a ZIP.

**Updating Sitor later:** build again and re-upload `build/web/`, but
**skip `config.php`** so the live password is kept. Never delete
`sitor/backups/`, because it holds the client's backups.

## What the server needs

- PHP 7.0 or newer. No database is needed.
- ZIP support: the `zip` extension (`ZipArchive`), or else `Phar`. After
  login, the app knows which one the server has (`"zip"` in the login
  response). If the server has neither, login fails with "no ZIP support". To
  fix that, enable `zip` in the hosting panel's PHP settings.
- PHP must be able to write to the website root (`index.html`, `media/`) and
  to `sitor/`, where it creates `backups/`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Wrong password" (401) | Wrong value compared with `sitor/config.php`. The password is case-sensitive. |
| "Sitor is not configured yet…" (500) | `$SITOR_PASSWORD` is empty in the uploaded `sitor/config.php`. |
| 403 or 406 on save/upload, HTML error page instead of JSON | The host's mod_security firewall is blocking the request. In the hosting panel, turn ModSecurity off for the domain, or ask support to whitelist `/sitor/api.php`. |
| "Could not write …" / "not writable" / "Could not create the folder" | File permissions. Folders should be `755` and files `644`, owned by the FTP user. If PHP runs as a different user, make the site root, `media/` and `sitor/` writable for it (ask the host). |
| Blank page, 404s for `main.dart.js` | Open the folder URL with its trailing slash (`/sitor/`). Check that all of `build/web/` was uploaded, including `canvaskit/` and `assets/`. |
| "Server error: …" (500) | A PHP problem. The message says what went wrong. The host's `error_log` has more detail. |

Every publish and restore first saves the current site as a ZIP in
`sitor/backups/`. The client can restore or download any of them from the
Backups screen. If the editor itself is broken, restore by hand: download
the ZIP from `sitor/backups/` over FTP, unzip it on your computer, and upload
its files into the site root.

## Local testing (no PHP needed)

```
flutter build web
dart run tool/dev_server.dart
```

Open <http://localhost:8080/sitor/> and log in with the password `test`.
The dev server implements the same API as `api.php`. It edits a scratch copy
of `website/current` in `.sitor_dev/site` (the original is never touched) and
keeps backups in `.sitor_dev/backups`.

Options: `--port 8080`, `--key test`, `--site website/current`,
`--app build/web`, `--keep-backups 0`, and `--reset` to throw away
`.sitor_dev` and start fresh.
