import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../utils/nav_key.dart';
import 'database_service.dart';

/// Handles a push notification that arrives while the app is fully closed
/// or backgrounded. Must be a top-level (or static) function — this is a
/// Flutter/FCM requirement, not a style choice, since it runs in a separate
/// isolate. Currently just logs; there's no server-side Cloud Function yet
/// actually sending alert pushes (see NotificationService docs below for
/// why), so this exists as the plumbing for when that's added.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('Background FCM message received: ${message.messageId}');
}

/// Thin wrapper around flutter_local_notifications so every real event in
/// the app (theft report, geofence violation, alert relayed, recovery,
/// sync result) can trigger an actual Android notification.
///
/// Also handles the RECEIVING side of Firebase Cloud Messaging (FCM) — this
/// is the manuscript's "dual-layer fallback": when the ad hoc BLE/Wi-Fi
/// mesh has no nearby peers but the internet is available, FCM is the
/// second channel an alert could travel through.
///
/// IMPORTANT — what this does NOT do: actually push an alert to a specific
/// other user's phone. Sending a targeted FCM message requires a
/// server-side component (a Cloud Function watching Firestore for new
/// `theft_alerts` documents, then calling the FCM Admin SDK) — a pure
/// client-side Flutter app cannot securely send push notifications to
/// other specific devices without embedding a server key in the app
/// itself, which would be a real security hole. That Cloud Function is a
/// known next step, not implemented in this project — the app's real,
/// working delivery paths today are the ad hoc mesh and the Firestore-based
/// internet alert feed (see FirebaseSyncService.startAlertFeed).
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  int _idCounter = 1000;

  Future<void> init() async {
    if (_initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    const channel = AndroidNotificationChannel(
      'vehicleguard_alerts',
      'VIGILINK Alerts',
      description: 'Theft alerts, geofence violations, relay and sync updates',
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _initialized = true;
  }

  /// Opens the Alert Received screen for the tapped notification's alert —
  /// works whether the tap happened while the app was foregrounded,
  /// backgrounded, or (since this plugin re-delivers taps once the Flutter
  /// engine is back up) freshly relaunched from a background-service-shown
  /// notification. [payload] is the alert id passed to [show]; a
  /// notification with no payload (geofence/sync/etc. notices) is just
  /// dismissed, same as tapping it does today.
  static void _onNotificationTapped(NotificationResponse response) {
    final alertId = response.payload;
    if (alertId == null || alertId.isEmpty) return;
    unawaited(_openAlert(alertId));
  }

  static Future<void> _openAlert(String alertId) async {
    final alert = await DatabaseService.instance.getAlertById(alertId);
    if (alert == null) return;
    rootNavigatorKey.currentState?.pushNamed('/alert-received', arguments: alert);
  }

  Future<bool> requestPermission() async {
    final granted = await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    return granted ?? false;
  }

  /// [payload] is an alert id — when present, tapping this notification
  /// opens that alert's details (see [_onNotificationTapped]). Omitted for
  /// notifications that aren't about a received alert (geofence, recovery,
  /// sync), which keep today's behavior of just dismissing on tap.
  Future<void> show(String title, String body, {String? payload}) async {
    if (!_initialized) await init();
    await _plugin.show(
      _idCounter++,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'vehicleguard_alerts',
          'VIGILINK Alerts',
          channelDescription:
              'Theft alerts, geofence violations, relay and sync updates',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
      payload: payload,
    );
  }

  // ──────────────────────────────────────────
  // Firebase Cloud Messaging — receiving side
  // ──────────────────────────────────────────
  bool _fcmInitialized = false;

  /// Requests notification permission (covers both the local-notification
  /// path and FCM), registers the background handler, and starts listening
  /// for messages that arrive while the app is open. Safe to call even if
  /// Firebase failed to initialize — every call is wrapped so a missing/
  /// misconfigured Firebase project degrades to "no push", not a crash.
  Future<void> initFcm() async {
    if (_fcmInitialized) return;
    try {
      await FirebaseMessaging.instance
          .requestPermission(alert: true, badge: true, sound: true);
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final title = message.notification?.title ?? 'VIGILINK';
        final body = message.notification?.body ?? 'You have a new alert.';
        show(title, body);
      });
      _fcmInitialized = true;
    } catch (e) {
      debugPrint('FCM init skipped (Firebase unavailable): $e');
    }
  }
}
