import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Reports real device connectivity (Wi-Fi / mobile data), separate from
/// the ad hoc BLE/Wi-Fi Direct simulation. Used to drive the ONLINE /
/// OFFLINE / SYNCING / SYNC COMPLETE / SYNC FAILED indicators required by
/// the offline-first design in prompt §6.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final Connectivity _connectivity = Connectivity();

  Future<bool> isOnline() async {
    final result = await _connectivity.checkConnectivity();
    return _hasConnection(result);
  }

  bool _hasConnection(List<ConnectivityResult> results) {
    return results.any((r) => r != ConnectivityResult.none);
  }

  StreamSubscription<List<ConnectivityResult>>? _sub;

  void listen(void Function(bool online) onChange) {
    _sub?.cancel();
    _sub = _connectivity.onConnectivityChanged.listen((results) {
      onChange(_hasConnection(results));
    });
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
