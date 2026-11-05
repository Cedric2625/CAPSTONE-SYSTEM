import 'package:flutter_test/flutter_test.dart';
import 'package:vehicleguard/models/models.dart';
import 'package:vehicleguard/screens/admin/admin_widgets.dart';
import 'package:vehicleguard/services/admin_service.dart';

AdminUserRow _row(String id, String name, {DateTime? createdAt}) =>
    AdminUserRow(
        UserModel(
            id: id,
            name: name,
            email: '$id@example.com',
            phone: '09171234567',
            deviceId: 'DEV-123',
            createdAt: createdAt),
        false);

void main() {
  group('registrationNumbers', () {
    test(
        'a freshly-registered (dated) account is numbered LAST, behind '
        'undated legacy accounts — the real bug: it was sorting as #1 '
        '("oldest") ahead of five older, undated accounts', () {
      final rows = [
        _row('a', 'Ced'),
        _row('b', 'Cedric Michael Uy'),
        _row('c', 'Cedric Michael Uy'),
        _row('d', 'Cedric Michael Uy'),
        _row('e', 'Cindy'),
        // The only dated account — just registered under the new system.
        _row('f', 'Cindy Francas A.', createdAt: DateTime(2026, 9, 30)),
      ];
      final numbers = registrationNumbers(rows);
      expect(numbers['f'], 6);
      // The five undated accounts fill 1..5, ordered by name.
      expect(numbers.values.where((n) => n != 6).toSet(), {1, 2, 3, 4, 5});
    });

    test('two dated accounts sort in their actual chronological order', () {
      final rows = [
        _row('older', 'Older Account', createdAt: DateTime(2026, 1, 1)),
        _row('newer', 'Newer Account', createdAt: DateTime(2026, 6, 1)),
      ];
      final numbers = registrationNumbers(rows);
      expect(numbers['older'], 1);
      expect(numbers['newer'], 2);
    });

    test('deleting an account shifts the remaining numbers down', () {
      final before = registrationNumbers([
        _row('a', 'A', createdAt: DateTime(2026, 1, 1)),
        _row('b', 'B', createdAt: DateTime(2026, 2, 1)),
        _row('c', 'C', createdAt: DateTime(2026, 3, 1)),
      ]);
      expect(before['c'], 3);

      // "a" deleted — "b" and "c" are the only ones left.
      final after = registrationNumbers([
        _row('b', 'B', createdAt: DateTime(2026, 2, 1)),
        _row('c', 'C', createdAt: DateTime(2026, 3, 1)),
      ]);
      expect(after['b'], 1);
      expect(after['c'], 2);
    });
  });
}
