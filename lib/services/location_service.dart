import 'dart:async';
import 'package:geolocator/geolocator.dart';
import '../models/models.dart';

/// Wraps the smartphone's built-in GPS (via `geolocator`) so the rest of the
/// app never has to guess whether a coordinate is real.
///
/// IMPORTANT (see manuscript §4 / prompt §4 & §29): this service NEVER
/// fabricates coordinates. If real GPS cannot be obtained, callers receive
/// an explicit [GpsStatus] instead of a silently-faked position.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  Position? lastKnownPosition;
  DateTime? lastUpdated;
  GpsStatus status = GpsStatus.checking;

  /// Checks permission + service state and returns the current honest status.
  Future<GpsStatus> checkStatus() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      status = GpsStatus.disabled;
      return status;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      status = GpsStatus.permissionRequired;
      return status;
    }
    status = GpsStatus.available;
    return status;
  }

  /// Requests location permission explicitly (for a dedicated permission
  /// explanation screen/dialog, per manuscript §27).
  Future<bool> requestPermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  /// Returns a REAL current position, or null if unavailable. Never invents
  /// coordinates — callers must handle the null case with a clear message
  /// ("Location unavailable. Turn on Location Services and try again.").
  Future<Position?> getCurrentPosition() async {
    final s = await checkStatus();
    if (s != GpsStatus.available) return null;
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 12));
      lastKnownPosition = pos;
      lastUpdated = DateTime.now();
      status = GpsStatus.available;
      return pos;
    } catch (_) {
      status = lastKnownPosition != null
          ? GpsStatus.available
          : GpsStatus.unavailable;
      return null;
    }
  }

  StreamSubscription<Position>? _sub;

  /// Starts continuous foreground location updates (used while the app is
  /// open, e.g. for live geofence checking). This is a foreground watcher,
  /// not a guaranteed OS-level background service — see README limitations.
  void startWatching(void Function(Position) onUpdate,
      {void Function(Object error)? onError}) {
    _sub?.cancel();
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, distanceFilter: 10),
    ).listen((pos) {
      lastKnownPosition = pos;
      lastUpdated = DateTime.now();
      status = GpsStatus.available;
      onUpdate(pos);
    }, onError: (e) {
      // Previously silently swallowed — a stream that dies (common on real
      // devices once the OS throttles a backgrounded/screen-off app) left
      // every caller (geofence checking included) working off a frozen
      // position forever, with nothing recording that it had happened.
      status = GpsStatus.unavailable;
      onError?.call(e);
    });
  }

  void stopWatching() {
    _sub?.cancel();
    _sub = null;
  }

  /// Haversine great-circle distance in meters (Sinnott, 1984) — the same
  /// formula referenced in Chapter 3 of the manuscript for proximity and
  /// geofence-violation detection.
  static double distanceMeters(
      double lat1, double lng1, double lat2, double lng2) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2);
  }
}
