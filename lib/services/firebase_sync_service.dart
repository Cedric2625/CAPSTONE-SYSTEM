import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/models.dart';
import 'database_service.dart';

/// Uploads locally-stored data to Firebase Firestore whenever the device is
/// online. This is the real implementation behind the ONLINE/SYNCING/SYNC
/// COMPLETE indicators that were previously cosmetic — every alert and
/// location record marked "synced" here has actually round-tripped to
/// Firestore, not just had a local flag flipped.
///
/// Collections (flat, not nested under a user — see note below):
///   /theft_alerts/{alertId}       — one document per TheftAlert
///   /location_history/{dbId}      — one document per LocationRecord
///
/// NOTE on scope: system logs are intentionally NOT synced here. They're
/// local diagnostic data (useful for debugging on-device), not something
/// your manuscript's centralized dashboard needs — syncing them would mean
/// adding sync-tracking to a table that doesn't have it yet for marginal
/// value. Documented as a deliberate scope decision, not an oversight.
///
/// NOTE on security: now that registration/login go through real Firebase
/// Authentication (see FirebaseAuthService), Firestore rules should require
/// `request.auth != null` at minimum, and can compare `request.auth.uid`
/// against a document's `userId`/`id` field for real per-owner ownership —
/// no longer just "wide open" rules with no identity behind them.
class FirebaseSyncService {
  FirebaseSyncService._();
  static final FirebaseSyncService instance = FirebaseSyncService._();

  final _db = DatabaseService.instance;
  final _firestore = FirebaseFirestore.instance;
  static const Duration _cloudTimeout = Duration(seconds: 12);

  /// Uploads every unsynced alert and location record. Returns the total
  /// count of records successfully synced (0 is a valid "nothing pending"
  /// result, not an error). Throws if there WAS pending data but none of it
  /// went through (e.g. genuinely offline, or rejected by security rules) —
  /// previously this caught every per-item exception and silently returned
  /// 0, so a total failure looked identical to "nothing to sync" and the
  /// caller (AppState) always showed SYNC COMPLETE, never SYNC FAILED.
  Future<int> syncAll() async {
    final (alertsAttempted, alertsSynced) = await _syncAlerts();
    final (locationsAttempted, locationsSynced) = await _syncLocations();
    final (sightingsAttempted, sightingsSynced) = await _syncSightings();
    final totalAttempted =
        alertsAttempted + locationsAttempted + sightingsAttempted;
    final totalSynced = alertsSynced + locationsSynced + sightingsSynced;
    if (totalAttempted > 0 && totalSynced == 0) {
      throw Exception(
          'Firestore sync failed: 0 of $totalAttempted record(s) uploaded.');
    }
    return totalSynced;
  }

  /// Returns (attempted, synced) rather than just a count, so [syncAll] can
  /// tell "nothing was pending" apart from "everything pending failed".
  ///
  /// SECURITY: a device that only RECEIVED an alert (over the mesh or the
  /// internet feed) also uploads its local copy — that's the store-carry-
  /// forward design — but that copy must never be treated as authoritative
  /// over the reporter's own data. This used to `.set()` the WHOLE document
  /// regardless of who was uploading, which matched a Firestore rule that
  /// let any signed-in user rewrite any alert's status/owner/location. Now
  /// that the rule only lets the original reporter (or an admin) change
  /// those fields, a non-reporter's upload only ever touches its own
  /// relay-chain bookkeeping (`hopCount`/`relayedTo`) via a field-limited
  /// merge — never the alert's status, ownership, location, or vehicle
  /// info — so it passes the rule instead of being rejected outright.
  Future<(int, int)> _syncAlerts() async {
    final unsynced = await _db.getUnsyncedAlerts();
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    var synced = 0;
    for (final alert in unsynced) {
      try {
        final ref = _firestore.collection('theft_alerts').doc(alert.id);
        // Bounded: Firestore writes wait for the server, so on Wi-Fi with no
        // real internet a plain await here could stall every later sync.
        final existing = await ref.get().timeout(_cloudTimeout);
        if (existing.exists) {
          // Statuses only ever move forward (active → recovered →
          // resolved) — a stale local copy must never downgrade one that's
          // already newer on the server.
          final cloudStatus = (existing.data()?['status'] as num?)?.toInt();
          if (cloudStatus != null && cloudStatus > alert.status.index) {
            await _db.markAlertSynced(alert.id);
            synced++;
            continue;
          }
          final isReporter = myUid != null && alert.userId == myUid;
          if (!isReporter) {
            // Relaying device, and the reporter (or an earlier relay)
            // already created this document — only bookkeeping fields are
            // ours to update.
            await ref.set({
              'hopCount': alert.hopCount,
              'relayedTo': alert.relayedTo.join(','),
            }, SetOptions(merge: true)).timeout(_cloudTimeout);
            await _db.markAlertSynced(alert.id);
            synced++;
            continue;
          }
        }
        // Either this device IS the reporter, or nobody has uploaded this
        // alert yet (a relay device getting there first, while the
        // reporter's own phone has no internet) — a full upsert is correct
        // in both cases, and the Firestore rule allows creating a missing
        // document regardless of who's doing it.
        await ref
            .set(Map<String, dynamic>.from(alert.toMap()))
            .timeout(_cloudTimeout);
        await _db.markAlertSynced(alert.id);
        synced++;
      } catch (e) {
        // Leave this one unsynced — it'll retry on the next connectivity
        // event rather than being silently dropped. One failed upload
        // shouldn't block the rest of the batch.
        continue;
      }
    }
    return (unsynced.length, synced);
  }

  // ── Alert delivery delay log (measures the real end-to-end delay) ───
  // One document per alert a device RECEIVES (never for the reporter's own
  // alert): how long after it was sent it actually arrived here, over which
  // layer (mesh or internet), and at what hop count. This is what the admin
  // dashboard's delivery-delay list/average is built from — previously
  // `alertDelay`/`transmissionRate` only measured the REPORTER's own
  // broadcast step, never the receiving device's real end-to-end delay.
  // Auto-ID'd (no uniqueness to enforce — every receipt is its own record).
  // Needs:
  //   match /alert_deliveries/{deliveryId} {
  //     allow create: if request.auth != null;
  //     allow get, list: if request.auth != null;
  //   }
  CollectionReference<Map<String, dynamic>> get _alertDeliveriesRef =>
      _firestore.collection('alert_deliveries');

  /// Records one receipt of [alertId] on this device. Best-effort — never
  /// throws, since this is a measurement/analytics write, not something the
  /// receive path should ever be blocked or slowed down by.
  Future<void> logAlertDelivery({
    required String alertId,
    required String plate,
    required String via, // 'Ad Hoc Mesh' | 'Internet'
    required int hopCount,
    required DateTime sentAt,
    required DateTime receivedAt,
  }) async {
    try {
      await _alertDeliveriesRef.add({
        'alertId': alertId,
        'plate': plate,
        'via': via,
        'hopCount': hopCount,
        'sentAt': sentAt.toIso8601String(),
        'receivedAt': receivedAt.toIso8601String(),
        'delayMs': receivedAt.difference(sentAt).inMilliseconds,
      }).timeout(_cloudTimeout);
    } catch (_) {
      // Offline, or the rule above isn't published yet — the delay is still
      // in this device's own System Logs either way (see AppState).
    }
  }

  // ── Sighting reports (nearby user → vehicle owner) ──────────────────
  // Stored in a top-level /sightings collection (not nested under the alert
  // or the owner) so the OWNER can listen with a single equality query on
  // `ownerId` — no composite or collection-group index needed — while the
  // reporter can still write to it. The compressed proof photo travels as
  // base64 inside the document, same approach (and same reason) as the
  // profile photo: Cloud Storage needs a paid plan for new projects. Needs:
  //   match /sightings/{sightingId} {
  //     allow create: if request.auth != null && request.resource.data.reporterId == request.auth.uid && request.resource.data.id == sightingId;
  //     allow update: if request.auth != null && resource.data.reporterId == request.auth.uid && request.resource.data.reporterId == request.auth.uid;
  //     allow get, list: if request.auth != null && (resource.data.ownerId == request.auth.uid || resource.data.reporterId == request.auth.uid || isAdmin());
  //     allow delete: if request.auth != null && isAdmin();
  //   }
  CollectionReference<Map<String, dynamic>> get _sightingsRef =>
      _firestore.collection('sightings');

  /// Uploads one sighting. Throws if it can't be delivered — the caller
  /// keeps the local copy queued and [_syncSightings] retries later.
  Future<void> uploadSighting(SightingReport s) => _sightingsRef
      .doc(s.id)
      .set(Map<String, dynamic>.from(s.toMap()))
      .timeout(const Duration(seconds: 20));

  /// Retries every sighting THIS account wrote that hasn't reached the cloud
  /// yet (sent while offline, or right when the connection dropped).
  Future<(int, int)> _syncSightings() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return (0, 0);
    final unsynced = await _db.getUnsyncedSightings(uid);
    var synced = 0;
    for (final s in unsynced) {
      try {
        await uploadSighting(s);
        await _db.markSightingSynced(s.id);
        synced++;
      } catch (_) {
        continue; // stays queued for the next attempt
      }
    }
    return (unsynced.length, synced);
  }

  // ── Driver's license verification ───────────────────────────────────
  // Two private documents per account, one per side, each holding a small
  // base64 JPEG (kept separate so each stays under Firestore's 1 MB limit).
  // Needs:
  //   match /users/{uid}/license/{side} {
  //     allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
  //     allow create, update: if request.auth != null && request.auth.uid == uid
  //                           && (side == 'front' || side == 'back');
  //     allow delete: if request.auth != null && isAdmin();
  //   }
  CollectionReference<Map<String, dynamic>> _licenseRef(String uid) =>
      _firestore.collection('users').doc(uid).collection('license');

  Future<void> uploadLicense(
      {required String uid,
      required Uint8List front,
      required Uint8List back}) {
    final batch = _firestore.batch();
    final now = DateTime.now().toIso8601String();
    for (final e in {'front': front, 'back': back}.entries) {
      batch.set(_licenseRef(uid).doc(e.key), {
        'side': e.key,
        'imageB64': base64Encode(e.value),
        'capturedAt': now,
      });
    }
    return batch.commit().timeout(const Duration(seconds: 30));
  }

  /// Whether both sides are on file. A count query, so it never downloads the
  /// photos themselves.
  Future<bool> hasLicense(String uid) async {
    final agg = await _licenseRef(uid).count().get().timeout(_cloudTimeout);
    return (agg.count ?? 0) >= 2;
  }

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sightingFeed;

  /// Live feed of sightings reported about [ownerId]'s stolen vehicles.
  /// [onSighting] gets each new or changed document's data.
  void startSightingFeed({
    required String ownerId,
    required void Function(Map<String, dynamic> data) onSighting,
    required void Function(Object error) onError,
  }) {
    stopSightingFeed();
    try {
      _sightingFeed = _sightingsRef
          .where('ownerId', isEqualTo: ownerId)
          .snapshots()
          .listen((snapshot) {
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.removed) continue;
          final data = change.doc.data();
          if (data != null) onSighting(data);
        }
      }, onError: onError);
    } catch (e) {
      onError(e);
    }
  }

  void stopSightingFeed() {
    _sightingFeed?.cancel();
    _sightingFeed = null;
  }

  // ── Internet alert feed (the manuscript's second delivery layer) ────
  // When Bluetooth/Wi-Fi Direct discovery can't link two phones (radios off,
  // out of range, an OEM blocking scans…), alerts still have to reach other
  // users. Every reporter already uploads its alert to /theft_alerts, so any
  // signed-in device can simply listen to that collection live. Requires the
  // Firestore rules to let signed-in users READ theft_alerts.
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _alertFeed;

  /// Starts listening for alerts reported in the last 24 hours. [onAlert]
  /// receives each new or changed alert document's data; [onError] is called
  /// if the feed can't be opened (typically a Firestore rules denial).
  void startAlertFeed({
    required void Function(Map<String, dynamic> data) onAlert,
    required void Function(Object error) onError,
  }) {
    stopAlertFeed();
    try {
      // ISO-8601 timestamps sort lexicographically, so a plain string range
      // works (and needs no composite index).
      final cutoff =
          DateTime.now().subtract(const Duration(hours: 24)).toIso8601String();
      _alertFeed = _firestore
          .collection('theft_alerts')
          .where('timestamp', isGreaterThan: cutoff)
          .snapshots()
          .listen((snapshot) {
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.removed) continue;
          final data = change.doc.data();
          if (data != null) onAlert(data);
        }
      }, onError: onError);
    } catch (e) {
      onError(e);
    }
  }

  void stopAlertFeed() {
    _alertFeed?.cancel();
    _alertFeed = null;
  }

  // ── User profiles ──────────────────────────────────────────────
  // The authoritative cloud copy of the account (Table 3.3.2.1: "Backend /
  // Database: Firebase (Firestore, Auth)"). The local SQLite copy (see
  // DatabaseService.upsertUser/getUserById) is only an offline-access
  // cache — it never carries a password or anything Firebase Auth already
  // owns, so a stolen/extracted local database exposes no credential.
  Future<void> upsertUserProfile(UserModel user) async {
    try {
      // Merge, not overwrite: this document also carries fields UserModel
      // doesn't know about — `photoB64` (see below) and `disabled` (set only
      // by an admin from the Admin Dashboard, see AdminService). A plain
      // `.set()` here would silently erase those every time the OWNER's own
      // device re-uploads its profile (every login/registration/edit).
      await _firestore.collection('users').doc(user.id).set(
          Map<String, dynamic>.from(user.toMap()), SetOptions(merge: true));
    } catch (_) {
      // Offline or unreachable — the local SQLite cache already has this
      // profile; the next successful sync will catch Firestore up.
    }
  }

  // ── Admin approval of new registrations ───────────────────────────────
  // A new account is written with `approvalStatus: 'pending'` only after its
  // license, vehicle and OR/CR photos are all uploaded (see
  // AppState.submitRegistration). An admin sets it to 'approved' or
  // 'rejected' from the Admin Dashboard. Accounts with no status field
  // (everything registered before this existed) are treated as approved.
  // Firestore rules must stop a user changing their own status — see
  // Progress.md for the exact rule block.

  /// Writes a brand-new account's profile as pending review. Unlike
  /// [upsertUserProfile] this THROWS on failure — the registration must not
  /// be reported as submitted unless it actually reached the cloud.
  Future<void> submitProfileForApproval(UserModel user) =>
      _firestore.collection('users').doc(user.id).set({
        ...user.toMap(),
        'approvalStatus': 'pending',
        'submittedAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true)).timeout(_cloudTimeout);

  /// The account's current approval state from the server, or null when it
  /// couldn't be read (offline, rules). [reason] is set only for a rejection.
  Future<({String? status, String? reason})?> fetchApprovalStatus(
      String uid) async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.server))
          .timeout(_cloudTimeout);
      final data = doc.data();
      return (
        status: data?['approvalStatus'] as String?,
        reason: data?['rejectionReason'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Live approval state of one account — used by the Awaiting Approval
  /// screen so an admin's decision reaches the phone without a relaunch.
  Stream<({String? status, String? reason})> watchApprovalStatus(String uid) =>
      _firestore.collection('users').doc(uid).snapshots().map((snap) => (
            status: snap.data()?['approvalStatus'] as String?,
            reason: snap.data()?['rejectionReason'] as String?,
          ));

  /// One-shot check used at the moment of login/Google sign-in, before the
  /// session is ever completed — see AppState.login()/signInWithGoogle().
  /// True for either a SUSPENDED account (`users/{uid}.disabled`, still has
  /// a profile document, reversible) or a PERMANENTLY REMOVED one (its
  /// `users/{uid}` document is gone entirely — see AdminService.removeUser
  /// — so the block lives in the separate `removed_accounts/{uid}`
  /// tombstone instead, which survives the profile being deleted). Fails
  /// "open" (false) when unreachable rather than locking someone out over a
  /// network blip; the live watch below still catches either case while a
  /// session is already running.
  Future<bool> isAccountDisabled(String uid) async {
    try {
      final results = await Future.wait([
        _firestore
            .collection('users')
            .doc(uid)
            .get()
            .timeout(const Duration(seconds: 6)),
        _firestore
            .collection('removed_accounts')
            .doc(uid)
            .get()
            .timeout(const Duration(seconds: 6)),
      ]);
      return results[0].data()?['disabled'] == true || results[1].exists;
    } catch (_) {
      return false;
    }
  }

  // ── Account status watch (admin can suspend or remove an account) ────
  // While signed in, a phone listens to its own /users/{uid} document AND
  // /removed_accounts/{uid} so an admin suspending or permanently removing
  // the account from the Admin Dashboard takes effect immediately — not
  // just on the next login attempt.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _accountFeed;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _removedFeed;

  void startAccountWatch({
    required String uid,
    required void Function(bool disabled) onChange,
    required void Function(Object error) onError,
  }) {
    stopAccountWatch();
    var suspended = false;
    var removed = false;
    void emit() => onChange(suspended || removed);
    try {
      _accountFeed =
          _firestore.collection('users').doc(uid).snapshots().listen((snap) {
        suspended = snap.data()?['disabled'] == true;
        emit();
      }, onError: onError);
      _removedFeed = _firestore
          .collection('removed_accounts')
          .doc(uid)
          .snapshots()
          .listen((snap) {
        removed = snap.exists;
        emit();
      }, onError: onError);
    } catch (e) {
      onError(e);
    }
  }

  void stopAccountWatch() {
    _accountFeed?.cancel();
    _accountFeed = null;
    _removedFeed?.cancel();
    _removedFeed = null;
  }

  // ── Presence (which registered devices are active nearby) ───────────
  // Bluetooth discovery can't be relied on across every phone, so signed-in
  // phones with the real mesh turned on also share a live position here
  // while the app is open. Every phone lists the ones within range. Needs:
  //   match /presence/{uid} {
  //     allow get, list: if request.auth != null;
  //     allow create, update, delete: if request.auth != null && request.auth.uid == uid;
  //   }
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _presenceFeed;

  Future<void> publishPresence({
    required String uid,
    required String name,
    required String deviceId,
    required double lat,
    required double lng,
  }) {
    return _firestore.collection('presence').doc(uid).set({
      'uid': uid,
      'name': name,
      'deviceId': deviceId,
      'lat': lat,
      'lng': lng,
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
    }).timeout(_cloudTimeout);
  }

  Future<void> deletePresence(String uid) => _firestore
      .collection('presence')
      .doc(uid)
      .delete()
      .timeout(_cloudTimeout);

  /// Streams presence documents recently updated. [onChange] gets each
  /// changed document (or `removed: true` when one is deleted).
  void startPresenceFeed({
    required void Function(String uid, Map<String, dynamic>? data) onChange,
    required void Function(Object error) onError,
  }) {
    stopPresenceFeed();
    try {
      final cutoff = DateTime.now()
          .subtract(const Duration(minutes: 10))
          .millisecondsSinceEpoch;
      _presenceFeed = _firestore
          .collection('presence')
          .where('updatedAtMs', isGreaterThan: cutoff)
          .snapshots()
          .listen((snapshot) {
        for (final change in snapshot.docChanges) {
          onChange(
              change.doc.id,
              change.type == DocumentChangeType.removed
                  ? null
                  : change.doc.data());
        }
      }, onError: onError);
    } catch (e) {
      onError(e);
    }
  }

  void stopPresenceFeed() {
    _presenceFeed?.cancel();
    _presenceFeed = null;
  }

  // ── Profile photo ───────────────────────────────────────────────
  // A small (resized, compressed) picture stored as base64 on the user's own
  // profile document, so it comes back on a new phone. The Cloud Storage
  // product needs a paid plan for new projects; a ~30-60 KB image fits
  // comfortably in the free Firestore document.
  Future<String?> fetchProfilePhoto(String uid) async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 6));
      return doc.data()?['photoB64'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveProfilePhoto(String uid, String? photoB64) {
    return _firestore.collection('users').doc(uid).set(
      {'photoB64': photoB64 ?? FieldValue.delete()},
      SetOptions(merge: true),
    ).timeout(_cloudTimeout);
  }

  // ── Full-name registry (best-effort duplicate check) ─────────────
  // A small top-level collection, the same shape as the plates registry
  // below, keyed by a case/whitespace-normalized full name (see
  // normalizedFullName in validators.dart) → {ownerId, name}. Unlike a
  // plate, a full name isn't a genuinely scarce real-world resource — two
  // different real people can legitimately share one — so this is a
  // best-effort existence check done BEFORE the Firebase Auth account is
  // even created (see AppState.submitRegistration()), not an atomic
  // transaction like a plate's: a collision from two people registering the
  // exact same name in the same instant is an acceptable, narrow race for
  // something this low-stakes. `create`/`delete` also allow an admin, not
  // just the account itself — AdminService.removeUser() and the dashboard's
  // one-time backfill (see AdminService._backfillNameClaims) write or
  // delete OTHER accounts' claims (the ADMIN is the one signed in when
  // those writes happen, not the account being claimed for/released).
  // Needs:
  //   match /account_names/{nameId} {
  //     allow get: if request.auth != null;
  //     allow create: if request.auth != null &&
  //                   (request.resource.data.ownerId == request.auth.uid || isAdmin());
  //     allow delete: if request.auth != null &&
  //                   (resource.data.ownerId == request.auth.uid || isAdmin());
  //   }
  CollectionReference<Map<String, dynamic>> get _accountNamesRef =>
      _firestore.collection('account_names');

  /// Whether [normalizedName] is already claimed by any account. Throws when
  /// unreachable — the caller must never treat "couldn't check" as
  /// "available" (same reasoning as [claimPlateIfAvailable]).
  Future<bool> isNameTaken(String normalizedName) async {
    final doc =
        await _accountNamesRef.doc(normalizedName).get().timeout(_cloudTimeout);
    return doc.data()?['ownerId'] != null;
  }

  /// Claims [normalizedName] for [ownerId] — best-effort, called right after
  /// a new account is created. Never throws: a failed claim only means a
  /// later registration's duplicate check might miss this one name, not
  /// that anything about the new account itself is broken.
  Future<void> claimName(
      String normalizedName, String name, String ownerId) async {
    try {
      await _accountNamesRef
          .doc(normalizedName)
          .set({'ownerId': ownerId, 'name': name}).timeout(_cloudTimeout);
    } catch (_) {}
  }

  // Freeing a name when its account is permanently deleted is handled
  // directly in AdminService.removeUser (the only place an account is ever
  // deleted) rather than here — that file deliberately never imports this
  // service (see its own class doc: importing DatabaseService/sqflite would
  // break its web build).

  // ── Plate uniqueness registry ───────────────────────────────────
  // A small top-level collection, deliberately separate from each owner's
  // PRIVATE /users/{uid}/vehicles — so checking whether a plate is already
  // taken never requires reading another user's actual vehicle data, only
  // this one opaque {ownerId, plate, vehicleId} record. Keyed by a
  // normalized plate (see AppState._normalizedPlateKey) so "ABC-123",
  // "ABC 123", and "ABC123" all collide as the same real-world plate even
  // though each owner's own vehicle document can keep its own formatting.
  // Needs:
  //   match /plates/{plateId} {
  //     allow get: if request.auth != null;
  //     allow create: if request.auth != null && request.resource.data.ownerId == request.auth.uid;
  //     allow update: if request.auth != null && resource.data.ownerId == request.auth.uid && request.resource.data.ownerId == request.auth.uid;
  //     allow delete: if request.auth != null && resource.data.ownerId == request.auth.uid;
  //   }
  CollectionReference<Map<String, dynamic>> get _platesRef =>
      _firestore.collection('plates');

  /// Atomically checks whether [normalizedPlate] is already claimed by a
  /// DIFFERENT owner and, if not, claims/re-claims it for [ownerId] — a
  /// Firestore transaction, not a separate read-then-write, so two people
  /// registering the exact same plate at the same moment can't both "win"
  /// (a plain check-then-write has exactly that race). Returns null on
  /// success (newly claimed, or re-claimed by its existing owner — e.g.
  /// re-registering after removing and re-adding the same vehicle), or the
  /// uid that already holds it. Throws if unreachable — the caller
  /// (AppState.addVehicle) must never treat "couldn't check" as "available".
  Future<String?> claimPlateIfAvailable({
    required String normalizedPlate,
    required String plate,
    required String ownerId,
    required String vehicleId,
  }) {
    final ref = _platesRef.doc(normalizedPlate);
    return _firestore.runTransaction<String?>((tx) async {
      final snap = await tx.get(ref);
      final existingOwner = snap.data()?['ownerId'] as String?;
      if (existingOwner != null && existingOwner != ownerId) {
        return existingOwner;
      }
      tx.set(ref, {'ownerId': ownerId, 'plate': plate, 'vehicleId': vehicleId});
      return null;
    }).timeout(_cloudTimeout);
  }

  /// Frees a plate so it can be registered again later — by this same
  /// owner, or by whoever legitimately owns it next (e.g. after a
  /// real-world sale). Best-effort: never throws, since a failed release
  /// (offline right when a vehicle is removed) is a narrow, recoverable
  /// edge case and must never block the removal itself from completing.
  Future<void> releasePlate(String normalizedPlate) async {
    try {
      await _platesRef.doc(normalizedPlate).delete().timeout(_cloudTimeout);
    } catch (_) {
      // Left claimed until the next attempt (see AppState._syncVehicles'
      // pending-delete retry, which tries this again) or a manual Console
      // cleanup — not worth failing the vehicle removal over.
    }
  }

  // ── Vehicles ───────────────────────────────────────────────────
  // Stored privately under the owner: /users/{uid}/vehicles/{vehicleId}.
  // Vehicles used to live ONLY in the phone's local database, so they
  // vanished on a reinstall, on a second phone, or when the account was
  // re-created. Needs this Firestore rule (owner-only):
  //   match /users/{uid}/vehicles/{vehicleId} {
  //     allow read, write: if request.auth != null && request.auth.uid == uid;
  //   }
  CollectionReference<Map<String, dynamic>> _vehiclesRef(String uid) =>
      _firestore.collection('users').doc(uid).collection('vehicles');

  /// Every vehicle the cloud has for [uid]. Deliberately reads from the
  /// SERVER: offline, a cache read could return an empty list, which would
  /// look like "everything was deleted elsewhere". Throws when unreachable.
  Future<List<VehicleModel>> fetchVehicles(String uid) async {
    final snap = await _vehiclesRef(uid)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 8));
    return snap.docs
        .map((d) =>
            VehicleModel.fromMap(Map<String, Object?>.from(d.data()), id: d.id))
        .toList();
  }

  Future<void> upsertVehicle(String uid, VehicleModel v) =>
      _vehiclesRef(uid).doc(v.id).set(Map<String, dynamic>.from(v.toMap()));

  // ── Vehicle OR/CR documents ─────────────────────────────────────────
  // Two private documents per vehicle — `or` (Official Receipt) and `cr`
  // (Certificate of Registration) — each a small base64 JPEG, kept separate so
  // each stays under Firestore's 1 MB limit. Needs:
  //   match /users/{uid}/vehicles/{vehicleId}/documents/{docId} {
  //     allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
  //     allow create, update: if request.auth != null && request.auth.uid == uid
  //                           && (docId == 'or' || docId == 'cr');
  //     allow delete: if request.auth != null && (request.auth.uid == uid || isAdmin());
  //   }
  CollectionReference<Map<String, dynamic>> _vehicleDocsRef(
          String uid, String vehicleId) =>
      _vehiclesRef(uid).doc(vehicleId).collection('documents');

  Future<void> uploadVehicleDocuments(
      {required String uid,
      required String vehicleId,
      required Uint8List or,
      required Uint8List cr}) {
    final batch = _firestore.batch();
    final now = DateTime.now().toIso8601String();
    for (final e in {'or': or, 'cr': cr}.entries) {
      batch.set(_vehicleDocsRef(uid, vehicleId).doc(e.key), {
        'kind': e.key,
        'imageB64': base64Encode(e.value),
        'capturedAt': now,
      });
    }
    return batch.commit().timeout(const Duration(seconds: 30));
  }

  /// Removes a vehicle AND its OR/CR photos (Firestore doesn't delete a
  /// document's subcollections along with it).
  Future<void> deleteVehicle(String uid, String vehicleId) async {
    try {
      final docs = await _vehicleDocsRef(uid, vehicleId).get();
      for (final d in docs.docs) {
        await d.reference.delete();
      }
    } on FirebaseException catch (e) {
      // A rules refusal would repeat forever and keep the vehicle (and its
      // plate) from ever being removed — so only a connection problem, which
      // the caller retries, is allowed to stop here.
      if (e.code != 'permission-denied') rethrow;
    }
    await _vehiclesRef(uid).doc(vehicleId).delete();
  }

  /// Fetches a user's profile from Firestore, or null if unreachable/absent.
  Future<UserModel?> fetchUserProfile(String uid) async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 6));
      if (!doc.exists) return null;
      return UserModel.fromMap(doc.data()!, id: uid);
    } catch (_) {
      return null;
    }
  }

  Future<(int, int)> _syncLocations() async {
    final unsynced = await _db.getUnsyncedLocations();
    var synced = 0;
    for (final loc in unsynced) {
      if (loc.dbId == null) continue;
      try {
        // dbId is a per-phone counter (every phone has a record 1, 2, 3…), so
        // using it alone as the document ID made two users collide on the
        // same document — and the rules only allow CREATING location
        // documents, so the second phone's upload was denied every time.
        // The vehicle ID (unique per vehicle) makes the ID unique across users.
        await _firestore
            .collection('location_history')
            .doc('${loc.vehicleId}_${loc.dbId}')
            .set(Map<String, dynamic>.from(loc.toMap()))
            .timeout(_cloudTimeout);
        await _db.markLocationSynced(loc.dbId!);
        synced++;
      } catch (e) {
        continue;
      }
    }
    return (unsynced.length, synced);
  }
}
