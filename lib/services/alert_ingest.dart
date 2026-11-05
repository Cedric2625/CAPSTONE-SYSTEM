import 'dart:async';
import '../models/models.dart';
import 'database_service.dart';
import 'nearby_mesh_service.dart';
import 'notification_service.dart';
import 'firebase_sync_service.dart';

// ══════════════════════════════════════
// ALERT INGEST — the data-layer core of "receive a theft_alert/status_update/
// sighting message (mesh or internet), dedupe it, store it, log it, notify,
// relay it onward". Extracted out of AppState so there is exactly ONE
// implementation of this, callable from both:
//   - AppState, while the app is in the foreground (unchanged behavior —
//     AppState passes its own [AlertLogSink]/[AlertNotifSink], so logs and
//     notifications still land in its in-memory lists exactly as before,
//     then layers its own foreground-only reactions on top: appending to
//     `_alerts`, `_announceIncomingAlert`, `notifyListeners()`).
//   - The background foreground-service TaskHandler (mesh_background_service.dart),
//     which has no in-memory list/ChangeNotifier at all — everything here
//     reads/writes only `DatabaseService` (SQLite), so the SAME dedup check
//     (`DatabaseService.alertExists`) is shared and authoritative regardless
//     of which isolate stored something, and nothing here is lost on a
//     foreground/background hand-off.
//
// Every function mirrors its AppState counterpart's logic exactly (same
// dedup, same hop-count handling, same relayedTo/alert-log/delivery-log
// writes, same notification copy) — this file does not change what any of
// that logic DOES, only where it lives.
// ══════════════════════════════════════

typedef AlertLogSink = Future<void> Function(
    String tag, String message, LogType type);
typedef AlertNotifSink = Future<void> Function(
    String title, String body, NotifType type,
    {DateTime? time});

/// Alert ids currently being processed by [ingestMeshTheftAlert] or
/// [ingestInternetAlert] IN THIS ISOLATE — claimed with a single
/// synchronous `.add()` call, before any `await`, so the same alert
/// arriving via the mesh AND the internet feed at the same moment can
/// never both pass this point: whichever call reaches it first wins the
/// claim, and Dart's single-threaded event loop guarantees the other
/// call's own claim attempt cannot run until the first one has already
/// added the id — so it sees the id taken and bails out immediately, with
/// no `await` in between to race through. Released in a `finally` once
/// each function finishes (success, duplicate, or error). This only
/// closes the race WITHIN one isolate; a `DatabaseService.alertExists`
/// recheck still guards the case where the OTHER isolate (foreground vs.
/// background, mid hand-off) stored it first.
final Set<String> _inFlightAlertIds = {};

/// Serializes (rather than drops) concurrent [storeReceivedSighting] calls
/// for the SAME sighting id — a Set-and-reject guard like
/// [_inFlightAlertIds] isn't right here, because a second copy of a
/// sighting can carry a photo or phone number the first lacked and must
/// still be merged in, not discarded. A call for an id already in flight
/// awaits that pending call's [Future] first, then runs its own logic
/// fresh — by then the first call's write has landed, so this call's own
/// `getSightingById` sees it as "existing" and merges, exactly like two
/// sequential (non-racing) calls would.
final Map<String, Future<void>> _inFlightSightings = {};

String _hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';

/// Mirrors `AppState._logAlertDelivery` exactly: measures the real
/// end-to-end delay, writes it to System Logs (via [logSink]) and,
/// best-effort, to Firestore's `/alert_deliveries`.
void logAlertDelivery(TheftAlert alert,
    {required String via, required AlertLogSink logSink}) {
  final receivedAt = DateTime.now();
  final delayMs = receivedAt.difference(alert.timestamp).inMilliseconds;
  final delaySec = (delayMs / 1000).toStringAsFixed(2);
  unawaited(logSink(
      'DELAY',
      'ALERT ${alert.plate} · sent ${_hms(alert.timestamp)} · received ${_hms(receivedAt)} · delay ${delaySec}s · via $via · hop ${alert.hopCount}',
      LogType.relay));
  unawaited(FirebaseSyncService.instance.logAlertDelivery(
    alertId: alert.id,
    plate: alert.plate,
    via: via,
    hopCount: alert.hopCount,
    sentAt: alert.timestamp,
    receivedAt: receivedAt,
  ));
}

/// Mirrors the `'theft_alert'` branch of `AppState._handleMeshMessage`
/// exactly. Returns the new [TheftAlert] once it's been stored (the caller
/// is responsible for its own in-memory bookkeeping, e.g. AppState inserting
/// into `_alerts`/`receivedVia`/`totalRelayed` and calling
/// `_announceIncomingAlert`/`notifyListeners()` — none of that lives here),
/// or null if it was a duplicate or malformed.
Future<TheftAlert?> ingestMeshTheftAlert(
  Map<String, dynamic> msg,
  String fromEndpointId, {
  required AlertLogSink logSink,
  required AlertNotifSink notifSink,
}) async {
  final id = msg['id'] as String?;
  if (id == null) return null;
  // Claimed synchronously before any await — see _inFlightAlertIds.
  if (!_inFlightAlertIds.add(id)) {
    await logSink(
        'RELAY',
        'Duplicate alert $id ignored (already stored) from $fromEndpointId',
        LogType.info);
    return null;
  }
  try {
    final db = DatabaseService.instance;
    final exists = await db.alertExists(id);
    final hopCount = (msg['hopCount'] as num?)?.toInt() ?? 0;
    if (exists) {
      await logSink(
          'RELAY',
          'Duplicate alert $id ignored (already stored) from $fromEndpointId',
          LogType.info);
      return null;
    }
    try {
      final alert = TheftAlert(
        id: id,
        vehicleId: msg['vehicleId'] as String? ?? '',
        userId: msg['userId'] as String? ?? '',
        plate: msg['plate'] as String? ?? 'UNKNOWN',
        model: msg['model'] as String? ?? '',
        color: msg['color'] as String? ?? '',
        engineNumber: msg['engineNumber'] as String? ?? '',
        chassisNumber: msg['chassisNumber'] as String? ?? '',
        lat: (msg['lat'] as num?)?.toDouble() ?? 0,
        lng: (msg['lng'] as num?)?.toDouble() ?? 0,
        timestamp: DateTime.tryParse(msg['timestamp'] as String? ?? '') ??
            DateTime.now(),
        trigger: AlertTrigger.values[(msg['trigger'] as num?)?.toInt() ?? 0],
        status: AlertStatus.active,
        // The real remarks, exactly as the reporter typed them — the photo
        // itself genuinely isn't available yet over a mesh-only connection
        // (see AppState._alertWireMessage) — `photos` stays empty here on
        // purpose.
        notes: msg['notes'] as String? ?? '',
        hopCount: hopCount,
        isDemoLocation: (msg['isDemoLocation'] as num?) == 1,
      );
      // Still rechecked at the DB level too — _inFlightAlertIds only closes
      // the race within THIS isolate; this catches the case where the
      // OTHER isolate (foreground vs. background, mid hand-off) already
      // stored it.
      if (await db.alertExists(id)) return null;
      await db.upsertAlert(alert, synced: false);
      await db.addAlertLog(
          alertId: alert.id,
          nodeDeviceId: fromEndpointId,
          duplicate: false,
          hopCount: hopCount);
      // Confirms to the sender that this alert was actually stored, not
      // merely that a socket write succeeded — a successful write only
      // proves the bytes left the sender's device. Sent back over the same
      // mesh connection the alert itself arrived on.
      unawaited(NearbyMeshService.instance
          .sendTo(fromEndpointId, {'msgType': 'alert_ack', 'alertId': id}));
      logAlertDelivery(alert, via: 'Ad Hoc Mesh', logSink: logSink);
      await logSink(
          'RELAY',
          '📡 Real alert received: ${alert.plate} from $fromEndpointId (hop $hopCount)',
          LogType.relay);
      await notifSink(
          '🚨 Stolen Vehicle Nearby!',
          '${alert.plate} — ${alert.model} reported nearby via the real ad hoc mesh.',
          NotifType.stolen,
          time: alert.timestamp);
      await NotificationService.instance.show('🚨 Stolen Vehicle Nearby!',
          '${alert.plate} detected via a nearby device.',
          payload: alert.id);

      // Store-carry-forward: relay onward to every OTHER connected peer,
      // decrementing hop count with a TTL floor to prevent infinite loops.
      if (hopCount > 0) {
        final forwardMsg = Map<String, dynamic>.from(msg)
          ..['hopCount'] = hopCount - 1;
        final sentTo = await NearbyMeshService.instance
            .broadcast(forwardMsg, excludeEndpointId: fromEndpointId);
        if (sentTo.isNotEmpty) {
          await logSink(
              'RELAY',
              'Forwarded ${alert.plate} alert to ${sentTo.length} other connected peer(s) (hop ${hopCount - 1})',
              LogType.relay);
        }
      }
      return alert;
    } catch (e) {
      await logSink('RELAY',
          'Malformed alert payload from $fromEndpointId: $e', LogType.err);
      return null;
    }
  } finally {
    _inFlightAlertIds.remove(id);
  }
}

/// Mirrors the `'status_update'` branch of `AppState._handleMeshMessage`
/// exactly, including the forward-only ordering fix (a multi-hop relay can
/// legitimately deliver status updates out of order, so an older/duplicate
/// update never regresses an alert that's already moved to a newer status).
/// Returns the updated [TheftAlert], or null if unknown/invalid/not newer.
Future<TheftAlert?> ingestMeshStatusUpdate(
  Map<String, dynamic> msg,
  String fromEndpointId, {
  required AlertLogSink logSink,
  required AlertNotifSink notifSink,
}) async {
  final db = DatabaseService.instance;
  final alertId = msg['alertId'] as String?;
  final newStatusIdx = (msg['status'] as num?)?.toInt();
  if (alertId == null || newStatusIdx == null) return null;
  final alert = await db.getAlertById(alertId);
  if (alert == null) return null;
  if (newStatusIdx < 0 || newStatusIdx >= AlertStatus.values.length) {
    await logSink(
        'RELAY',
        'Ignored status update with invalid status index ($newStatusIdx) from $fromEndpointId',
        LogType.err);
    return null;
  }
  if (newStatusIdx <= alert.status.index) return null;
  alert.status = AlertStatus.values[newStatusIdx];
  final recoveryRemarks = msg['recoveryRemarks'] as String?;
  if (recoveryRemarks != null && recoveryRemarks.isNotEmpty) {
    alert.recoveryRemarks = recoveryRemarks;
  }
  await db.upsertAlert(alert, synced: false);
  await logSink(
      'RELAY',
      'Status update received for ${alert.plate}: ${alert.statusLabel}',
      LogType.relay);
  await notifSink('✅ Vehicle Status Updated',
      '${alert.plate} is now ${alert.statusLabel}.', NotifType.recovered);
  unawaited(NearbyMeshService.instance
      .broadcast(msg, excludeEndpointId: fromEndpointId));
  return alert;
}

/// Mirrors `AppState._handleInternetAlert` — both branches: applying a
/// newer status to an alert this device already knows (a Firestore
/// document read carries the recovery photo too, unlike the mesh
/// status_update's text-only remark), and storing a brand-new active alert.
/// Every logged-in user with internet gets every active alert, regardless
/// of distance — there is no relevance-radius filter here. [currentLat]/
/// [currentLng] are no longer used by this function (kept as parameters so
/// existing callers don't need to change); they used to drive a distance
/// filter that has been removed.
/// Returns the new/updated [TheftAlert], or null if nothing changed.
Future<TheftAlert?> ingestInternetAlert(
  Map<String, dynamic> d, {
  required String? currentUserId,
  required double? currentLat,
  required double? currentLng,
  required AlertLogSink logSink,
  required AlertNotifSink notifSink,
}) async {
  final id = d['id'] as String?;
  if (id == null) return null;
  if (d['userId'] == currentUserId) return null; // our own report
  // Claimed synchronously before any await — see _inFlightAlertIds. Shares
  // the same guard as ingestMeshTheftAlert, since both operate on the same
  // alert-id namespace and this is exactly the mesh-vs-internet race it
  // exists to close.
  if (!_inFlightAlertIds.add(id)) return null;
  try {
    final db = DatabaseService.instance;
    final statusIdx = (d['status'] as num?)?.toInt() ?? 0;
    if (statusIdx < 0 || statusIdx >= AlertStatus.values.length) return null;

    final known = await db.getAlertById(id);
    if (known != null) {
      // Already have it (usually via the mesh) — only apply a newer status,
      // e.g. the owner marked it recovered.
      if (statusIdx <= known.status.index) return null;
      known.status = AlertStatus.values[statusIdx];
      known.recoveryRemarks =
          d['recoveryRemarks'] as String? ?? known.recoveryRemarks;
      final recoveryPhotos = (d['recoveryPhotos'] as String? ?? '')
          .split(',')
          .where((s) => s.isNotEmpty)
          .toList();
      if (recoveryPhotos.isNotEmpty) {
        known.recoveryPhotos = recoveryPhotos;
      }
      await db.upsertAlert(known, synced: true);
      await logSink(
          'CLOUD',
          'Status update received for ${known.plate}: ${known.statusLabel}',
          LogType.relay);
      await notifSink('✅ Vehicle Status Updated',
          '${known.plate} is now ${known.statusLabel}.', NotifType.recovered);
      return known;
    }

    // A brand-new alert is only worth raising while it's still active.
    if (statusIdx != AlertStatus.active.index) return null;
    final lat = (d['lat'] as num?)?.toDouble();
    final lng = (d['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;

    final triggerIdx = (d['trigger'] as num?)?.toInt() ?? 0;
    final alert = TheftAlert(
      id: id,
      vehicleId: d['vehicleId'] as String? ?? '',
      userId: d['userId'] as String? ?? '',
      plate: d['plate'] as String? ?? 'UNKNOWN',
      model: d['model'] as String? ?? '',
      color: d['color'] as String? ?? '',
      engineNumber: d['engineNumber'] as String? ?? '',
      chassisNumber: d['chassisNumber'] as String? ?? '',
      lat: lat,
      lng: lng,
      timestamp: DateTime.tryParse(d['timestamp'] as String? ?? '') ??
          DateTime.now(),
      trigger: (triggerIdx >= 0 && triggerIdx < AlertTrigger.values.length)
          ? AlertTrigger.values[triggerIdx]
          : AlertTrigger.manualReport,
      status: AlertStatus.active,
      // The real remarks AND the real photos — this path reads the full
      // Firestore document, so unlike the mesh path, there's no reason to
      // leave either one out.
      notes: d['notes'] as String? ?? '',
      photos: (d['photos'] as String? ?? '')
          .split(',')
          .where((s) => s.isNotEmpty)
          .toList(),
      isDemoLocation: (d['isDemoLocation'] as num?) == 1,
    );
    // Already in the cloud — nothing to upload.
    await db.upsertAlert(alert, synced: true);
    logAlertDelivery(alert, via: 'Internet', logSink: logSink);
    await logSink(
        'CLOUD', '📡 Alert received via the internet: ${alert.plate}',
        LogType.relay);
    await notifSink(
        '🚨 Stolen Vehicle Nearby!',
        '${alert.plate} — ${alert.model} reported stolen nearby (received via the internet).',
        NotifType.stolen,
        time: alert.timestamp);
    await NotificationService.instance.show('🚨 Stolen Vehicle Nearby!',
        '${alert.plate} was reported stolen near you.',
        payload: alert.id);
    return alert;
  } finally {
    _inFlightAlertIds.remove(id);
  }
}

/// TTL — how many hops a mesh alert may still be forwarded. Shared by
/// AppState's own broadcast path and the background service's
/// store-carry-forward catch-up (sending a currently-active alert to a
/// newly-connected peer), so a peer gets the exact same message shape
/// regardless of which isolate currently owns the mesh.
const int alertMeshHops = 5;

/// The alert as it goes over the mesh. Mirrors `AppState._alertWireMessage`
/// exactly: photos are stripped (too large for a reliable BLE/Wi-Fi Direct
/// relay payload, especially across several hops); `hasPhotoEvidence` still
/// tells receivers photos exist, so the Alert Received screen can say so
/// honestly — the real pictures reach a nearby device once it syncs over
/// the internet (see the Firestore alert listener), the same way a
/// sighting's photo does.
Map<String, dynamic> alertWireMessage(TheftAlert a) =>
    Map<String, dynamic>.from(a.toMap())
      ..['msgType'] = 'theft_alert'
      ..['hopCount'] = alertMeshHops
      ..['hasPhotoEvidence'] = a.hasPhoto
      ..remove('photos');

// ──────────────────────────────────────────
// SIGHTINGS
// ──────────────────────────────────────────

/// Mirrors `AppState._storeReceivedSighting` exactly: stores a sighting
/// about one of [ownerId]'s vehicles, or — if one with the same id is
/// already held — merges in a photo/phone number the first copy lacked.
/// Returns true only when it was genuinely new (so the caller only
/// announces/notifies once, same as today).
Future<bool> storeReceivedSighting(
  SightingReport s, {
  required String ownerId,
  required String via,
  required AlertLogSink logSink,
  required AlertNotifSink notifSink,
}) async {
  if (s.ownerId != ownerId) return false;
  // Wait out any call already in flight for this exact sighting id first
  // (see _inFlightSightings) — once it's done, this call's own
  // getSightingById below sees its write and merges instead of racing it.
  while (_inFlightSightings.containsKey(s.id)) {
    await _inFlightSightings[s.id];
  }
  final completer = Completer<void>();
  _inFlightSightings[s.id] = completer.future;
  try {
    final db = DatabaseService.instance;
    final existing = await db.getSightingById(s.id);
    if (existing != null) {
      if ((s.hasPhoto && !existing.hasPhoto) ||
          (s.hasContact && !existing.hasContact)) {
        await db.upsertSighting(s, synced: true);
      }
      return false;
    }
    await db.upsertSighting(s, synced: true);
    final alert = await db.getAlertById(s.alertId);
    final plate = alert?.plate ?? 'your vehicle';
    await logSink('SIGHTING',
        '📍 ${s.reporterName} reported seeing $plate (via $via)',
        LogType.relay);
    await notifSink('📍 Vehicle Sighting Reported',
        '${s.reporterName} saw $plate: "${s.message}"', NotifType.info,
        time: s.sentAt);
    await NotificationService.instance.show(
        '📍 Sighting reported for $plate', '${s.reporterName}: ${s.message}');
    return true;
  } finally {
    _inFlightSightings.remove(s.id);
    completer.complete();
  }
}

/// Mirrors `AppState._handleMeshSighting` exactly, except the sender-side
/// "already handled" set (`_seenSightingIds`, per-isolate and in-memory in
/// AppState) is replaced with the SQLite-backed `getSightingById` check
/// inside [storeReceivedSighting] — same reasoning as the alert dedup
/// above: a shared, DB-backed check survives a foreground/background
/// hand-off, where a per-isolate in-memory Set would not.
Future<void> ingestMeshSighting(
  Map<String, dynamic> msg,
  String fromEndpointId, {
  required String? currentUserId,
  required AlertLogSink logSink,
  required AlertNotifSink notifSink,
}) async {
  final id = msg['id'] as String?;
  if (id == null) return;
  final hops = (msg['hopCount'] as num?)?.toInt() ?? 0;
  try {
    final s = SightingReport.fromMap(Map<String, Object?>.from(msg));
    if (currentUserId != null && s.ownerId == currentUserId) {
      await storeReceivedSighting(s,
          ownerId: currentUserId,
          via: 'the ad hoc mesh',
          logSink: logSink,
          notifSink: notifSink);
    } else if (hops > 0) {
      final forward = Map<String, dynamic>.from(msg)..['hopCount'] = hops - 1;
      unawaited(NearbyMeshService.instance
          .broadcast(forward, excludeEndpointId: fromEndpointId));
    }
  } catch (e) {
    await logSink('SIGHTING', 'Malformed sighting from $fromEndpointId: $e',
        LogType.err);
  }
}
