// 2026-09-25
import 'package:flutter/material.dart';

import 'api/sitor_api.dart';
import 'ui/common.dart';
import 'ui/login_screen.dart';
import 'web/browser.dart';

void main() {
  preventWindowFileDrops();
  runApp(SitorApp(api: SitorApi(appBaseUri.resolve('api.php'))));
}

class SitorApp extends StatelessWidget {
  const SitorApp({super.key, required this.api});

  final SitorApi api;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: copper,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    return MaterialApp(
      title: 'Website editor',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      theme: ThemeData(
        colorScheme: scheme,
        visualDensity: VisualDensity.standard,
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(64, 48),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(64, 44),
            textStyle: const TextStyle(fontSize: 15),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: LoginScreen(api: api),
    );
  }
}
