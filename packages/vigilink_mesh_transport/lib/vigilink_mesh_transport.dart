import 'dart:async';
import 'package:flutter/services.dart';

/// Result of a connection attempt, mirroring the three outcomes
/// `nearby_connections`' `Status` enum exposed.
enum MeshConnectionStatus { connected, rejected, error }

class MeshConnectionInfo {
  final String endpointName;
  final bool isIncomingConnection;
  const MeshConnectionInfo({
    required this.endpointName,
    required this.isIncomingConnection,
  });
}

/// Ad hoc peer discovery and data transfer using raw BLE advertise/scan for
/// discovery and native Wi-Fi Direct for the connection and data transfer —
/// no Google Play Services / Nearby Connections involved, so there is no
/// internet dependency of any kind. Android only.
///
/// Deliberately mirrors the method/event shape `package:nearby_connections`
/// exposed, so `nearby_mesh_service.dart` only needed to swap which class it
/// talks to, not rewrite its own public API or watchdog logic.
class MeshTransport {
  MeshTransport._();
  static final MeshTransport instance = MeshTransport._();

  static const MethodChannel _channel =
      MethodChannel('vigilink_mesh_transport/methods');
  static const EventChannel _events =
      EventChannel('vigilink_mesh_transport/events');

  StreamSubscription? _sub;

  void Function(String endpointId, String name, String serviceId)?
      onEndpointFound;
  void Function(String? endpointId)? onEndpointLost;
  void Function(String endpointId, MeshConnectionInfo info)?
      onConnectionInitiated;
  void Function(String endpointId, MeshConnectionStatus status)?
      onConnectionResult;
  void Function(String endpointId)? onDisconnected;
  void Function(String endpointId, Uint8List bytes)? onPayloadReceived;

  /// A native BLE/Wi-Fi Direct failure that doesn't map to one specific
  /// endpoint (e.g. advertising/scanning/discovery itself failing to
  /// start) — distinct from [onConnectionResult], which is per-endpoint.
  void Function(String message)? onTransportError;

  /// Non-error diagnostic info (e.g. "BLE scan is receiving advertisements
  /// from the environment") — distinct from [onTransportError].
  void Function(String message)? onTransportInfo;

  void _ensureListening() {
    _sub ??= _events.receiveBroadcastStream().listen(_onEvent);
  }

  void _onEvent(dynamic event) {
    final map = Map<String, dynamic>.from(event as Map);
    switch (map['event'] as String?) {
      case 'onEndpointFound':
        onEndpointFound?.call(
          map['endpointId'] as String,
          map['endpointName'] as String? ?? 'VIGILINK User',
          map['serviceId'] as String? ?? '',
        );
        break;
      case 'onEndpointLost':
        onEndpointLost?.call(map['endpointId'] as String?);
        break;
      case 'onConnectionInitiated':
        onConnectionInitiated?.call(
          map['endpointId'] as String,
          MeshConnectionInfo(
            endpointName: map['endpointName'] as String? ?? 'Unknown Device',
            isIncomingConnection: map['isIncomingConnection'] == true,
          ),
        );
        break;
      case 'onConnectionResult':
        final code = map['statusCode'] as int? ?? 2;
        onConnectionResult?.call(
          map['endpointId'] as String,
          switch (code) {
            0 => MeshConnectionStatus.connected,
            1 => MeshConnectionStatus.rejected,
            _ => MeshConnectionStatus.error,
          },
        );
        break;
      case 'onDisconnected':
        onDisconnected?.call(map['endpointId'] as String);
        break;
      case 'onTransportError':
        onTransportError?.call(map['message'] as String? ?? 'unknown error');
        break;
      case 'onTransportInfo':
        onTransportInfo?.call(map['message'] as String? ?? '');
        break;
      case 'onPayloadReceived':
        final rawBytes = map['bytes'];
        final bytes = rawBytes is Uint8List
            ? rawBytes
            : Uint8List.fromList(List<int>.from(rawBytes as List));
        onPayloadReceived?.call(map['endpointId'] as String, bytes);
        break;
    }
  }

  /// [force] bypasses the native layer's debounce that otherwise resumes
  /// already-running radios untouched on a routine stop-then-start — pass
  /// true only for a genuine user-requested hard reset (see
  /// `NearbyMeshService.restart`).
  /// [deviceToken] lets the caller pin this device's mesh identity to a
  /// value that survives across a foreground/background engine hand-off
  /// (see `NearbyMeshService`) — otherwise each new native plugin instance
  /// would generate its own random token. Optional only so other callers
  /// aren't forced to pass one.
  Future<bool> startAdvertising(String userNickName,
      {required String serviceId, bool force = false, String? deviceToken}) async {
    _ensureListening();
    final ok = await _channel.invokeMethod<bool>('startAdvertising', {
      'userNickName': userNickName,
      'serviceId': serviceId,
      'force': force,
      'deviceToken': deviceToken,
    });
    return ok ?? false;
  }

  Future<bool> startDiscovery(String userNickName,
      {required String serviceId, bool force = false, String? deviceToken}) async {
    _ensureListening();
    final ok = await _channel.invokeMethod<bool>('startDiscovery', {
      'userNickName': userNickName,
      'serviceId': serviceId,
      'force': force,
      'deviceToken': deviceToken,
    });
    return ok ?? false;
  }

  Future<void> stopAdvertising() => _channel.invokeMethod('stopAdvertising');

  Future<void> stopDiscovery() => _channel.invokeMethod('stopDiscovery');

  Future<void> stopAllEndpoints() => _channel.invokeMethod('stopAllEndpoints');

  /// Returns true once the request was issued — not the final connection
  /// outcome, which arrives later via [onConnectionResult].
  Future<bool> requestConnection(String userNickName, String endpointId) async {
    final ok = await _channel.invokeMethod<bool>('requestConnection', {
      'userNickName': userNickName,
      'endpointId': endpointId,
    });
    return ok ?? false;
  }

  Future<bool> acceptConnection(String endpointId) async {
    final ok = await _channel
        .invokeMethod<bool>('acceptConnection', {'endpointId': endpointId});
    return ok ?? false;
  }

  /// Returns whether the native layer actually found a live socket for
  /// [endpointId] and wrote the bytes to it — not just whether the method
  /// channel call itself completed. A connected-looking peer can still have
  /// no matching socket (a stale/mismatched identity), and that must not be
  /// reported as a successful send.
  Future<bool> sendBytesPayload(String endpointId, Uint8List bytes) async {
    final ok = await _channel.invokeMethod<bool>('sendBytesPayload', {
      'endpointId': endpointId,
      'bytes': bytes,
    });
    return ok ?? false;
  }
}
