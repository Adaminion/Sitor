// 2026-09-25
import 'package:flutter/material.dart';

import '../api/sitor_api.dart';
import '../web/browser.dart';
import 'common.dart';
import 'editor_controller.dart';
import 'editor_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api, this.message});

  final SitorApi api;

  /// Shown above the form, e.g. after the password stopped working.
  final String? message;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _password = TextEditingController();
  bool _remember = true;
  bool _busy = false;
  bool _auto = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.message;
    final saved = loadSetting(savedKeySetting);
    if (saved != null && saved.isNotEmpty) {
      _auto = true;
      _busy = true;
      _open(saved, auto: true);
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _open(String password, {bool auto = false}) async {
    if (password.isEmpty) {
      setState(() => _error = 'Please type your password.');
      return;
    }
    if (!auto) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await widget.api.login(password);
      final controller = await EditorController.open(widget.api);
      if (!auto) saveSetting(savedKeySetting, _remember ? password : null);
      if (!mounted) {
        controller.dispose();
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => EditorScreen(controller: controller),
        ),
      );
    } catch (e) {
      if (auto && e is ApiException && e.isAuth) {
        saveSetting(savedKeySetting, null);
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _auto = false;
        // A stale remembered password just shows the form, no scary error.
        _error = auto && e is ApiException && e.isAuth ? null : errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF4EFE7),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 32, 32, 28),
                child: _auto ? _autoView(theme) : _form(theme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _autoView(ThemeData theme) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 8),
      const CircularProgressIndicator(),
      const SizedBox(height: 20),
      Text('Opening the editor…', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
    ],
  );

  Widget _form(ThemeData theme) {
    final submit = _busy ? null : () => _open(_password.text);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.edit_note, size: 56, color: copper),
        const SizedBox(height: 8),
        Text(
          'Website editor',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Type your password to change your website.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 28),
        TextField(
          controller: _password,
          obscureText: _obscure,
          autofocus: true,
          enabled: !_busy,
          style: const TextStyle(fontSize: 18),
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => submit?.call(),
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _remember,
          onChanged: _busy ? null : (v) => setState(() => _remember = v!),
          title: const Text('Remember me on this computer'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.error, fontSize: 15),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: submit,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
          child: _busy
              ? const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    SizedBox(width: 14),
                    Text('Opening…'),
                  ],
                )
              : const Text('Open editor', style: TextStyle(fontSize: 18)),
        ),
      ],
    );
  }
}
