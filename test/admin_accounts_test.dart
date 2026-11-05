import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vehicleguard/models/models.dart';
import 'package:vehicleguard/screens/admin/admin_accounts.dart';
import 'package:vehicleguard/services/admin_service.dart';
import 'package:vehicleguard/utils/app_theme.dart';

AdminUserRow _row(String id, String name,
        {bool disabled = false,
        bool? license = true,
        String role = 'owner',
        DateTime? createdAt}) =>
    AdminUserRow(
        UserModel(
            id: id,
            name: name,
            email: '$id@example.com',
            phone: '09171234567',
            role: role,
            deviceId: 'DEV-123',
            createdAt: createdAt),
        disabled,
        vehicleCount: 2,
        licenseOnFile: license);

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.theme,
    home: Scaffold(
      body: AccountsTab(
        rows: [
          _row('a', 'Juan Dela Cruz'),
          _row('b', 'Maria Santos', disabled: true, license: false),
          _row('c', 'Admin User', role: 'admin', license: null),
        ],
        loading: false,
        error: null,
        meUid: 'c',
        onRetry: () {},
        onToggle: (_) async {},
        onRemove: (_) async {},
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('accounts tab lays out as a table on a wide window',
      (tester) async {
    await _pump(tester, const Size(1300, 900));
    expect(find.text('Juan Dela Cruz'), findsOneWidget);
    expect(find.text('MOBILE NUMBER'), findsOneWidget); // table header
    expect(find.text('NO LICENSE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('accounts tab lays out as cards on a narrow window',
      (tester) async {
    // Tall enough that all 3 cards build without needing a scroll — rows
    // are now sorted oldest-first rather than left in whatever order the
    // caller passed them, which can push a given account further down the
    // list than before; ListView.builder only lazily builds what's near the
    // viewport, so a too-short viewport here would make this a test of
    // scroll position rather than of the narrow-card layout it's meant to
    // check.
    await _pump(tester, const Size(400, 1400));
    expect(find.text('Maria Santos'), findsOneWidget);
    expect(find.text('MOBILE NUMBER'), findsNothing); // no table header
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'row order on screen matches registration order (oldest first), '
      'not alphabetical — the real reported bug: a row numbered "1" was '
      'appearing BELOW a row numbered "8" because the list itself was still '
      'sorted by name', (tester) async {
    // Deliberately fed in alphabetical order (Firestore's own query order,
    // via AdminService.fetchAllUsers' `orderBy('name')`) — oldest-to-newest
    // by name is "Carl" (newest) then "Zoe" (oldest), the OPPOSITE of
    // registration order, so a test that passed by coincidence is ruled out.
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.theme,
      home: Scaffold(
        body: AccountsTab(
          rows: [
            _row('a', 'Carl Newest', createdAt: DateTime(2026, 9, 1)),
            _row('b', 'Zoe Oldest', createdAt: DateTime(2026, 1, 1)),
          ],
          loading: false,
          error: null,
          meUid: null,
          onRetry: () {},
          onToggle: (_) async {},
          onRemove: (_) async {},
        ),
      ),
    ));
    await tester.pump();

    final oldestY = tester.getTopLeft(find.text('Zoe Oldest')).dy;
    final newestY = tester.getTopLeft(find.text('Carl Newest')).dy;
    expect(oldestY, lessThan(newestY),
        reason: 'the oldest account ("Zoe Oldest") must render ABOVE the newer '
            'one, regardless of alphabetical order');
    expect(tester.takeException(), isNull);
  });
}
