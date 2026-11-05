import 'package:flutter_test/flutter_test.dart';
import 'package:vehicleguard/models/models.dart';

TheftAlert _alert({List<String>? photos}) => TheftAlert(
      id: 'ALT-1',
      vehicleId: 'v1',
      userId: 'u1',
      plate: 'ABC-1234',
      model: 'S-PRESSO1.0-GL',
      color: 'GRAY',
      lat: 9.0,
      lng: 125.0,
      timestamp: DateTime(2026, 9, 30, 20, 47),
      notes: 'Last seen near the waiting shed.',
      photos: photos,
    );

void main() {
  group('TheftAlert photo evidence', () {
    // A real bug: the old `photoPath` field stored a path on the REPORTING
    // phone's own filesystem, which toMap()/fromMap() dutifully round-
    // tripped through Firestore and the mesh — but was meaningless on any
    // other device, which is exactly why a received alert's photo never
    // showed up anywhere. `photos` (actual bytes, base64 — now up to 3)
    // replaces it.
    test('photos round-trip through toMap/fromMap', () {
      final original = _alert(photos: [
        'ZmFrZS1waG90by1ieXRlcw==',
        'b3RoZXJwaG90bw==',
        'dGhpcmRwaG90bw==',
      ]);
      final restored = TheftAlert.fromMap(original.toMap());
      expect(restored.photos, original.photos);
      expect(restored.photos, hasLength(3));
      expect(restored.hasPhoto, isTrue);
    });

    test('hasPhoto is false when no photos were attached', () {
      final alert = _alert();
      expect(alert.hasPhoto, isFalse);
      expect(TheftAlert.fromMap(alert.toMap()).hasPhoto, isFalse);
    });

    test('hasPhoto is false for an empty list, not just null', () {
      final alert = _alert(photos: []);
      expect(alert.hasPhoto, isFalse);
    });

    test('toMap no longer writes the old dead "photoPath"/"photoB64" keys', () {
      final map = _alert(photos: ['abc', 'def']).toMap();
      expect(map.containsKey('photoPath'), isFalse);
      expect(map.containsKey('photoB64'), isFalse);
      expect(map['photos'], 'abc,def');
    });

    test('notes round-trip without any injected placeholder text', () {
      // The old receive-handlers used to append a hardcoded
      // "📷 Photo evidence attached on reporter's device." string into
      // `notes` — fromMap must never do anything like that; the real text
      // must come back exactly as stored.
      final alert = _alert(photos: ['abc']);
      final restored = TheftAlert.fromMap(alert.toMap());
      expect(restored.notes, 'Last seen near the waiting shed.');
    });
  });
}
