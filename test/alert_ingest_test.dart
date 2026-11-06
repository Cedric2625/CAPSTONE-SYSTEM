import 'package:flutter_test/flutter_test.dart';
import 'package:vehicleguard/models/models.dart';
import 'package:vehicleguard/services/alert_ingest.dart';

TheftAlert _alert({required int hopCount, List<String>? photos}) => TheftAlert(
      id: 'alert-1',
      vehicleId: 'veh-1',
      userId: 'user-1',
      plate: 'GAS9817',
      model: 'S-Presso 1.0-GL',
      color: 'Gray',
      lat: 9.7838,
      lng: 125.4855,
      timestamp: DateTime(2026, 11, 6, 12, 0, 0),
      hopCount: hopCount,
      photos: photos,
    );

void main() {
  group('alertWireMessage', () {
    // Regression test for the exact bug fixed in commit 85be313: hopCount
    // used to be forced to alertMeshHops (a descending TTL) on every
    // broadcast, regardless of the alert's own value, which made the
    // reporter always show "Hop 0" and the first receiver show "Hop 5" —
    // backwards from "hops actually traveled." This proves the wire
    // message now carries the alert's own hopCount through unmodified.
    test('carries the origin alert\'s own hopCount (0) through unmodified',
        () {
      final msg = alertWireMessage(_alert(hopCount: 0));
      expect(msg['hopCount'], 0);
    });

    test(
        'carries a relaying device\'s own hopCount through unmodified '
        '(not reset to the TTL constant)', () {
      final msg = alertWireMessage(_alert(hopCount: 3));
      expect(msg['hopCount'], 3);
    });

    test('never includes photos (too large for a BLE/Wi-Fi Direct relay)',
        () {
      final msg = alertWireMessage(_alert(hopCount: 0, photos: ['base64data']));
      expect(msg.containsKey('photos'), isFalse);
    });

    test('flags hasPhotoEvidence without sending the actual photo bytes', () {
      final msg = alertWireMessage(_alert(hopCount: 0, photos: ['base64data']));
      expect(msg['hasPhotoEvidence'], isTrue);
      expect(msg.containsKey('photos'), isFalse);
    });

    test('tags every wire message as a theft_alert', () {
      final msg = alertWireMessage(_alert(hopCount: 0));
      expect(msg['msgType'], 'theft_alert');
    });
  });

  group('alertMeshHops', () {
    // The receiving side's own hop math (myHop = receivedHop + 1, relay
    // while myHop < alertMeshHops) lives inline inside ingestMeshTheftAlert
    // in alert_ingest.dart, which also touches DatabaseService.instance and
    // NearbyMeshService.instance — both immutable singletons with no seam
    // to substitute a fake for in a test, so that function itself can't be
    // unit-tested without either a dependency-injection refactor (too
    // invasive to do unprompted on this file) or a real device. This at
    // least locks down the shared constant that logic depends on, so a
    // future change can't silently shrink/grow the mesh's reach.
    test('is 5 real hops from the original reporter', () {
      expect(alertMeshHops, 5);
    });
  });
}
