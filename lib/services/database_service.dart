import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/models.dart';

/// Handles all local persistence for VIGILINK using SQLite.
///
/// Tables: users, vehicles, theft_alerts, alert_logs, location_history,
/// nodes, notifications, system_logs, pending_sync.
///
/// Data written here survives app restarts (fixes the original prototype's
/// "everything resets on relaunch" problem).
class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  // Sighting reports (nearby users telling a vehicle's owner they've seen it).
  // One definition, used by both onCreate (fresh installs) and the v4 upgrade
  // (existing installs) so the two can never drift apart.
  static const String _sightingsTableSql = '''
    CREATE TABLE IF NOT EXISTS sightings (
      id TEXT PRIMARY KEY, alertId TEXT, ownerId TEXT, reporterId TEXT,
      reporterName TEXT, reporterPhone TEXT, message TEXT, lat REAL, lng REAL, seenAt TEXT,
      sentAt TEXT, photoB64 TEXT, synced INTEGER DEFAULT 0
    )
  ''';

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'vehicleguard.db');
    return openDatabase(
      path,
      version: 11,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 4) {
          await db.execute(_sightingsTableSql);
        }
        if (oldVersion < 11) {
          // v11: proof required when an owner marks a vehicle recovered — a
          // photo of it plus a remark on how/where it was found. Same
          // comma-joined-base64 shape as `photos`, for the same reason
          // (round-trips through Firestore to every device, not just a path
          // that only resolves on the reporting phone's own filesystem).
          try {
            await db.execute(
                'ALTER TABLE theft_alerts ADD COLUMN recoveryPhotos TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE theft_alerts ADD COLUMN recoveryRemarks TEXT');
          } catch (_) {}
        }
        if (oldVersion < 10) {
          // v10: the CR's own ENGINE NO. and CHASSIS NO. — recommended by the
          // Highway Patrol Group (HPG) as what actually tells a single car
          // apart from every other one sharing its plate, make, or color.
          // Copied onto a theft_alerts row too (same as plate/model/color
          // already are), so a received alert carries them without needing
          // the vehicle record itself.
          try {
            await db
                .execute('ALTER TABLE vehicles ADD COLUMN engineNumber TEXT');
          } catch (_) {}
          try {
            await db
                .execute('ALTER TABLE vehicles ADD COLUMN chassisNumber TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE theft_alerts ADD COLUMN engineNumber TEXT');
          } catch (_) {}
          try {
            await db.execute(
                'ALTER TABLE theft_alerts ADD COLUMN chassisNumber TEXT');
          } catch (_) {}
        }
        if (oldVersion < 9) {
          // v9: a theft report now takes up to 3 photos instead of 1, stored
          // comma-joined (base64 never contains a comma, same join already
          // used for `relayedTo`) in a new column — replacing the old single
          // `photoB64` column. `photoB64` is left in place but never written
          // to again, same reasoning as `photoPath`/`salt`/`passwordHash`
          // below: an already-installed app's local database can't have a
          // column silently removed without a migration, and there's nothing
          // to gain by adding one just for an always-empty column.
          try {
            await db.execute('ALTER TABLE theft_alerts ADD COLUMN photos TEXT');
          } catch (_) {}
        }
        if (oldVersion < 8) {
          // v8: a theft report's photo evidence, as base64 — replaces the
          // old `photoPath` column (a path on the REPORTING phone's own
          // filesystem, meaningless once read back on any other device,
          // which is exactly why a received alert's photo never showed up
          // anywhere). `photoPath` is left in place but never written to
          // again — same reasoning as the `salt`/`passwordHash` columns
          // below: an already-installed app's local database can't have a
          // column silently removed without a migration, and there's
          // nothing to gain by adding one just for an always-empty column.
          try {
            await db
                .execute('ALTER TABLE theft_alerts ADD COLUMN photoB64 TEXT');
          } catch (_) {}
        }
        if (oldVersion < 7) {
          // v7: when an account/vehicle was created, shown as a new column
          // on the Admin Dashboard. Throws (and is ignored) when onCreate
          // above just made the tables with the column already in them.
          try {
            await db.execute('ALTER TABLE users ADD COLUMN createdAt TEXT');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE vehicles ADD COLUMN createdAt TEXT');
          } catch (_) {}
        }
        if (oldVersion < 6) {
          // v6: the vehicle's model year, read off its CR's own "YEAR MODEL"
          // field. Throws (and is ignored) when onCreate above just made the
          // table with the column already in it.
          try {
            await db.execute('ALTER TABLE vehicles ADD COLUMN yearModel TEXT');
          } catch (_) {}
        }
        if (oldVersion < 5) {
          // v5: the reporter's phone number, for the owner to contact them.
          // Throws (and is ignored) when the v4 step above just created the
          // table with the column already in it.
          try {
            await db
                .execute('ALTER TABLE sightings ADD COLUMN reporterPhone TEXT');
          } catch (_) {}
        }
        if (oldVersion < 2) {
          // v2 adds real BLE/Wi-Fi Direct peer support (Nearby Connections)
          // alongside the existing simulated ad hoc demo nodes.
          try {
            await db.execute(
                'ALTER TABLE nodes ADD COLUMN isSimulated INTEGER DEFAULT 1');
          } catch (_) {}
          try {
            await db.execute('ALTER TABLE nodes ADD COLUMN endpointId TEXT');
          } catch (_) {}
        }
        if (oldVersion < 3) {
          // v3 added a per-user password salt, from when this table still
          // verified passwords locally. Real Firebase Authentication (see
          // FirebaseAuthService) replaced that entirely — passwordHash/salt
          // are dead columns now, never read or written by anything
          // (UserModel.toMap() doesn't include them) — kept only because an
          // already-installed app's local database can't have a column
          // silently removed without a migration, and there's nothing to
          // gain by adding one for two always-empty columns.
          try {
            await db
                .execute("ALTER TABLE users ADD COLUMN salt TEXT DEFAULT ''");
          } catch (_) {}
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE users (
            id TEXT PRIMARY KEY, name TEXT, email TEXT UNIQUE, passwordHash TEXT,
            salt TEXT DEFAULT '', phone TEXT, role TEXT, deviceId TEXT, createdAt TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE vehicles (
            id TEXT PRIMARY KEY, ownerId TEXT, plate TEXT, model TEXT, color TEXT,
            type TEXT, yearModel TEXT, engineNumber TEXT, chassisNumber TEXT,
            status INTEGER, geofenceRadius REAL,
            geofenceActive INTEGER, geofenceCenterLat REAL, geofenceCenterLng REAL,
            deviceId TEXT, lat REAL, lng REAL, lastLocationUpdate TEXT, createdAt TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE theft_alerts (
            id TEXT PRIMARY KEY, vehicleId TEXT, userId TEXT, plate TEXT, model TEXT,
            color TEXT, engineNumber TEXT, chassisNumber TEXT,
            lat REAL, lng REAL, timestamp TEXT, trigger INTEGER,
            status INTEGER, notes TEXT, photoPath TEXT, photoB64 TEXT, photos TEXT,
            hopCount INTEGER, relayedTo TEXT, isDemoLocation INTEGER,
            recoveryPhotos TEXT, recoveryRemarks TEXT, synced INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE alert_logs (
            logId INTEGER PRIMARY KEY AUTOINCREMENT, alertId TEXT, nodeDeviceId TEXT,
            receivedAt TEXT, relayedAt TEXT, hopCount INTEGER, duplicateFlag INTEGER,
            syncStatus TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE location_history (
            dbId INTEGER PRIMARY KEY AUTOINCREMENT, vehicleId TEXT, lat REAL, lng REAL,
            time TEXT, synced INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE nodes (
            id TEXT PRIMARY KEY, name TEXT, distance REAL, isOnline INTEGER,
            connectionType INTEGER, hopCount INTEGER, relayStatus INTEGER,
            mapX REAL, mapY REAL, isSimulated INTEGER DEFAULT 1, endpointId TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE notifications (
            id TEXT PRIMARY KEY, title TEXT, body TEXT, type INTEGER, time TEXT, isRead INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE system_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT, tag TEXT, message TEXT,
            type INTEGER, createdAt TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE pending_sync (
            id INTEGER PRIMARY KEY AUTOINCREMENT, entityType TEXT, entityId TEXT,
            createdAt TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE session (
            k TEXT PRIMARY KEY, v TEXT
          )
        ''');
        await db.execute(_sightingsTableSql);
      },
    );
  }

  // ── Session (remembers logged-in user id between app launches) ──
  // Written on every login/logout, but nothing reads it back anymore —
  // session restore now goes through FirebaseAuth's own persisted session
  // (see AppState.init()) instead of this local pointer, ever since real
  // Firebase Authentication replaced the old local-only login. Left as a
  // lightweight local record of "who was last signed in on this device"
  // rather than removed outright, since it costs nothing to keep writing
  // and other local diagnostics could reasonably want it later.
  Future<void> setSession(String userId) async {
    final d = await db;
    await d.insert('session', {'k': 'currentUserId', 'v': userId},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearSession() async {
    final d = await db;
    await d.delete('session', where: 'k = ?', whereArgs: ['currentUserId']);
  }

  // ── Generic key/value preferences (reuses the session table) ──
  Future<void> setPref(String key, String value) async {
    final d = await db;
    await d.insert('session', {'k': key, 'v': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getPref(String key) async {
    final d = await db;
    final rows = await d.query('session', where: 'k = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['v'] as String?;
  }

  // ── Users ──
  Future<void> upsertUser(UserModel u) async {
    final d = await db;
    await d.insert('users', u.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<UserModel?> getUserById(String id) async {
    final d = await db;
    final rows = await d.query('users', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return UserModel.fromMap(rows.first, id: id);
  }

  // ── Vehicles ──
  Future<void> upsertVehicle(VehicleModel v) async {
    final d = await db;
    await d.insert('vehicles', v.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteVehicle(String id) async {
    final d = await db;
    await d.delete('vehicles', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<VehicleModel>> getVehiclesForOwner(String ownerId) async {
    final d = await db;
    final rows =
        await d.query('vehicles', where: 'ownerId = ?', whereArgs: [ownerId]);
    return rows.map((r) => VehicleModel.fromMap(r)).toList();
  }

  // ── Theft Alerts ──
  Future<void> upsertAlert(TheftAlert a, {bool synced = false}) async {
    final d = await db;
    final map = a.toMap();
    map['synced'] = synced ? 1 : 0;
    await d.insert('theft_alerts', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<TheftAlert>> getAllAlerts() async {
    final d = await db;
    final rows = await d.query('theft_alerts', orderBy: 'timestamp DESC');
    return rows.map((r) => TheftAlert.fromMap(r)).toList();
  }

  Future<bool> alertExists(String id) async {
    final d = await db;
    final rows =
        await d.query('theft_alerts', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty;
  }

  /// Single-alert lookup by id — added for `alert_ingest.dart`'s portable
  /// status-update handling (applying a newer status to an alert this
  /// device already has), which has no in-memory alert list to search the
  /// way `AppState` does, only this database.
  Future<TheftAlert?> getAlertById(String id) async {
    final d = await db;
    final rows =
        await d.query('theft_alerts', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return TheftAlert.fromMap(rows.first);
  }

  Future<List<TheftAlert>> getUnsyncedAlerts() async {
    final d = await db;
    final rows = await d.query('theft_alerts', where: 'synced = 0');
    return rows.map((r) => TheftAlert.fromMap(r)).toList();
  }

  Future<void> markAlertSynced(String id) async {
    final d = await db;
    await d.update('theft_alerts', {'synced': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  // ── Sighting reports ──
  /// Single-sighting lookup by id — added for `alert_ingest.dart`'s portable
  /// sighting dedup (the same reasoning as `getAlertById`: no in-memory list
  /// to search in a background isolate, only this database).
  Future<SightingReport?> getSightingById(String id) async {
    final d = await db;
    final rows =
        await d.query('sightings', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return SightingReport.fromMap(rows.first);
  }

  Future<void> upsertSighting(SightingReport s, {bool synced = false}) async {
    final d = await db;
    final map = s.toMap();
    map['synced'] = synced ? 1 : 0;
    await d.insert('sightings', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Every sighting this account is part of — ones it RECEIVED as an owner,
  /// and ones it SENT as a nearby user — newest sighting first. The table is
  /// shared by every account that has used this phone, hence the filter.
  Future<List<SightingReport>> getSightingsFor(String uid) async {
    final d = await db;
    final rows = await d.query('sightings',
        where: 'ownerId = ? OR reporterId = ?',
        whereArgs: [uid, uid],
        orderBy: 'seenAt DESC');
    return rows.map((r) => SightingReport.fromMap(r)).toList();
  }

  /// Sightings this account wrote that haven't reached the cloud yet.
  Future<List<SightingReport>> getUnsyncedSightings(String reporterId) async {
    final d = await db;
    final rows = await d.query('sightings',
        where: 'synced = 0 AND reporterId = ?', whereArgs: [reporterId]);
    return rows.map((r) => SightingReport.fromMap(r)).toList();
  }

  Future<void> markSightingSynced(String id) async {
    final d = await db;
    await d.update('sightings', {'synced': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  // ── Alert relay logs (per-node delivery record, used for duplicate detection) ──
  Future<void> addAlertLog({
    required String alertId,
    required String nodeDeviceId,
    required bool duplicate,
    int hopCount = 0,
  }) async {
    final d = await db;
    await d.insert('alert_logs', {
      'alertId': alertId,
      'nodeDeviceId': nodeDeviceId,
      'receivedAt': DateTime.now().toIso8601String(),
      'relayedAt': DateTime.now().toIso8601String(),
      'hopCount': hopCount,
      'duplicateFlag': duplicate ? 1 : 0,
      'syncStatus': 'PENDING',
    });
  }

  Future<bool> hasAlertLog(String alertId, String nodeDeviceId) async {
    final d = await db;
    final rows = await d.query('alert_logs',
        where: 'alertId = ? AND nodeDeviceId = ?',
        whereArgs: [alertId, nodeDeviceId]);
    return rows.isNotEmpty;
  }

  // ── Location history ──
  Future<void> addLocation(LocationRecord r) async {
    final d = await db;
    await d.insert('location_history', r.toMap());
  }

  Future<List<LocationRecord>> getLocationHistory(String vehicleId) async {
    final d = await db;
    final rows = await d.query('location_history',
        where: 'vehicleId = ?',
        whereArgs: [vehicleId],
        orderBy: 'time DESC',
        limit: 100);
    return rows.map((r) => LocationRecord.fromMap(r)).toList();
  }

  Future<List<LocationRecord>> getAllLocationHistory() async {
    final d = await db;
    final rows =
        await d.query('location_history', orderBy: 'time DESC', limit: 200);
    return rows.map((r) => LocationRecord.fromMap(r)).toList();
  }

  Future<List<LocationRecord>> getUnsyncedLocations() async {
    final d = await db;
    final rows = await d.query('location_history', where: 'synced = 0');
    return rows.map((r) => LocationRecord.fromMap(r)).toList();
  }

  Future<void> markLocationSynced(int dbId) async {
    final d = await db;
    await d.update('location_history', {'synced': 1},
        where: 'dbId = ?', whereArgs: [dbId]);
  }

  // ── Nodes ──
  Future<void> upsertNode(AdHocNode n) async {
    final d = await db;
    await d.insert(
        'nodes',
        {
          'id': n.id,
          'name': n.name,
          'distance': n.distance,
          'isOnline': n.isOnline ? 1 : 0,
          'connectionType': n.connectionType.index,
          'hopCount': n.hopCount,
          'relayStatus': n.relayStatus.index,
          'mapX': n.mapX,
          'mapY': n.mapY,
          'isSimulated': n.isSimulated ? 1 : 0,
          'endpointId': n.endpointId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteNode(String id) async {
    final d = await db;
    await d.delete('nodes', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<AdHocNode>> getNodes() async {
    final d = await db;
    final rows = await d.query('nodes');
    return rows
        .map((r) => AdHocNode(
              id: r['id'] as String,
              name: r['name'] as String,
              distance: (r['distance'] as num).toDouble(),
              isOnline: (r['isOnline'] as int) == 1,
              connectionType: ConnectionType.values[r['connectionType'] as int],
              hopCount: r['hopCount'] as int,
              relayStatus: RelayStatus.values[r['relayStatus'] as int],
              mapX: (r['mapX'] as num).toDouble(),
              mapY: (r['mapY'] as num).toDouble(),
              isSimulated: (r['isSimulated'] as int? ?? 1) == 1,
              endpointId: r['endpointId'] as String?,
            ))
        .toList();
  }

  // ── Notifications ──
  Future<void> addNotification(NotifItem n) async {
    final d = await db;
    await d.insert('notifications', n.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<NotifItem>> getNotifications() async {
    final d = await db;
    final rows =
        await d.query('notifications', orderBy: 'time DESC', limit: 100);
    return rows.map((r) => NotifItem.fromMap(r)).toList();
  }

  Future<void> markAllNotificationsRead() async {
    final d = await db;
    await d.update('notifications', {'isRead': 1});
  }

  // ── System logs ──
  Future<void> addSystemLog(SystemLog log) async {
    final d = await db;
    await d.insert('system_logs', log.toMap());
    // keep table bounded
    final count = Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM system_logs')) ??
        0;
    if (count > 300) {
      await d.rawDelete(
          'DELETE FROM system_logs WHERE id IN (SELECT id FROM system_logs ORDER BY id ASC LIMIT ?)',
          [count - 300]);
    }
  }

  Future<List<SystemLog>> getSystemLogs() async {
    final d = await db;
    final rows = await d.query('system_logs', orderBy: 'id DESC', limit: 300);
    return rows.map((r) => SystemLog.fromMap(r)).toList();
  }

  Future<void> clearSystemLogs() async {
    final d = await db;
    await d.delete('system_logs');
  }
}
