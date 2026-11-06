import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vigilink_mesh_transport/vigilink_mesh_transport.dart';

/// REAL AD HOC NETWORK (raw BLE advertise/scan + native Wi-Fi Direct)
/// ------------------------------------------------------------------
/// Genuine device-to-device discovery and data transfer, with no Google
/// Play Services involved anywhere in the path — confirmed necessary after
/// real 3-phone testing found the previous implementation
/// (`package:nearby_connections`, which goes through Google's
/// play-services-nearby client) silently failed to discover anyone with no
/// internet on the device, even with Bluetooth/Wi-Fi/Location all correctly
/// on. `vigilink_mesh_transport` (an app-local plugin, see
/// `packages/vigilink_mesh_transport/`) uses only raw AOSP APIs —
/// `BluetoothLeAdvertiser`/`BluetoothLeScanner` for discovery,
/// `WifiP2pManager` for the actual connection and data transfer — so there
/// is nothing left in this path that could depend on connectivity.
///
/// How it matches the manuscript's design:
///   • Every phone both advertises itself AND scans for others at the same
///     time — this is the "each smartphone is a node" model from Chapter 3.
///   • When two devices come in range, they connect automatically (no
///     manual pairing) — matching "temporary peer-to-peer mesh". BLE is
///     purely the discovery/signaling layer; the connection and all alert
///     data travel over real Wi-Fi Direct.
///   • Theft alert packets are sent as JSON byte payloads over the
///     established connection.
///   • Received alerts are re-broadcast to every OTHER connected peer
///     (excluding the one that sent it) with a decrementing hop count —
///     this is the real implementation of multi-hop store-carry-forward
///     relay, instead of a scripted animation. A single Wi-Fi Direct Group
///     Owner can serve several connected Clients at once, which is what
///     lets 3+ phones share one mesh and still relay through each other.
///
/// Known real-world limits (be upfront about these with your panel):
///   • Requires both devices to have the app open (or, with the background
///     foreground service, running) — matching the "foreground-only"
///     limitation already noted for geofencing.
///   • Range is realistically ~10-100m depending on BLE vs Wi-Fi Direct
///     negotiation, phone hardware, and interference — consistent with the
///     manuscript's stated 50-100m proximity assumption.
///   • Needs Bluetooth, Location (GPS, set to Precise) AND Wi-Fi switched ON
///     on both phones — Wi-Fi does NOT need to be connected to any network
///     or have internet, just switched on.
///   • On some Android versions/OEMs, native Wi-Fi Direct can show a system
///     "connection invitation" prompt rather than connecting silently —
///     unlike the old Nearby-Connections-based implementation. Needs
///     real-device confirmation on the panel's test phones.
class NearbyMeshService {
  NearbyMeshService._();
  static final NearbyMeshService instance = NearbyMeshService._();

  static const String _serviceId = 'com.vehicleguard.theftalert';
  final MeshTransport _nearby = MeshTransport.instance;
  final Random _rng = Random();

  /// True only while BOTH advertising and discovery are confirmed running.
  bool isRunning = false;
  bool advertising = false;
  bool discovering = false;
  String? _myDisplayName;

  /// What the caller last asked for. The watchdog only keeps retrying while
  /// this is true, and a start that finishes after stop() was called tears
  /// itself back down instead of silently leaving the radios on.
  bool _wantRunning = false;

  /// In-flight start, so overlapping start() calls (app launch, login,
  /// the "Grant permission" button, and the mode switch all used to be able
  /// to call it at once) share ONE attempt instead of each calling
  /// startAdvertising — the second call is what produced
  /// STATUS_ALREADY_ADVERTISING (8001).
  Future<bool>? _starting;
  Timer? _watchdog;

  /// This device's mesh identity, persisted via SharedPreferences (backed by
  /// the same on-disk file regardless of which Flutter engine/isolate reads
  /// it) rather than generated fresh by the native plugin. Needed because
  /// the foreground app and the background hand-off service each run their
  /// own separate native plugin instance — without a shared, persisted
  /// value, each one would generate its own random token, making one real
  /// phone look like two different devices the moment it backgrounds.
  static const String _deviceTokenPrefsKey = 'vigilink_mesh_device_token';
  String? _deviceToken;

  Future<String> _getOrCreateDeviceToken() async {
    final cached = _deviceToken;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    var token = prefs.getString(_deviceTokenPrefsKey);
    if (token == null || token.length != 8) {
      const chars = '0123456789abcdef';
      token = List.generate(8, (_) => chars[_rng.nextInt(16)]).join();
      await prefs.setString(_deviceTokenPrefsKey, token);
    }
    _deviceToken = token;
    return token;
  }

  /// endpointId -> display name, for every currently-connected peer.
  final Map<String, String> connectedEndpoints = {};

  /// endpointId -> when it connected, so a failed send can tell a
  /// connection that's barely a second old (still settling — the
  /// catch-up logic resends every stored alert the instant a peer
  /// connects, and an early send can hit a harmless timing race) apart
  /// from one that's been "connected" for minutes with no disconnect
  /// event while every send quietly fails (a genuinely dead link). Forcing
  /// a destructive restart on the former is a real bug that was found from
  /// a real test: it tore down a connection within 1-3 seconds of making
  /// it, which just made both sides rediscover and reconnect into the same
  /// failure forever.
  final Map<String, DateTime> _connectedSince = {};
  static const Duration _connectionGracePeriod = Duration(seconds: 8);

  /// endpointId -> display name, for peers seen but not yet connected.
  final Map<String, String> discoveredEndpoints = {};

  /// Endpoints we've already sent a connection request to and are waiting
  /// to hear back from — prevents firing requestConnection twice for the
  /// same peer while a request is still in flight.
  final Set<String> _pendingConnections = {};

  void Function(String endpointId, String name)? onPeerDiscovered;
  void Function(String endpointId)? onPeerLost;
  void Function(String endpointId, String name)? onPeerConnected;
  void Function(String endpointId)? onPeerDisconnected;
  void Function(Map<String, dynamic> message, String fromEndpointId)?
      onMessageReceived;
  void Function(String error)? onError;

  /// Fired whenever the mesh's running state changes (including changes made
  /// by the background watchdog), so the UI never shows a stale "Scanning".
  void Function()? onStateChanged;

  /// Fired when every discovered/connected peer is invalidated at once
  /// (radios torn down). Nearby endpoint IDs are ephemeral per session, so
  /// anything remembered from before the reset is stale.
  void Function()? onReset;

  /// Plain-language trace of everything the mesh does (start results,
  /// endpoints found/lost, connection requests and their outcomes). Goes to
  /// System Logs so a failed link on real phones can be diagnosed from a
  /// screenshot instead of guessed at.
  void Function(String message)? onLog;
  void _log(String message) => onLog?.call(message);

  /// Last time anything happened on the mesh (start, peer found, peer
  /// connected) — the watchdog only refreshes the radios after a long quiet
  /// spell, rather than constantly tearing down a scan that is still working.
  DateTime _lastActivity = DateTime.now();

  /// Requests every runtime permission Nearby Connections needs. Returns
  /// true only if the device can realistically discover/connect to peers.
  /// Never silently pretends permissions are granted when they aren't.
  Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.nearbyWifiDevices,
    ].request();
    // bluetoothScan/Advertise/Connect/nearbyWifiDevices only exist on
    // Android 12+/13+; on older OS versions permission_handler reports
    // them as already-granted (no-op), so this check stays accurate
    // across OS versions instead of assuming a single API level.
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  /// Human-readable list of things that will stop discovery from working
  /// even with every permission granted — Android silently refuses to scan
  /// with Bluetooth or Location (GPS) switched off, which looks exactly like
  /// "no devices nearby" unless the user is told.
  Future<List<String>> radioProblems() async {
    final problems = <String>[];
    try {
      if (!(await Permission.bluetooth.serviceStatus.isEnabled)) {
        problems.add('Bluetooth is turned off');
      }
    } catch (_) {}
    try {
      if (!(await Permission.location.serviceStatus.isEnabled)) {
        problems.add('Location (GPS) is turned off');
      }
    } catch (_) {}
    try {
      // Android 12+ lets the user grant only "Approximate" location. Bluetooth
      // scanning returns nothing without PRECISE location, and it fails
      // silently — the mesh shows Scanning ON while never finding anyone.
      if (await Geolocator.getLocationAccuracy() ==
          LocationAccuracyStatus.reduced) {
        problems.add('Location is set to Approximate (needs Precise)');
      }
    } catch (_) {}
    return problems;
  }

  /// Starts advertising (so nearby phones can find this device) AND
  /// discovery (so this device finds nearby phones) at the same time.
  /// Safe to call repeatedly and from several places at once.
  Future<bool> start(String displayName) {
    _myDisplayName = displayName;
    _wantRunning = true;
    if (isRunning) return Future.value(true);
    return _begin(quiet: false, force: false);
  }

  /// Tears the radios down and starts them again — the fix for a mesh that
  /// is stuck inactive or has stopped finding anyone. [force] is threaded
  /// down to the native transport as a genuine hard reset: unlike the
  /// automatic watchdog/hand-off stop-then-start pattern (debounced
  /// natively so routine churn doesn't trip Android's BLE scan throttling,
  /// see `VigilinkMeshTransportPlugin`), an explicit "Restart Scan" tap
  /// must always really tear down and rebuild the radios.
  Future<bool> restart({String? displayName}) {
    if (displayName != null) _myDisplayName = displayName;
    _wantRunning = true;
    isRunning = false;
    return _begin(quiet: false, force: true);
  }

  Future<bool> _begin({required bool quiet, required bool force}) {
    final existing = _starting;
    if (existing != null) return existing;
    final attempt = _doStart(quiet: quiet, force: force);
    _starting = attempt;
    attempt.whenComplete(() {
      if (identical(_starting, attempt)) _starting = null;
    });
    return attempt;
  }

  Future<bool> _doStart({required bool quiet, required bool force}) async {
    // Clear anything a previous attempt (or an earlier partial start) left
    // running. Nearby Connections answers STATUS_ALREADY_ADVERTISING /
    // STATUS_ALREADY_DISCOVERING otherwise, and a half-started mesh used to
    // be impossible to recover from because stop() bailed out whenever
    // isRunning was false.
    await _teardown();
    _log(
        'Starting mesh as "${_myDisplayName ?? 'VIGILINK User'}" (service $_serviceId)…');
    try {
      // Callbacks are set once as persistent instance fields rather than
      // per-call parameters — the new transport fires every event over one
      // shared EventChannel, unlike the old advertiser-side/discoverer-side
      // callback split `nearby_connections` had.
      _nearby.onConnectionInitiated = _onConnectionInitiated;
      _nearby.onConnectionResult = _onConnectionResult;
      _nearby.onDisconnected = _onEndpointDisconnected;
      _nearby.onEndpointFound = _onEndpointFound;
      _nearby.onEndpointLost = _onEndpointLost;
      _nearby.onPayloadReceived = _onPayloadReceived;
      _nearby.onTransportError = (message) {
        _log('Transport error: $message');
        onError?.call(message);
      };
      _nearby.onTransportInfo = (message) {
        _log('Transport info: $message');
      };

      final deviceToken = await _getOrCreateDeviceToken();
      advertising = await _nearby.startAdvertising(
        _myDisplayName ?? 'VIGILINK User',
        serviceId: _serviceId,
        force: force,
        deviceToken: deviceToken,
      );
      discovering = await _nearby.startDiscovery(
        _myDisplayName ?? 'VIGILINK User',
        serviceId: _serviceId,
        force: force,
        deviceToken: deviceToken,
      );
      if (!_wantRunning || !advertising || !discovering) {
        // stop() arrived mid-start, or one half failed without throwing —
        // never leave a half-started mesh behind.
        await _teardown();
        onStateChanged?.call();
        return false;
      }
      isRunning = true;
      _lastActivity = DateTime.now();
      _log('Mesh running — advertising ON, scanning ON.');
      _ensureWatchdog();
      onStateChanged?.call();
      return true;
    } catch (e) {
      _log('Mesh start failed: $e');
      await _teardown();
      if (!quiet) {
        onError?.call('Could not start the ad hoc mesh: $e');
      }
      onStateChanged?.call();
      return false;
    }
  }

  Future<void> stop() async {
    _wantRunning = false;
    _watchdog?.cancel();
    _watchdog = null;
    final inFlight = _starting;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
    }
    await _teardown();
    onStateChanged?.call();
  }

  /// Best-effort teardown of every radio and all peer bookkeeping. Runs even
  /// when isRunning is false, and each step is guarded separately so one
  /// failing call can't skip the rest.
  Future<void> _teardown() async {
    try {
      await _nearby.stopAdvertising();
    } catch (_) {}
    try {
      await _nearby.stopDiscovery();
    } catch (_) {}
    try {
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    connectedEndpoints.clear();
    discoveredEndpoints.clear();
    _pendingConnections.clear();
    advertising = false;
    discovering = false;
    isRunning = false;
    onReset?.call();
  }

  // ── Watchdog ─────────────────────────────────────────────────────────
  // Android can silently stall discovery, and a connection attempt can hang
  // without ever reporting a result. While the mesh is wanted, this checks
  // periodically and repairs things without the user having to do anything.
  void _ensureWatchdog() {
    _watchdog ??= Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(_watchdogTick()));
  }

  Future<void> _watchdogTick() async {
    if (!_wantRunning || _starting != null) return;
    if (!isRunning) {
      // An earlier start failed — keep trying quietly (no repeat toasts).
      // Not forced: this can retry every 30s while stuck, and forcing a
      // real native teardown that often is exactly the BLE-scan-throttling
      // churn the native debounce exists to avoid.
      _log('Mesh not running — retrying start.');
      await _begin(quiet: true, force: false);
      return;
    }
    if (connectedEndpoints.isNotEmpty || _pendingConnections.isNotEmpty) return;
    if (discoveredEndpoints.isNotEmpty) {
      // Saw someone but never got connected — try again.
      _log(
          'Seen ${discoveredEndpoints.length} device(s) but none connected — retrying connection.');
      for (final id in discoveredEndpoints.keys.toList()) {
        _requestConnectionTo(id, quiet: true);
      }
      return;
    }
    // Nobody seen at all. Give discovery a proper chance first, then refresh
    // the radios in case the scan silently stalled.
    final quietFor = DateTime.now().difference(_lastActivity);
    if (quietFor < const Duration(seconds: 90)) return;
    _log('Nobody found for ${quietFor.inSeconds}s — refreshing radios.');
    isRunning = false;
    // Forced: this only fires at most once every 90s (well clear of
    // Android's BLE scan-restart throttling window) and is specifically
    // meant to un-stick a scan that's gone quiet, so it needs a genuine
    // native teardown+rebuild, not the debounced no-op resume.
    await _begin(quiet: true, force: true);
  }

  // ── Discovery / connection ───────────────────────────────────────────
  void _onEndpointFound(String id, String name, String serviceId) {
    _lastActivity = DateTime.now();
    _log('Found nearby device "$name" ($id).');
    discoveredEndpoints[id] = name;
    onPeerDiscovered?.call(id, name);
    // Two phones that find each other at the same instant would both fire
    // requestConnection at the same instant, which Nearby Connections
    // resolves unreliably (one side gets a collision error and the pair can
    // end up not connected). A short random delay lets one side go first;
    // the other then sees the connection already exists/pending and skips.
    final jitter = Duration(milliseconds: 250 + _rng.nextInt(1750));
    Future.delayed(jitter, () => _requestConnectionTo(id));
  }

  /// [quiet] is used by the background retry: a device that has since walked
  /// away fails the request, and that must not pop an error every 30 seconds.
  void _requestConnectionTo(String id, {bool quiet = false}) {
    final name = discoveredEndpoints[id];
    if (name == null || !_wantRunning) return; // lost in the meantime
    // Guard against re-requesting a connection we already have (or already
    // asked for).
    if (connectedEndpoints.containsKey(id) ||
        _pendingConnections.contains(id)) {
      return;
    }
    _pendingConnections.add(id);
    _log('Requesting connection to "$name" ($id)…');
    // A request that never reports back must not block retries forever.
    // Was 20s, but a single BLE GATT connection probe can now legitimately
    // take up to ~190s across all its retries (VigilinkMeshTransportPlugin's
    // GATT_MAX_ATTEMPTS/GATT_RETRY_GAP_MS, each attempt's own 30s timeout) -
    // the 20s guard was clearing while a probe was still genuinely in
    // flight, letting a SECOND overlapping probe launch to the same peer.
    // If both eventually succeeded, onPeerConnected fired twice for one
    // peer, each time re-running the full store-carry-forward catch-up -
    // confirmed on a real device as repeated "Duplicate alert ... ignored"
    // log spam and a manual Force Relay getting stuck behind that backlog
    // in the per-address send queue. Kept with headroom above that ~190s
    // worst case.
    Timer(const Duration(seconds: 210), () => _pendingConnections.remove(id));
    // Auto-connect on discovery — matches the manuscript's "temporary
    // peer-to-peer mesh" with no manual pairing step.
    _nearby
        .requestConnection(_myDisplayName ?? 'VIGILINK User', id)
        .then((issued) {
      if (issued) return;
      // The native layer returned false WITHOUT throwing — it couldn't even
      // attempt the connection (almost always because its own Wi-Fi Direct
      // peer discovery, a separate and slower process than BLE's, hasn't
      // caught up with this peer yet, or it's mid-negotiation elsewhere;
      // the native onTransportInfo event already logs which). This used to
      // be silently swallowed entirely, leaving a request "stuck" for up to
      // 20s before even being eligible to retry — now it retries quickly,
      // since that timing gap is normally short-lived.
      _pendingConnections.remove(id);
      Timer(const Duration(seconds: 3), () {
        if (!connectedEndpoints.containsKey(id) &&
            !_pendingConnections.contains(id)) {
          _requestConnectionTo(id, quiet: quiet);
        }
      });
    }).catchError((e) {
      _pendingConnections.remove(id);
      final msg = e.toString();
      // 8003: the other phone got there first and we're already connected —
      // not a failure.
      if (msg.contains('8003') || msg.contains('ALREADY_CONNECTED')) {
        return;
      }
      if (quiet) {
        _log('Retry to "$name" failed: $e');
        // Most likely out of range now — forget it until discovery finds it again.
        discoveredEndpoints.remove(id);
        onPeerLost?.call(id);
        return;
      }
      onError?.call('Could not request a connection to $name: $e');
    });
  }

  void _onEndpointLost(String? id) {
    if (id == null) return;
    discoveredEndpoints.remove(id);
    _pendingConnections.remove(id);
    onPeerLost?.call(id);
  }

  void _onConnectionInitiated(String id, MeshConnectionInfo info) {
    // A connection can be initiated for a peer this device never saw via
    // onEndpointFound (e.g. the other side discovered us first) — without
    // this, _onConnectionResult's `discoveredEndpoints[id] ?? 'Unknown
    // Device'` lookup would miss and the peer would show as "Unknown
    // Device" even though its real name (info.endpointName) was available
    // the whole time.
    discoveredEndpoints.putIfAbsent(id, () => info.endpointName);
    _log(
        'Connection ${info.isIncomingConnection ? 'requested by' : 'to'} "${info.endpointName}" ($id) — accepting.');
    // Auto-accept every incoming connection — an ad hoc theft-alert network
    // has no concept of "rejecting" a fellow registered node. The new
    // transport's acceptConnection is a no-op (the socket handshake already
    // fully established the connection by this point) but is still called
    // for symmetry with the rest of this flow.
    _nearby.acceptConnection(id).catchError((e) {
      onError?.call(
          'Could not accept the connection from ${info.endpointName}: $e');
      return false;
    });
  }

  void _onConnectionResult(String id, MeshConnectionStatus status) {
    _pendingConnections.remove(id);
    final name = discoveredEndpoints[id] ?? 'Unknown Device';
    _log('Connection result for "$name" ($id): $status.');
    if (status == MeshConnectionStatus.connected) {
      _lastActivity = DateTime.now();
      connectedEndpoints[id] = name;
      _connectedSince[id] = DateTime.now();
      onPeerConnected?.call(id, name);
      onStateChanged?.call();
      return;
    }
    // When both phones connect at once, one attempt can be reported as
    // failed even though the other succeeds. Wait a moment before telling
    // the user, and only if this peer really did end up unconnected.
    Future.delayed(const Duration(seconds: 3), () {
      if (connectedEndpoints.containsKey(id)) return;
      if (status == MeshConnectionStatus.rejected) {
        onError?.call('$name rejected the connection request.');
      } else {
        onError?.call('Connection to $name failed ($status).');
      }
    });
  }

  void _onEndpointDisconnected(String id) {
    connectedEndpoints.remove(id);
    _connectedSince.remove(id);
    _pendingConnections.remove(id);
    onPeerDisconnected?.call(id);
    onStateChanged?.call();
  }

  void _onPayloadReceived(String endpointId, Uint8List bytes) {
    try {
      final jsonStr = utf8.decode(bytes);
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      onMessageReceived?.call(decoded, endpointId);
    } catch (e) {
      onError?.call('Received a malformed payload from $endpointId: $e');
    }
  }

  /// Sends a JSON message to one specific connected peer. Returns whether
  /// the native layer actually wrote it to a live socket — a UI/log that
  /// says "sent"/"relayed" without checking this would be reporting a
  /// connection attempt, not a real delivery.
  Future<bool> sendTo(String endpointId, Map<String, dynamic> message,
      {bool isRetry = false}) async {
    if (!connectedEndpoints.containsKey(endpointId)) return false;
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    bool ok;
    try {
      ok = await _nearby.sendBytesPayload(endpointId, bytes);
    } catch (e) {
      onError?.call('Failed to send to $endpointId: $e');
      ok = false;
    }
    if (ok) return true;
    final connectedAt = _connectedSince[endpointId];
    final stillSettling = !isRetry &&
        connectedAt != null &&
        DateTime.now().difference(connectedAt) < _connectionGracePeriod;
    if (stillSettling) {
      // The very first write right after a Wi-Fi Direct group forms can
      // fail even though the socket handshake itself just succeeded — the
      // underlying IP link can still be stabilizing for a moment.
      // Confirmed from a real test: the alert send failed the instant the
      // connection formed, while the connection itself stayed healthy
      // seconds later. One bounded retry (never more than one, via
      // isRetry) after a short pause, instead of giving up silently.
      _log(
          'Send to $endpointId failed shortly after connecting — retrying once after a short settle delay.');
      await Future.delayed(const Duration(seconds: 2));
      if (connectedEndpoints.containsKey(endpointId)) {
        return sendTo(endpointId, message, isRetry: true);
      }
      return false;
    }
    _treatAsDisconnected(endpointId);
    return false;
  }

  /// Broadcasts a JSON message to every currently connected peer, optionally
  /// skipping one endpoint (used when relaying — never bounce a message
  /// straight back to whoever just sent it). Returns only the endpoint IDs
  /// that actually succeeded, so callers can distinguish a real relay from
  /// an attempted one instead of assuming every connected peer got it.
  /// Delegates to [sendTo] per peer rather than duplicating its retry/
  /// dead-link logic.
  Future<Set<String>> broadcast(Map<String, dynamic> message,
      {String? excludeEndpointId}) async {
    final succeeded = <String>{};
    for (final id in connectedEndpoints.keys.toList()) {
      if (id == excludeEndpointId) continue;
      if (await sendTo(id, message)) succeeded.add(id);
    }
    return succeeded;
  }

  /// A send that the native layer couldn't deliver to a peer this device
  /// still lists as connected means the underlying Wi-Fi Direct link
  /// actually died without Android ever reporting a group loss — a real,
  /// known behavior around screen lock/power-saving, confirmed from real
  /// test logs showing "Connected" persist for minutes after every send to
  /// that peer started failing.
  ///
  /// Clearing only Dart's own bookkeeping here was a real bug: the native
  /// Wi-Fi Direct layer has no per-peer disconnect (one radio is only ever
  /// in one group at a time) and, since its own group-loss detection is
  /// exactly what failed to fire, it still considers itself busy/grouped —
  /// which silently refuses every future requestConnection from this
  /// moment on, with Dart now desynced from native reality. That's exactly
  /// the "stuck on Requesting connection forever" regression a real device
  /// test caught right after this fix first shipped. A forced restart tears
  /// the stale native state down for real, so rediscovery/reconnect can
  /// actually succeed instead of being refused forever.
  void _treatAsDisconnected(String endpointId) {
    if (!connectedEndpoints.containsKey(endpointId)) return;
    final connectedAt = _connectedSince[endpointId];
    if (connectedAt != null &&
        DateTime.now().difference(connectedAt) < _connectionGracePeriod) {
      // Too soon after connecting to conclude the link is actually dead —
      // the catch-up logic resends every stored alert the instant a peer
      // connects, and an early failure there is far more likely a harmless
      // settling race than a dead link. Forcing a destructive restart here
      // was a real, confirmed bug: a real test showed it tearing a
      // connection down 1-3 seconds after making it, which just sent both
      // sides back into rediscovery and the same failure, forever. Leave
      // the connection alone and let the next real send attempt decide.
      _log(
          'Send to $endpointId failed shortly after connecting — treating as a settling race, not a dead link.');
      return;
    }
    connectedEndpoints.remove(endpointId);
    _connectedSince.remove(endpointId);
    _pendingConnections.remove(endpointId);
    onPeerDisconnected?.call(endpointId);
    onStateChanged?.call();
    _log(
        'Send to $endpointId failed while still "connected" — the underlying link is dead; forcing a mesh restart to recover.');
    unawaited(restart());
  }
}
