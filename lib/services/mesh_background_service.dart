import 'dart:async';
import 'dart:math';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../models/models.dart';
import 'alert_ingest.dart';
import 'database_service.dart';
import 'firebase_sync_service.dart';
import 'nearby_mesh_service.dart';
import 'notification_service.dart';

// ══════════════════════════════════════
// Runs the ad hoc mesh and the Firestore alert/sighting feeds in a
// background isolate, independent of the main Activity — so alert
// reception/relay keep working after Home or Back, surviving Activity
// destruction, which a plain Dart Timer/Isolate cannot do on Android.
//
// The foreground service itself runs continuously from login to logout
// (started once in AppState._completeSignIn, stopped in AppState.logout —
// see the hand-off wiring there). What hands off between the main isolate
// and this one is only MESH OWNERSHIP, driven by the 'startMesh'/'stopMesh'
// commands below (sent via FlutterForegroundTask.sendDataToTask from
// AppState's debounced background-hand-off timer). Starting the service
// itself only once at login — rather than only when backgrounding — means
// the persistent notification and the OS-level "keep this process alive"
// guarantee are already in place well before any debounce timer fires, so
// a Back press can't race a service that hasn't started yet.
//
// Every message this isolate receives is routed through the exact same
// `alert_ingest.dart` functions AppState uses in the foreground — same
// dedup (SQLite-backed, so it's shared across the hand-off), same
// hop-count/relay logic, same System Log and delivery-log writes, same
// notifications. Nothing here reimplements that logic.
// ══════════════════════════════════════

@pragma('vm:entry-point')
void startMeshBackgroundCallback() {
  FlutterForegroundTask.setTaskHandler(MeshBackgroundTaskHandler());
}

class MeshBackgroundTaskHandler extends TaskHandler {
  final _db = DatabaseService.instance;
  final _mesh = NearbyMeshService.instance;
  final _firebaseSync = FirebaseSyncService.instance;
  final _notif = NotificationService.instance;
  final _rng = Random();

  bool _meshOwned = false;
  String? _currentUserId;

  Future<void> _addLog(String tag, String message, LogType type) =>
      _db.addSystemLog(SystemLog(tag: tag, message: message, type: type));

  Future<void> _addNotif(String title, String body, NotifType type,
      {DateTime? time}) {
    final n = NotifItem(
      id: 'n${DateTime.now().millisecondsSinceEpoch}${_rng.nextInt(999)}',
      title: title,
      body: body,
      type: type,
      time: time ?? DateTime.now(),
    );
    return _db.addNotification(n);
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      await Firebase.initializeApp();
    } catch (_) {
      // Already initialized in this isolate, or briefly offline — same
      // offline-first tolerance main() already relies on.
    }
    await _notif.init();
    await _addLog('MESH', 'Background service started.', LogType.ok);
  }

  /// Takes over mesh ownership: wires the mesh's callbacks to the shared
  /// ingest functions and starts the Firestore feeds. A no-op if this
  /// isolate already owns the mesh (a duplicate 'startMesh' command, e.g.
  /// from a retried hand-off, is harmless).
  Future<void> _startMesh(String displayName, String? userId) async {
    if (_meshOwned) return;
    _meshOwned = true;
    _currentUserId = userId;

    _mesh.onMessageReceived = (message, fromEndpointId) {
      final type = message['msgType'] as String?;
      if (type == 'theft_alert') {
        unawaited(ingestMeshTheftAlert(message, fromEndpointId,
            logSink: _addLog, notifSink: _addNotif));
      } else if (type == 'status_update') {
        unawaited(ingestMeshStatusUpdate(message, fromEndpointId,
            logSink: _addLog, notifSink: _addNotif));
      } else if (type == 'sighting') {
        unawaited(ingestMeshSighting(message, fromEndpointId,
            currentUserId: _currentUserId,
            logSink: _addLog,
            notifSink: _addNotif));
      }
    };

    _mesh.onPeerConnected = (endpointId, name) {
      // Store-carry-forward: catch this newly-joined peer up on every
      // active alert this device currently has stored — read straight from
      // SQLite rather than an in-memory list, so it reflects alerts stored
      // by either isolate across the hand-off.
      unawaited(() async {
        final all = await _db.getAllAlerts();
        final active = all.where((a) => a.status == AlertStatus.active).toList();
        if (active.isNotEmpty) {
          await _addLog(
              'RELAY',
              'Catching up "$name" on ${active.length} active alert(s) this device already has (store-carry-forward)',
              LogType.relay);
        }
        for (final a in active) {
          unawaited(_mesh.sendTo(endpointId, alertWireMessage(a)).then((ok) {
            if (!ok) {
              _addLog(
                  'RELAY',
                  'Catch-up: failed to send ${a.plate} alert to newly-connected "$name"',
                  LogType.err);
            }
          }));
        }
      }());
    };

    await _mesh.requestPermissions();
    await _mesh.start(displayName);

    _firebaseSync.startAlertFeed(
      onAlert: (data) => unawaited(ingestInternetAlert(
        data,
        currentUserId: _currentUserId,
        // No live location is tracked in this isolate — the same filter
        // AppState applies is skipped rather than approximated, matching
        // the "no extra scanning/polling beyond what already exists"
        // requirement (starting GPS here would be new battery use).
        currentLat: null,
        currentLng: null,
        logSink: _addLog,
        notifSink: _addNotif,
      )),
      onError: (e) =>
          _addLog('CLOUD', 'Background alert feed unavailable: $e', LogType.warn),
    );

    final uid = _currentUserId;
    if (uid != null) {
      _firebaseSync.startSightingFeed(
        ownerId: uid,
        onSighting: (data) => unawaited(() async {
          try {
            final s = SightingReport.fromMap(Map<String, Object?>.from(data));
            await storeReceivedSighting(s,
                ownerId: uid,
                via: 'the internet',
                logSink: _addLog,
                notifSink: _addNotif);
          } catch (e) {
            await _addLog(
                'SIGHTING', 'Malformed sighting from the cloud: $e', LogType.err);
          }
        }()),
        onError: (e) => _addLog(
            'CLOUD', 'Background sighting feed unavailable: $e', LogType.warn),
      );
    }

    await _addLog(
        'MESH',
        'Moved to background — mesh now running in the background service.',
        LogType.ok);
  }

  /// Releases mesh ownership back to the foreground (AppState resuming).
  Future<void> _stopMesh() async {
    if (!_meshOwned) return;
    _meshOwned = false;
    await _mesh.stop();
    _firebaseSync.stopAlertFeed();
    _firebaseSync.stopSightingFeed();
    await _addLog(
        'MESH',
        'Moved to foreground — background service released the mesh.',
        LogType.ok);
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final cmd = data['cmd'] as String?;
    if (cmd == 'startMesh') {
      unawaited(_startMesh(
        data['displayName'] as String? ?? 'VIGILINK User',
        data['userId'] as String?,
      ));
    } else if (cmd == 'stopMesh') {
      unawaited(_stopMesh());
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _stopMesh();
    await _addLog('MESH', 'Background service stopped.', LogType.ok);
  }
}
