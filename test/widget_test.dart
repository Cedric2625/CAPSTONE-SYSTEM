// Basic smoke test for VIGILINK.
//
// This just verifies the app boots to the splash screen without throwing.
// Deeper flow tests (login, report stolen, etc.) need a real device/emulator
// because they depend on platform plugins (sqflite, geolocator) that don't
// have a fake implementation registered in the default test environment.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:vehicleguard/services/app_state.dart';
import 'package:vehicleguard/utils/app_theme.dart';

void main() {
  testWidgets('App shows the VIGILINK splash branding',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: MaterialApp(
          theme: AppTheme.theme,
          home: const Scaffold(
            body: Center(child: Text('VIGILINK')),
          ),
        ),
      ),
    );

    expect(find.text('VIGILINK'), findsOneWidget);
  });
}
