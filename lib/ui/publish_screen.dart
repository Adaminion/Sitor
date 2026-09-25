// 2026-09-25
import 'package:flutter/material.dart';

import '../api/sitor_api.dart';
import '../web/browser.dart';
import 'common.dart';
import 'editor_controller.dart';

class PublishScreen extends StatefulWidget {
  const PublishScreen({super.key, required this.controller});

  final EditorController controller;

  @override
  State<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends State<PublishScreen> {
  /// Progress text while a long operation runs; null when idle.
  String? _busy;
  bool _published = false;
  List<BackupInfo>? _backups;
  String? _backupsError;
  bool _loadingBackups = false;

  EditorController get c => widget.controller;
  SitorApi get api => c.api;

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  void _setBusy(String text) {
    if (mounted) setState(() => _busy = text);
  }

  /// Runs [job] with buttons disabled; shows any error.
  Future<void> _run(String status, Future<void> Function() job) async {
    if (_busy != null) return;
    setState(() => _busy = status);
    try {
      await job();
    } on ApiException catch (e) {
      if (e.isConflict) {
        await _conflict(e);
      } else {
        showError(e, api);
      }
    } catch (e) {
      showError(e, api);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _loadBackups() async {
    setState(() {
      _loadingBackups = true;
      _backupsError = null;
    });
    try {
      final list = await api.listBackups();
      if (mounted) setState(() => _backups = list);
    } catch (e) {
      if (e is ApiException && e.isAuth) {
        showError(e, api);
        return;
      }
      if (mounted) setState(() => _backupsError = errorText(e));
    } finally {
      if (mounted) setState(() => _loadingBackups = false);
    }
  }

  Future<void> _upload() => _run('Getting ready…', () async {
    final texts = c.currentTexts;
    // An emptied element stops being a field once published, so it could
    // never be edited again.
    final empty = [
      for (final e in texts.entries)
        if (e.value.trim().isEmpty) c.doc.fields[e.key].label,
    ];
    if (empty.isNotEmpty) {
      showMessage(
        '"${empty.first}" is empty. Type some text or press Undo on it, '
        'then upload again.',
      );
      return;
    }
    final imageIds = c.changedImageIds;
    final paths = <int, String>{};
    for (var i = 0; i < imageIds.length; i++) {
      _setBusy('Uploading picture ${i + 1} of ${imageIds.length}…');
      final image = c.imageFor(imageIds[i])!.image;
      paths[imageIds[i]] = await api.uploadImage(image.fileName, image.bytes);
    }
    _setBusy('Saving a backup and updating your website…');
    final html = c.doc.render(texts: texts, images: paths);
    await api.publish(html, c.page.version);
    if (mounted) setState(() => _published = true);
    _setBusy('Refreshing the editor…');
    try {
      await c.reload();
    } catch (e) {
      showMessage(
        'Your website is updated, but the editor could not refresh. '
        'Please reload this browser page before making more changes.',
      );
    }
    if (mounted) await _loadBackups();
  });

  Future<void> _conflict(ApiException e) async {
    if (!mounted) return;
    final reload = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, size: 40),
        title: const Text('The website was changed'),
        content: Text(
          '${e.message}\n\nReloading shows the latest website in the editor. '
          'Changes you have not uploaded will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reload editor'),
          ),
        ],
      ),
    );
    if (reload != true) return;
    try {
      await c.reload();
      showMessage('The editor now shows the latest website.');
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      showError(err, api);
    }
  }

  Future<void> _downloadCurrent() => _run('Preparing the download…', () async {
    final bytes = await api.downloadCurrent();
    saveBytesAsFile(
      bytes,
      'website-${dateStamp(DateTime.now())}.zip',
      mimeType: 'application/zip',
    );
  });

  Future<void> _backupNow() => _run('Making a backup…', () async {
    await api.backupNow();
    showMessage('Backup made.');
    await _loadBackups();
  });

  Future<void> _downloadBackup(BackupInfo b) =>
      _run('Preparing the download…', () async {
        final bytes = await api.downloadBackup(b.name);
        saveBytesAsFile(bytes, b.name, mimeType: 'application/zip');
      });

  Future<void> _restore(BackupInfo b) async {
    final changes = c.changeCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.restore, size: 40),
        title: const Text('Restore this backup?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Put back the website as it was on ${formatDateTime(b.time)}? '
                'The current website is backed up first, so you can undo this.',
                style: const TextStyle(fontSize: 16),
              ),
              if (changes > 0) ...[
                const SizedBox(height: 16),
                Text(
                  'Your $changes unsaved change${changes == 1 ? '' : 's'} '
                  'in the editor will be discarded.',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run('Restoring the website…', () async {
      await api.restore(b.name);
      if (mounted) setState(() => _published = false);
      await c.reload();
      showMessage('Website restored');
      if (mounted) await _loadBackups();
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy != null;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 68,
          title: const Text(
            'Publish your website',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          leading: IconButton(
            tooltip: 'Back to editing',
            icon: const Icon(Icons.arrow_back),
            onPressed: busy ? null : () => Navigator.of(context).pop(),
          ),
        ),
        body: ListenableBuilder(
          listenable: c,
          builder: (context, _) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (busy) _progress(context),
                    _published ? _success(context) : _changes(context),
                    const SizedBox(height: 20),
                    _tools(context),
                    const SizedBox(height: 20),
                    _backupList(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(
    BuildContext context,
    String title,
    List<Widget> children, {
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _progress(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: const Color(0xFFFFF3E6),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _busy!,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text('Please wait, do not close this page.'),
          ],
        ),
      ),
    ),
  );

  Widget _changes(BuildContext context) {
    final theme = Theme.of(context);
    final fields = c.doc.fields;
    final texts = c.currentTexts;
    final textIds = texts.keys.toList()..sort();
    final imageIds = c.changedImageIds;
    final none = textIds.isEmpty && imageIds.isEmpty;
    final busy = _busy != null;
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);

    return _card(context, 'Your changes', [
      if (none)
        Text(
          'No changes to upload. Go back to the editor to change texts or '
          'pictures.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      for (final id in textIds)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 130,
                child: Text(
                  fields[id].label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: copper,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  truncate(fields[id].original, 120),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: muted.copyWith(decoration: TextDecoration.lineThrough),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.arrow_forward, size: 18),
              ),
              Expanded(
                child: Text(
                  texts[id]!.trim().isEmpty
                      ? '(empty)'
                      : truncate(texts[id]!, 120),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      for (final id in imageIds)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 130,
                child: Text(
                  fields[id].label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: copper,
                  ),
                ),
              ),
              _thumb(
                Image.network(
                  c.page.siteBase.resolve(fields[id].original).toString(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.arrow_forward, size: 18),
              ),
              _thumb(
                Image.memory(
                  c.imageFor(id)!.image.bytes,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(),
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'New picture',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: none || busy ? null : _upload,
            icon: const Icon(Icons.cloud_upload, size: 26),
            label: const Text('Upload to website'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(260, 60),
              textStyle: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.edit),
            label: const Text('Back to editing'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 60)),
          ),
        ],
      ),
      if (!none) ...[
        const SizedBox(height: 10),
        Text(
          'A backup of the current website is made automatically before '
          'uploading, so you can always go back.',
          style: muted,
        ),
      ],
    ]);
  }

  Widget _thumb(Widget image) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: ColoredBox(
      color: const Color(0xFFE0DAD0),
      child: SizedBox(width: 80, height: 56, child: image),
    ),
  );

  Widget _success(BuildContext context) {
    final busy = _busy != null;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: const Color(0xFFE8F3E8),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            const Icon(Icons.check_circle, color: Color(0xFF2E7D32), size: 64),
            const SizedBox(height: 12),
            Text(
              'Your website is updated!',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  // Version query so the browser can't show a cached old page.
                  onPressed: () => openInNewTab(
                    c.page.siteBase
                        .replace(queryParameters: {'v': c.page.version})
                        .toString(),
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open website'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.edit),
                  label: const Text('Back to editor'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tools(BuildContext context) {
    final busy = _busy != null;
    return _card(context, 'Copies of your website', [
      Text(
        'Download a copy to keep on your computer, or make an extra backup '
        'on the server.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          OutlinedButton.icon(
            onPressed: busy ? null : _downloadCurrent,
            icon: const Icon(Icons.download),
            label: const Text('Download website (.zip)'),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : _backupNow,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Make a backup now'),
          ),
        ],
      ),
    ]);
  }

  Widget _backupList(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _busy != null;
    final backups = _backups;
    return _card(
      context,
      'Backups',
      trailing: IconButton(
        tooltip: 'Refresh the list',
        onPressed: _loadingBackups ? null : _loadBackups,
        icon: const Icon(Icons.refresh),
      ),
      [
        Text(
          'A copy of the website is saved every time you upload. '
          'Restore puts that copy back on the website.',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (_loadingBackups && backups == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_backupsError != null)
          Text(_backupsError!, style: TextStyle(color: theme.colorScheme.error))
        else if (backups == null || backups.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No backups yet.'),
          )
        else
          for (final b in backups)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    b.reason == 'manual' ? Icons.save_outlined : Icons.history,
                    color: copper,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatDateTime(b.time),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${b.reasonLabel} · ${formatSize(b.size)}',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : () => _downloadBackup(b),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => _restore(b),
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('Restore'),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
