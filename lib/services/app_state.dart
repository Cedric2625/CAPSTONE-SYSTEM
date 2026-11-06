import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import 'alert_ingest.dart';
import 'database_service.dart';
import 'location_service.dart';
import 'mesh_background_service.dart';
import 'notification_service.dart';
import 'connectivity_service.dart';
import 'nearby_mesh_service.dart';
import 'firebase_sync_service.dart';
import 'firebase_auth_service.dart';
import '../utils/picker_guard.dart';
import '../utils/validators.dart';
import '../utils/geo_defaults.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final _db = DatabaseService.instance;
  final _loc = LocationService.instance;
  final _notif = NotificationService.instance;
  final _conn = ConnectivityService.instance;
  final _mesh = NearbyMeshService.instance;
  final _firebaseSync = FirebaseSyncService.instance;
  final _authSvc = FirebaseAuthService.instance;
  final _rng = Random();

  // ─── Auth errors (mirrors the lastMeshError pattern below) ───
  String? lastAuthError;

  /// Set after a `login()` call returns false because the account is still
  /// waiting for admin approval, or was rejected. Rejection keeps the sign-in
  /// alive so [discardRejectedRegistration] can free the account; pending
  /// signs out at once. The Login screen shows the matching notice.
  RegistrationDecision? registrationDecision;
  String? rejectionReason;

  /// Non-null (holding the account's email) after a `login()` call returns
  /// false specifically because the credentials were correct but the
  /// account's email was never verified (registration was abandoned before
  /// clicking the link, or it expired). The UI should route to the email
  /// verification screen rather than showing a plain error.
  String? pendingEmailVerification;

  /// True after a sign-in whose credentials were fine but whose account has no
  /// driver's license photos on file yet. The UI shows the license screen,
  /// then calls [completePendingSignIn] (or [cancelPendingSignIn]).
  bool pendingLicense = false;
  UserModel? _pendingLicenseProfile;
  String _pendingLicenseLog = '';
  static const _licenseFlagPrefix = 'license_on_file_';

  bool isInitializing = true;

  // ─── Auth ───
  UserModel? currentUser;
  bool get isLoggedIn => currentUser != null;

  // ─── Vehicles ───
  final List<VehicleModel> _vehicles = [];
  List<VehicleModel> get myVehicles =>
      _vehicles.where((v) => v.ownerId == currentUser?.id).toList();

  // ─── Alerts ───
  final List<TheftAlert> _alerts = [];
  List<TheftAlert> get activeAlerts =>
      _alerts.where((a) => a.status == AlertStatus.active).toList();
  List<TheftAlert> get allAlerts => _alerts;
  List<TheftAlert> get myAlerts =>
      _alerts.where((a) => a.userId == currentUser?.id).toList();

  // ─── Sightings (nearby users telling an owner they've seen a stolen car) ───
  // Holds both directions for the signed-in account: sightings it RECEIVED
  // about its own stolen vehicles, and sightings it SENT about someone else's.
  final List<SightingReport> _sightings = [];

  /// Sighting ids already handled/relayed over the mesh — the same report
  /// reaches a phone from several neighbours, and each must relay it only once.
  final Set<String> _seenSightingIds = {};

  /// Every sighting for [alertId], newest sighting first.
  List<SightingReport> sightingsForAlert(String alertId) =>
      _sightings.where((s) => s.alertId == alertId).toList()
        ..sort((a, b) => b.seenAt.compareTo(a.seenAt));

  // ─── Nodes (real peers via raw BLE/Wi-Fi Direct + simulated demo nodes) ───
  List<AdHocNode> nodes = [];

  // ─── Real ad hoc mesh (raw BLE for discovery, native Wi-Fi Direct for data) ───
  bool meshPermissionsGranted = false;
  String? lastMeshError;
  int meshErrorSeq =
      0; // increments on every new error so the UI can detect it even if the message text repeats
  bool get meshActive => _mesh.isRunning;
  bool get meshAdvertising => _mesh.advertising;
  bool get meshDiscovering => _mesh.discovering;
  int get connectedPeerCount =>
      nodes.where((n) => !n.isSimulated && !n.viaInternet && n.isOnline).length;

  /// Real devices this phone has SEEN but isn't connected to yet. Previously
  /// these were invisible everywhere in the UI, so "0 nearby" looked
  /// identical whether nothing had been found or a device had been found and
  /// the connection was still being negotiated.
  int get discoveredPeerCount => nodes
      .where((n) => !n.isSimulated && !n.viaInternet && !n.isOnline)
      .length;

  /// Things Android will silently refuse to scan without (Bluetooth or
  /// Location/GPS switched off), refreshed whenever the mesh (re)starts.
  List<String> meshRadioProblems = [];

  String get meshStatusLabel {
    if (!meshPermissionsGranted) return 'Permission Required';
    if (!meshActive) {
      return meshRadioProblems.isNotEmpty
          ? '${meshRadioProblems.join(' & ')} — turn on, then Restart Scan'
          : 'Mesh Inactive';
    }
    if (connectedPeerCount == 0) {
      if (discoveredPeerCount > 0) {
        return 'Found $discoveredPeerCount device${discoveredPeerCount == 1 ? '' : 's'} — connecting…';
      }
      if (meshRadioProblems.isNotEmpty) {
        return '${meshRadioProblems.join(' & ')} — turn on for discovery';
      }
      return 'Scanning for nearby devices…';
    }
    return 'Connected to $connectedPeerCount device${connectedPeerCount == 1 ? '' : 's'}';
  }

  // ─── Notifications ───
  List<NotifItem> notifications = [];

  // ─── Logs ───
  List<SystemLog> logs = [];

  // ─── Location history ───
  List<LocationRecord> locationHistory = [];

  // ─── Monitoring ───
  bool monitoringArmed = true;

  // ─── GPS status (never faked — see LocationService) ───
  GpsStatus gpsStatus = GpsStatus.checking;
  double? currentLat;
  double? currentLng;
  double? currentAccuracy;
  DateTime? lastGpsUpdate;

  // ─── Network / sync status ───
  NetworkStatus networkStatus = NetworkStatus.offline;

  // ─── Stats (derived from real relay/log activity) ───
  int totalRelayed = 0;
  int alertDelay = 0; // ms, last measured
  int transmissionRate = 100; // %
  int proximityAccuracy =
      94; // % (Haversine formula accuracy, from manuscript target)

  Timer? _geofenceTimer;
  final Set<String> _geofenceWarned = {};

  // ──────────────────────────────────────────
  // INIT / SESSION RESTORE
  // ──────────────────────────────────────────
  Future<void> init() async {
    isInitializing = true;
    notifyListeners();
    await _notif.init();
    WidgetsBinding.instance.addObserver(this);

    nodes = await _db.getNodes();
    // Real Nearby Connections endpoint IDs are ephemeral per advertising/
    // discovery session — a "real" node persisted from a previous app run
    // is stale and would misleadingly show as connected. Drop those always;
    // real discovery repopulates them once the mesh starts.
    final staleRealNodes = nodes.where((n) => !n.isSimulated).toList();
    for (final n in staleRealNodes) {
      await _db.deleteNode(n.id);
    }
    nodes.removeWhere((n) => !n.isSimulated);
    // One-time migration cleanup: a phone that had the app installed before
    // Demo Mode was removed may still have old simulated nodes sitting in
    // its local SQLite from back when Demo Mode could seed them. Purge any
    // leftovers so they never show mixed in with real nearby devices.
    for (final n in nodes.where((n) => n.isSimulated).toList()) {
      await _db.deleteNode(n.id);
    }
    nodes.removeWhere((n) => n.isSimulated);

    _wireMeshCallbacks();

    // Session restore: Firebase Auth persists the signed-in user locally on
    // the device, so this works fully offline once a user has logged in
    // here before — no network needed just to know who's signed in.
    final fbUser = _authSvc.currentFirebaseUser;
    if (fbUser != null) {
      if (!fbUser.emailVerified || !_authSvc.isRegisteredAccount(fbUser)) {
        // (Also drops a persisted Google-only session — an account that was
        // auto-created by Google sign-in and never registered through the
        // app, as earlier builds allowed.)
        // Same email-verification gate as login(), applied here too — a
        // Firebase session persisting across an app relaunch must not grant
        // access to an account that never finished email verification. Sign
        // out so this device lands on the normal Login screen instead,
        // whose own login() call already re-checks and re-offers
        // verification. Without this, closing and reopening the app was a
        // way to skip the check entirely.
        await _authSvc.signOut();
      } else if (!await _hasLicense(fbUser.uid, assumeIfUnknown: true)) {
        // No driver's license on file: land on Login, whose own gate asks
        // for it. (Unknown — offline, say — is allowed through here.)
        await _authSvc.signOut();
      } else if (await _approvalBlocksSession(fbUser.uid)) {
        // Still awaiting an admin's decision, or rejected: Login explains
        // which and handles it. Unknown (offline) is let through, the same
        // as the license check above.
        await _authSvc.signOut();
      } else {
        final cached = await _db.getUserById(fbUser.uid);
        currentUser = cached ??
            UserModel(
              id: fbUser.uid,
              name: fbUser.displayName?.isNotEmpty == true
                  ? fbUser.displayName!
                  : 'User',
              email: fbUser.email ?? '',
              phone: '',
              deviceId: 'DEV-${_rng.nextInt(900) + 100}',
              createdAt: fbUser.metadata.creationTime,
            );
        await _loadUserData();
        await _loadProfilePhoto(currentUser!.id);
      }
    }

    _conn.listen((online) => _onConnectivityChanged(online));
    final online = await _conn.isOnline();
    networkStatus = online ? NetworkStatus.online : NetworkStatus.offline;

    await refreshGps();
    // Ask for the notification permission explicitly (on Android 13+ a
    // notification without it is silently dropped, and this was never being
    // requested). Done AFTER the location prompt above rather than alongside
    // it: two permission dialogs requested at the same instant can cancel one
    // another, leaving a permission looking "denied" when the user never got
    // to answer. Sequenced before FCM for the same reason.
    unawaited(_notif.requestPermission().then((_) => _notif.initFcm()));
    _loc.startWatching((pos) {
      currentLat = pos.latitude;
      currentLng = pos.longitude;
      currentAccuracy = pos.accuracy;
      lastGpsUpdate = DateTime.now();
      gpsStatus = GpsStatus.available;
      _checkGeofences();
      _recomputePresenceNodes();
      notifyListeners();
    }, onError: (e) async {
      // The passive stream can die (Android throttling a backgrounded or
      // screen-off app is the common real-device case) with no event ever
      // telling the rest of the app — geofence checking used to then keep
      // comparing against whatever position it saw last, forever, so moving
      // the phone any distance afterward triggered nothing. Logged once,
      // and the periodic geofence poll below (which asks for a fresh fix
      // itself rather than trusting this stream) is what actually recovers.
      gpsStatus = GpsStatus.unavailable;
      await _addLog(
          'GPS',
          'Live location updates stopped ($e). Geofence checks continue on their own timer.',
          LogType.warn);
      notifyListeners();
    });

    _geofenceTimer?.cancel();
    _geofenceTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => unawaited(_checkGeofencesFresh()));

    if (currentUser != null) {
      unawaited(_startMeshIfNeeded());
      unawaited(_startForegroundServiceIfNeeded());
    }
    _startAlertFeed();
    _startSightingFeed();
    _startPresence();
    // A restored session (app relaunch, not a fresh login()) never goes
    // through _completeSignIn, so it needs its own account watch too —
    // otherwise a phone that was disabled while its app was closed would
    // only find out the next time it happened to log in again.
    _startAccountWatch();
    // Anything left unsent from a previous session goes out now, rather than
    // waiting for the next network change (this also reconciles vehicles).
    if (currentUser != null) _syncSoonIfOnline();

    // A failed sync used to stay failed until the network happened to change.
    _syncRetryTimer?.cancel();
    _syncRetryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (currentUser != null && networkStatus == NetworkStatus.syncFailed) {
        _syncSoonIfOnline();
      }
    });

    isInitializing = false;
    notifyListeners();
  }

  Timer? _syncRetryTimer;

  /// Coming back to the app is the moment things are most likely to have
  /// gone stale: Android throttles Bluetooth scanning and network listeners
  /// while an app is in the background or the screen is locked, and the user
  /// may have switched Bluetooth/Location on after seeing the warning. So on
  /// resume: refresh uploads and the internet feed, and restart the mesh
  /// radios if nothing is connected.
  DateTime? _pausedAt;

  /// Debounce timer for handing the mesh off to the background service —
  /// only fires (and only then, if no picker is open) after the app has
  /// been backgrounded for this long, so a quick Home-and-back never
  /// triggers a reconnect.
  static const Duration _handoffDelay = Duration(seconds: 15);
  Timer? _handoffTimer;

  /// True while the background service currently owns the mesh (the app has
  /// been backgrounded long enough for the hand-off to actually happen).
  bool _meshHandedOff = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      _appInForeground = false;
      _startHandoffTimer();
    }
    if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
      _handoffTimer?.cancel();
      _handoffTimer = null;
      unawaited(_onAppResumed());
    }
  }

  /// Starts (or restarts) the hand-off debounce timer. Cancelled immediately
  /// on resume, so only a genuine ~15s-plus absence ever hands the mesh off.
  void _startHandoffTimer() {
    _handoffTimer?.cancel();
    if (currentUser == null) return;
    _handoffTimer = Timer(_handoffDelay, _onHandoffTimerFired);
  }

  void _onHandoffTimerFired() {
    if (_appInForeground || currentUser == null) return;
    // Never hand off while a camera/photo picker THIS app opened is in
    // front: Android reports the app as "paused" the instant it opens,
    // indistinguishable here from the user actually switching away, and a
    // mesh reconnect right then would blip it mid photo-pick (e.g. while
    // submitting a theft report). Retry shortly instead of handing off.
    if (isPickerOpen) {
      _handoffTimer = Timer(const Duration(seconds: 3), _onHandoffTimerFired);
      return;
    }
    unawaited(_handOffMeshToBackground());
  }

  /// Hands mesh ownership to the background service, which is already
  /// running (started once at login — see _startForegroundServiceIfNeeded)
  /// so this only ever moves the mesh/feeds, never the service itself.
  Future<void> _handOffMeshToBackground() async {
    if (currentUser == null || _meshHandedOff) return;
    _meshHandedOff = true;
    await _addLog(
        'MESH',
        'App moved to the background - handing the mesh off to the background service.',
        LogType.ok);
    await _mesh.stop();
    _firebaseSync.stopAlertFeed();
    _firebaseSync.stopSightingFeed();
    final displayName =
        currentUser!.name.isNotEmpty ? currentUser!.name : 'VIGILINK User';
    FlutterForegroundTask.sendDataToTask({
      'cmd': 'startMesh',
      'displayName': displayName,
      'userId': currentUser!.id,
    });
  }

  /// Reclaims the mesh from the background service on resume, and reloads
  /// this device's in-memory state from SQLite - alerts, sightings, logs,
  /// notifications, location history, totalRelayed - so anything the
  /// background service stored while the app was away shows up at once.
  Future<void> _reclaimMeshFromBackground() async {
    if (!_meshHandedOff) return;
    _meshHandedOff = false;
    FlutterForegroundTask.sendDataToTask({'cmd': 'stopMesh'});
    await _addLog(
        'MESH',
        'App moved to the foreground - reclaiming the mesh from the background service.',
        LogType.ok);
    await _loadUserData();
    notifyListeners();
    unawaited(_startMeshIfNeeded());
  }

  Future<void> _onAppResumed() async {
    if (currentUser == null) return;
    final awayFor = _pausedAt == null
        ? Duration.zero
        : DateTime.now().difference(_pausedAt!);
    _pausedAt = null;
    if (_meshHandedOff) {
      await _reclaimMeshFromBackground();
    }
    _syncSoonIfOnline();
    _startAlertFeed();
    _startSightingFeed();
    _startPresence();
    // Only restart the radios after a real absence, and never while a device
    // has been found and is mid-connection. Quick trips out of the app — the
    // camera, a permission popup, the Google account picker — also count as
    // "resumed", and restarting on each of those threw away a working scan.
    if (meshPermissionsGranted &&
        awayFor > const Duration(seconds: 20) &&
        (!meshActive ||
            (connectedPeerCount == 0 && discoveredPeerCount == 0))) {
      await restartMesh(quiet: true);
    }
  }

  // ──────────────────────────────────────────
  // REAL AD HOC MESH (raw BLE for discovery, native Wi-Fi Direct for data)
  // ──────────────────────────────────────────
  void _wireMeshCallbacks() {
    _mesh.onPeerDiscovered = (endpointId, name) {
      final id = 'real-$endpointId';
      final existing = nodes.any((n) => n.id == id);
      if (!existing) {
        final node = AdHocNode(
          id: id,
          name: name,
          distance: -1, // real distance unknown — UI shows "Nearby" instead
          isOnline: false,
          connectionType: ConnectionType.ble,
          relayStatus: RelayStatus.pending,
          mapX: _rng.nextDouble() * 0.7 + 0.15,
          mapY: _rng.nextDouble() * 0.7 + 0.15,
          isSimulated: false,
          endpointId: endpointId,
        );
        nodes.add(node);
        _db.upsertNode(node);
        // Only log the first sighting — Android re-fires onEndpointFound
        // repeatedly for a peer that's still in range while discovery keeps
        // running, and logging every one of those flooded the system log.
        _addLog('NODE', '🔎 Discovered nearby device: $name', LogType.info);
      }
      notifyListeners();
    };

    _mesh.onPeerLost = (endpointId) {
      final id = 'real-$endpointId';
      nodes.removeWhere((n) => n.id == id && !n.isOnline);
      _db.deleteNode(id);
      notifyListeners();
    };

    _mesh.onPeerConnected = (endpointId, name) {
      final id = 'real-$endpointId';
      final idx = nodes.indexWhere((n) => n.id == id);
      if (idx >= 0) {
        nodes[idx].isOnline = true;
        nodes[idx].relayStatus = RelayStatus.received;
        _db.upsertNode(nodes[idx]);
      } else {
        final node = AdHocNode(
          id: id,
          name: name,
          distance: -1,
          isOnline: true,
          connectionType: ConnectionType.ble,
          relayStatus: RelayStatus.received,
          mapX: _rng.nextDouble() * 0.7 + 0.15,
          mapY: _rng.nextDouble() * 0.7 + 0.15,
          isSimulated: false,
          endpointId: endpointId,
        );
        nodes.add(node);
        _db.upsertNode(node);
      }
      _addLog('NODE', '✅ Connected to real device: $name', LogType.ok);
      _addNotif(
          '📶 Nearby Device Connected',
          '$name joined the ad hoc mesh — you can now relay theft alerts directly.',
          NotifType.info);
      notifyListeners();

      // Store-carry-forward: catch this newly-joined peer up on any alerts
      // this device currently has active, so late arrivals aren't missed.
      // Previously completely silent (fire-and-forget with no logging at
      // all) — a real-device 3-phone multi-hop test showed the middle
      // device connecting to the 3rd device WITHOUT the alert ever
      // reaching it, and there was no way to tell from the logs whether
      // this catch-up path even ran, let alone whether it succeeded.
      final activeMine =
          _alerts.where((a) => a.status == AlertStatus.active).toList();
      if (activeMine.isNotEmpty) {
        _addLog(
            'RELAY',
            'Catching up "$name" on ${activeMine.length} active alert(s) this device already has (store-carry-forward)',
            LogType.relay);
      }
      for (final a in activeMine) {
        unawaited(_mesh.sendTo(endpointId, alertWireMessage(a)).then((ok) {
          if (ok) {
            _addLog(
                'RELAY',
                'Catch-up: sent ${a.plate} alert to newly-connected "$name"',
                LogType.relay);
          } else {
            _addLog(
                'RELAY',
                'Catch-up: failed to send ${a.plate} alert to newly-connected "$name"',
                LogType.err);
          }
        }));
      }
    };

    _mesh.onPeerDisconnected = (endpointId) {
      final id = 'real-$endpointId';
      final idx = nodes.indexWhere((n) => n.id == id);
      if (idx >= 0) {
        nodes[idx].isOnline = false;
        _db.upsertNode(nodes[idx]);
      }
      _addLog('NODE', 'Device disconnected: $endpointId', LogType.warn);
      notifyListeners();
    };

    _mesh.onMessageReceived = (message, fromEndpointId) =>
        unawaited(_handleMeshMessage(message, fromEndpointId));

    _mesh.onError = (error) {
      lastMeshError = error;
      meshErrorSeq++;
      _addLog('MESH', error, LogType.err);
      notifyListeners();
    };

    // The mesh repairs itself in the background (watchdog restarts), so the
    // UI has to be told when its state changes — otherwise it would keep
    // showing whatever it saw last.
    _mesh.onStateChanged = () => notifyListeners();

    // Full trace of what the mesh is doing, into System Logs — so when two
    // phones fail to link, the logs show exactly which step didn't happen.
    _mesh.onLog = (message) {
      _addLog('MESH', message, LogType.info);
    };

    // Nearby endpoint IDs are ephemeral: when the radios are torn down,
    // every remembered "real" peer is stale and would misleadingly linger.
    _mesh.onReset = () {
      // Internet-presence nodes aren't Bluetooth peers and survive a radio reset.
      final stale =
          nodes.where((n) => !n.isSimulated && !n.viaInternet).toList();
      if (stale.isEmpty) return;
      nodes.removeWhere((n) => !n.isSimulated && !n.viaInternet);
      for (final n in stale) {
        _db.deleteNode(n.id);
      }
      notifyListeners();
    };
  }

  /// One shared start attempt no matter how many places ask for it. Mesh
  /// start is requested at app launch, on login/registration, from the
  /// "Grant permission" buttons, and on the mode switch — those used to run
  /// concurrently, and the overlapping startAdvertising calls are what
  /// produced STATUS_ALREADY_ADVERTISING and left the mesh stuck inactive.
  Future<void>? _meshStartInFlight;

  Future<void> _startMeshIfNeeded() {
    final existing = _meshStartInFlight;
    if (existing != null) return existing;
    final run = _startMesh();
    _meshStartInFlight = run;
    run.whenComplete(() {
      if (identical(_meshStartInFlight, run)) _meshStartInFlight = null;
    });
    return run;
  }

  /// Warns (once per start) when Bluetooth or Location is off — Android
  /// silently refuses to scan without them, which is indistinguishable from
  /// "nobody nearby" unless the user is told. Can't check Wi-Fi the same way
  /// (no OS-level "is Wi-Fi on" check is exposed to this app), but it's
  /// mentioned here regardless: Google's Nearby Connections — what actually
  /// implements this mesh — also leans on the Wi-Fi radio (Wi-Fi Direct /
  /// Hotspot) to establish and keep a connection, on top of Bluetooth for
  /// discovery, so a phone with Wi-Fi fully switched off can fail to relay
  /// even with Bluetooth on. This is a real limitation of the Android API
  /// itself, not something this app's own code can route around.
  Future<void> _refreshRadioProblems({bool toast = true}) async {
    meshRadioProblems = await _mesh.radioProblems();
    if (meshRadioProblems.isNotEmpty) {
      final msg =
          '${meshRadioProblems.join(' and ')}. Android needs Bluetooth, Location (GPS) AND Wi-Fi switched on (Wi-Fi doesn\'t need to be connected to a network) to find and relay to nearby devices — turn them all on, then tap "Restart Scan".';
      await _addLog('MESH', msg, LogType.warn);
      if (toast) {
        lastMeshError = msg;
        meshErrorSeq++;
      }
    }
  }

  Future<void> _startMesh() async {
    if (currentUser == null) return;
    try {
      final granted = await _mesh.requestPermissions();
      meshPermissionsGranted = granted;
      notifyListeners();
      if (!granted) {
        await _addLog(
            'MESH',
            'Bluetooth/Location/Nearby permissions not granted — real ad hoc discovery unavailable.',
            LogType.warn);
        return;
      }
      await _refreshRadioProblems();
      final displayName =
          currentUser!.name.isNotEmpty ? currentUser!.name : 'VIGILINK User';
      final started = await _mesh.start(displayName);
      if (started) {
        await _addLog(
            'MESH',
            'Real ad hoc mesh started — advertising and scanning as "$displayName".',
            LogType.ok);
      }
    } catch (e) {
      await _addLog('MESH', 'Could not start the mesh: $e', LogType.err);
    }
    notifyListeners();
  }

  /// Tears the mesh down and starts it fresh — for a mesh that's stuck
  /// inactive or has stopped finding anyone (the "Restart Scan" button).
  Future<void> restartMesh({bool quiet = false}) async {
    if (currentUser == null) return;
    try {
      final granted = await _mesh.requestPermissions();
      meshPermissionsGranted = granted;
      notifyListeners();
      if (!granted) return;
      await _refreshRadioProblems(toast: !quiet);
      final displayName =
          currentUser!.name.isNotEmpty ? currentUser!.name : 'VIGILINK User';
      final started = await _mesh.restart(displayName: displayName);
      await _addLog(
          'MESH',
          started
              ? 'Mesh restarted — advertising and scanning again.'
              : 'Mesh restart did not succeed — see the message above.',
          started ? LogType.ok : LogType.warn);
    } catch (e) {
      await _addLog('MESH', 'Could not restart the mesh: $e', LogType.err);
    }
    notifyListeners();
  }

  /// Explicitly requests mesh permissions (for a Settings "Request Permission"
  /// button) and starts the mesh immediately if granted.
  Future<bool> requestMeshPermissions() async {
    final granted = await _mesh.requestPermissions();
    meshPermissionsGranted = granted;
    notifyListeners();
    if (granted && !meshActive) {
      await _startMeshIfNeeded();
    }
    return granted;
  }

  /// True once the background foreground-service has been started for this
  /// login (idempotent — safe to call again, e.g. on an app relaunch while
  /// already logged in). Runs continuously until [logout]; only mesh
  /// OWNERSHIP hands off between this isolate and the background one while
  /// backgrounded (see [_handOffMeshToBackground]/[_reclaimMeshFromBackground])
  /// — the service itself, and its persistent notification, stay up the
  /// whole time so a Back press (which destroys the Activity) can never
  /// race a service that hasn't started yet.
  bool _foregroundServiceStarted = false;

  Future<void> _startForegroundServiceIfNeeded() async {
    if (currentUser == null) return;
    if (_foregroundServiceStarted ||
        await FlutterForegroundTask.isRunningService) {
      _foregroundServiceStarted = true;
      return;
    }
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: const [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'VIGILINK',
      notificationText: 'Monitoring for theft alerts',
      callback: startMeshBackgroundCallback,
    );
    if (result is ServiceRequestSuccess) {
      _foregroundServiceStarted = true;
      await _addLog(
          'MESH',
          'Background service started (will take over the mesh if the app is backgrounded).',
          LogType.ok);
      unawaited(_maybePromptBatteryOptimization());
    } else if (result is ServiceRequestFailure) {
      await _addLog('MESH',
          'Could not start the background service: ${result.error}', LogType.warn);
    }
  }

  static const _batteryOptPromptShownKey = 'battery_opt_prompt_shown';

  /// Asks once, ever, for "Unrestricted" battery use — without it, some
  /// OEM phones can still kill the background service despite it being a
  /// proper foreground service. Tracked in SharedPreferences so this is
  /// never asked twice.
  Future<void> _maybePromptBatteryOptimization() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_batteryOptPromptShownKey) ?? false) return;
    await prefs.setBool(_batteryOptPromptShownKey, true);
    final alreadyUnrestricted =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!alreadyUnrestricted) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  // _hms/_logAlertDelivery used to live here. Both are now in
  // alert_ingest.dart (as _hms / logAlertDelivery) — byte-for-byte the same
  // 'DELAY' log line and the same FirebaseSyncService.logAlertDelivery
  // write, just taking a logSink parameter instead of calling _addLog
  // directly, so the background service can reuse it too. Every call site
  // below passes logSink: _addLog, so nothing about what gets written
  // changes.

  Future<void> _handleMeshMessage(
      Map<String, dynamic> msg, String fromEndpointId) async {
    final type = msg['msgType'] as String?;
    if (type == 'theft_alert') {
      final id = msg['id'] as String?;
      if (id == null) return;
      // Checked in memory, with no await before the shared ingest call
      // below: the same alert can arrive over the mesh AND the internet
      // feed at the same moment, and a database-only check left a gap in
      // which both paths passed the check and the alert was stored (and
      // announced) twice. (The shared function itself now also closes this
      // race internally with a synchronous in-flight guard — see
      // alert_ingest.dart's _inFlightAlertIds — so this is defense in depth
      // for the common "already fully processed" case, not the only thing
      // preventing a double-store.)
      if (_alerts.any((a) => a.id == id)) {
        await _addLog(
            'RELAY',
            'Duplicate alert $id ignored (already stored) from $fromEndpointId',
            LogType.info);
        return;
      }
      // Dedup/store/log/notify/relay is shared with the background service
      // (alert_ingest.dart), so there is exactly one implementation of it —
      // same dedup, hop-count handling and relay, same logs/notifications.
      final alert = await ingestMeshTheftAlert(msg, fromEndpointId,
          logSink: _addLog, notifSink: _addNotif);
      if (alert == null) return;
      // Re-check right at the insert: the internet feed may have added this
      // same alert while the shared ingest call above was awaiting.
      if (_alerts.any((a) => a.id == id)) return;
      _alerts.insert(0, alert);
      receivedVia[alert.id] = 'Ad Hoc Mesh';
      totalRelayed++;
      _announceIncomingAlert(alert);
      notifyListeners();
      // Sync this relayed alert to Firestore too, not just ones we created
      // ourselves — don't wait for the next connectivity transition.
      _syncSoonIfOnline();
    } else if (type == 'status_update') {
      final updated = await ingestMeshStatusUpdate(msg, fromEndpointId,
          logSink: _addLog, notifSink: _addNotif);
      if (updated == null) return;
      final idx = _alerts.indexWhere((a) => a.id == updated.id);
      if (idx == -1) return;
      // Mutated in place (not replaced) — same object identity as before,
      // in case anything still holds a direct reference to it.
      _alerts[idx].status = updated.status;
      _alerts[idx].recoveryRemarks = updated.recoveryRemarks;
      notifyListeners();
    } else if (type == 'sighting') {
      await _handleMeshSighting(msg, fromEndpointId);
    } else if (type == 'alert_ack') {
      final alertId = msg['alertId'] as String?;
      if (alertId != null) await _onAlertAcked(alertId, fromEndpointId);
    }
  }

  /// The peer at [fromEndpointId] has confirmed it actually stored
  /// [alertId] locally — not just that our socket write to it succeeded.
  /// Only now does it count as genuinely relayed/received.
  Future<void> _onAlertAcked(String alertId, String fromEndpointId) async {
    final idx = _alerts.indexWhere((a) => a.id == alertId);
    if (idx == -1) return;
    final alert = _alerts[idx];
    if (alert.relayedTo.contains(fromEndpointId)) return; // already confirmed
    alert.relayedTo.add(fromEndpointId);
    totalRelayed++;
    await _db.upsertAlert(alert, synced: false);
    final nodeIdx = nodes.indexWhere((n) => n.endpointId == fromEndpointId);
    final name = nodeIdx != -1 ? nodes[nodeIdx].name : fromEndpointId;
    if (nodeIdx != -1) nodes[nodeIdx].relayStatus = RelayStatus.received;
    await _addLog(
        'RELAY',
        '✅ Delivery confirmed: $name actually stored alert $alertId (real mesh).',
        LogType.ok);
    await _addNotif('📡 Alert Relayed',
        '${alert.plate} alert confirmed received by $name.', NotifType.relayed);
    notifyListeners();
  }

  // ──────────────────────────────────────────
  // SIGHTING REPORTS (nearby user → vehicle owner)
  // ──────────────────────────────────────────
  // A phone that receives a "Stolen Vehicle Nearby" alert can report having
  // SEEN that vehicle — a message, where (GPS, when available), when, and an
  // optional proof photo — straight to the owner. Same dual-layer delivery as
  // the alerts themselves: over the internet (Firestore, carries the photo)
  // and, when the mesh has neighbours, over the ad hoc mesh (text only — a
  // photo is far too big for a Nearby Connections bytes payload), relayed hop
  // by hop until it reaches the owner. An offline sighting is kept on the
  // phone and delivered by the normal sync when the connection returns.
  static const int _sightingMeshHops = 5;

  void _startSightingFeed() {
    if (currentUser == null) return;
    _firebaseSync.startSightingFeed(
      ownerId: currentUser!.id,
      onSighting: (data) => unawaited(_handleInternetSighting(data)),
      onError: (e) {
        _addLog(
            'CLOUD',
            'Sighting feed unavailable ($e). Signed-in users must be allowed to read their sightings in the Firestore rules.',
            LogType.warn);
      },
    );
  }

  Future<void> _handleInternetSighting(Map<String, dynamic> data) async {
    try {
      final s = SightingReport.fromMap(Map<String, Object?>.from(data));
      await _storeReceivedSighting(s, via: 'the internet');
    } catch (e) {
      await _addLog(
          'SIGHTING', 'Malformed sighting from the cloud: $e', LogType.err);
    }
  }

  Future<void> _handleMeshSighting(
      Map<String, dynamic> msg, String fromEndpointId) async {
    final id = msg['id'] as String?;
    // add() is false when this id was already handled — the same report comes
    // in from several neighbours and must be stored/relayed only once.
    if (id == null || !_seenSightingIds.add(id)) return;
    final hops = (msg['hopCount'] as num?)?.toInt() ?? 0;
    try {
      final s = SightingReport.fromMap(Map<String, Object?>.from(msg));
      if (currentUser != null && s.ownerId == currentUser!.id) {
        await _storeReceivedSighting(s, via: 'the ad hoc mesh');
      } else if (hops > 0) {
        final forward = Map<String, dynamic>.from(msg)..['hopCount'] = hops - 1;
        unawaited(_mesh.broadcast(forward, excludeEndpointId: fromEndpointId));
      }
    } catch (e) {
      await _addLog('SIGHTING', 'Malformed sighting from $fromEndpointId: $e',
          LogType.err);
    }
  }

  /// Stores a sighting about one of THIS account's vehicles and tells the
  /// owner. Returns true only when it was new. A second copy of one already
  /// held (e.g. the cloud copy arriving after the text-only mesh copy) is not
  /// announced again — it just adds the photo and phone number if the first
  /// one lacked them.
  ///
  /// The actual dedup/store/log/notify work is shared with the background
  /// service (alert_ingest.dart's storeReceivedSighting, DB-backed), so
  /// there is exactly one implementation of it; this wrapper only layers on
  /// the in-memory `_sightings` list bookkeeping, mirroring the merge
  /// condition the shared function applies to the DB row.
  Future<bool> _storeReceivedSighting(SightingReport s,
      {required String via}) async {
    final me = currentUser;
    if (me == null || s.ownerId != me.id) return false;
    final isNew = await storeReceivedSighting(s,
        ownerId: me.id, via: via, logSink: _addLog, notifSink: _addNotif);
    if (isNew) {
      _sightings.insert(0, s);
      _seenSightingIds.add(s.id);
      notifyListeners();
      return true;
    }
    final idx = _sightings.indexWhere((x) => x.id == s.id);
    if (idx != -1) {
      final held = _sightings[idx];
      if ((s.hasPhoto && !held.hasPhoto) || (s.hasContact && !held.hasContact)) {
        _sightings[idx] = s;
        notifyListeners();
      }
    }
    return false;
  }

  /// Sends a sighting of [alert]'s vehicle to its owner. Never fabricates
  /// anything: [lat]/[lng] are whatever real GPS gave (null when it had no
  /// fix) and [seenAt] is when the person says they saw it. Saved on this
  /// phone FIRST, so it can't be lost if the connection drops mid-send.
  Future<SightingSubmitResult> submitSighting({
    required TheftAlert alert,
    required String message,
    required DateTime seenAt,
    double? lat,
    double? lng,
    Uint8List? photoBytes,
  }) async {
    final me = currentUser;
    if (me == null) {
      return const SightingSubmitResult.failure(
          'Please sign in again to send a sighting.');
    }
    if (alert.userId == me.id) {
      return const SightingSubmitResult.failure(
          'This is your own vehicle — use Update Status to mark it recovered.');
    }
    final text = message.trim();
    if (text.length < 5) {
      return const SightingSubmitResult.failure(
          'Please describe what you saw (at least a few words).');
    }
    if (text.length > 500) {
      return const SightingSubmitResult.failure(
          'Your message is too long. Keep it under 500 characters.');
    }
    String? photoB64;
    if (photoBytes != null) {
      // Travels inside a Firestore document (1 MB limit) — the picker already
      // shrinks it, this is the backstop.
      if (photoBytes.length > 500000) {
        return const SightingSubmitResult.failure(
            'That photo is too large. Please take or choose a smaller one.');
      }
      photoB64 = base64Encode(photoBytes);
    }

    final sighting = SightingReport(
      id: 'sg-${me.id.substring(0, me.id.length < 6 ? me.id.length : 6)}-${DateTime.now().millisecondsSinceEpoch}',
      alertId: alert.id,
      ownerId: alert.userId,
      reporterId: me.id,
      reporterName: me.name.isNotEmpty ? me.name : 'A nearby user',
      reporterPhone: me.phone,
      message: text,
      lat: lat,
      lng: lng,
      seenAt: seenAt,
      sentAt: DateTime.now(),
      photoB64: photoB64,
    );
    _sightings.insert(0, sighting);
    _seenSightingIds.add(sighting.id);
    await _db.upsertSighting(sighting, synced: false);

    var delivered = false;
    var blockedByRules = false;
    try {
      await _firebaseSync.uploadSighting(sighting);
      await _db.markSightingSynced(sighting.id);
      delivered = true;
    } catch (e) {
      blockedByRules = e.toString().contains('permission-denied');
      await _addLog(
          'SIGHTING',
          'Sighting saved but not delivered yet ($e). It will retry when online. If this says permission-denied, add the sightings rule in Firestore.',
          LogType.warn);
    }

    var sharedOverMesh = false;
    if (_mesh.connectedEndpoints.isNotEmpty) {
      final msg = Map<String, dynamic>.from(sighting.forMesh().toMap())
        ..['msgType'] = 'sighting'
        ..['hopCount'] = _sightingMeshHops;
      unawaited(_mesh.broadcast(msg));
      sharedOverMesh = true;
    }

    await _addLog(
        'SIGHTING',
        'Sighting of ${alert.plate} sent (${delivered ? "delivered" : "queued"}${sharedOverMesh ? ", shared over the mesh" : ""})',
        delivered ? LogType.ok : LogType.info);
    notifyListeners();
    // Retrying only makes sense for a connection problem — a refusal by the
    // rules would just be refused again.
    if (!delivered && !blockedByRules) _syncSoonIfOnline();
    return SightingSubmitResult(
        delivered: delivered,
        sharedOverMesh: sharedOverMesh,
        blockedByRules: blockedByRules);
  }

  // ──────────────────────────────────────────
  // INTERNET ALERT FEED (second delivery layer)
  // ──────────────────────────────────────────
  // Alerts normally travel phone-to-phone over the ad hoc mesh, but that
  // needs Bluetooth/Wi-Fi Direct discovery to succeed. The reporter also
  // uploads every alert to Firestore, so any signed-in phone that's online
  // can receive it that way too — the manuscript's dual-layer design. Every
  // active alert is surfaced to every logged-in, internet-connected user,
  // with no distance filter (see alert_ingest.dart's ingestInternetAlert).

  void _startAlertFeed() {
    if (currentUser == null) return;
    _firebaseSync.startAlertFeed(
      onAlert: (data) => unawaited(_handleInternetAlert(data)),
      onError: (e) {
        _addLog(
            'CLOUD',
            'Internet alert feed unavailable ($e). Signed-in users must be allowed to read theft_alerts in the Firestore rules.',
            LogType.warn);
      },
    );
  }

  // ──────────────────────────────────────────
  // ACCOUNT STATUS WATCH (an admin can disable this account)
  // ──────────────────────────────────────────
  /// Increments each time an admin disables this signed-in account, so the
  /// UI (see main.dart's `_IncomingAlertWatcher`) can show it exactly once
  /// and route back to Login — the same seq-counter pattern as
  /// [incomingAlertSeq] / [geofenceNearWarningSeq].
  int accountDisabledSeq = 0;

  void _startAccountWatch() {
    if (currentUser == null) return;
    _firebaseSync.startAccountWatch(
      uid: currentUser!.id,
      onChange: (disabled) {
        if (disabled) unawaited(_forceLogoutDisabled());
      },
      onError: (_) {
        // Offline/unreachable — nothing to do; login() itself re-checks this
        // the next time the account signs in from anywhere.
      },
    );
  }

  Future<void> _forceLogoutDisabled() async {
    if (currentUser == null) return;
    await _addLog('AUTH', 'Account disabled by an administrator — signed out.',
        LogType.warn);
    await logout();
    accountDisabledSeq++;
    notifyListeners();
  }

  Future<void> _handleInternetAlert(Map<String, dynamic> d) async {
    final me = currentUser;
    if (me == null) return;
    final id = d['id'] as String?;
    if (id == null) return;
    // Computed before the shared ingest call so we know, after it returns,
    // whether this was an update to an alert we already had or a brand-new
    // one — same distinction the original two branches made.
    final knownIdx = _alerts.indexWhere((a) => a.id == id);
    final result = await ingestInternetAlert(
      d,
      currentUserId: me.id,
      currentLat: currentLat,
      currentLng: currentLng,
      logSink: _addLog,
      notifSink: _addNotif,
    );
    if (result == null) return;
    if (knownIdx != -1) {
      // Mutated in place (not replaced) — same object identity as before,
      // in case anything still holds a direct reference to it.
      _alerts[knownIdx].status = result.status;
      _alerts[knownIdx].recoveryRemarks = result.recoveryRemarks;
      _alerts[knownIdx].recoveryPhotos = result.recoveryPhotos;
      notifyListeners();
      return;
    }
    _alerts.insert(0, result);
    receivedVia[result.id] = 'Internet';
    totalRelayed++;
    _announceIncomingAlert(result);
    notifyListeners();
  }

  /// Uploads pending changes right away when online, rather than waiting for
  /// the next connectivity change — used after anything other devices should
  /// see promptly (a new alert, a recovery).
  void _syncSoonIfOnline() {
    // Only skip when we KNOW we're offline. It used to also skip while
    // "syncing" or "sync failed", which meant an alert reported at the wrong
    // moment — or after any earlier failure — never went out.
    if (networkStatus != NetworkStatus.offline) {
      unawaited(_onConnectivityChanged(true));
    }
  }

  /// The most recent alert this phone RECEIVED from someone else (over the
  /// mesh or the internet feed). [incomingAlertSeq] increments each time so
  /// the UI can pop up "Stolen Vehicle Nearby" exactly once per alert.
  TheftAlert? incomingAlert;
  int incomingAlertSeq = 0;

  void _announceIncomingAlert(TheftAlert alert) {
    incomingAlert = alert;
    incomingAlertSeq++;
  }

  // ──────────────────────────────────────────
  // NEARBY DEVICES BY SHARED POSITION (internet presence)
  // ──────────────────────────────────────────
  // Bluetooth discovery can't be relied on across every phone (Android
  // restrictions, phone-maker limits, precise-location settings), so the
  // "Nearby Devices" list also uses this: while the real mesh is on and the
  // app is open, a signed-in phone shares its position to /presence/{uid}
  // (rounded to ~11 m), and every phone lists the registered devices within
  // [nearbyRangeMeters] of its own GPS position. Deleted on logout / when the
  // mesh is turned off / not refreshed while the app is closed.
  static const double nearbyRangeMeters = 100;
  static const Duration _presenceFreshFor = Duration(seconds: 100);
  final Map<String, Map<String, dynamic>> _presenceDocs = {};
  Timer? _presenceTimer;
  bool _appInForeground = true;
  bool _presencePublished = false;

  bool get _presenceWanted => currentUser != null;

  double _round4(double v) => (v * 10000).roundToDouble() / 10000;

  void _startPresence() {
    _presenceTimer?.cancel();
    if (!_presenceWanted) {
      unawaited(_stopPresence());
      return;
    }
    _firebaseSync.startPresenceFeed(
      onChange: (uid, data) {
        if (data == null) {
          _presenceDocs.remove(uid);
        } else {
          _presenceDocs[uid] = data;
        }
        _recomputePresenceNodes();
      },
      onError: (e) {
        _addLog(
            'CLOUD',
            'Nearby-device feed unavailable ($e). Signed-in users must be allowed to read /presence in the Firestore rules.',
            LogType.warn);
      },
    );
    _presenceTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(_presenceTick()));
    unawaited(_presenceTick());
  }

  Future<void> _presenceTick() async {
    final user = currentUser;
    if (user == null || !_presenceWanted) return;
    if (_appInForeground &&
        currentLat != null &&
        currentLng != null &&
        networkStatus != NetworkStatus.offline) {
      try {
        await _firebaseSync.publishPresence(
          uid: user.id,
          name: user.name,
          deviceId: user.deviceId,
          lat: _round4(currentLat!),
          lng: _round4(currentLng!),
        );
        _presencePublished = true;
      } catch (_) {}
    }
    _recomputePresenceNodes();
  }

  Future<void> _stopPresence({String? uid}) async {
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _firebaseSync.stopPresenceFeed();
    _presenceDocs.clear();
    final had = nodes.any((n) => n.viaInternet);
    nodes.removeWhere((n) => n.viaInternet);
    if (had) notifyListeners();
    final id = uid ?? currentUser?.id;
    if (_presencePublished && id != null) {
      _presencePublished = false;
      try {
        await _firebaseSync.deletePresence(id);
      } catch (_) {}
    }
  }

  void _recomputePresenceNodes() {
    final me = currentUser;
    final found = <AdHocNode>[];
    if (me != null && currentLat != null && currentLng != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      // A phone already connected over Bluetooth shouldn't be listed twice.
      final btNames = nodes
          .where((n) => !n.isSimulated && !n.viaInternet && n.isOnline)
          .map((n) => n.name)
          .toSet();
      for (final e in _presenceDocs.entries) {
        if (e.key == me.id) continue;
        final d = e.value;
        final updated = (d['updatedAtMs'] as num?)?.toInt() ?? 0;
        if (now - updated > _presenceFreshFor.inMilliseconds) continue;
        final lat = (d['lat'] as num?)?.toDouble();
        final lng = (d['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        final dist =
            LocationService.distanceMeters(currentLat!, currentLng!, lat, lng);
        if (dist > nearbyRangeMeters) continue;
        final name = (d['name'] as String?)?.trim().isNotEmpty == true
            ? d['name'] as String
            : 'VIGILINK User';
        if (btNames.contains(name)) continue;
        found.add(AdHocNode(
          id: 'cloud-${e.key}',
          name: name,
          distance: dist.roundToDouble(),
          isOnline: true,
          connectionType: ConnectionType.wifiDirect,
          hopCount: 1,
          relayStatus: RelayStatus.received,
          mapX: 0.5,
          mapY: 0.5,
          isSimulated: false,
          viaInternet: true,
        ));
      }
    }
    found.sort((a, b) => a.distance.compareTo(b.distance));
    String sig(Iterable<AdHocNode> l) =>
        l.map((n) => '${n.id}:${n.distance.toInt()}').join(',');
    if (sig(nodes.where((n) => n.viaInternet)) == sig(found)) return;
    nodes.removeWhere((n) => n.viaInternet);
    nodes.addAll(found);
    notifyListeners();
  }

  // ──────────────────────────────────────────
  // HOW EACH RECEIVED ALERT ARRIVED
  // ──────────────────────────────────────────
  // Kept in memory so the Alert Received screen can say the truth — it used
  // to always claim "Real Ad Hoc Mesh", even for alerts that came over the
  // internet.
  final Map<String, String> receivedVia = {};

  // ──────────────────────────────────────────
  // PROFILE PHOTO
  // ──────────────────────────────────────────
  // Stored locally (as base64) and on the user's own profile document, so it
  // comes back on a new phone. Kept small (see the picker settings on the
  // Profile screen) — well inside a Firestore document.
  Uint8List? profilePhotoBytes;

  String _photoKey(String uid) => 'profile_photo_$uid';

  void _applyPhoto(String? b64) {
    if (b64 == null || b64.isEmpty) {
      profilePhotoBytes = null;
      return;
    }
    try {
      profilePhotoBytes = base64Decode(b64);
    } catch (_) {
      profilePhotoBytes = null;
    }
  }

  Future<void> _loadProfilePhoto(String uid) async {
    final local = await _db.getPref(_photoKey(uid));
    _applyPhoto(local);
    if (local != null && local.isNotEmpty) return;
    // Nothing on this phone (new phone / reinstall) — try the account copy
    // without holding anything up.
    unawaited(_firebaseSync.fetchProfilePhoto(uid).then((b64) async {
      if (b64 == null || b64.isEmpty || currentUser?.id != uid) return;
      await _db.setPref(_photoKey(uid), b64);
      _applyPhoto(b64);
      notifyListeners();
    }));
  }

  Future<void> setProfilePhoto(Uint8List bytes) async {
    final uid = currentUser?.id;
    if (uid == null) return;
    final b64 = base64Encode(bytes);
    await _db.setPref(_photoKey(uid), b64);
    profilePhotoBytes = bytes;
    notifyListeners();
    unawaited(_firebaseSync.saveProfilePhoto(uid, b64).catchError((_) {}));
  }

  Future<void> removeProfilePhoto() async {
    final uid = currentUser?.id;
    if (uid == null) return;
    await _db.setPref(_photoKey(uid), '');
    profilePhotoBytes = null;
    notifyListeners();
    unawaited(_firebaseSync.saveProfilePhoto(uid, null).catchError((_) {}));
  }

  Future<void> _loadUserData() async {
    _vehicles
      ..clear()
      ..addAll(await _db.getVehiclesForOwner(currentUser!.id));
    _alerts
      ..clear()
      ..addAll(await _db.getAllAlerts());
    _sightings
      ..clear()
      ..addAll(await _db.getSightingsFor(currentUser!.id));
    notifications
      ..clear()
      ..addAll(await _db.getNotifications());
    logs
      ..clear()
      ..addAll(await _db.getSystemLogs());
    locationHistory
      ..clear()
      ..addAll(await _db.getAllLocationHistory());
    totalRelayed = _alerts.fold(0, (sum, a) => sum + a.relayedTo.length);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncRetryTimer?.cancel();
    _geofenceTimer?.cancel();
    _loc.stopWatching();
    _conn.dispose();
    _firebaseSync.stopAlertFeed();
    _firebaseSync.stopSightingFeed();
    _firebaseSync.stopPresenceFeed();
    _presenceTimer?.cancel();
    _mesh.stop();
    super.dispose();
  }

  // ──────────────────────────────────────────
  // GPS
  // ──────────────────────────────────────────
  Future<void> refreshGps() async {
    gpsStatus = GpsStatus.checking;
    notifyListeners();
    final pos = await _loc.getCurrentPosition();
    gpsStatus = _loc.status;
    if (pos != null) {
      currentLat = pos.latitude;
      currentLng = pos.longitude;
      currentAccuracy = pos.accuracy;
      lastGpsUpdate = DateTime.now();
    }
    notifyListeners();
  }

  Future<bool> requestLocationPermission() => _loc.requestPermission();

  // ──────────────────────────────────────────
  // AUTH
  // ──────────────────────────────────────────
  /// Authenticates against Firebase Auth — the manuscript's stated backend
  /// (Table 3.3.2.1: "Backend / Database: Firebase (Firestore, Auth)").
  // ─── Login attempt throttling ───
  // A client-side lockout on top of Firebase's own server-side throttling
  // ("too-many-requests") — this one is visible to the user (tells them
  // exactly how long to wait) and kicks in earlier, so a script trying
  // passwords against one email gets locked out well before it could
  // meaningfully brute-force anything. Persisted in SharedPreferences (not
  // just in-memory) so it survives an app relaunch — closing and reopening
  // the app can't be used to reset the counter.
  static const int _maxLoginAttempts = 5;
  static const Duration _lockoutDuration = Duration(minutes: 5);

  String _attemptsKey(String email) =>
      'login_attempts_${email.trim().toLowerCase()}';
  String _lockoutKey(String email) =>
      'login_lockout_${email.trim().toLowerCase()}';

  /// Returns how much longer [email] stays locked out, or null if it isn't
  /// currently locked (clearing any stale/expired lockout record found).
  Future<Duration?> _getLockoutRemaining(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_lockoutKey(email));
    if (until == null) return null;
    final remaining =
        DateTime.fromMillisecondsSinceEpoch(until).difference(DateTime.now());
    if (remaining <= Duration.zero) {
      await prefs.remove(_lockoutKey(email));
      await prefs.remove(_attemptsKey(email));
      return null;
    }
    return remaining;
  }

  /// Records one failed login attempt for [email]; once it reaches
  /// [_maxLoginAttempts], locks the account out for [_lockoutDuration] and
  /// resets the counter. Returns attempts remaining before lockout (or null
  /// if this attempt just triggered the lockout).
  Future<int?> _recordFailedLoginAttempt(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final attempts = (prefs.getInt(_attemptsKey(email)) ?? 0) + 1;
    if (attempts >= _maxLoginAttempts) {
      await prefs.setInt(_lockoutKey(email),
          DateTime.now().add(_lockoutDuration).millisecondsSinceEpoch);
      await prefs.setInt(_attemptsKey(email), 0);
      return null;
    }
    await prefs.setInt(_attemptsKey(email), attempts);
    return _maxLoginAttempts - attempts;
  }

  Future<void> _clearLoginAttempts(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_attemptsKey(email));
    await prefs.remove(_lockoutKey(email));
  }

  static String _formatLockoutRemaining(Duration d) {
    final minutes = d.inSeconds / 60;
    if (minutes <= 1) return 'less than a minute';
    return '${minutes.ceil()} minute${minutes.ceil() == 1 ? '' : 's'}';
  }

  /// Finishes signing [profile] into the app: caches it locally, syncs it to
  /// Firestore, loads the account's data, and starts the mesh if applicable.
  /// Shared by every path that reaches a fully-verified, approved account —
  /// [login], [completeApprovedSignIn] and [signInWithGoogle].
  Future<void> _completeSignIn(UserModel profile,
      {required String logMessage, Future<void> Function()? beforeLoad}) async {
    await _db.upsertUser(profile);
    unawaited(_firebaseSync.upsertUserProfile(profile));
    currentUser = profile;
    await _db.setSession(profile.id);
    if (beforeLoad != null) await beforeLoad();
    // Bring this account's vehicles back from the cloud BEFORE loading, so a
    // new phone or a reinstall shows them straight away instead of an empty
    // list. Bounded, so an offline login isn't held up.
    if (networkStatus != NetworkStatus.offline) {
      await _syncVehicles()
          .timeout(const Duration(seconds: 10), onTimeout: () {});
    }
    await _loadUserData();
    await _loadProfilePhoto(profile.id);
    await _addLog('AUTH', logMessage, LogType.ok);
    lastAuthError = null;
    pendingEmailVerification = null;
    notifyListeners();
    unawaited(_startMeshIfNeeded());
    unawaited(_startForegroundServiceIfNeeded());
    _startAlertFeed();
    _startSightingFeed();
    _startPresence();
    _startAccountWatch();
    _syncSoonIfOnline();
  }

  /// Local SQLite never verifies a password; it only caches the resulting
  /// profile for offline access (see DatabaseService.getUserById).
  Future<bool> login(String email, String password) async {
    final trimmedEmail = email.trim();
    registrationDecision = null;
    rejectionReason = null;

    final lockedFor = await _getLockoutRemaining(trimmedEmail);
    if (lockedFor != null) {
      lastAuthError =
          'Too many failed login attempts. Try again in ${_formatLockoutRemaining(lockedFor)}.';
      pendingEmailVerification = null;
      notifyListeners();
      return false;
    }

    final outcome =
        await _authSvc.login(email: trimmedEmail, password: password);

    if (!outcome.ok) {
      final remaining = await _recordFailedLoginAttempt(trimmedEmail);
      lastAuthError = remaining == null
          ? 'Too many failed login attempts. Your account is locked for ${_formatLockoutRemaining(_lockoutDuration)}.'
          : '${outcome.error} ($remaining attempt${remaining == 1 ? '' : 's'} remaining before temporary lockout.)';
      pendingEmailVerification = null;
      notifyListeners();
      return false;
    }
    await _clearLoginAttempts(trimmedEmail);

    final fbUser = outcome.user!;
    UserModel? profile = await _db.getUserById(fbUser.uid);
    profile ??= await _firebaseSync.fetchUserProfile(fbUser.uid);
    profile ??= UserModel(
      id: fbUser.uid,
      name:
          fbUser.displayName?.isNotEmpty == true ? fbUser.displayName! : 'User',
      email: fbUser.email ?? trimmedEmail,
      phone: '',
      deviceId: 'DEV-${_rng.nextInt(900) + 100}',
      createdAt: fbUser.metadata.creationTime,
    );

    // FR-01 / "for verification and security reasons": a Firebase account
    // whose email was never confirmed (registration abandoned before
    // clicking the verification link, or the link expired) has correct
    // credentials but is not a COMPLETE account. Block access here too —
    // not only at the moment of registration — so this can't be skipped by
    // simply logging in afterward instead of finishing verification.
    // Google sign-in accounts are exempt — Firebase marks a
    // Google-authenticated email as verified automatically (see
    // signInWithGoogle), so they never hit this gate at all.
    if (!fbUser.emailVerified) {
      pendingEmailVerification = trimmedEmail;
      lastAuthError = null;
      notifyListeners();
      return false;
    }

    // An admin-disabled account must be refused here too, not only kicked
    // out live once already signed in (see _startAccountWatch) — otherwise
    // a disabled account could still start a brand-new session.
    if (await _firebaseSync.isAccountDisabled(fbUser.uid)) {
      await _authSvc.signOut();
      lastAuthError =
          'This account has been disabled by an administrator. Contact support.';
      pendingEmailVerification = null;
      notifyListeners();
      return false;
    }

    if (!await _approvalGate(fbUser.uid)) return false;

    if (!await _licenseGate(
        fbUser.uid, profile, 'User logged in: ${profile.name}')) {
      return false;
    }
    await _completeSignIn(profile,
        logMessage: 'User logged in: ${profile.name}');
    return true;
  }

  /// Whether [uid]'s account may continue into the app. A pending account is
  /// signed out at once; a rejected one stays signed in so the person can be
  /// told why and the registration discarded (see discardRejectedRegistration).
  /// An unreadable status fails closed — approval can't be assumed.
  Future<bool> _approvalGate(String uid) async {
    final approval = await _firebaseSync.fetchApprovalStatus(uid);
    if (approval == null) {
      await _authSvc.signOut();
      lastAuthError =
          "We couldn't confirm your account's approval status. Check your internet connection and try again.";
      notifyListeners();
      return false;
    }
    if (approval.status == 'pending') {
      await _authSvc.signOut();
      registrationDecision = RegistrationDecision.pending;
      notifyListeners();
      return false;
    }
    if (approval.status == 'rejected') {
      registrationDecision = RegistrationDecision.rejected;
      rejectionReason = approval.reason;
      notifyListeners();
      return false;
    }
    return true;
  }

  /// Whether a restored session belongs to an account the admins haven't
  /// approved (or have rejected). False when the status can't be read right
  /// now — an approved account must still open the app offline.
  Future<bool> _approvalBlocksSession(String uid) async {
    final approval = await _firebaseSync.fetchApprovalStatus(uid);
    return approval?.status == 'pending' || approval?.status == 'rejected';
  }

  // ─── Driver's license verification ───
  /// Whether this account has both license photos on file. The answer is
  /// remembered on the device once true (photos are never removed by the
  /// account itself), so it only costs a network call the first time.
  Future<bool> _hasLicense(String uid, {bool assumeIfUnknown = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_licenseFlagPrefix$uid';
    if (prefs.getBool(key) == true) return true;
    try {
      final has = await _firebaseSync.hasLicense(uid);
      if (has) await prefs.setBool(key, true);
      return has;
    } catch (e) {
      if (assumeIfUnknown) return true;
      rethrow;
    }
  }

  /// True when sign-in may continue. When the license is missing, parks the
  /// profile and raises [pendingLicense] instead; when it can't be checked,
  /// signs out with an error (fail closed).
  Future<bool> _licenseGate(
      String uid, UserModel profile, String logMessage) async {
    final bool has;
    try {
      has = await _hasLicense(uid);
    } catch (e) {
      await _addLog(
          'AUTH', "Could not check driver's license status ($e)", LogType.err);
      await _authSvc.signOut();
      lastAuthError =
          "We couldn't check your driver's license verification. Check your internet connection and try again.";
      pendingLicense = false;
      notifyListeners();
      return false;
    }
    if (has) return true;
    pendingLicense = true;
    _pendingLicenseProfile = profile;
    _pendingLicenseLog = logMessage;
    lastAuthError = null;
    notifyListeners();
    return false;
  }

  /// Uploads the front and back photos for the signed-in account. Returns
  /// null on success, or a user-facing error.
  Future<String?> submitLicense(
      {required Uint8List front, required Uint8List back}) async {
    final uid = _authSvc.currentFirebaseUser?.uid;
    if (uid == null) return 'Please sign in again.';
    try {
      await _firebaseSync.uploadLicense(uid: uid, front: front, back: back);
    } catch (e) {
      await _addLog('AUTH', "Driver's license upload failed ($e)", LogType.err);
      return e.toString().contains('permission-denied')
          ? 'The server refused the upload. The latest Firestore rules must be published first.'
          : 'Could not upload your license photos. Check your internet connection and try again.';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_licenseFlagPrefix$uid', true);
    await _addLog('AUTH', "Driver's license photos submitted", LogType.ok);
    return null;
  }

  /// Finishes a sign-in that was waiting on the license photos.
  Future<void> completePendingSignIn() async {
    final profile = _pendingLicenseProfile;
    if (profile == null) return;
    final log = _pendingLicenseLog;
    _pendingLicenseProfile = null;
    pendingLicense = false;
    await _completeSignIn(profile, logMessage: log);
  }

  /// The person backed out of the license step — sign the half-finished
  /// session back out so nothing stays open without a license.
  Future<void> cancelPendingSignIn() async {
    _pendingLicenseProfile = null;
    pendingLicense = false;
    await _authSvc.signOut();
    notifyListeners();
  }

  /// Submits a brand-new account for admin approval. The sign-in is created
  /// first (Firebase needs it for the uid and to file the photos), then the
  /// license photos, the vehicle (plate claim, OR/CR photos and record), and
  /// only last the profile flagged 'pending' — so an account reaches the
  /// admins' queue only once everything it needs is on the server. Returns
  /// null on success, or the reason it couldn't be submitted; anything created
  /// so far is rolled back. The sign-in stays active on this phone so the
  /// Awaiting Approval screen hears the admin's decision live.
  ///
  /// The name check runs AFTER the sign-in exists, because Firestore's rules
  /// need `request.auth` to read the name registry (see FirebaseSyncService).
  Future<RegistrationResult> submitRegistration({
    required String name,
    required String email,
    required String phone,
    required String password,
    required Uint8List licenseFront,
    required Uint8List licenseBack,
    required VehicleDraft vehicle,
  }) async {
    final trimmedName = name.trim();
    final trimmedEmail = email.trim();
    if (trimmedName.isEmpty ||
        !isValidEmail(trimmedEmail) ||
        !hasAllowedRegistrationEmailDomain(trimmedEmail) ||
        password.length < 8) {
      return const RegistrationResult.failure(
          'Please check your details and try again.');
    }

    final outcome = await _authSvc.register(
        email: trimmedEmail, password: password, displayName: trimmedName);
    if (!outcome.ok) {
      return RegistrationResult.failure(outcome.error!,
          field: outcome.code == 'email-already-in-use'
              ? RegistrationIssueField.email
              : null);
    }
    final user = outcome.user!;
    final uid = user.uid;

    final normalizedName = normalizedFullName(trimmedName);
    try {
      if (await _firebaseSync.isNameTaken(normalizedName)) {
        await _authSvc.discardAccount(user);
        return RegistrationResult.failure(
            'An account is already registered under the name "$trimmedName". '
            'If this is you, log in instead; otherwise, use your full legal name to tell yourself apart from the existing account.',
            field: RegistrationIssueField.name);
      }
    } catch (_) {
      // Couldn't confirm either way — a real account already exists at this
      // point, so don't destroy it over a check that's best-effort by design.
    }

    final now = DateTime.now();
    final plateKey = normalizedPlate(vehicle.plate);
    final vehicleId = 'v${now.millisecondsSinceEpoch}';
    final profile = UserModel(
      id: uid,
      name: trimmedName,
      email: trimmedEmail,
      phone: phone.trim(),
      deviceId: 'DEV-${_rng.nextInt(900) + 100}',
      createdAt: user.metadata.creationTime ?? now,
    );
    final vehicleRecord = VehicleModel(
      id: vehicleId,
      ownerId: uid,
      plate: vehicle.plate,
      model: vehicle.model.trim(),
      color: vehicle.color.trim(),
      type: vehicle.type,
      yearModel: vehicle.yearModel.trim(),
      engineNumber: vehicle.engineNumber.trim(),
      chassisNumber: vehicle.chassisNumber.trim(),
      geofenceRadius: vehicle.geofence,
      deviceId: profile.deviceId,
      lat: kDefaultLat,
      lng: kDefaultLng,
      lastLocationUpdate: now,
      createdAt: now,
    );

    var plateClaimed = false;
    var vehicleSaved = false;
    try {
      final conflictOwner = await _firebaseSync.claimPlateIfAvailable(
        normalizedPlate: plateKey,
        plate: vehicle.plate,
        ownerId: uid,
        vehicleId: vehicleId,
      );
      if (conflictOwner != null) {
        await _authSvc.discardAccount(user);
        return RegistrationResult.failure(
            'This vehicle (${vehicle.plate}) is already registered to another account.');
      }
      plateClaimed = true;
      await _firebaseSync.uploadVehicleDocuments(
          uid: uid,
          vehicleId: vehicleId,
          or: vehicle.orPhoto,
          cr: vehicle.crPhoto);
      await _firebaseSync.upsertVehicle(uid, vehicleRecord);
      vehicleSaved = true;
      await _firebaseSync.uploadLicense(
          uid: uid, front: licenseFront, back: licenseBack);
      await _firebaseSync.submitProfileForApproval(profile);
    } catch (e) {
      await _addLog(
          'AUTH', 'Registration could not be submitted ($e)', LogType.err);
      if (vehicleSaved) {
        try {
          await _firebaseSync.deleteVehicle(uid, vehicleId);
        } catch (_) {}
      }
      if (plateClaimed) await _firebaseSync.releasePlate(plateKey);
      await _authSvc.discardAccount(user);
      return RegistrationResult.failure(e
              .toString()
              .contains('permission-denied')
          ? 'The server refused the registration. The latest Firestore rules must be published first.'
          : 'Could not submit your registration. Check your internet connection and try again.');
    }
    await _firebaseSync.claimName(normalizedName, trimmedName, uid);
    await _addLog('AUTH', 'Registration submitted for approval: $trimmedName',
        LogType.ok);
    return const RegistrationResult.success();
  }

  /// Email of the account waiting on approval, shown on the Awaiting screen.
  String? get pendingRegistrationEmail => _authSvc.currentFirebaseUser?.email;

  /// The signed-in account's approval state, live — the Awaiting Approval
  /// screen listens to this so an admin's decision reaches the phone without
  /// a relaunch. Null when no account is signed in on this phone.
  Stream<({String? status, String? reason})>? watchOwnApproval() {
    final uid = _authSvc.currentFirebaseUser?.uid;
    return uid == null ? null : _firebaseSync.watchApprovalStatus(uid);
  }

  /// Signs in an account the admins just approved. Approval alone isn't
  /// enough — its email must be verified too. Returns false (signing nothing
  /// in) while either is still missing.
  Future<bool> completeApprovedSignIn() async {
    final fbUser = _authSvc.currentFirebaseUser;
    if (fbUser == null) return false;
    if (!await _authSvc.checkEmailVerified()) return false;
    UserModel? profile = await _db.getUserById(fbUser.uid);
    profile ??= await _firebaseSync.fetchUserProfile(fbUser.uid);
    if (profile == null) return false;
    if (!await _licenseGate(
        fbUser.uid, profile, 'User logged in: ${profile.name}')) {
      return false;
    }
    await _completeSignIn(profile,
        logMessage: 'Account approved — signed in: ${profile.name}');
    return true;
  }

  /// Ends a rejected registration by deleting the sign-in it created, which
  /// frees the email so the person can register again from scratch. Returns
  /// false when Firebase refused the delete (see FirebaseAuthService.discardAccount).
  Future<bool> discardRejectedRegistration() async {
    final fbUser = _authSvc.currentFirebaseUser;
    registrationDecision = null;
    rejectionReason = null;
    final freed = fbUser == null || await _authSvc.discardAccount(fbUser);
    notifyListeners();
    return freed;
  }

  /// Leaves the Awaiting Approval screen. The account stays pending and is
  /// reviewed as usual; it just stops being signed in on this phone.
  Future<void> leaveAwaitingApproval() async {
    await _authSvc.signOut();
    notifyListeners();
  }

  /// Sends a Firebase password-reset email. Returns null on success, or a
  /// user-facing error message on failure.
  Future<String?> sendPasswordResetEmail(String email) =>
      _authSvc.sendPasswordReset(email);

  /// FR-01 email verification — confirms the registrant actually controls
  /// the email address before registration is considered complete. Free on
  /// Firebase's no-cost Spark plan (unlike SMS OTP, which requires the paid
  /// Blaze plan) — the free replacement described in the manuscript update.
  /// Thin passthrough to FirebaseAuthService, kept here so screens only
  /// ever talk to AppState, matching every other service in this app.
  Future<String?> resendVerificationEmail() =>
      _authSvc.resendEmailVerification();

  /// Reloads the current Firebase user and reports whether their email is
  /// now verified — call after the user says they've clicked the link in
  /// their inbox.
  Future<bool> checkEmailVerified() => _authSvc.checkEmailVerified();

  /// Set (to the Google account's email) when the last [signInWithGoogle]
  /// was refused because that email was never registered through the app —
  /// the Login screen shows a "not registered" modal for it.
  String? googleRejectedEmail;

  /// Logs in with a Google account that is ALREADY registered through the
  /// Register form — Google is a login shortcut here, never a way to create
  /// an account. Firebase itself auto-creates an account for any Google email
  /// it hasn't seen, so the result is checked: an account without the
  /// email/password provider was never registered in the app and is refused
  /// (and the auto-created account deleted). A Google-authenticated email is
  /// already verified by Google, so a registered account signs straight in.
  Future<bool> signInWithGoogle() async {
    googleRejectedEmail = null;
    registrationDecision = null;
    rejectionReason = null;
    final outcome = await _authSvc.signInWithGoogle();
    if (!outcome.ok) {
      // An empty error string means the user simply closed the account
      // picker — not a real failure worth surfacing as an error message.
      if (outcome.error != null && outcome.error!.isNotEmpty) {
        lastAuthError = outcome.error;
        notifyListeners();
      }
      return false;
    }

    final fbUser = outcome.user!;
    if (!_authSvc.isRegisteredAccount(fbUser)) {
      googleRejectedEmail = fbUser.email ?? 'This Google account';
      lastAuthError = null;
      await _authSvc.discardAccount(fbUser);
      await _addLog(
          'AUTH',
          'Google sign-in refused — $googleRejectedEmail is not registered',
          LogType.warn);
      notifyListeners();
      return false;
    }

    if (await _firebaseSync.isAccountDisabled(fbUser.uid)) {
      lastAuthError =
          'This account has been disabled by an administrator. Contact support.';
      await _authSvc.signOut();
      notifyListeners();
      return false;
    }

    if (!await _approvalGate(fbUser.uid)) return false;

    UserModel? profile = await _db.getUserById(fbUser.uid);
    profile ??= await _firebaseSync.fetchUserProfile(fbUser.uid);
    profile ??= UserModel(
      id: fbUser.uid,
      name:
          fbUser.displayName?.isNotEmpty == true ? fbUser.displayName! : 'User',
      email: fbUser.email ?? '',
      phone: '',
      deviceId: 'DEV-${_rng.nextInt(900) + 100}',
      createdAt: fbUser.metadata.creationTime,
    );

    if (!await _licenseGate(
        fbUser.uid, profile, 'User logged in via Google: ${profile.name}')) {
      return false;
    }
    await _completeSignIn(profile,
        logMessage: 'User logged in via Google: ${profile.name}');
    return true;
  }

  Future<void> logout() async {
    await _addLog('AUTH', 'User logged out', LogType.info);
    await _authSvc.signOut();
    await _db.clearSession();
    _firebaseSync.stopAlertFeed();
    _firebaseSync.stopSightingFeed();
    _firebaseSync.stopAccountWatch();
    // Take this phone off other people's nearby list while still signed in
    // (the presence document can only be deleted by its owner).
    await _stopPresence();
    await _mesh.stop();
    _handoffTimer?.cancel();
    _handoffTimer = null;
    _meshHandedOff = false;
    if (_foregroundServiceStarted || await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
      _foregroundServiceStarted = false;
    }
    nodes.removeWhere((n) => !n.isSimulated);
    profilePhotoBytes = null;
    currentUser = null;
    _vehicles.clear();
    _alerts.clear();
    _sightings.clear();
    _seenSightingIds.clear();
    notifications.clear();
    locationHistory.clear();
    notifyListeners();
  }

  /// Updates the current user's name and/or phone number. Email is
  /// intentionally not editable here — it's the login identifier and has a
  /// UNIQUE constraint in the local database, so changing it would need
  /// its own dedicated re-verification flow rather than a quick edit.
  /// Saves the profile. Returns null on success, or a user-facing error.
  ///
  /// The mobile number is what a vehicle owner uses to reach someone who
  /// reported a sighting, so it is required and format-checked, and CHANGING
  /// it needs the account password ([currentPassword]) — someone holding an
  /// unlocked phone shouldn't be able to quietly swap it. A change is also
  /// logged and announced in Notifications, so it never happens silently.
  Future<String?> updateProfile(
      {required String name,
      required String phone,
      String? currentPassword}) async {
    final me = currentUser;
    if (me == null) return 'Please sign in again.';
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return 'Name cannot be empty.';
    final phoneError = validatePhMobile(phone);
    if (phoneError != null) return phoneError;

    final phoneChanged =
        canonicalPhMobile(phone) != canonicalPhMobile(me.phone);
    if (phoneChanged) {
      if (currentPassword == null || currentPassword.isEmpty) {
        return 'Enter your current password to change your mobile number.';
      }
      final authError = await _authSvc.reauthenticate(currentPassword);
      if (authError != null) return authError;
    }

    final updated = UserModel(
      id: me.id,
      name: trimmedName,
      email: me.email,
      phone: phone.trim(),
      role: me.role,
      deviceId: me.deviceId,
      // Preserved, not reset — this is an edit to an existing account, and
      // the Admin Dashboard's "Date Created" column must keep showing when
      // it was actually registered, not the moment it was last edited.
      createdAt: me.createdAt,
    );
    await _db.upsertUser(updated);
    unawaited(_firebaseSync.upsertUserProfile(updated));
    final fbUser = _authSvc.currentFirebaseUser;
    if (fbUser != null) unawaited(fbUser.updateDisplayName(trimmedName));
    currentUser = updated;
    await _addLog(
        'AUTH',
        phoneChanged
            ? 'Profile updated (mobile number changed)'
            : 'Profile updated',
        phoneChanged ? LogType.warn : LogType.ok);
    if (phoneChanged) {
      await _addNotif(
          'Mobile Number Changed',
          'Your contact number is now ${updated.phone}. If you did not do this, change your password right away.',
          NotifType.info);
    }
    notifyListeners();
    return null;
  }

  // ──────────────────────────────────────────
  // VEHICLE
  // ──────────────────────────────────────────
  // Canonical form of a plate used as the uniqueness key, both cross-account
  // (see addVehicle/removeVehicle and FirebaseSyncService's plates registry)
  // and within the SAME account (see the duplicate check in addVehicle) —
  // "ABC-123", "ABC 123", and "ABC123" must all collide as the same
  // real-world plate, while the plate as actually stored/displayed on the
  // vehicle keeps whatever formatting the owner typed. Delegates to the
  // shared `normalizedPlate()` in validators.dart, which the vehicle
  // registration screen also uses to compare a plate read off the OR
  // against one read off the CR — one definition of "same plate", used
  // everywhere that matters.
  String _normalizedPlateKey(String plate) => normalizedPlate(plate);

  /// Registers a new vehicle for the signed-in owner. Returns null on
  /// success, or a user-facing error message. Two duplicate checks run
  /// before anything is created: [claimPlateIfAvailable] blocks a DIFFERENT
  /// account from claiming a plate this owner (or anyone else) already has;
  /// the check just below blocks THIS SAME owner from registering a plate
  /// they already have a second time — without it, resubmitting the form
  /// (or registering the same real vehicle again by mistake) silently
  /// created a second, third, … entry for the identical plate, each with its
  /// own OR/CR, since re-claiming a plate you already own was never treated
  /// as a conflict. The uniqueness check needs a live connection — there's
  /// no way to know what OTHER accounts have already registered while
  /// offline — the same requirement account registration already has, for
  /// the same reason (see FirebaseAuthService/register()).
  ///
  /// The vehicle's OR (Official Receipt) and CR (Certificate of Registration)
  /// photos are required and are filed with it; if they can't be uploaded, the
  /// plate claim is given back and nothing is registered.
  Future<String?> addVehicle(
      String plate,
      String model,
      String color,
      String type,
      String yearModel,
      String engineNumber,
      String chassisNumber,
      double geofence,
      {required Uint8List orPhoto,
      required Uint8List crPhoto}) async {
    final trimmedPlate = plate.trim().toUpperCase();
    final normalizedPlate = _normalizedPlateKey(trimmedPlate);

    if (_vehicles.any((v) => _normalizedPlateKey(v.plate) == normalizedPlate)) {
      return 'You already have a vehicle registered with plate $trimmedPlate. Each vehicle can only be registered once.';
    }

    final id = 'v${DateTime.now().millisecondsSinceEpoch}';

    String? conflictOwner;
    try {
      conflictOwner = await _firebaseSync.claimPlateIfAvailable(
        normalizedPlate: normalizedPlate,
        plate: trimmedPlate,
        ownerId: currentUser!.id,
        vehicleId: id,
      );
    } catch (_) {
      return 'Could not verify this plate number. Check your internet connection and try again.';
    }
    if (conflictOwner != null) {
      return 'This vehicle ($trimmedPlate) is already registered to another account.';
    }

    try {
      await _firebaseSync.uploadVehicleDocuments(
          uid: currentUser!.id, vehicleId: id, or: orPhoto, cr: crPhoto);
    } catch (e) {
      await _firebaseSync.releasePlate(normalizedPlate);
      await _addLog(
          'VEHICLE', 'OR/CR upload failed for $trimmedPlate ($e)', LogType.err);
      return e.toString().contains('permission-denied')
          ? 'The server refused the OR/CR upload. The latest Firestore rules must be published first.'
          : 'Could not upload the OR/CR photos. Check your internet connection and try again.';
    }

    final v = VehicleModel(
      id: id,
      ownerId: currentUser!.id,
      plate: trimmedPlate,
      model: model.trim(),
      color: color.trim(),
      type: type,
      yearModel: yearModel.trim(),
      engineNumber: engineNumber.trim(),
      chassisNumber: chassisNumber.trim(),
      geofenceRadius: geofence,
      deviceId: currentUser!.deviceId,
      lat: currentLat ?? kDefaultLat,
      lng: currentLng ?? kDefaultLng,
      lastLocationUpdate: DateTime.now(),
      createdAt: DateTime.now(),
    );
    _vehicles.add(v);
    await _db.upsertVehicle(v);
    _pushVehicle(v);
    await _addLog('VEHICLE', 'Registered: ${v.plate} — ${v.model}', LogType.ok);
    notifyListeners();
    return null;
  }

  Future<void> removeVehicle(String id) async {
    final uid = currentUser?.id;
    final removed = _vehicles.where((v) => v.id == id).toList();
    _vehicles.removeWhere((v) => v.id == id);
    await _db.deleteVehicle(id);
    // The one and only way a vehicle is meant to go away: the owner removes
    // it. Remembered until the cloud copy is gone too, so it can't come back.
    // Its plate claim is remembered and released the same way, so a plate
    // stays blocked for other accounts only for as long as the vehicle
    // itself is actually still registered.
    if (uid != null) {
      final normalizedPlate =
          removed.isNotEmpty ? _normalizedPlateKey(removed.first.plate) : '';
      await _forgetVehicleInCloud(uid, id, normalizedPlate);
    }
    await _addLog('VEHICLE', 'Vehicle removed', LogType.warn);
    notifyListeners();
  }

  // ── Vehicle cloud backup ───────────────────────────────────────────
  // Vehicles used to be saved ONLY in this phone's local database, keyed by
  // the account's ID — so logging into the same account on another phone, or
  // after a reinstall / cleared app data, showed no vehicle and forced the
  // user to register it again. They're now also saved to Firestore under the
  // owner (/users/{uid}/vehicles) and restored on login; only the owner
  // removing a vehicle deletes it.
  bool _vehicleSyncRunning = false;
  bool _vehicleSyncWarned = false;

  static const String _pendingVehicleDeletesKey = 'pending_vehicle_deletes';
  String _knownSyncedKey(String uid) => 'synced_vehicles_$uid';

  Future<Set<String>> _readIdSet(String key) async {
    final raw = await _db.getPref(key) ?? '';
    return raw.split(',').where((s) => s.isNotEmpty).toSet();
  }

  Future<void> _writeIdSet(String key, Set<String> ids) =>
      _db.setPref(key, ids.join(','));

  /// Best-effort push of one vehicle right after it changes. If it fails
  /// (offline, rules), the next full [_syncVehicles] pushes it anyway.
  void _pushVehicle(VehicleModel v) {
    _firebaseSync.upsertVehicle(v.ownerId, v).then((_) async {
      final known = await _readIdSet(_knownSyncedKey(v.ownerId));
      if (known.add(v.id)) await _writeIdSet(_knownSyncedKey(v.ownerId), known);
    }).catchError((_) {});
  }

  /// [normalizedPlate] may be empty (defensively — should never happen in
  /// practice) if the vehicle was already gone from [_vehicles] by the time
  /// this ran; the plate-release step is then just skipped for that entry.
  Future<void> _forgetVehicleInCloud(
      String uid, String vehicleId, String normalizedPlate) async {
    final known = await _readIdSet(_knownSyncedKey(uid));
    if (known.remove(vehicleId)) await _writeIdSet(_knownSyncedKey(uid), known);
    final pending = await _readIdSet(_pendingVehicleDeletesKey);
    pending.add('$uid|$vehicleId|$normalizedPlate');
    await _writeIdSet(_pendingVehicleDeletesKey, pending);
    unawaited(_syncVehicles());
  }

  /// Reconciles this phone's vehicles with the cloud for the signed-in user:
  ///  1. finishes cloud deletions the owner made (possibly while offline);
  ///  2. restores vehicles the cloud has but this phone doesn't (new phone,
  ///     reinstall);
  ///  3. drops a local vehicle the owner deleted on ANOTHER device;
  ///  4. uploads everything else, so the cloud always has a current copy.
  Future<void> _syncVehicles() async {
    final user = currentUser;
    if (user == null || _vehicleSyncRunning) return;
    _vehicleSyncRunning = true;
    try {
      // 1. Pending deletions for this user. Entry format is
      // 'uid|vehicleId|normalizedPlate' — the plate segment may be absent
      // on an entry written before plate release existed, handled below by
      // just skipping that step for it.
      final pending = await _readIdSet(_pendingVehicleDeletesKey);
      final mine = pending.where((e) => e.startsWith('${user.id}|')).toList();
      final deletedIds = <String>{};
      for (final e in mine) {
        final parts = e.substring(user.id.length + 1).split('|');
        final vehicleId = parts[0];
        final normalizedPlate =
            parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
        deletedIds.add(vehicleId);
        try {
          await _firebaseSync.deleteVehicle(user.id, vehicleId);
          if (normalizedPlate != null) {
            await _firebaseSync.releasePlate(normalizedPlate);
          }
          pending.remove(e);
        } catch (_) {}
      }
      await _writeIdSet(_pendingVehicleDeletesKey, pending);

      // Throws if the cloud can't be reached — nothing below runs then.
      final cloud = await _firebaseSync.fetchVehicles(user.id);
      final cloudIds = cloud.map((v) => v.id).toSet();
      final local = await _db.getVehiclesForOwner(user.id);
      final localIds = local.map((v) => v.id).toSet();
      final known = await _readIdSet(_knownSyncedKey(user.id));
      var changedLocally = false;

      for (final v in local) {
        if (!cloudIds.contains(v.id) &&
            known.contains(v.id) &&
            !deletedIds.contains(v.id)) {
          // Was in the cloud before, now gone: the owner removed it elsewhere.
          await _db.deleteVehicle(v.id);
          known.remove(v.id);
          changedLocally = true;
        } else if (!deletedIds.contains(v.id)) {
          await _firebaseSync.upsertVehicle(user.id, v);
          known.add(v.id);
        }
      }
      for (final v in cloud) {
        if (localIds.contains(v.id) || deletedIds.contains(v.id)) continue;
        await _db.upsertVehicle(v);
        known.add(v.id);
        changedLocally = true;
        await _addLog(
            'VEHICLE', 'Restored ${v.plate} from your account', LogType.ok);
      }
      await _writeIdSet(_knownSyncedKey(user.id), known);

      if (changedLocally && currentUser?.id == user.id) {
        _vehicles
          ..clear()
          ..addAll(await _db.getVehiclesForOwner(user.id));
        notifyListeners();
      }
      _vehicleSyncWarned = false;
    } catch (e) {
      // Local vehicles keep working; report once instead of on every retry.
      if (!_vehicleSyncWarned && networkStatus != NetworkStatus.offline) {
        _vehicleSyncWarned = true;
        await _addLog(
            'VEHICLE',
            'Vehicle cloud backup unavailable ($e). If this says permission-denied, add the users/{uid}/vehicles rule in Firestore.',
            LogType.warn);
      }
    } finally {
      _vehicleSyncRunning = false;
    }
  }

  /// Sets the geofence for [id]. [centerLat]/[centerLng] default to the
  /// device's current real GPS position when not supplied (manual override
  /// is still possible via the optional params) — boundary is set manually,
  /// violation detection then runs automatically.
  Future<void> setVehicleGeofence(String id, double radius,
      {bool active = true, double? centerLat, double? centerLng}) async {
    final vi = _vehicles.indexWhere((v) => v.id == id);
    if (vi == -1) return;
    final v = _vehicles[vi];
    v.geofenceRadius = radius;
    v.geofenceActive = active;
    v.geofenceCenterLat = centerLat ?? currentLat ?? v.lat;
    v.geofenceCenterLng = centerLng ?? currentLng ?? v.lng;
    _geofenceWarned.remove(id);
    _geofenceNearWarned.remove(id);
    await _db.upsertVehicle(v);
    _pushVehicle(v);
    await _addLog(
        'GEOFENCE',
        'Geofence set to ${radius.toInt()}m for ${v.plate} (${active ? "armed" : "inactive"})',
        LogType.info);
    notifyListeners();
  }

  /// Turns monitoring OFF for [id] without touching anything else about
  /// it — the configured radius and center are kept exactly as they were,
  /// so re-arming later (e.g. the next time the vehicle is parked
  /// somewhere) is a single tap on "Reactivate Geofence" rather than
  /// having to set the whole safe zone up again from scratch.
  ///
  /// This is the deliberate alternative to [removeVehicle] for "I'm not
  /// monitoring right now" — until this existed, turning geofence
  /// monitoring off required deleting the vehicle entirely (its only
  /// "off switch" was Remove), which also erased the registration itself.
  /// A returning owner who's about to drive the car again shouldn't have
  /// to re-register it just to stop yesterday's safe zone from watching.
  Future<void> deactivateGeofence(String id) async {
    final vi = _vehicles.indexWhere((v) => v.id == id);
    if (vi == -1) return;
    final v = _vehicles[vi];
    await setVehicleGeofence(id, v.geofenceRadius,
        active: false,
        centerLat: v.geofenceCenterLat,
        centerLng: v.geofenceCenterLng);
  }

  // ──────────────────────────────────────────
  // GEOFENCE VIOLATION DETECTION (automatic, foreground)
  // ──────────────────────────────────────────
  // How close to the boundary (while still inside it) counts as "almost
  // outside" — the early-warning modal fires in this band, once, until the
  // device either returns well inside or actually crosses the boundary.
  static const double _geofenceNearMarginMeters = 20;
  final Set<String> _geofenceNearWarned = {};

  bool _geofenceCheckRunning = false;

  /// Asks for a FRESH GPS fix and then checks geofences against it, instead
  /// of trusting whatever `currentLat`/`currentLng` the passive location
  /// stream last happened to deliver. Root cause of geofence violations
  /// never firing: that stream only updates on its own schedule (roughly
  /// every 10 m of movement) and can silently stop altogether once Android
  /// throttles a backgrounded/screen-off app — either way, this timer used
  /// to keep re-checking a position that had stopped changing, so walking
  /// the phone outside the safe zone did nothing. Runs every 15 s and skips
  /// a tick if the previous one is still in flight (a fix can take a few
  /// seconds), and does nothing at all when no vehicle actually has an
  /// active geofence, so it isn't polling GPS for no reason.
  Future<void> _checkGeofencesFresh() async {
    if (!monitoringArmed || _geofenceCheckRunning) return;
    if (!_vehicles
        .any((v) => v.geofenceActive && v.status == VehicleStatus.active)) {
      return;
    }
    _geofenceCheckRunning = true;
    try {
      final pos = await _loc.getCurrentPosition();
      if (pos != null) {
        currentLat = pos.latitude;
        currentLng = pos.longitude;
        currentAccuracy = pos.accuracy;
        lastGpsUpdate = DateTime.now();
        gpsStatus = GpsStatus.available;
        notifyListeners();
      }
    } finally {
      _geofenceCheckRunning = false;
    }
    _checkGeofences();
  }

  void _checkGeofences() {
    if (!monitoringArmed) return;
    if (currentLat == null || currentLng == null) return;
    for (final v in _vehicles) {
      if (!v.geofenceActive) continue;
      if (v.status != VehicleStatus.active) continue;
      if (v.geofenceCenterLat == null || v.geofenceCenterLng == null) continue;
      final dist = LocationService.distanceMeters(
        v.geofenceCenterLat!,
        v.geofenceCenterLng!,
        currentLat!,
        currentLng!,
      );
      if (dist > v.geofenceRadius) {
        _geofenceNearWarned.remove(v.id);
        if (_geofenceWarned.contains(v.id)) continue;
        _geofenceWarned.add(v.id);
        _addLog(
            'GEOFENCE',
            '⚠ Boundary violation: ${v.plate} is ${dist.toInt()}m from safe zone (limit ${v.geofenceRadius.toInt()}m)',
            LogType.warn);
        // Unlike the manual Report Stolen flow (which runs inside a
        // try/catch and shows an error modal on failure), this automatic
        // report has no caller watching its result — a failure here (e.g.
        // a local database write error) must not vanish silently, since
        // this is the one path whose whole job is catching a real theft
        // automatically.
        unawaited(() async {
          try {
            await reportStolen(v.id,
                'Automatic geofence boundary violation. Device moved ${dist.toInt()}m from the configured safe zone.',
                trigger: AlertTrigger.geofenceViolation);
          } catch (e) {
            await _addLog(
                'GEOFENCE',
                'Automatic theft report for ${v.plate} failed: $e',
                LogType.err);
          }
        }());
      } else {
        _geofenceWarned.remove(v.id);
        final margin = v.geofenceRadius - dist;
        if (margin <= _geofenceNearMarginMeters) {
          if (!_geofenceNearWarned.contains(v.id)) {
            _geofenceNearWarned.add(v.id);
            _addLog(
                'GEOFENCE',
                '${v.plate} is ${margin.toInt()}m from leaving its safe zone',
                LogType.warn);
            _addNotif(
                '⚠ Approaching Safe Zone Boundary',
                '${v.plate} is about ${margin.toInt()}m from leaving its configured safe zone.',
                NotifType.geofence);
            geofenceNearWarningVehicle = v;
            geofenceNearWarningMargin = margin;
            geofenceNearWarningSeq++;
            notifyListeners();
          }
        } else {
          _geofenceNearWarned.remove(v.id);
        }
      }
    }
  }

  /// The vehicle currently inside its geofence but within
  /// [_geofenceNearMarginMeters] of the boundary, and how close — the UI
  /// shows a one-time "almost outside" warning modal for it, keyed off
  /// [geofenceNearWarningSeq] the same way [incomingAlertSeq] drives the
  /// "Stolen Vehicle Nearby" popup.
  VehicleModel? geofenceNearWarningVehicle;
  double? geofenceNearWarningMargin;
  int geofenceNearWarningSeq = 0;

  // ──────────────────────────────────────────
  // THEFT ALERT
  // ──────────────────────────────────────────
  ///
  /// Throws [StateError] if [vehicleId] is no longer registered — e.g. it was
  /// removed from another device between this screen opening and the report
  /// being confirmed — or if it's already reported stolen. The caller shows
  /// an error modal for either case instead of letting a raw exception crash
  /// the screen.
  ///
  /// One vehicle can only have ONE active theft report at a time, enforced
  /// here regardless of [trigger] — this is the single place both the
  /// manual Report Stolen screen and the automatic geofence-violation check
  /// go through, so one guard covers both. (`_checkGeofences` already skips
  /// a vehicle whose status isn't `active` before it would even get here —
  /// this is the backstop that makes the rule a real guarantee rather than
  /// something only one of the two callers happens to respect. A second
  /// registered vehicle is unaffected: the check is per-vehicle, not
  /// per-account.) Once the owner marks it recovered — see
  /// [markRecovered] — the vehicle's status returns to `active` and it can
  /// be reported again if it's ever stolen a second time.
  Future<TheftAlert> reportStolen(String vehicleId, String notes,
      {AlertTrigger trigger = AlertTrigger.manualReport,
      List<Uint8List> photoBytes = const []}) async {
    // Up to 3 photos, travelling inside ONE Firestore document (1 MB limit)
    // together with everything else on the alert — ReportStolenScreen's own,
    // tighter per-photo cap (see its _maxEvidencePhotoBytes) is what keeps 3
    // of these combined safely under that limit; this method just encodes
    // whatever it's given. Empty for an automatic geofence-violation report,
    // which has no form for the owner to attach a photo to.
    final photos = [for (final bytes in photoBytes) base64Encode(bytes)];
    final vi = _vehicles.indexWhere((v) => v.id == vehicleId);
    if (vi == -1) {
      throw StateError('This vehicle is no longer registered on this account.');
    }
    final v = _vehicles[vi];
    if (v.status == VehicleStatus.stolen) {
      throw StateError(
          '${v.plate} is already reported stolen. Mark it as recovered first if you want to report it again.');
    }

    double lat;
    double lng;
    bool isDemo;
    if (currentLat != null && currentLng != null) {
      lat = currentLat!;
      lng = currentLng!;
      isDemo = false;
    } else {
      // Only reached if GPS is genuinely unavailable — clearly labeled so
      // it is never mistaken for a real fix (prompt §4 & §29).
      lat = v.lat;
      lng = v.lng;
      isDemo = true;
    }

    final alert = TheftAlert(
      id: 'ALT-${currentUser!.deviceId}-${DateTime.now().millisecondsSinceEpoch}',
      vehicleId: vehicleId,
      userId: currentUser!.id,
      plate: v.plate,
      model: v.model,
      color: v.color,
      engineNumber: v.engineNumber,
      chassisNumber: v.chassisNumber,
      lat: lat,
      lng: lng,
      timestamp: DateTime.now(),
      trigger: trigger,
      notes: notes,
      photos: photos,
      isDemoLocation: isDemo,
    );
    // The alert is written FIRST, before the vehicle flips to `stolen` — if
    // something interrupts this method partway (app killed, a DB write
    // failing), the worst case is an alert with no stolen vehicle to match
    // (already a tolerated state — see markRecovered's own comment), never
    // the other way around: a vehicle stuck `stolen` with no alert to close
    // it, which the owner would otherwise have no way to recover from.
    _alerts.insert(0, alert);
    await _db.upsertAlert(alert, synced: false);
    v.status = VehicleStatus.stolen;
    await _db.upsertVehicle(v);
    _pushVehicle(v);

    final locRecord = LocationRecord(
        vehicleId: vehicleId,
        lat: lat,
        lng: lng,
        time: DateTime.now(),
        synced: false);
    locationHistory.insert(0, locRecord);
    await _db.addLocation(locRecord);

    final triggerText = trigger == AlertTrigger.geofenceViolation
        ? 'Geofence violation'
        : 'Manual report';
    await _addLog(
        'ALERT',
        '🚨 THEFT ALERT: ${v.plate} reported stolen ($triggerText)',
        LogType.err);
    await _addNotif(
        '🚨 Stolen Vehicle Alert',
        '${v.plate} — ${v.model} alert created and broadcasting to nearby nodes.',
        NotifType.stolen);
    await _notif.show('🚨 Stolen Vehicle Alert',
        '${v.plate} — ${v.model} has been reported stolen.');

    if (trigger == AlertTrigger.geofenceViolation) {
      await _addNotif(
          '📍 Geofence Violation Detected!',
          '${v.plate} moved outside its configured safe zone.',
          NotifType.geofence);
      await _notif.show('📍 Geofence Violation',
          '${v.plate} has moved outside its safe zone.');
    }

    notifyListeners();

    // Fire-and-forget relay so the UI (broadcasting screen) can subscribe
    // to node state changes via notifyListeners as it progresses.
    unawaited(_broadcastAlertReal(alert));

    // A theft alert is high-priority data — don't wait for the next
    // connectivity transition to sync it if we're already online right now.
    _syncSoonIfOnline();

    return alert;
  }

  /// Returns the set of endpoint ids the write actually succeeded to (NOT
  /// confirmed delivery — see the comment below) so [forceRelayAlert] can
  /// report back how many peers were reached.
  Future<Set<String>> _broadcastAlertReal(TheftAlert alert) async {
    final stopwatch = Stopwatch()..start();
    final message = alertWireMessage(alert);

    if (_mesh.connectedEndpoints.isEmpty) {
      await _addLog(
          'RELAY',
          'No connected peers right now — alert is stored locally and will relay automatically once a nearby device connects (store-carry-forward).',
          LogType.warn);
      alertDelay = 0;
      transmissionRate = 0;
      notifyListeners();
      return {};
    }

    final sentTo = await _mesh.broadcast(message);
    for (final entry in _mesh.connectedEndpoints.entries) {
      final node = nodes.firstWhere(
        (n) => n.endpointId == entry.key,
        orElse: () => AdHocNode(
            id: entry.key,
            name: entry.value,
            distance: -1,
            mapX: 0.5,
            mapY: 0.5,
            isSimulated: false),
      );
      // A successful write here only proves the bytes left this device —
      // it does NOT mean the peer actually stored the alert. "Relayed"/
      // "received" (relayedTo, totalRelayed, RelayStatus.received, the
      // notification) are only set once that peer's own alert_ack confirms
      // it — see _onAlertAcked. Conflating a socket write with a confirmed
      // delivery is exactly the false-success reporting that made earlier
      // bugs hard to diagnose from the UI alone.
      if (sentTo.contains(entry.key)) {
        node.relayStatus = RelayStatus.relaying;
        await _addLog(
            'RELAY',
            'Alert ${alert.id} sent to ${entry.value} (real mesh) — awaiting delivery confirmation.',
            LogType.relay);
        _warnIfAlertNeverAcked(alert, entry.key, entry.value);
      } else {
        await _addLog(
            'RELAY',
            'Failed to relay alert ${alert.id} to ${entry.value} — no active socket for this connection.',
            LogType.err);
      }
    }
    await _db.upsertAlert(alert, synced: false);
    stopwatch.stop();
    alertDelay = stopwatch.elapsedMilliseconds;
    transmissionRate = 100;
    notifyListeners();
    return sentTo;
  }

  /// Manual safety-net relay, in addition to the automatic store-carry-
  /// forward relay that already fires the instant an alert is first
  /// received or a new peer connects. Lets a user explicitly re-attempt
  /// sending an alert they already have to whoever is currently connected
  /// — e.g. if the automatic relay to a specific nearby device hasn't
  /// happened yet. Reuses the exact same send/ack-tracking/logging path as
  /// a fresh report (`_broadcastAlertReal`) rather than a second
  /// implementation, so it's held to the same "write succeeded ≠ confirmed
  /// delivered" honesty the automatic path already has.
  ///
  /// Returns the number of currently-connected peers the write succeeded
  /// to, or null if no alert with [alertId] is known on this device.
  Future<int?> forceRelayAlert(String alertId) async {
    final idx = _alerts.indexWhere((a) => a.id == alertId);
    if (idx == -1) return null;
    final alert = _alerts[idx];
    await _addLog(
        'RELAY',
        '🔁 Manual force-relay requested for ${alert.plate} alert '
            '(${alert.id})',
        LogType.relay);
    final sentTo = await _broadcastAlertReal(alert);
    return sentTo.length;
  }

  // 12s was calibrated for the old TCP-socket transport, where an ack went
  // back over the same already-open connection almost instantly. On the
  // real BLE GATT transport, sending the ack back is its own brand-new
  // connectGatt() round trip (see alert_ingest.dart's alert_ack comment).
  // BleGattClient's own per-attempt timeout and VigilinkMeshTransportPlugin's
  // GATT_MAX_ATTEMPTS/GATT_RETRY_GAP_MS were both raised after real-device
  // testing kept failing even at the previous (already-raised) budget —
  // worst case across all retries there is now ~190s. Kept with headroom
  // above that worst case so this warning doesn't fire on a normal, still-
  // in-progress BLE round trip.
  static const Duration _alertAckTimeout = Duration(seconds: 210);

  /// A socket write succeeding is not proof of delivery — only the peer's
  /// own alert_ack is. If none arrives within [_alertAckTimeout], this logs
  /// it plainly instead of leaving the alert silently stuck on "awaiting
  /// confirmation" with no signal that something is actually wrong.
  void _warnIfAlertNeverAcked(
      TheftAlert alert, String endpointId, String peerName) {
    Timer(_alertAckTimeout, () {
      if (alert.relayedTo.contains(endpointId)) return; // confirmed meanwhile
      unawaited(_addLog(
          'RELAY',
          'No delivery confirmation from $peerName for alert ${alert.id} within ${_alertAckTimeout.inSeconds}s — the write may have succeeded without the peer actually storing it.',
          LogType.warn));
    });
  }

  /// [remarks] and [recoveryPhotoBytes] are the owner's proof the vehicle is
  /// genuinely back — at least one photo plus a remark on how/where it was
  /// found, both required (the caller validates this before calling; see
  /// `UpdateStatusScreen._confirm`). Kept as their own `recoveryRemarks`/
  /// `recoveryPhotos` fields rather than appended onto the alert's original
  /// `notes`, so a device displaying this alert can tell "what the owner
  /// said when it was stolen" apart from "what they said when it came back".
  Future<void> markRecovered(String alertId,
      {required String remarks,
      required List<Uint8List> recoveryPhotoBytes}) async {
    final ai = _alerts.indexWhere((a) => a.id == alertId);
    if (ai == -1) return;
    final alert = _alerts[ai];
    alert.status = AlertStatus.recovered;
    alert.recoveryRemarks = remarks.trim();
    alert.recoveryPhotos = [
      for (final bytes in recoveryPhotoBytes) base64Encode(bytes)
    ];
    await _db.upsertAlert(alert, synced: false);
    // The vehicle may have since been removed (removeVehicle() doesn't
    // cascade-delete its alerts) — the alert can still be marked recovered
    // on its own; there's just no vehicle record left to un-flag as stolen.
    final vIdx = _vehicles.indexWhere((v) => v.id == alert.vehicleId);
    if (vIdx != -1) {
      _vehicles[vIdx].status = VehicleStatus.active;
      await _db.upsertVehicle(_vehicles[vIdx]);
      _pushVehicle(_vehicles[vIdx]);
    }
    await _addLog(
        'RECOVERY', 'Vehicle ${alert.plate} marked recovered', LogType.ok);
    await _addNotif(
        '✅ Vehicle Recovered',
        '${alert.plate} status updated. Nearby nodes notified.',
        NotifType.recovered);
    await _notif.show(
        '✅ Vehicle Recovered', '${alert.plate} has been marked as recovered.');
    notifyListeners();
    // Push the recovery to the cloud now so phones that get alerts over the
    // internet feed see it promptly (it used to wait for the next network change).
    _syncSoonIfOnline();
    final msg = <String, dynamic>{
      'msgType': 'status_update',
      'alertId': alert.id,
      'plate': alert.plate,
      'status': AlertStatus.recovered.index,
      // The remark travels fine over mesh (short text, same as the
      // original report's `notes`) — the recovery PHOTO doesn't (same
      // size reasoning as the original report's photos; see
      // _alertWireMessage). A receiving device missing it can still tell
      // one exists, since recovery always has exactly one — see
      // hasRecoveryPhoto's doc comment — so no separate flag is needed.
      'recoveryRemarks': alert.recoveryRemarks,
    };
    unawaited(_mesh.broadcast(msg));
  }

  /// Clears a vehicle's `stolen` flag directly, with no theft alert
  /// involved. [markRecovered] is the normal path — it closes a specific
  /// active alert, and that's what flips the vehicle back to `active` — but
  /// a vehicle can end up stuck `stolen` with no matching active alert to
  /// close (its alert failed to sync, was never created because
  /// [reportStolen] was interrupted between its two writes, or was removed
  /// separately). Home's "Recovered" button falls back to this, after the
  /// owner confirms, whenever no active alert can be found for the vehicle —
  /// otherwise that owner would have no way to ever report it stolen again.
  Future<void> forceRecoverVehicle(String vehicleId) async {
    final vIdx = _vehicles.indexWhere((v) => v.id == vehicleId);
    if (vIdx == -1) return;
    final v = _vehicles[vIdx];
    if (v.status != VehicleStatus.stolen) return;
    v.status = VehicleStatus.active;
    await _db.upsertVehicle(v);
    _pushVehicle(v);
    await _addLog(
        'RECOVERY',
        'Vehicle ${v.plate} status cleared directly — no active alert was found to close',
        LogType.warn);
    await _addNotif('✅ Vehicle Recovered', '${v.plate} status cleared.',
        NotifType.recovered);
    notifyListeners();
    _syncSoonIfOnline();
  }

  // ──────────────────────────────────────────
  // MONITORING
  // ──────────────────────────────────────────
  Future<void> toggleMonitoring(bool value) async {
    monitoringArmed = value;
    await _addLog(
        'MONITOR',
        value
            ? 'Monitoring armed — location watcher active'
            : 'Monitoring disabled',
        value ? LogType.ok : LogType.warn);
    notifyListeners();
  }

  // ──────────────────────────────────────────
  // CONNECTIVITY / SYNC
  // ──────────────────────────────────────────
  bool _syncRunning = false;
  bool _syncAgain = false;

  Future<void> _onConnectivityChanged(bool online) async {
    if (!online) {
      networkStatus = NetworkStatus.offline;
      notifyListeners();
      return;
    }
    // One sync at a time — but if something new needs uploading while one is
    // already running (say an alert is reported mid-sync), run again right
    // after instead of dropping the request. Previously that alert waited for
    // the next network change and could sit unsent indefinitely.
    if (_syncRunning) {
      _syncAgain = true;
      return;
    }
    _syncRunning = true;
    try {
      do {
        _syncAgain = false;
        final wasFailed = networkStatus == NetworkStatus.syncFailed;
        networkStatus = NetworkStatus.syncing;
        notifyListeners();
        try {
          final synced = await _firebaseSync.syncAll();
          networkStatus = NetworkStatus.syncComplete;
          if (synced > 0) {
            await _addLog(
                'SYNC',
                'Synchronized $synced pending record(s) to Firestore',
                LogType.ok);
            await _addNotif('☁ Sync Completed',
                '$synced record(s) synchronized to the cloud.', NotifType.sync);
          }
        } catch (_) {
          networkStatus = NetworkStatus.syncFailed;
          // Report a failure once, not on every automatic retry.
          if (!wasFailed) {
            await _addLog(
                'SYNC',
                'Synchronization failed — will retry automatically',
                LogType.err);
            await _addNotif(
                '⚠ Sync Failed',
                'Could not reach the cloud. Data remains stored locally and will be retried.',
                NotifType.sync);
          }
        }
        notifyListeners();
        unawaited(_syncVehicles());
      } while (_syncAgain);
    } finally {
      _syncRunning = false;
    }
  }

  // ──────────────────────────────────────────
  // NOTIFICATIONS
  // ──────────────────────────────────────────
  /// [time] defaults to now (right for anything that's genuinely happening
  /// live — a device connecting, a sync completing, this phone's own
  /// action). Callers that already know the real, original moment the
  /// underlying event occurred — a sighting's own submission time, an
  /// alert's own report time — pass it explicitly instead, so a
  /// catch-up/backlog delivery (e.g. several sightings arriving at once from
  /// a Firestore listener on app start) doesn't stamp every one of them with
  /// the current time and make them look like they just happened together.
  Future<void> _addNotif(String title, String body, NotifType type,
      {DateTime? time}) async {
    final n = NotifItem(
      id: 'n${DateTime.now().millisecondsSinceEpoch}${_rng.nextInt(999)}',
      title: title,
      body: body,
      type: type,
      time: time ?? DateTime.now(),
    );
    notifications.insert(0, n);
    await _db.addNotification(n);
  }

  Future<void> markAllRead() async {
    for (var n in notifications) {
      n.isRead = true;
    }
    await _db.markAllNotificationsRead();
    notifyListeners();
  }

  // ──────────────────────────────────────────
  // LOGS
  // ──────────────────────────────────────────
  Future<void> _addLog(String tag, String msg, LogType type) async {
    final log = SystemLog(tag: tag, message: msg, type: type);
    logs.insert(0, log);
    if (logs.length > 300) logs.removeLast();
    await _db.addSystemLog(log);
  }

  Future<void> clearLogs() async {
    logs.clear();
    await _db.clearSystemLogs();
    notifyListeners();
  }
}
