// 2026-09-25
// Shared UI helpers: navigation keys, messages, error handling, formatting.
import 'package:flutter/material.dart';

import '../api/sitor_api.dart';
import '../web/browser.dart';
import 'login_screen.dart';

const copper = Color(0xFFB5683A);

/// localStorage key holding the remembered password.
const savedKeySetting = 'sitor.key';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

void showMessage(String message) {
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 15)),
        behavior: SnackBarBehavior.floating,
        width: 560,
        showCloseIcon: true,
        duration: const Duration(seconds: 6),
      ),
    );
}

/// Friendly text for any error.
String errorText(Object error) {
  if (error is ApiException) return error.message;
  if (error is ImageFormatException) return error.message;
  return 'Something went wrong. Please try again. ($error)';
}

/// Shows [error]; if the password stopped working, goes back to the login.
void showError(Object error, SitorApi api) {
  if (error is ApiException && error.isAuth) {
    returnToLogin(api, message: 'Please enter your password again.');
    return;
  }
  showMessage(errorText(error));
}

void returnToLogin(SitorApi api, {String? message}) {
  api.key = null;
  saveSetting(savedKeySetting, null);
  setLeaveWarning(false);
  navigatorKey.currentState?.pushAndRemoveUntil(
    MaterialPageRoute<void>(
      builder: (_) => LoginScreen(api: api, message: message),
    ),
    (_) => false,
  );
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "Fri 25 Sep 2026, 14:12"
String formatDateTime(DateTime t) =>
    '${_weekdays[t.weekday - 1]} ${t.day} ${_months[t.month - 1]} ${t.year}, '
    '${_two(t.hour)}:${_two(t.minute)}';

/// "2026-09-25"
String dateStamp(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

String formatSize(int bytes) {
  final mb = bytes / (1024 * 1024);
  if (mb < 0.1) return '< 0.1 MB';
  return '${mb.toStringAsFixed(1)} MB';
}

String truncate(String s, int max) {
  final one = s.replaceAll('\n', ' ');
  return one.length <= max ? one : '${one.substring(0, max - 1)}…';
}
