import 'dart:typed_data';
import '../utils/geo_defaults.dart';

// ─── GPS STATUS ───
enum GpsStatus {
  available,
  permissionRequired,
  disabled,
  unavailable,
  checking
}

extension GpsStatusX on GpsStatus {
  String get label {
    switch (this) {
      case GpsStatus.available:
        return 'GPS Location Available';
      case GpsStatus.permissionRequired:
        return 'GPS Permission Required';
      case GpsStatus.disabled:
        return 'GPS Disabled';
      case GpsStatus.unavailable:
        return 'Location Unavailable';
      case GpsStatus.checking:
        return 'Checking Location…';
    }
  }
}

// ─── NETWORK / SYNC STATUS ───
enum NetworkStatus { online, offline, syncing, syncComplete, syncFailed }

extension NetworkStatusX on NetworkStatus {
  String get label {
    switch (this) {
      case NetworkStatus.online:
        return 'ONLINE';
      case NetworkStatus.offline:
        return 'OFFLINE';
      case NetworkStatus.syncing:
        return 'SYNCING';
      case NetworkStatus.syncComplete:
        return 'SYNC COMPLETE';
      case NetworkStatus.syncFailed:
        return 'SYNC FAILED';
    }
  }
}

// ─── USER MODEL ───
class UserModel {
  final String
      id; // Firebase Authentication UID — the canonical, server-verified identity
  final String name;
  final String email;
  final String phone;
  final String role; // 'owner' | 'admin'
  final String deviceId;
  final String initials;

  /// When this account was created. Null for an account that existed before
  /// this field was added, or one whose owner hasn't signed back in since —
  /// the Admin Dashboard shows those as "—" rather than guessing. Not
  /// permanently unrecoverable, though: AppState.init() backfills it from
  /// Firebase Auth's own `metadata.creationTime` the next time that
  /// specific account signs in (that value is only ever visible to the
  /// account's own session, never readable for another user — not even by
  /// an admin — which is why this can't be fixed from the Admin Dashboard
  /// itself).
  final DateTime? createdAt;

  UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    this.role = 'owner',
    required this.deviceId,
    this.createdAt,
  }) : initials = _initials(name);

  static String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : 'U';
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'email': email,
        'phone': phone,
        'role': role,
        'deviceId': deviceId,
        'createdAt': createdAt?.toIso8601String(),
      };

  /// [id] should be the account's real identifier — normally the Firestore
  /// document's own ID (the source of truth), passed in by the caller,
  /// which is always correct even for a document hand-created in the
  /// Firebase Console and missing an `id` field inside its body. Every
  /// field falls back to something harmless rather than throwing, so one
  /// malformed document can't crash whatever list it's part of.
  factory UserModel.fromMap(Map<String, Object?> m, {String? id}) => UserModel(
        id: id ?? (m['id'] as String? ?? ''),
        name: m['name'] as String? ?? '',
        email: m['email'] as String? ?? '',
        phone: m['phone'] as String? ?? '',
        role: m['role'] as String? ?? 'owner',
        deviceId: m['deviceId'] as String? ?? '',
        createdAt: _parseDate(m['createdAt']),
      );
}

/// Parses a `createdAt` value that may be an ISO string (every write this
/// app itself makes) or a Firestore `Timestamp` (only if a document was ever
/// hand-edited in the Console to use one) — either way falls back to null
/// rather than throwing, consistent with every other field on these models.
DateTime? _parseDate(Object? v) {
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v);
  try {
    // Firestore's Timestamp has a toDate() method; avoided as a static type
    // here so this file doesn't need to import cloud_firestore.
    return (v as dynamic).toDate() as DateTime?;
  } catch (_) {
    return null;
  }
}

/// Where a newly registered account stands with the admins. Accounts with no
/// status on file (everything registered before approval existed) count as
/// approved — see AppState.login.
enum RegistrationDecision { pending, rejected }

/// What the registration form collects for the vehicle, before anything is
/// saved — the same fields AppState.addVehicle takes, plus its two photos.
class VehicleDraft {
  final String plate;
  final String model;
  final String color;
  final String type;
  final String yearModel;

  /// The CR's own ENGINE NO. and CHASSIS NO. fields — recommended by the
  /// Highway Patrol Group (HPG) as what actually tells a single car apart
  /// from every other one that happens to share its plate, make, or color.
  final String engineNumber;
  final String chassisNumber;
  final double geofence;
  final Uint8List orPhoto;
  final Uint8List crPhoto;
  const VehicleDraft({
    required this.plate,
    required this.model,
    required this.color,
    required this.type,
    required this.yearModel,
    required this.engineNumber,
    required this.chassisNumber,
    required this.geofence,
    required this.orPhoto,
    required this.crPhoto,
  });
}

// ─── VEHICLE MODEL ───
enum VehicleStatus { active, stolen, recovered }

class VehicleModel {
  final String id;
  final String ownerId;
  String plate;
  String model;
  String color;
  String type;

  /// The 4-digit model year, as printed on the CR's own "YEAR MODEL" field.
  /// Empty on a vehicle registered before this field existed.
  String yearModel;

  /// The CR's own ENGINE NO. and CHASSIS NO. — recommended by the Highway
  /// Patrol Group (HPG) as what actually tells a single car apart from every
  /// other one that happens to share its plate, make, or color. Empty on a
  /// vehicle registered before these fields existed.
  String engineNumber;
  String chassisNumber;
  VehicleStatus status;
  double geofenceRadius;
  bool geofenceActive;
  double? geofenceCenterLat;
  double? geofenceCenterLng;
  final String deviceId;
  double lat;
  double lng;
  DateTime? lastLocationUpdate;

  /// When this vehicle was registered. Null for a vehicle registered before
  /// this field was added.
  final DateTime? createdAt;

  VehicleModel({
    required this.id,
    required this.ownerId,
    required this.plate,
    required this.model,
    required this.color,
    required this.type,
    this.yearModel = '',
    this.engineNumber = '',
    this.chassisNumber = '',
    this.status = VehicleStatus.active,
    this.geofenceRadius = 100,
    this.geofenceActive = false,
    this.geofenceCenterLat,
    this.geofenceCenterLng,
    required this.deviceId,
    this.lat = kDefaultLat,
    this.lng = kDefaultLng,
    this.lastLocationUpdate,
    this.createdAt,
  });

  String get statusLabel {
    switch (status) {
      case VehicleStatus.active:
        return 'NOT STOLEN';
      case VehicleStatus.stolen:
        return 'STOLEN';
      case VehicleStatus.recovered:
        return 'RECOVERED';
    }
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'ownerId': ownerId,
        'plate': plate,
        'model': model,
        'color': color,
        'type': type,
        'yearModel': yearModel,
        'engineNumber': engineNumber,
        'chassisNumber': chassisNumber,
        'status': status.index,
        'geofenceRadius': geofenceRadius,
        'geofenceActive': geofenceActive ? 1 : 0,
        'geofenceCenterLat': geofenceCenterLat,
        'geofenceCenterLng': geofenceCenterLng,
        'deviceId': deviceId,
        'lat': lat,
        'lng': lng,
        'lastLocationUpdate': lastLocationUpdate?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
      };

  /// [id] should be the vehicle's real identifier — the Firestore
  /// document's own ID, passed in by the caller, the same defense used by
  /// [UserModel.fromMap] (see there for why a duplicated `id` field inside
  /// the document body is never trusted as the source of truth). Every
  /// field falls back to something harmless rather than throwing, so one
  /// malformed document can't crash whatever list it's part of.
  factory VehicleModel.fromMap(Map<String, Object?> m, {String? id}) =>
      VehicleModel(
        id: id ?? (m['id'] as String? ?? ''),
        ownerId: m['ownerId'] as String? ?? '',
        plate: m['plate'] as String? ?? '',
        model: m['model'] as String? ?? '',
        color: m['color'] as String? ?? '',
        type: m['type'] as String? ?? '',
        yearModel: m['yearModel'] as String? ?? '',
        engineNumber: m['engineNumber'] as String? ?? '',
        chassisNumber: m['chassisNumber'] as String? ?? '',
        status: VehicleStatus.values[m['status'] as int? ?? 0],
        geofenceRadius: (m['geofenceRadius'] as num?)?.toDouble() ?? 100,
        geofenceActive: (m['geofenceActive'] as int? ?? 0) == 1,
        geofenceCenterLat: (m['geofenceCenterLat'] as num?)?.toDouble(),
        geofenceCenterLng: (m['geofenceCenterLng'] as num?)?.toDouble(),
        deviceId: m['deviceId'] as String? ?? '',
        lat: (m['lat'] as num?)?.toDouble() ?? kDefaultLat,
        lng: (m['lng'] as num?)?.toDouble() ?? kDefaultLng,
        lastLocationUpdate: m['lastLocationUpdate'] != null
            ? DateTime.tryParse(m['lastLocationUpdate'] as String)
            : null,
        createdAt: _parseDate(m['createdAt']),
      );
}

// ─── THEFT ALERT MODEL ───
enum AlertStatus { active, recovered, resolved }

enum AlertTrigger { manualReport, geofenceViolation }

class TheftAlert {
  final String id;
  final String vehicleId;
  final String userId;
  final String plate;
  final String model;
  final String color;

  /// Copied from the vehicle's own record at the moment it's reported, the
  /// same way [plate]/[model]/[color] already are — so a nearby device that
  /// only ever receives this alert (never the vehicle record itself) can
  /// still see them. Recommended by the Highway Patrol Group (HPG) as what
  /// actually tells a single car apart from every other one sharing its
  /// plate, make, or color. Empty for an alert reported before these fields
  /// existed, or when the vehicle itself has none on file.
  final String engineNumber;
  final String chassisNumber;
  double lat;
  double lng;
  final DateTime timestamp;
  AlertTrigger trigger;
  AlertStatus status;
  String notes;

  /// The reporter's photo evidence — up to 3 compressed JPEGs, each as base64
  /// (FR-12 requires exactly 3 for a manual report, for clearer proof than a
  /// single photo; empty for an automatic geofence-violation alert, which has
  /// no report form and so no photo). Each round-trips through Firestore and
  /// reaches another device, unlike a local file path (what a single photo
  /// used to be stored as: `photoPath`, a path on the REPORTING phone's own
  /// filesystem, meaningless to read back on anyone else's).
  List<String> photos;
  int hopCount;
  List<String> relayedTo;
  bool isDemoLocation;

  /// Proof the owner attached when marking this alert recovered: exactly
  /// one photo of the vehicle, plus a required remark on how/where it was
  /// found — always both together, enforced by `UpdateStatusScreen` before
  /// [AppState.markRecovered] is ever called. Never populated for an alert
  /// that's still [AlertStatus.active]. Same base64-list shape as [photos],
  /// for the same cross-device reason (a nearby device, or the owner's own
  /// Alert History on another device, needs the actual bytes, not a path
  /// that only resolves on the phone that took the photo). Because a photo
  /// is always required, a mesh-received copy with status `recovered`/
  /// `resolved` but no `recoveryPhotos` can be read the same way a
  /// mesh-received report with no `photos` already is (see
  /// `AppState._alertWireMessage`) — one genuinely exists, it just didn't
  /// travel over the mesh (too large), and will arrive once this device is
  /// back online.
  List<String> recoveryPhotos;
  String recoveryRemarks;

  bool get hasPhoto => photos.isNotEmpty;
  bool get hasRecoveryPhoto => recoveryPhotos.isNotEmpty;

  TheftAlert({
    required this.id,
    required this.vehicleId,
    required this.userId,
    required this.plate,
    required this.model,
    required this.color,
    this.engineNumber = '',
    this.chassisNumber = '',
    required this.lat,
    required this.lng,
    required this.timestamp,
    this.trigger = AlertTrigger.manualReport,
    this.status = AlertStatus.active,
    this.notes = '',
    List<String>? photos,
    this.hopCount = 0,
    List<String>? relayedTo,
    this.isDemoLocation = false,
    List<String>? recoveryPhotos,
    this.recoveryRemarks = '',
  })  : photos = photos ?? [],
        relayedTo = relayedTo ?? [],
        recoveryPhotos = recoveryPhotos ?? [];

  String get triggerLabel {
    switch (trigger) {
      case AlertTrigger.manualReport:
        return 'Manual Report';
      case AlertTrigger.geofenceViolation:
        return 'Geofence Violation';
    }
  }

  String get statusLabel {
    switch (status) {
      case AlertStatus.active:
        return 'STOLEN';
      case AlertStatus.recovered:
        return 'RECOVERED';
      case AlertStatus.resolved:
        return 'RESOLVED';
    }
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'vehicleId': vehicleId,
        'userId': userId,
        'plate': plate,
        'model': model,
        'color': color,
        'engineNumber': engineNumber,
        'chassisNumber': chassisNumber,
        'lat': lat,
        'lng': lng,
        'timestamp': timestamp.toIso8601String(),
        'trigger': trigger.index,
        'status': status.index,
        'notes': notes,
        'photos': photos.join(','),
        'hopCount': hopCount,
        'relayedTo': relayedTo.join(','),
        'isDemoLocation': isDemoLocation ? 1 : 0,
        'recoveryPhotos': recoveryPhotos.join(','),
        'recoveryRemarks': recoveryRemarks,
      };

  factory TheftAlert.fromMap(Map<String, Object?> m) => TheftAlert(
        id: m['id'] as String,
        vehicleId: m['vehicleId'] as String,
        userId: m['userId'] as String,
        plate: m['plate'] as String,
        model: m['model'] as String,
        color: m['color'] as String,
        engineNumber: m['engineNumber'] as String? ?? '',
        chassisNumber: m['chassisNumber'] as String? ?? '',
        lat: (m['lat'] as num).toDouble(),
        lng: (m['lng'] as num).toDouble(),
        timestamp: DateTime.parse(m['timestamp'] as String),
        trigger: AlertTrigger.values[m['trigger'] as int? ?? 0],
        status: AlertStatus.values[m['status'] as int? ?? 0],
        notes: m['notes'] as String? ?? '',
        photos: (m['photos'] as String? ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList(),
        hopCount: m['hopCount'] as int? ?? 0,
        relayedTo: (m['relayedTo'] as String? ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList(),
        isDemoLocation: (m['isDemoLocation'] as int? ?? 0) == 1,
        recoveryPhotos: (m['recoveryPhotos'] as String? ?? '')
            .split(',')
            .where((s) => s.isNotEmpty)
            .toList(),
        recoveryRemarks: m['recoveryRemarks'] as String? ?? '',
      );
}

// ─── SIGHTING REPORT ───
/// A nearby user's report that they've seen a vehicle flagged as stolen: what
/// they saw (message), where (GPS, when available), when, and an optional
/// photo as proof. Sent to the vehicle's owner ([ownerId] is the alert's own
/// `userId`). Location is nullable on purpose — the app never fabricates GPS
/// coordinates (same rule as LocationService), so a sighting sent from a phone
/// with no fix simply carries none.
class SightingReport {
  final String id;
  final String alertId;
  final String ownerId; // the stolen vehicle's owner — who this is FOR
  final String reporterId; // the person who saw it
  final String reporterName;

  /// The reporter's registered phone number, so the owner can call or text
  /// them. Empty when the reporter has none on file, and always empty on the
  /// mesh copy ([forMesh]): relaying phones can read what they forward, so a
  /// phone number only travels via the cloud copy, which Firestore rules limit
  /// to the owner, the reporter and an admin.
  final String reporterPhone;
  final String message;
  final double? lat;
  final double? lng;
  final DateTime seenAt; // when they saw the vehicle
  final DateTime sentAt; // when they submitted this report
  final String?
      photoB64; // compressed JPEG, base64 — null when no photo (or mesh copy)

  const SightingReport({
    required this.id,
    required this.alertId,
    required this.ownerId,
    required this.reporterId,
    required this.reporterName,
    this.reporterPhone = '',
    required this.message,
    this.lat,
    this.lng,
    required this.seenAt,
    required this.sentAt,
    this.photoB64,
  });

  bool get hasLocation => lat != null && lng != null;
  bool get hasPhoto => photoB64 != null && photoB64!.isNotEmpty;
  bool get hasContact => reporterPhone.isNotEmpty;

  Map<String, Object?> toMap() => {
        'id': id,
        'alertId': alertId,
        'ownerId': ownerId,
        'reporterId': reporterId,
        'reporterName': reporterName,
        'reporterPhone': reporterPhone,
        'message': message,
        'lat': lat,
        'lng': lng,
        'seenAt': seenAt.toIso8601String(),
        'sentAt': sentAt.toIso8601String(),
        'photoB64': photoB64,
      };

  factory SightingReport.fromMap(Map<String, Object?> m) => SightingReport(
        id: m['id'] as String,
        alertId: m['alertId'] as String,
        ownerId: m['ownerId'] as String,
        reporterId: m['reporterId'] as String,
        reporterName: m['reporterName'] as String? ?? 'A nearby user',
        reporterPhone: m['reporterPhone'] as String? ?? '',
        message: m['message'] as String? ?? '',
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
        seenAt:
            DateTime.tryParse(m['seenAt'] as String? ?? '') ?? DateTime.now(),
        sentAt:
            DateTime.tryParse(m['sentAt'] as String? ?? '') ?? DateTime.now(),
        photoB64: m['photoB64'] as String?,
      );

  /// The copy that goes over the ad hoc mesh: text only, with no photo (too
  /// big for a Nearby Connections payload) and no phone number (see
  /// [reporterPhone]).
  SightingReport forMesh() => SightingReport(
        id: id,
        alertId: alertId,
        ownerId: ownerId,
        reporterId: reporterId,
        reporterName: reporterName,
        message: message,
        lat: lat,
        lng: lng,
        seenAt: seenAt,
        sentAt: sentAt,
      );
}

/// Outcome of sending a sighting. A sighting is always SAVED on the phone
/// first, so "not delivered" is not a failure — it's queued and goes out on
/// the next sync. [error] is only set when nothing was saved (bad input).
// ─── REGISTRATION RESULT ───
// Which field a failed registration should be blamed on, so the Register
// form can show a specific inline error under that field (and a specific
// modal title) instead of a single generic "Registration Not Submitted"
// popup that leaves the person guessing which of Full Name/Email was the
// problem.
enum RegistrationIssueField { name, email }

class RegistrationResult {
  final String? error;
  final RegistrationIssueField? field;
  const RegistrationResult.success()
      : error = null,
        field = null;
  const RegistrationResult.failure(String message, {this.field})
      : error = message;
  bool get ok => error == null;
}

class SightingSubmitResult {
  final String? error;
  final bool
      delivered; // reached the cloud — the owner gets it over the internet
  final bool sharedOverMesh; // also broadcast to connected nearby devices

  /// The server actively REFUSED the upload (Firestore `permission-denied`) —
  /// a setup problem (the sightings rule isn't published), not a connection
  /// problem, so retrying later would never help and "we'll deliver it when
  /// you're online" would be a false promise.
  final bool blockedByRules;
  const SightingSubmitResult(
      {this.delivered = false,
      this.sharedOverMesh = false,
      this.blockedByRules = false})
      : error = null;
  const SightingSubmitResult.failure(String message)
      : error = message,
        delivered = false,
        sharedOverMesh = false,
        blockedByRules = false;
  bool get ok => error == null;
}

// ─── AD HOC NODE MODEL ───
enum ConnectionType { wifiDirect, ble }

enum RelayStatus { pending, relaying, received }

class AdHocNode {
  final String id;
  final String name;
  double
      distance; // meters — estimate only; real nodes show this as "Nearby" since raw BLE/Wi-Fi Direct doesn't expose distance
  bool isOnline;
  ConnectionType connectionType;
  int hopCount;
  RelayStatus relayStatus;
  double mapX; // 0.0–1.0 relative position
  double mapY;
  final bool
      isSimulated; // false = real device found via Nearby Connections (BLE/Wi-Fi Direct)
  String? endpointId; // Nearby Connections endpoint ID, for real nodes only
  /// A real, registered device that is signed in nearby and was located by
  /// its shared GPS position (internet presence) rather than found over
  /// Bluetooth. Never saved to the local database — it's rebuilt live.
  final bool viaInternet;

  AdHocNode({
    required this.id,
    required this.name,
    required this.distance,
    this.isOnline = true,
    this.connectionType = ConnectionType.ble,
    this.hopCount = 1,
    this.relayStatus = RelayStatus.pending,
    required this.mapX,
    required this.mapY,
    this.isSimulated = true,
    this.endpointId,
    this.viaInternet = false,
  });

  String get connectionLabel {
    if (viaInternet) return 'GPS · Internet';
    final suffix = isSimulated ? '(Simulated)' : '(Real)';
    switch (connectionType) {
      case ConnectionType.wifiDirect:
        return 'Wi-Fi Direct $suffix';
      case ConnectionType.ble:
        return 'BLE $suffix';
    }
  }
}

// ─── LOCATION HISTORY ───
class LocationRecord {
  final int? dbId;
  final String vehicleId;
  final double lat;
  final double lng;
  final DateTime time;
  bool synced;

  LocationRecord({
    this.dbId,
    required this.vehicleId,
    required this.lat,
    required this.lng,
    required this.time,
    this.synced = false,
  });

  Map<String, Object?> toMap() => {
        'vehicleId': vehicleId,
        'lat': lat,
        'lng': lng,
        'time': time.toIso8601String(),
        'synced': synced ? 1 : 0,
      };

  factory LocationRecord.fromMap(Map<String, Object?> m) => LocationRecord(
        dbId: m['dbId'] as int?,
        vehicleId: m['vehicleId'] as String,
        lat: (m['lat'] as num).toDouble(),
        lng: (m['lng'] as num).toDouble(),
        time: DateTime.parse(m['time'] as String),
        synced: (m['synced'] as int? ?? 0) == 1,
      );
}

// ─── SYSTEM LOG ───
enum LogType { ok, warn, err, info, relay }

class SystemLog {
  final String timestamp;
  final String tag;
  final String message;
  final LogType type;

  /// The real date and time this entry was logged. `timestamp` (HH:mm:ss,
  /// no date) is kept only because the SQLite column already exists and
  /// shouldn't be dropped — `createdAt` is what the UI actually displays
  /// now, so a log from yesterday is never mistaken for one from today.
  final DateTime createdAt;

  SystemLog({
    required this.tag,
    required this.message,
    required this.type,
    String? timestamp,
    DateTime? createdAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        timestamp = timestamp ?? _ts(createdAt ?? DateTime.now());

  static String _ts(DateTime n) =>
      '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}:${n.second.toString().padLeft(2, '0')}';

  Map<String, Object?> toMap() => {
        'timestamp': timestamp,
        'tag': tag,
        'message': message,
        'type': type.index,
        'createdAt': createdAt.toIso8601String(),
      };

  factory SystemLog.fromMap(Map<String, Object?> m) => SystemLog(
        tag: m['tag'] as String,
        message: m['message'] as String,
        type: LogType.values[m['type'] as int? ?? 3],
        timestamp: m['timestamp'] as String?,
        createdAt: DateTime.tryParse(m['createdAt'] as String? ?? ''),
      );
}

// ─── NOTIFICATION ITEM ───
enum NotifType { stolen, geofence, relayed, recovered, info, sync }

class NotifItem {
  final String id;
  final String title;
  final String body;
  final NotifType type;
  final DateTime time;
  bool isRead;

  NotifItem({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    required this.time,
    this.isRead = false,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'body': body,
        'type': type.index,
        'time': time.toIso8601String(),
        'isRead': isRead ? 1 : 0,
      };

  factory NotifItem.fromMap(Map<String, Object?> m) => NotifItem(
        id: m['id'] as String,
        title: m['title'] as String,
        body: m['body'] as String,
        type: NotifType.values[m['type'] as int? ?? 4],
        time: DateTime.parse(m['time'] as String),
        isRead: (m['isRead'] as int? ?? 0) == 1,
      );
}
