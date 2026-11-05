import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/models.dart';
import '../utils/validators.dart';

/// Parses each of [docs] with [parse], skipping (not crashing on) any single
/// one that fails — malformed data in one document (a hand-edited record
/// missing a field, a partial write) must never blank an entire admin list.
/// [parse] also gets the document's own ID, the source of truth for a
/// model's `id` field (see `UserModel.fromMap`/`VehicleModel.fromMap`);
/// callers that don't need it can just ignore the second argument.
List<T> _parseSkippingBad<T>(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    T Function(Map<String, Object?> data, String docId) parse) {
  final out = <T>[];
  for (final d in docs) {
    try {
      out.add(parse(Map<String, Object?>.from(d.data()), d.id));
    } catch (_) {}
  }
  return out;
}

/// One registered account as the Admin Dashboard sees it: the same profile
/// every screen already uses ([UserModel]), plus the one extra field that's
/// deliberately kept OUT of UserModel — `disabled` — the same way the
/// profile photo (`photoB64`) is kept as a side document field rather than
/// a UserModel property (see FirebaseSyncService.upsertUserProfile).
class AdminUserRow {
  final UserModel user;
  final bool disabled;

  /// How many vehicles the account registered, and whether both driver's
  /// license photos are on file — null when that couldn't be read (the row
  /// still shows; the value just displays as unknown).
  final int? vehicleCount;
  final bool? licenseOnFile;

  /// 'pending' | 'approved' | 'rejected' — null for accounts registered before
  /// approval existed (treated as approved).
  final String? approvalStatus;
  const AdminUserRow(this.user, this.disabled,
      {this.vehicleCount, this.licenseOnFile, this.approvalStatus});
}

/// A new registration waiting on an admin's decision.
typedef PendingRegistration = ({UserModel user, DateTime? submittedAt});

/// One registered vehicle as the Admin Dashboard sees it: the vehicle, who
/// owns it, and whether both its OR and CR photos are on file (null when that
/// couldn't be read).
class AdminVehicleRow {
  final VehicleModel vehicle;
  final UserModel owner;
  final bool ownerDisabled;
  final bool? documentsOnFile;
  const AdminVehicleRow(
      {required this.vehicle,
      required this.owner,
      required this.ownerDisabled,
      required this.documentsOnFile});
}

/// A phone that's currently sharing its position (`/presence/{uid}`).
class AdminDevice {
  final String uid;
  final String name;
  final String deviceId;
  final double lat;
  final double lng;
  final DateTime updatedAt;
  const AdminDevice(
      {required this.uid,
      required this.name,
      required this.deviceId,
      required this.lat,
      required this.lng,
      required this.updatedAt});

  /// Phones re-publish every 30 seconds while the app is open, so two minutes
  /// of silence means it closed, lost signal or logged out.
  bool get onlineNow =>
      DateTime.now().difference(updatedAt) < const Duration(minutes: 2);

  static AdminDevice? fromMap(String uid, Map<String, dynamic> m) {
    final lat = (m['lat'] as num?)?.toDouble();
    final lng = (m['lng'] as num?)?.toDouble();
    final ms = (m['updatedAtMs'] as num?)?.toInt();
    if (lat == null || lng == null || ms == null) return null;
    return AdminDevice(
      uid: uid,
      name: m['name'] as String? ?? 'Unknown',
      deviceId: m['deviceId'] as String? ?? '—',
      lat: lat,
      lng: lng,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }
}

/// One receipt of an alert by one device (`/alert_deliveries/{id}`) — the
/// real end-to-end delay measurement: how long after an alert was sent it
/// actually arrived, over which layer, at what hop count. Backs the Live
/// Activity tab's "Delivery Log" filter and its average-delay stat chip.
class AlertDelivery {
  final String alertId;
  final String plate;
  final String via; // 'Ad Hoc Mesh' | 'Internet'
  final int hopCount;
  final DateTime sentAt;
  final DateTime receivedAt;
  final int delayMs;
  const AlertDelivery({
    required this.alertId,
    required this.plate,
    required this.via,
    required this.hopCount,
    required this.sentAt,
    required this.receivedAt,
    required this.delayMs,
  });

  static AlertDelivery? fromMap(Map<String, Object?> m) {
    final sentAt = DateTime.tryParse(m['sentAt'] as String? ?? '');
    final receivedAt = DateTime.tryParse(m['receivedAt'] as String? ?? '');
    if (sentAt == null || receivedAt == null) return null;
    return AlertDelivery(
      alertId: m['alertId'] as String? ?? '',
      plate: m['plate'] as String? ?? 'UNKNOWN',
      via: m['via'] as String? ?? 'Unknown',
      hopCount: (m['hopCount'] as num?)?.toInt() ?? 0,
      sentAt: sentAt,
      receivedAt: receivedAt,
      delayMs: (m['delayMs'] as num?)?.toInt() ??
          receivedAt.difference(sentAt).inMilliseconds,
    );
  }
}

/// The live data behind the dashboard's Live Activity and Map tabs — owned
/// by the dashboard screen so both tabs share ONE set of Firestore
/// listeners. Each source reports its own failure in [errors], so e.g. a
/// missing `sightings` rule doesn't blank the alerts feed.
class AdminMonitorFeed extends ChangeNotifier {
  List<TheftAlert> alerts = const [];
  List<SightingReport> sightings = const [];
  List<AdminDevice> devices = const [];
  List<AlertDelivery> deliveries = const [];
  final Map<String, String> errors = {};
  bool alertsReady = false;
  DateTime? lastUpdate;

  /// Fired for an alert / sighting that appears AFTER the first snapshot —
  /// i.e. genuinely new, not just what was already there on load.
  void Function(TheftAlert alert)? onNewAlert;
  void Function(SightingReport sighting)? onNewSighting;

  final List<StreamSubscription<dynamic>> _subs = [];
  Set<String>? _alertIds;
  Set<String>? _sightingIds;
  bool _disposed = false;

  void start() {
    if (_subs.isNotEmpty) return;
    final svc = AdminService.instance;
    _subs.add(svc.watchAlerts().listen((list) {
      final known = _alertIds;
      if (known != null) {
        for (final a in list) {
          if (!known.contains(a.id)) onNewAlert?.call(a);
        }
      }
      _alertIds = list.map((a) => a.id).toSet();
      alerts = list;
      alertsReady = true;
      errors.remove('alerts');
      _touch();
    }, onError: (Object e) {
      errors['alerts'] = _describe('alerts', e);
      alertsReady = true;
      _touch();
    }));
    _subs.add(svc.watchSightings().listen((list) {
      final known = _sightingIds;
      if (known != null) {
        for (final s in list) {
          if (!known.contains(s.id)) onNewSighting?.call(s);
        }
      }
      _sightingIds = list.map((s) => s.id).toSet();
      sightings = list;
      errors.remove('sightings');
      _touch();
    }, onError: (Object e) {
      errors['sightings'] = _describe('sightings', e);
      _touch();
    }));
    _subs.add(svc.watchDevices().listen((list) {
      devices = list;
      errors.remove('devices');
      _touch();
    }, onError: (Object e) {
      errors['devices'] = _describe('online devices', e);
      _touch();
    }));
    _subs.add(svc.watchAlertDeliveries().listen((list) {
      deliveries = list;
      errors.remove('deliveries');
      _touch();
    }, onError: (Object e) {
      errors['deliveries'] = _describe('delivery delay', e);
      _touch();
    }));
  }

  static String _describe(String what, Object e) => e is FirebaseException &&
          e.code == 'permission-denied'
      ? "Firestore's security rules are blocking the $what feed — publish the latest rules from Progress.md."
      : 'The $what feed is unavailable right now (${e is FirebaseException ? e.code : e}).';

  void _touch() {
    lastUpdate = DateTime.now();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    super.dispose();
  }
}

/// Backs the Admin Dashboard — web-only, see `lib/admin_main.dart` (the
/// phone app has no admin login, link, or route anywhere in it). Every call
/// here reads/writes Firestore directly for OTHER people's accounts — this
/// never goes through AppState's local-first, single-current-user sync
/// path, which only ever knows about the phone's own signed-in
/// vehicle-owner profile, and is intentionally not imported here at all
/// (see the file-level note in `screens/admin/admin_dashboard.dart` about why).
///
/// ── The admin account itself ──────────────────────────────────────
/// There is no hardcoded admin credential and no client-side way to create
/// or promote an admin — both existed here before and were removed as a
/// security fix (see Progress.md, "Admin auth hardened"): a password baked
/// into the compiled web bundle can be read straight out of it, and
/// auto-creating the admin account on first login meant whoever reached
/// this screen first became admin. An admin account is now created by
/// hand in the Firebase Console (a normal email/password Authentication
/// user, plus a `role: 'admin'` field set directly on its Firestore
/// `users/{uid}` document — see Progress.md for the exact steps) and
/// [login] only ever verifies against that: sign in with Firebase Auth,
/// then confirm `role == 'admin'` on that account's own Firestore document
/// before granting access. Authenticating successfully is necessary but
/// not sufficient — a real, registered vehicle-owner account can sign in
/// here too, and is correctly turned away for not being an admin.
///
/// Requires Firestore rules where only an account with `role == 'admin'`
/// can read every `users/{uid}` document (and its `vehicles` subcollection),
/// delete a user doc, or update someone else's `theft_alerts` document,
/// plus a rule for the `removed_accounts/{uid}` tombstone [removeUser]
/// writes — see Progress.md for the exact rules to publish. Note that
/// `role` itself is NOT one of the fields an admin (or anyone) can change
/// through those rules — no write this app can ever issue, admin session
/// or not, is allowed to result in `role: 'admin'`. Every account is
/// created through self-registration (see AppState.submitRegistration()),
/// which never touches `role` at all. The Console edit that creates an
/// admin bypasses these rules entirely (Console access isn't subject to
/// them), which is the ONLY place that can ever happen.
class AdminService {
  AdminService._();
  static final AdminService instance = AdminService._();

  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  static const Duration _timeout = Duration(seconds: 12);

  bool get isSignedIn => _auth.currentUser != null;
  String? get currentAdminUid => _auth.currentUser?.uid;
  String? get currentAdminEmail => _auth.currentUser?.email;

  /// Signs in with a real Firebase email/password account, then checks that
  /// account's OWN Firestore document for `role == 'admin'` before granting
  /// access — being able to authenticate (any registered vehicle owner can)
  /// is not the same as being an admin. Returns null on success, or a
  /// user-facing error message. Immediately signs back out if the check
  /// fails, so no non-admin session is ever left open on this screen.
  Future<String?> login(String email, String password) async {
    final UserCredential cred;
    try {
      cred = await _auth.signInWithEmailAndPassword(
          email: email.trim(), password: password);
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'invalid-credential':
        case 'wrong-password':
        case 'user-not-found':
          return 'Invalid email or password.';
        case 'invalid-email':
          return 'Enter a valid email address.';
        case 'user-disabled':
          return 'This account has been disabled.';
        case 'too-many-requests':
          return 'Too many attempts. Please wait a moment and try again.';
        case 'network-request-failed':
          return 'No internet connection. Check your network and try again.';
        default:
          return e.message ?? 'Could not sign in.';
      }
    } catch (_) {
      return 'Could not reach the server. Check your internet connection and try again.';
    }

    try {
      final doc = await _firestore
          .collection('users')
          .doc(cred.user!.uid)
          .get()
          .timeout(_timeout);
      final role = doc.data()?['role'] as String? ?? 'owner';
      if (role != 'admin') {
        await _auth.signOut();
        return 'This account does not have admin access.';
      }
      return null;
    } catch (_) {
      // Signed in but couldn't confirm admin access (e.g. offline right at
      // this moment) — fail closed rather than letting an unverified
      // session sit on the dashboard's route.
      await _auth.signOut();
      return 'Could not verify admin access. Check your internet connection and try again.';
    }
  }

  Future<void> logout() => _auth.signOut();

  /// Every registered account. Queried ordered by name (a field every
  /// account has) rather than `createdAt` — a Firestore `orderBy` silently
  /// DROPS any document missing that field from the results, which would
  /// hide every account registered before this field existed. The Admin
  /// Dashboard does its own registration-order sort/numbering client-side
  /// instead (see AccountsTab), where a missing date can be handled
  /// explicitly rather than making the account disappear.
  Future<List<AdminUserRow>> fetchAllUsers() async {
    final snap = await _firestore
        .collection('users')
        .orderBy('name')
        .get()
        .timeout(_timeout);
    // Counts only (aggregate queries) — nothing heavy like the license photos
    // is downloaded just to fill the list.
    Future<int?> count(String uid, String sub) async {
      try {
        final agg = await _firestore
            .collection('users')
            .doc(uid)
            .collection(sub)
            .count()
            .get()
            .timeout(_timeout);
        return agg.count;
      } catch (_) {
        return null;
      }
    }

    final rows = await Future.wait(snap.docs.map((d) async {
      try {
        final data = Map<String, Object?>.from(d.data());
        final counts = await Future.wait<int?>(
            [count(d.id, 'vehicles'), count(d.id, 'license')]);
        return AdminUserRow(
            UserModel.fromMap(data, id: d.id), data['disabled'] == true,
            vehicleCount: counts[0],
            licenseOnFile: counts[1] == null ? null : counts[1]! >= 2,
            approvalStatus: data['approvalStatus'] as String?);
      } catch (_) {
        // One malformed account document (e.g. one hand-created in the
        // Console with a field missing) shouldn't blank the whole accounts
        // list — same reasoning as AdminMonitorFeed.watchAlerts skipping a
        // bad alert document instead of failing its whole feed.
        return null;
      }
    }));
    // Pending and rejected sign-ups aren't accounts yet — they live in the
    // Approvals tab (pending) or are gone from the admin's view (rejected).
    final result = rows
        .whereType<AdminUserRow>()
        .where((r) => !_isUnapproved(r.approvalStatus))
        .toList();
    // Best-effort, fire-and-forget: claims any of these accounts' names that
    // aren't in the registry yet, so an account registered before the
    // duplicate-name check existed still blocks a NEW duplicate of its name
    // going forward. Never awaited — this must never slow down or fail
    // loading the accounts list itself.
    unawaited(_backfillNameClaims(result));
    return result;
  }

  /// See [fetchAllUsers]. For each account not yet in the `account_names`
  /// registry, claims its name — but only if no one else already holds that
  /// exact normalized name, so of several pre-existing duplicates only one
  /// (whichever is checked first) ends up claiming it, which is enough: the
  /// goal is only to stop a NEW duplicate from being added, not to pick a
  /// "winner" among accounts that already exist.
  Future<void> _backfillNameClaims(List<AdminUserRow> rows) async {
    await Future.wait(rows.map((r) async {
      final name = r.user.name.trim();
      if (name.isEmpty) return;
      final normalized = normalizedFullName(name);
      final ref = _firestore.collection('account_names').doc(normalized);
      try {
        await _firestore.runTransaction((tx) async {
          final snap = await tx.get(ref);
          if (snap.data()?['ownerId'] != null) return;
          tx.set(ref, {'ownerId': r.user.id, 'name': name});
        }).timeout(_timeout);
      } catch (_) {
        // Best-effort — tried again on the next dashboard load.
      }
    }));
  }

  /// A user's registered vehicles, for the account-detail view. Deliberately
  /// its own query rather than reusing FirebaseSyncService.fetchVehicles —
  /// that service also imports DatabaseService (sqflite), which has no web
  /// implementation. Keeping the admin screens free of that import is what
  /// lets `lib/admin_main.dart` compile as a small, self-contained web
  /// build with nothing mobile-only dragged in.
  Future<List<VehicleModel>> fetchVehicles(String uid) async {
    final snap = await _firestore
        .collection('users')
        .doc(uid)
        .collection('vehicles')
        .get()
        .timeout(_timeout);
    return _parseSkippingBad(
        snap.docs, (data, id) => VehicleModel.fromMap(data, id: id));
  }

  // ── Live monitoring (FR-11) ─────────────────────────────────────────
  // Real-time streams the admin's Live Activity and Map tabs listen to. All
  // three collections are already readable by any signed-in account, or by
  // an admin specifically (sightings) — see Progress.md for the rules.

  /// Every theft alert, newest first, pushed the moment Firestore changes.
  /// Sorted here rather than with `orderBy` so no index is ever required.
  Stream<List<TheftAlert>> watchAlerts() =>
      _firestore.collection('theft_alerts').snapshots().map((snap) {
        final list = <TheftAlert>[];
        for (final d in snap.docs) {
          try {
            list.add(TheftAlert.fromMap(Map<String, Object?>.from(d.data())));
          } catch (_) {
            // One malformed document shouldn't blank the whole feed.
          }
        }
        list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        return list;
      });

  /// Every sighting a nearby user has sent, newest first.
  Stream<List<SightingReport>> watchSightings() =>
      _firestore.collection('sightings').snapshots().map((snap) {
        final list = <SightingReport>[];
        for (final d in snap.docs) {
          try {
            list.add(
                SightingReport.fromMap(Map<String, Object?>.from(d.data())));
          } catch (_) {}
        }
        list.sort((a, b) => b.sentAt.compareTo(a.sentAt));
        return list;
      });

  /// Phones that shared a position in the last 10 minutes (the same
  /// `/presence` documents the phone app's "nearby devices" list is built
  /// from). Whether one counts as online NOW is [AdminDevice.onlineNow].
  Stream<List<AdminDevice>> watchDevices() {
    final cutoff = DateTime.now()
        .subtract(const Duration(minutes: 10))
        .millisecondsSinceEpoch;
    return _firestore
        .collection('presence')
        .where('updatedAtMs', isGreaterThan: cutoff)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => AdminDevice.fromMap(d.id, d.data()))
            .whereType<AdminDevice>()
            .toList());
  }

  /// Every recorded alert delivery (one per device's receipt of an alert),
  /// newest first. Sorted here rather than with `orderBy` so no index is
  /// ever required, same reasoning as [watchAlerts]/[watchSightings].
  Stream<List<AlertDelivery>> watchAlertDeliveries() =>
      _firestore.collection('alert_deliveries').snapshots().map((snap) {
        final list = <AlertDelivery>[];
        for (final d in snap.docs) {
          try {
            final delivery =
                AlertDelivery.fromMap(Map<String, Object?>.from(d.data()));
            if (delivery != null) list.add(delivery);
          } catch (_) {
            // One malformed document shouldn't blank the whole feed.
          }
        }
        list.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
        return list;
      });

  /// A vehicle's recorded positions, newest first. Sorted here (not
  /// `orderBy`) to avoid needing a composite index.
  Future<List<LocationRecord>> fetchLocationHistory(String vehicleId) async {
    final snap = await _firestore
        .collection('location_history')
        .where('vehicleId', isEqualTo: vehicleId)
        .get()
        .timeout(_timeout);
    final list =
        _parseSkippingBad(snap.docs, (data, _) => LocationRecord.fromMap(data));
    list.sort((a, b) => b.time.compareTo(a.time));
    return list;
  }

  /// Every registered vehicle across [users], ordered by owner name then
  /// plate. Vehicles are read per owner (the rules give an admin access to each
  /// account's `vehicles`). Throws if a read fails, so the tab shows an error
  /// rather than a silently partial list.
  Future<List<AdminVehicleRow>> fetchAllVehicles(
      List<AdminUserRow> users) async {
    Future<bool?> hasDocuments(String uid, String vehicleId) async {
      try {
        final agg = await _firestore
            .collection('users')
            .doc(uid)
            .collection('vehicles')
            .doc(vehicleId)
            .collection('documents')
            .count()
            .get()
            .timeout(_timeout);
        return (agg.count ?? 0) >= 2;
      } catch (_) {
        return null;
      }
    }

    final perOwner = await Future.wait(users.map((u) async {
      final vehicles = await fetchVehicles(u.user.id);
      return Future.wait(vehicles.map((v) async => AdminVehicleRow(
          vehicle: v,
          owner: u.user,
          ownerDisabled: u.disabled,
          documentsOnFile: await hasDocuments(u.user.id, v.id))));
    }));
    return perOwner.expand((rows) => rows).toList()
      ..sort((a, b) {
        final byOwner =
            a.owner.name.toLowerCase().compareTo(b.owner.name.toLowerCase());
        return byOwner != 0
            ? byOwner
            : a.vehicle.plate.compareTo(b.vehicle.plate);
      });
  }

  /// A vehicle's OR and CR photos as raw JPEG bytes — either null when that
  /// one was never submitted.
  Future<({Uint8List? or, Uint8List? cr})> fetchVehicleDocuments(
      String uid, String vehicleId) async {
    final snap = await _firestore
        .collection('users')
        .doc(uid)
        .collection('vehicles')
        .doc(vehicleId)
        .collection('documents')
        .get()
        .timeout(const Duration(seconds: 30));
    return (or: _documentImage(snap, 'or'), cr: _documentImage(snap, 'cr'));
  }

  /// The photo stored in the document named [name] of a `license` /
  /// `documents` subcollection snapshot, or null when it's missing or unreadable.
  static Uint8List? _documentImage(
      QuerySnapshot<Map<String, dynamic>> snap, String name) {
    for (final d in snap.docs) {
      if (d.id != name) continue;
      final b64 = d.data()['imageB64'] as String?;
      if (b64 == null || b64.isEmpty) return null;
      try {
        return base64Decode(b64);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// The account's driver's license photos as raw JPEG bytes — `front` and
  /// `back`, either null when that side was never submitted.
  Future<({Uint8List? front, Uint8List? back})> fetchLicense(String uid) async {
    final snap = await _firestore
        .collection('users')
        .doc(uid)
        .collection('license')
        .get()
        .timeout(const Duration(seconds: 30));
    return (
      front: _documentImage(snap, 'front'),
      back: _documentImage(snap, 'back')
    );
  }

  /// Blocks or restores an account's ability to sign in. Reversible, and
  /// takes effect immediately on any phone that's currently logged into
  /// that account — see AppState's live account watch, started right after
  /// every sign-in, which force-logs-out the moment this flips to true.
  Future<void> setDisabled(String uid, bool disabled) => _firestore
      .collection('users')
      .doc(uid)
      .set({'disabled': disabled}, SetOptions(merge: true)).timeout(_timeout);

  /// Every registration waiting on a decision, oldest first, live.
  Stream<List<PendingRegistration>> watchPendingRegistrations() => _firestore
          .collection('users')
          .where('approvalStatus', isEqualTo: 'pending')
          .snapshots()
          .map((snap) {
        final list = <PendingRegistration>[];
        for (final d in snap.docs) {
          try {
            final data = Map<String, Object?>.from(d.data());
            list.add((
              user: UserModel.fromMap(data, id: d.id),
              submittedAt:
                  DateTime.tryParse(data['submittedAt'] as String? ?? ''),
            ));
          } catch (_) {
            // One malformed submission shouldn't hide the rest of the queue.
          }
        }
        list.sort((a, b) => (a.submittedAt ?? DateTime(0))
            .compareTo(b.submittedAt ?? DateTime(0)));
        return list;
      });

  /// Accepts a pending registration. The account's own app picks this up
  /// live and signs it in (see AppState.watchOwnApproval).
  Future<void> approveRegistration(String uid) =>
      _firestore.collection('users').doc(uid).set({
        'approvalStatus': 'approved',
        'approvedAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true)).timeout(_timeout);

  /// Rejects a pending registration and removes everything it submitted —
  /// its vehicle(s) and their OR/CR, its license photos, its plate claims and
  /// its full-name claim — so the person can register again from scratch. The
  /// profile itself stays, marked 'rejected' with [reason], which is what the
  /// person sees next time they try to log in.
  Future<void> rejectRegistration(String uid, String reason) async {
    final owned = await _ownedRecords(uid);
    final batch = _firestore.batch();
    for (final ref in owned.refs) {
      batch.delete(ref);
    }
    batch.set(
        _firestore.collection('users').doc(uid),
        {
          'approvalStatus': 'rejected',
          'rejectionReason': reason.trim(),
          'rejectedAt': DateTime.now().toIso8601String(),
        },
        SetOptions(merge: true));
    await batch.commit().timeout(_timeout);
    await _releasePlateClaims(uid, owned.plateKeys);
    await _releaseNameClaim(owned.claimedName);
  }

  static bool _isUnapproved(String? status) =>
      status == 'pending' || status == 'rejected';

  /// Permanently deletes an account's data from Firestore: every vehicle it
  /// registered AND its `users/{uid}` profile document itself — nothing
  /// lingers in the accounts list afterward. The one thing this can't touch
  /// is the Firebase AUTHENTICATION record — the client SDK can only ever
  /// delete the CURRENTLY signed-in user's own account, never someone
  /// else's; truly erasing another user's auth record needs a Cloud
  /// Function with the Admin SDK (and Firebase's paid Blaze plan), which
  /// this project doesn't use. Without something to block it, that bare
  /// auth record could otherwise just sign in again and — since nothing
  /// would exist to say otherwise — get treated as a brand-new account. So
  /// this also leaves a small `removed_accounts/{uid}` tombstone, checked
  /// by [FirebaseSyncService.isAccountDisabled] and its live watch, which
  /// permanently blocks that login attempt regardless of the profile
  /// document being gone. The vehicles' plate claims and the account's
  /// full-name claim are released too, so they can be registered again.
  /// There is deliberately no "undo" for this — see [setDisabled] for the
  /// reversible suspend/restore instead.
  Future<void> removeUser(String uid) async {
    final owned = await _ownedRecords(uid);
    final batch = _firestore.batch();
    for (final ref in owned.refs) {
      batch.delete(ref);
    }
    batch.delete(_firestore.collection('users').doc(uid));
    batch.set(_firestore.collection('removed_accounts').doc(uid), {
      'removedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit().timeout(_timeout);
    await _releasePlateClaims(uid, owned.plateKeys);
    await _releaseNameClaim(owned.claimedName);
  }

  /// Everything an account owns in Firestore, for deleting or rejecting it:
  /// the document references to delete, the normalized plates it claimed, and
  /// its full-name claim key. Reads its vehicles and their OR/CR documents,
  /// and its license photos.
  Future<
      ({
        List<DocumentReference<Map<String, dynamic>>> refs,
        List<String> plateKeys,
        String? claimedName,
      })> _ownedRecords(String uid) async {
    final userRef = _firestore.collection('users').doc(uid);
    final refs = <DocumentReference<Map<String, dynamic>>>[];
    final plateKeys = <String>[];

    final userDoc = await userRef.get().timeout(_timeout);
    final rawName = userDoc.data()?['name'] as String?;
    final claimedName = (rawName != null && rawName.trim().isNotEmpty)
        ? normalizedFullName(rawName)
        : null;

    final vehicles =
        await userRef.collection('vehicles').get().timeout(_timeout);
    for (final v in vehicles.docs) {
      final docs =
          await v.reference.collection('documents').get().timeout(_timeout);
      refs.addAll(docs.docs.map((d) => d.reference));
      refs.add(v.reference);
      final plate = v.data()['plate'] as String?;
      if (plate != null && plate.trim().isNotEmpty) {
        plateKeys.add(normalizedPlate(plate));
      }
    }
    // Its driver's license photos are personal data too — they go with it.
    final license = await userRef.collection('license').get().timeout(_timeout);
    refs.addAll(license.docs.map((d) => d.reference));

    return (refs: refs, plateKeys: plateKeys, claimedName: claimedName);
  }

  /// Frees each plate claim, but only where it still belongs to [uid] — never
  /// another owner's claim that happens to share a normalized key. Best-effort:
  /// a failure here leaves that plate claimed, which is logged in Progress.md
  /// as the one manual cleanup case (Firebase Console → plates).
  Future<void> _releasePlateClaims(String uid, List<String> plateKeys) async {
    for (final key in plateKeys) {
      try {
        final ref = _firestore.collection('plates').doc(key);
        final snap = await ref.get().timeout(_timeout);
        if (snap.data()?['ownerId'] == uid) {
          await ref.delete().timeout(_timeout);
        }
      } catch (_) {
        // Best-effort — see the doc comment above.
      }
    }
  }

  Future<void> _releaseNameClaim(String? normalizedName) async {
    if (normalizedName == null) return;
    try {
      await _firestore
          .collection('account_names')
          .doc(normalizedName)
          .delete()
          .timeout(_timeout);
    } catch (_) {
      // Best-effort, same reasoning as the claim itself.
    }
  }
}
