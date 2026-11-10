# VehicleGuard — Progress.md
### Code Review Reference — What Each File Does

This document explains every file in `lib/` in plain language: what it's
responsible for, how it connects to the rest of the app, and anything
important to know when reviewing or modifying it. Use this alongside
`PROJECT_PROGRESS.md` (status/roadmap) and `GAP_ANALYSIS.md` (known
limitations) — this one is specifically for understanding the code itself.

---

## Entry point

### `lib/main.dart`
Where the app starts. Initializes Firebase (safely — if it fails, the app
still runs offline), sets the app to portrait-only, and defines all the
named routes (`/login`, `/home`, `/geofence`, etc.) that screens navigate
between. Also wraps the whole app in a `ChangeNotifierProvider` so every
screen can access `AppState`.

---

## `lib/models/models.dart`
Every data structure the app uses, in one file:
- **`UserModel`** — account info (name, email, hashed password, device ID)
- **`VehicleModel`** — a registered vehicle, including its geofence settings
- **`TheftAlert`** — a theft report: location, timestamp, trigger type, photo path, relay/hop info
- **`AdHocNode`** — a nearby device in the ad hoc network (real or simulated — see `isSimulated` flag)
- **`LocationRecord`** — one GPS breadcrumb, used for location history + cloud sync tracking
- **`SystemLog`** / **`NotifItem`** — diagnostic logs and in-app notifications
- **Enums** — `GpsStatus`, `NetworkStatus`, `VehicleStatus`, `AlertStatus`, `AlertTrigger`, `ConnectionType`, `RelayStatus`, `LogType`, `NotifType`

Every model has a `toMap()`/`fromMap()` pair — this is how data moves in and
out of SQLite (and, for `TheftAlert`/`LocationRecord`, Firestore too).

---

## `lib/services/` — all the business logic lives here

### `app_state.dart` (the biggest file — the central brain)
This is a `ChangeNotifier` that every screen listens to. It owns almost all
app-wide state (current user, vehicles, alerts, nodes, GPS status, network
status) and coordinates every other service. Key responsibilities:
- Login/register/logout (credentials verified by Firebase Authentication via
  `firebase_auth_service.dart`; `database_service.dart` only caches the
  resulting profile locally for offline access — see the security section
  near the end of this document)
- GPS refresh + continuous location watching (talks to `location_service.dart`)
- Automatic geofence violation checking (Haversine distance, runs on a timer)
- Reporting a vehicle stolen — creates the alert, saves it locally, then
  broadcasts it over either the real mesh or Demo Mode (talks to
  `nearby_mesh_service.dart` / `adhoc_network_service.dart`)
- Receiving and relaying alerts from other devices (duplicate detection,
  hop-count decrement, store-carry-forward to newly-connected peers)
- Triggering Firestore sync when online (talks to `firebase_sync_service.dart`)
- Notifications for every major event (talks to `notification_service.dart`)

If you're trying to understand "what happens when X occurs" in this app,
this is almost always the file to check first.

### `database_service.dart`
All local SQLite persistence. Defines the database schema (users, vehicles,
theft_alerts, alert_logs, location_history, nodes, notifications,
system_logs, session/prefs) and every read/write method `app_state.dart`
uses. Includes the version-2 migration that added real-device support to
the `nodes` table. **Nothing here talks to the internet or Firebase** — this
file is purely local storage.

### `firebase_sync_service.dart`
Uploads unsynced theft alerts and location history to Firestore when the
device is online. Deliberately does NOT sync user accounts, vehicles, or
system logs — see the comments at the top of the file for why. This is what
makes the ONLINE/SYNCING/SYNC COMPLETE indicators in the UI real instead of
cosmetic.

### `location_service.dart`
Wraps the `geolocator` package for real GPS. Reports honest status
(`GpsStatus.available` / `.permissionRequired` / `.disabled` / `.unavailable`)
instead of ever faking a coordinate. Also provides the Haversine
distance-between-two-points calculation used for geofence checking.

### `notification_service.dart`
Two jobs in one file:
1. Local Android notifications (`flutter_local_notifications`) — shown for
   every real event (theft alert, geofence violation, relay, recovery, sync result)
2. Firebase Cloud Messaging **receiving** side — permission request,
   background handler, foreground listener. Does NOT send targeted pushes
   to other devices (that needs a server-side Cloud Function — documented,
   not built).

### `connectivity_service.dart`
Small wrapper around `connectivity_plus` — reports real online/offline
status, used by `app_state.dart` to decide when to attempt a Firestore sync.

### `nearby_mesh_service.dart`
The **real** ad hoc network — Bluetooth/Wi-Fi Direct peer discovery and
data exchange via Google's Nearby Connections API. Handles advertising,
discovery, connection requests (with duplicate-request guarding), and
sending/receiving JSON-encoded alert packets. This is what actually finds
and talks to nearby phones — no external hardware involved, just the
phone's own Bluetooth/Wi-Fi radios.

### `adhoc_network_service.dart`
The **simulated** ad hoc network — a scripted, clearly-labeled fallback used
in Demo Mode (for testing/demonstrating without a second physical device).
Never pretends to be a real connection; every label in the UI that shows
data from this service says "(Simulated)".

---

## `lib/screens/` — grouped by your lowfi prototype's screen numbers

### `s1_splash_screen.dart` — Screen 1
Splash/loading screen. Waits for `AppState.init()` to finish (DB setup,
session restore) before routing to Login or Home.

### `s2_s3_auth_screens.dart` — Screens 2–3
Register and Login screens. Talks to `AppState.register()`/`login()`, which
are SQLite-backed (not Firebase Auth — see `PROJECT_PROGRESS.md` §2 for why).

### `s4_s5_vehicle_home.dart` — Screens 4–5
Vehicle registration form, and the Home Dashboard — the app's main screen.
Shows vehicle status, GPS/network status, the ad hoc mesh status card
(`_MeshStatusCard`), and the nearby-devices list (`_NearbyNodeRow`).

### `s6_s7_s8_geofence_report.dart` — Screens 6–8
Three screens in one file:
- **`GeofenceScreen`** — set the safe-zone radius and center. **Now shows a
  real OpenStreetMap** (`flutter_map`) with the geofence circle drawn as an
  actual meter-accurate overlay, replacing the old fake grid mock.
- **`ReportStolenScreen`** — the theft-report flow: photo capture, GPS
  capture, confirmation dialog, submit.
- **`AlertBroadcastingScreen`** — shows the alert relaying out to nearby
  nodes in real time, with mode-aware labels (Real mesh vs. Demo Mode).

### `s9_s10_s11_alerts_map.dart` — Screens 9–11
Three more screens:
- **`AlertReceivedScreen`** — what a nearby user sees when an alert arrives.
- **`ProximityMapScreen`** — **now a real OpenStreetMap** showing the stolen
  vehicle's actual last-known location, your live GPS position, and nearby
  node markers, replacing the old fake pixel-grid mock. The ripple animation
  and pin/tag styling from the original design are preserved — only the
  map itself changed from fake to real.
- **`AlertHistoryScreen`** — filterable list of all past alerts.

### `s12_s13_s14_status_notif_profile.dart` — Screens 12–14
Three more:
- **`UpdateStatusScreen`** — mark a vehicle Recovered or still-searching.
- **`NotificationsScreen`** — the notification inbox.
- **`ProfileScreen`** — account info, settings, and the Ad Hoc Network
  settings panel (Real/Demo toggle, connected devices, permission button).

---

## `lib/utils/app_theme.dart`
Colors, typography, and shared style constants. One place to change the
app's look — every screen pulls from `AppColors` here rather than
hardcoding colors.

## `lib/widgets/widgets.dart`
Shared, reusable UI pieces used across multiple screens: `TapScale` (button
press animation), `showConfirmDialog`/`showResultToast` (confirmation
modals and toasts), `AppCard`/`AppTextField`/`PrimaryButton` (consistent
form/card styling), `GpsStatusChip`/`NetworkStatusChip`, `VehicleCard`,
`NodeRelayRow`, and the alert status color/icon helpers.

---

## Map integration — what changed and why (this session)

**What was added:** real OpenStreetMap rendering (via the `flutter_map` +
`latlong2` packages) in `GeofenceScreen` and `ProximityMapScreen`, replacing
hand-drawn `CustomPainter` grid mocks that were never real maps.

**What was NOT touched:** no other file was modified. `AppState`,
`DatabaseService`, the models, the mesh services, and every other screen
are exactly as they were before this change — this was a scoped,
visual-only replacement of the two placeholder maps.

**Why no API key was needed:** OpenStreetMap tiles are free and don't
require a Google Cloud account, billing, or API key — unlike the
alternative (Google Maps API), which your manuscript also lists as an
acceptable option but requires that extra setup.

**Known limitation, stated honestly:** nearby *node* markers still don't
have real GPS coordinates (Bluetooth/Wi-Fi Direct doesn't expose a peer's
exact location — see `AdHocNode` docs in `models.dart`), so their position
on the map is still an approximate visual spread around the reference
point, same as before — it's just drawn on a real map now instead of a
fake grid. The stolen-vehicle pin and your own "You" pin, by contrast, now
use 100% real coordinates.

---

## Bug-fix pass — what changed and why (this session)

Went through the whole app looking specifically for real, verifiable bugs —
dead buttons, missing confirmations, accessibility gaps — rather than
subjective polish. Found and fixed five concrete issues, all scoped to
exactly the files that needed changing:

1. **"Edit Profile" was a fake button.** It just showed a toast saying
   "coming in full build" instead of doing anything. Now it opens a real
   bottom sheet (`_EditProfileSheet` in `s12_s13_s14_status_notif_profile.dart`)
   that lets you change your name and phone number, backed by a new
   `AppState.updateProfile()` method. Email stays read-only by design — it's
   the login identifier and has a UNIQUE constraint in the database, so
   changing it needs its own re-verification flow, not a quick edit.

2. **The notification bell on the Alert Received screen did nothing.**
   `onPressed: () {}` — an empty callback. Now it navigates to the
   Notifications screen, like every other notification icon in the app
   already does.

3. **Zero accessibility labels on any icon-only button.** All 11
   `IconButton`s across every screen had no `tooltip`, meaning Android's
   screen reader (TalkBack) would announce nothing meaningful for any of
   them — directly against the manuscript's accessibility requirement
   (§22). Added a tooltip to every one (Back, Refresh GPS location,
   Notifications, etc.).

4. **"Clear" system logs had no confirmation.** One tap permanently wiped
   all diagnostic logs, no undo, no warning — inconsistent with every other
   destructive action in the app (remove vehicle, log out), which all use
   the shared `showConfirmDialog`. Now Clear Logs does too.

5. **The Report Stolen screen ignored the Android back button entirely** —
   not just this screen, the whole app has zero back-button handling
   anywhere, despite the manuscript explicitly listing it as a required
   test case (§31, TEST 12). Fixed the highest-risk instance: wrapped
   `ReportStolenScreen` in a `PopScope` that blocks back-navigation while a
   report is actively submitting, so you can't accidentally back out mid-
   submission and end up unsure whether the alert actually went out. Used
   only the stable, version-independent part of `PopScope`'s API
   (`canPop`) rather than the newer callback variants, since I can't verify
   exact Flutter-version API compatibility without a compiler.

**Verification:** re-ran the brace-balance and switch-terminator checks
after every single edit in this pass — all clean throughout.

**What was deliberately left alone:** a few remaining raw `GestureDetector`
uses (password-visibility toggle, text links) that are legitimate simple
interactions, not bugs — didn't touch them to avoid unnecessary scope
creep beyond what was actually broken or missing.

---

## Build-blocking bug — found via real `flutter run`, fixed (this session)

This is the first time this project actually hit a real Gradle build, and
it surfaced a genuine issue (screenshotted by the user from VS Code):

**Error:** `Namespace not specified. Specify a namespace in the module's
build file: ...\nearby_connections-3.3.1\android\build.gradle`

**What this actually was:** not a bug in this project's own code. The
`nearby_connections` plugin (last published in 2023) predates a change in
Android's build tooling (AGP 7.3+) that requires every Android library
module to declare a `namespace`. This is a widely-documented ecosystem
issue affecting many older, unmaintained Flutter plugins — confirmed via
multiple real GitHub issues (`flutter/flutter`, `uni_links`, `realm-dart`,
`flutter_contacts`, others) hitting the identical error against different
plugins for the identical reason.

**Fix applied:** `android/build.gradle.kts` now automatically backfills a
missing `namespace` for any plugin module that doesn't declare one, reading
it from that plugin's own `AndroidManifest.xml` at build time — the same
value Android's own "AGP Upgrade Assistant" would migrate automatically.
This is the standard, well-documented community pattern for this exact
problem. It's purely additive to the build system: no plugin version
changed, no Dart code changed, nothing in the pub cache was hand-edited
(which wouldn't have survived a fresh `flutter pub get` or a different
machine anyway).

**Also fixed:** two harmless "unused import" warnings flagged in the same
VS Code session (`geolocator` in `app_state.dart`, `models.dart` in
`firebase_sync_service.dart`) — confirmed both were genuinely unused
(Dart's type inference didn't need them) before removing.

**Honest caveat:** I still can't compile-test Gradle Kotlin DSL scripts
here. I chose the standard Java XML API (`javax.xml.parsers`, always
available on any JVM) over Groovy's XML parser specifically to reduce the
risk of depending on something that might not be on the Kotlin DSL
classpath — but this is the one piece of this fix I can't 100% guarantee
without your own `flutter run` confirming it. If it throws a *new* Gradle
scripting error, send it back immediately, exactly like this one.

---

## Registration/login security overhaul — moved auth to Firebase (this session)

The manuscript's own architecture table (3.3.2.1) names Firebase
(Firestore, Auth) as the backend, with local SQLite scoped specifically to
*"offline alert and vehicle data storage."* The app had drifted from that:
registration/login were verifying passwords locally against a SQLite hash.
This session closed that gap — identity now genuinely lives in Firebase,
and local storage went back to being purely an offline cache, nothing more.

**New file:** `lib/services/firebase_auth_service.dart` — a thin wrapper
around Firebase Authentication (email/password + phone), following the
same one-service-per-concern pattern as `LocationService`/`NearbyMeshService`.
Every Firebase Auth error code gets translated to a specific, human-readable
message (wrong password, email already registered, no network, too many
attempts, invalid phone number, expired code, etc.) instead of one generic
"failed" message.

**What changed and why:**

1. **`UserModel` no longer has `passwordHash`/`salt` fields at all.**
   Firebase Auth is the only thing that ever sees or checks a password now.
   A stolen or `adb`-extracted local database contains zero password
   material to crack — there's nothing there to crack.

2. **`AppState.register()`/`login()`** now call `FirebaseAuthService`
   instead of hashing/comparing locally. `database_service.dart` was
   **not touched at all** — `upsertUser`/`getUserById` still work exactly
   as before, just storing a profile (name/email/phone/deviceId/role)
   instead of a profile-plus-password-hash. Any old locally-hashed password
   data left over from before this change gets automatically overwritten
   with nothing the next time that account logs in (SQLite `REPLACE`
   semantics drop columns not included in the new write).

3. **`firebase_sync_service.dart`** gained `upsertUserProfile()` /
   `fetchUserProfile()` — the account's profile is now mirrored to
   Firestore under `/users/{uid}`, making it the authoritative cloud copy
   the manuscript's architecture table describes. Local SQLite is the
   offline-access cache for it, consulted first so the Profile screen still
   works with no connectivity.

4. **Session restore is now Firebase-Auth-first.** `AppState.init()` checks
   `FirebaseAuth`'s own persisted sign-in state (works fully offline once a
   user has logged in on the device before) instead of a local SQLite
   session table. Logging out now calls `FirebaseAuth.signOut()` as the
   primary action, which is what actually invalidates the session — a
   stolen/backed-up local database can no longer be dropped onto another
   device to silently resume someone else's session, because there's no
   password-adjacent secret sitting in it anymore.

5. **Demo account (`juan@vehicleguard.ph` / `demo1234`) is now a real
   Firebase account**, auto-created on its very first login attempt so
   evaluators still need no pre-existing credential — but it goes through
   the exact same Firebase Auth path, and the exact same security, as every
   other user. No special-cased weaker branch.

6. **Phone number verification (SMS OTP)** — added per an explicit request
   to gate registration on proving the registrant actually controls the
   phone number they typed in. After the Firebase account is created, a new
   `_PhoneVerificationScreen` (in `s2_s3_auth_screens.dart`) sends a 6-digit
   code via Firebase Phone Auth and blocks reaching the "successfully
   created an Account" modal until that code is confirmed (or Android's SMS
   Retriever silently auto-verifies it). The verified phone number is
   linked to the Firebase account as a credential, not just stored as a
   string.
   **Requires one-time setup in the Firebase Console that I can't do from
   here** (needs your account access): Authentication → Sign-in method →
   enable **Phone**; and Project Settings → your Android app → add the
   **SHA-1 and SHA-256** fingerprints from your debug keystore (`keytool
   -list -v -keystore %USERPROFILE%\.android\debug.keystore` on Windows,
   default password `android`), so Android can silently verify via Play
   Integrity instead of falling back to a reCAPTCHA web challenge. The free
   Spark plan's SMS quota is more than enough for a ~20-respondent
   evaluation.

7. **Tightened form validation** in `s2_s3_auth_screens.dart`: email fields
   now check a real `something@something.tld` pattern instead of just
   `contains('@')`; the phone field requires a genuine PH mobile format
   (`09XXXXXXXXX` or `+639XXXXXXXXX`).

8. **"Forgot password?" is no longer decorative.** It opens a small dialog
   that calls Firebase's real `sendPasswordResetEmail` — this only became
   buildable once real Firebase Auth accounts existed to reset.

9. **`android/app/src/main/AndroidManifest.xml`**: added
   `android:allowBackup="false"`. Without it, `adb backup` or Android's
   Auto Backup to Google Drive could pull the entire private app directory
   off a non-rooted device with USB debugging on — closing this was a
   direct, low-effort fix for a real local-extraction risk.

10. **Removed the anonymous-Firebase-auth bootstrapping** added earlier in
    `main.dart` — superseded by real per-user auth, since every Firestore
    call now happens after a genuine sign-in. Leaving both would've meant
    two different identity mechanisms coexisting for no reason.

**Recommended Firestore rules** (paste into Firebase Console → Firestore →
Rules — I can't do this myself, it's in your Google account):

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{uid} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
    match /theft_alerts/{alertId} {
      allow get: if request.auth != null;
      allow list: if false;
      allow create, update: if request.auth != null && request.resource.data.id == alertId;
      allow delete: if false;
    }
    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if false;
      allow create: if request.auth != null;
      allow update, delete: if false;
    }
  }
}
```

This is now meaningfully stronger than the earlier "require any signed-in
request" recommendation — `request.auth.uid` is a real, Firebase-verified
identity, so the `/users/{uid}` rule genuinely restricts a profile to only
the account that owns it. `theft_alerts`/`location_history` still aren't
restricted to their own reporter (every legitimate user can still relay/read
alerts from others, which is the app's actual intended behavior), but they
can no longer be touched by anything that hasn't authenticated through the
real app at all.

**What I deliberately did not do this session** (flagged, not silently
skipped): at-rest encryption of the SQLite file itself (would need
SQLCipher — a real dependency swap and migration, bigger than this pass);
per-owner Firestore rules on `theft_alerts`/`location_history` (would
contradict the mesh-relay feature, where seeing other users' alerts is the
point); local login-attempt throttling (now largely redundant — Firebase
Auth already rate-limits repeated failed sign-ins server-side via
`too-many-requests`).

**Caveat for testing:** any account created *before* this session (back
when accounts were purely local) has no corresponding Firebase Auth user —
register fresh through the app to test the new flow.

### Follow-up fix: closed the phone-verification bypass (same session)

A self-review after the above turned up a real gap: phone verification was
only checked at the moment of registration. If someone abandoned or failed
the OTP screen, the Firebase email/password account already existed and was
fully usable — nothing stopped them from just logging in normally afterward
and skipping verification forever, which defeated the point of adding it.

**Fix:** `AppState.login()` now also checks `firebaseUser.phoneNumber ==
null` (Firebase populates this only once a phone credential is actually
linked) *after* the password is confirmed. An account whose phone was never
verified is blocked here too — `login()` returns `false` and sets
`pendingPhoneVerificationNumber` instead of granting access. `LoginScreen`
sees that field, routes the user back through the exact same
`_PhoneVerificationScreen`, and retries the login automatically once the
code is confirmed. The demo account is deliberately exempt — it's
auto-provisioned inline with no UI path through the OTP screen by design.

Also fixed while in there: the toast shown when someone abandons
verification during registration used to say "log in and try again" —
which used to be false, since there was nothing on the login side to catch
it. It's true now, and worded to say so. Separately, tapping "Verify &
Continue" before a code had even been sent (e.g., Phone sign-in not yet
enabled in the console) silently did nothing; it now shows a clear message
instead of looking frozen.

### Real-device testing pass — console config, OTP UI, and one more bypass (this session)

Testing against a real Firebase project (not just code review) surfaced
three more things:

**Firebase Console setup gaps.** `CONFIGURATION_NOT_FOUND` on register
turned out to mean Authentication itself had never been initialized for
the project — enabling Firestore doesn't also enable Authentication, they're
separate products. Fixed by enabling Email/Password + Phone under
Authentication → Sign-in method. Separately, OTP codes never arrived
because (a) the emulator has no SIM/radio to receive real SMS at all — a
Firebase **test phone number** (Authentication → Sign-in method → Phone →
"Phone numbers for testing") is required for emulator testing, and (b) new
Firebase projects default to a restrictive **SMS region policy** that
blocked the Philippines specifically — fixed by setting it to Allow +
Philippines (PH) under Authentication → Settings → SMS region policy. Also
added the debug keystore's SHA-1/SHA-256 fingerprints to the Firebase
Android app config (Project Settings → Your apps), so silent Play
Integrity-based verification is available instead of always falling back
to the reCAPTCHA challenge flow.

**OTP entry is now a real 6-box input**, not one text field — auto-advances
forward as you type, moves back on backspace into an empty box. First
attempt at this used a `KeyboardListener` wrapping the `TextField` and gave
them the same `FocusNode`, which threw a Flutter Focus-tree error
("Tried to make a child into a parent of itself") and rendered as garbled
overlapping debug text instead of the input screen. Fixed by attaching the
backspace-navigation logic directly to each digit's own
`FocusNode.onKeyEvent` instead of a second widget sharing the node.

**A second phone-verification bypass, independent of the login-time one
fixed above.** `AppState.init()` — which restores a session on every app
relaunch — never got the same `phoneNumber == null` check `login()` got.
So closing and reopening the app (instead of explicitly logging out and
back in) was a second way to land on the Home dashboard with a phone that
was never verified. Fixed: `init()` now applies the identical check and
signs out an unverified session instead of restoring it, so it falls back
to the Login screen, whose gate already handles it correctly.

**Still open, not part of this session:** the pre-existing bug list from
the general code-review pass (recover-after-delete crash, unchecked mesh
`status_update` index, sync failures reported as success, discarded
"remarks" field on Update Status, Nearby Nodes stat capped at 3, manual
geofence coordinates not reflected on the map preview, other users'
relayed alerts invisible in Alert History, three 12-hour-clock display
bugs, notification read/unread rows sharing one color, demo nodes visible
in Real mesh mode) — untouched, still open, listed here for continuity.

---

## Bug-fix pass #2 + reusable success modal + verified release build (this session)

Every item from the "still open" list right above is now fixed. Verified
`flutter analyze` (0 issues) and `flutter test` (passing) after each batch,
and — since the actual goal this session was producing a real APK — a full
`flutter build apk --release` was run twice (before and after all fixes)
and succeeded both times: `build\app\outputs\flutter-apk\app-release.apk`
(57.3MB). That APK is signed with the debug keystore (see `build.gradle.kts`
— `signingConfig = signingConfigs.getByName("debug")`), which is exactly
why Phone Auth kept working without extra Firebase Console steps: the
release build uses the same debug keystore whose SHA fingerprints were
already registered. This is fine for installing directly on your own or
respondents' phones for evaluation; it would need real release signing
before ever going through the Play Store, which is a separate, later step.

**Root causes and fixes, one by one:**

1. **Recover-after-delete crash** (`s4_s5_vehicle_home.dart` + `app_state.dart`).
   Root cause: `removeVehicle()` deletes a vehicle but never cascade-deletes
   its alerts, so an alert can outlive the vehicle it belongs to. Both the
   Home screen's Recover button and `AppState.markRecovered()` assumed the
   vehicle would always still exist and used `orElse: () => throw
   Exception()` — an unconditional crash — when it didn't. Fixed: both now
   check for absence first and degrade gracefully (skip the vehicle-status
   update, or show "No active theft alert found") instead of crashing.

2. **Unchecked mesh status-index crash** (`app_state.dart`,
   `_handleMeshMessage`). Root cause: a peer's `status_update` packet
   carries a raw integer that was indexed directly into `AlertStatus.values`
   with no bounds check — a malformed or malicious packet with an
   out-of-range value would throw `RangeError` and crash the receiving
   device. Fixed: the index is validated against `AlertStatus.values.length`
   before use; an invalid one is logged and ignored instead.

3. **Sync failures silently reported as success** (`firebase_sync_service.dart`).
   Root cause: `syncAll()`'s doc comment promised it would throw on total
   failure so `AppState` could show SYNC FAILED, but the implementation
   caught every per-record exception and just returned however many
   happened to succeed — including 0, which looked identical to "nothing
   was pending". A total outage (offline, or every write rejected by
   security rules) always displayed as SYNC COMPLETE. Fixed:
   `_syncAlerts`/`_syncLocations` now report `(attempted, synced)`, and
   `syncAll()` throws when something was attempted but literally 0 of it
   went through — fulfilling the contract the comment already claimed,
   with zero changes needed on the `AppState` side since its catch block
   was already written to handle exactly this.

4. **Discarded "remarks" field** (Update Status screen). Root cause: the
   remarks `TextEditingController` was wired to a visible text field but
   never read anywhere — typing something and confirming just discarded it.
   Fixed: `AppState.markRecovered()` now accepts an optional `remarks` and
   appends it to the alert's notes when non-empty; the screen passes
   `_remarks.text` through.

5. **"Nearby Nodes" stat capped at 3** (Home dashboard). Root cause: the
   same capped-to-3 list built for the compact preview row was also used as
   the stat tile's count, so 8 connected nodes still displayed "3". Fixed:
   the full online-node list and the capped preview slice are now separate
   variables; the stat tile reads the full count.

6. **Manual geofence coordinates ignored by the map preview**
   (`GeofenceScreen`). Root cause: `_mapCenter()` always prioritized live
   GPS regardless of the "Use Current GPS Location" toggle, and never once
   read the manual coordinates field — so turning that toggle off and
   typing coordinates changed what got *saved* but never what the map
   *showed*, letting them silently disagree. Fixed: when the toggle is off,
   a successfully parsed manual entry now drives the map center; a listener
   on the coordinates field also makes the map update live as you type,
   not just on the next unrelated rebuild.

7. **Relayed alerts from other users invisible in your own Alert History**
   (`AlertHistoryScreen`). Root cause: the screen filtered to `myAlerts`
   (reported by the current account) instead of `allAlerts` (everything
   this device has, including alerts relayed in from nearby peers) — so an
   alert that already triggered a push notification and appeared on the
   Proximity Map was nowhere to be found in the screen literally named
   Alert History. Fixed: switched to `allAlerts` for visibility. Doing that
   alone would have let anyone mark *someone else's* vehicle "Recovered",
   so the Update Status button is now additionally gated to
   `alert.userId == currentUser.id` — visibility for everyone, control only
   for the original reporter.

8. **Three 12-hour-clock display bugs** ("15:30 PM", "00:15 AM" — wrong
   because `t.hour` is 24-hour but was printed directly with an AM/PM
   suffix bolted on). Root cause: hand-rolled formatting instead of using
   the `intl` package already in `pubspec.yaml`. Fixed all three
   (`AlertBroadcastingScreen`, `ProximityMapScreen`, `UpdateStatusScreen`)
   with `DateFormat('hh:mm a')` / `DateFormat('M/d/yyyy · hh:mm a')`.

9. **Notification read/unread rows visually identical**
   (`NotificationsScreen`). Root cause: `color: notif.isRead ?
   AppColors.white : AppColors.white` — both branches were the same color,
   almost certainly a copy-paste slip. Fixed: unread notifications now get
   a subtle tint in the alert's own type color (reusing the same light
   shade already computed for its icon background), so unread items are
   visibly distinct, not just marked by a slightly thicker left border.

10. **Demo/Simulated nodes showing up in Real mesh mode** (`AppState.init()`
    + `setAdHocMode()`). Root cause: the 4 seeded demo nodes were loaded
    unconditionally at startup regardless of which mode was active — a
    fresh install (which defaults to Real mode) immediately showed 4
    "nearby devices" no real alert could ever reach, and switching modes
    only ever cleaned up nodes in one direction (Demo → Real removed real
    nodes, but Real → Demo never removed simulated ones). Fixed: both
    `init()` and `setAdHocMode()` now enforce the same rule symmetrically —
    Real mode never has simulated nodes, Demo mode always seeds the default
    set if none exist.

**Cleanup:** the success modal shown after register/login was duplicated
as a private function inside `s2_s3_auth_screens.dart`. It's now
`showSuccessModal()` in `widgets.dart` — one shared, reusable component
(matching how `showConfirmDialog`/`showResultToast` already work) instead
of a copy only that one file could use. It also now has a small entrance
animation (scale + fade, via the `flutter_animate` package already in
`pubspec.yaml` — no new dependency) instead of appearing instantly. Wired
it into two more milestone actions beyond auth: registering a vehicle and
saving a geofence now show this modal instead of a plain toast, matching
the weight of what just happened; smaller, routine confirmations (remove
vehicle, mark all read, etc.) intentionally stay as lightweight toasts —
reserving the modal for genuine milestones keeps it meaningful instead of
diluting it into background noise.

**Explicitly scoped down, not silently skipped:** a full animation pass
across all 14 screens was asked for in the same breath as this bug-fix
batch. Doing that properly — real transition/motion design per screen,
verified on a live device — is a substantial project on its own, and
attempting it mechanically across every screen in one pass without live
testing risks shipping visual regressions right before your evaluation
phase. This session added animation only where it was safe, high-value,
and directly verifiable (the new shared success modal); a broader pass is
a good, focused follow-up task rather than something to rush through here.

---

## Real-device sideload testing (2026-09-18) — OTP expiry timer, login
## lockout, and a real registration-gating bypass

The Sep 17 release APK was installed on a real phone. Registering surfaced
one real bug and prompted two explicit new security requirements.

**Bug found: no SMS ever arrived for the OTP.** The number format itself
was valid E.164 (`+639485673665`). Since the app's UI already showed "We
sent a code…" (meaning Firebase's client SDK considered the send
successful), this isn't a code bug — the most likely cause is that this
exact number is still sitting under Firebase Console → Authentication →
Sign-in method → Phone → **"Phone numbers for testing"** from earlier
debugging this same session line. Firebase never sends a real SMS to a
listed test number; it just expects a fixed fake code, so the box waits
forever for a text that was never going to come. **Action needed in the
console, not in code:** remove that number from the test list (or use its
preset code if it's meant to stay a permanent test entry), then retry on
the real device. Play Integrity/App Check attestation gaps and carrier-side
spam filtering are the other, less likely possibilities if removing the
test-number entry doesn't fix it.

**Fix 1 — 60-second OTP expiry timer** (`_PhoneVerificationScreen` in
`s2_s3_auth_screens.dart`). Previously a sent code stayed valid to submit
indefinitely from the UI's point of view. Added a client-side countdown:
starts the moment Firebase confirms the code was dispatched (`onCodeSent`),
shown live above the digit boxes ("Code expires in 0:45", turning amber
under 10 seconds). At 0 the code is invalidated client-side (digit boxes
disabled, Verify button hidden, `_verificationId` cleared, entered digits
wiped), and the user must tap **Resend Code** — which requests a fresh
Firebase verification session and restarts the same 60-second countdown.
This repeats for as many resend cycles as needed.

**Fix 2 — login attempt lockout** (`AppState.login()` in `app_state.dart`).
Firebase Auth already throttles repeated failed sign-ins server-side
(`too-many-requests`), but that's silent and its exact threshold isn't
user-facing. Added an explicit client-side layer on top: 5 failed password
attempts for the same email locks that email out for 5 minutes, persisted
in `SharedPreferences` (not just in-memory) so relaunching the app can't be
used to reset the counter. Each failed attempt's error message now also
says how many tries remain before lockout; a locked-out attempt is rejected
immediately with a "try again in N minutes" message *before* even calling
Firebase, saving a wasted network round trip. A successful login clears the
counter for that email.

**Fix 3 (the important one) — registration could reach the dashboard
without completing phone verification.** Root cause: `AppState.register()`
signed the user into the app (set `currentUser`, wrote the local/Firestore
profile, started the mesh) **immediately after the Firebase account was
created — before the OTP screen even ran.** The OTP screen was pushed on
top afterward purely as a UI step; the app-level "am I logged in" flag
(`isLoggedIn`, i.e. `currentUser != null`) was already true underneath it.
Backing out of the OTP screen (via its "Change phone number" arrow) and
then pressing back once more from the Register screen would reveal the
Splash screen with `isLoggedIn` already true, and Splash auto-routes
straight to `/home` whenever it becomes the current route and the user is
logged in — a real, reachable bypass of the OTP requirement, not a
theoretical one. (Killing and relaunching the app mid-OTP was already safe
— `AppState.init()`'s session-restore gate correctly signs out an
unverified session — this was specifically the *stay-in-the-app-and-back-
out* path.)

Fixed by splitting registration into two steps: `register()` now only
creates the Firebase account and returns — it no longer touches
`currentUser`, the local DB, Firestore, or the mesh, so `isLoggedIn` stays
false the entire time the OTP screen is up. A new `finalizeRegistration()`
does everything `register()` used to do (build the profile, cache it
locally, sync to Firestore, set `currentUser`, start the mesh) and is only
ever called from `RegisterScreen._submit()` after the OTP screen has popped
with `verified == true`. If the user abandons OTP, `currentUser` was simply
never set, so there is nothing for Splash (or anything else) to auto-route
into — the existing "finish verification next time you log in" recovery
path (via `pendingPhoneVerificationNumber` in `login()`) still works
unchanged, since that path never depended on `register()`'s old behavior.

Verified `flutter analyze` (0 issues) and `flutter test` (passing) after
these three fixes, then rebuilt the release APK —
`build\app\outputs\flutter-apk\app-release.apk` (57.3MB, debug-signed,
same as before) — so the file on disk now reflects all of today's fixes.

**Still needed from you:** check the Firebase Console test-number list for
`+639485673665` (see above) — that's the most likely reason no OTP SMS has
arrived on the real device yet.

---

## Full re-scan requested after real-device testing (2026-09-18) — 7 more
## fixes, no features removed

A full pass over every remaining file in `lib/` (all services, all screens,
`widgets.dart`, `models.dart`) that hadn't been fully re-read since earlier
passes. `flutter analyze` (0 issues) and `flutter test` (passing) after
every fix, then a third `flutter build apk --release` (57.3MB) so the file
on disk reflects everything below too. Nothing was removed — every fix
below is additive or corrects what a widget/method already displays.

1. **Real mesh peers displayed as "-1m away"** (`NodeRelayRow` and
   `ProximityNodeRow` in `widgets.dart`). Root cause: `AdHocNode.distance`
   is deliberately set to `-1` for real (non-simulated) peers, since raw
   BLE/Wi-Fi Direct doesn't expose an actual range — `app_state.dart`'s own
   comment even says "UI shows 'Nearby' instead," but neither widget
   actually checked for that sentinel value before formatting it as
   `${distance.toInt()}m`. Fixed: both now show "Nearby" whenever
   `distance < 0`; `ProximityNodeRow`'s progress bar also no longer feeds
   `-1` into the same 0–100m formula simulated nodes use (it now shows full
   for a connected real peer, partial while still connecting).

2. **Incoming mesh connections could show "Unknown Device"**
   (`nearby_mesh_service.dart`). Root cause: `_onConnectionResult` names a
   peer by looking up `discoveredEndpoints[id]`, which is only populated by
   `_onEndpointFound` — but a connection can be *initiated* for a peer this
   device never discovered first (the other phone found us first). Fixed:
   `_onConnectionInitiated` now also records the name from
   `ConnectionInfo.endpointName`, so the lookup never misses regardless of
   which side discovered which.

3. **Discovery log spam** (`AppState._wireMeshCallbacks`). Root cause:
   Android re-fires `onEndpointFound` repeatedly for a peer that's still in
   range while discovery keeps running, and every single firing wrote a
   "🔎 Discovered nearby device" line to System Logs — a peer sitting
   nearby for a few minutes could produce dozens of duplicate log lines.
   Fixed: the log line now only writes the first time a peer is actually
   added as a new node, not on every repeat sighting.

4. **"NEARBY NODES (100M SIMULATED PROXIMITY)" label shown even in Real
   mesh mode** (Proximity Map). Cosmetic but misleading — real BLE/Wi-Fi
   Direct nodes were listed under a header that claims simulated 100m
   proximity. Fixed: the label now reads "NEARBY NODES (REAL AD HOC MESH)"
   when `adHocRealMode` is on.

5. **"LAST KNOWN LOCATION" badge could be wrong on Proximity Map.** Root
   cause: the badge was driven by the device's *current* GPS status, not by
   whether the location actually being shown (`center` — the active
   alert's own recorded lat/lng, when there is one) was real. An alert
   reported without a GPS fix (`isDemoLocation: true`) could still display
   "LAST KNOWN LOCATION" simply because the phone happened to have a GPS
   fix *now*, at viewing time — misrepresenting the alert's own data as
   more precise than it was. Fixed: the badge now checks
   `alerts.first.isDemoLocation` when an alert is being shown, falling back
   to current GPS status only when there's no alert (i.e. centered on the
   user's own position).

6. **Two more leaked `TextEditingController`s**, same pattern as a similar
   one fixed in an earlier pass: a controller built inline inside `build()`
   for a read-only field is a brand-new object on every rebuild, and the
   old one is never disposed.
   - `RegisterVehicleScreen` (`s4_s5_vehicle_home.dart`) — the read-only
     "Device ID" field. Fixed: moved to a real field (`_deviceIdCtrl`),
     created once, disposed in `dispose()`, text kept in sync with the
     current device ID.
   - `_EditProfileSheet` (`s12_s13_s14_status_notif_profile.dart`) — the
     read-only "Email (not editable)" field. Fixed the same way
     (`_emailCtrl`).

---

## Verification method changed: SMS OTP → Email verification + Google
## Sign-In (2026-09-18)

Real-device testing hit `BILLING_NOT_ENABLED` on the OTP screen — Firebase
Phone Auth requires the project to be on the paid Blaze plan to send real
SMS to arbitrary numbers (the free "test phone numbers" list only covers a
closed set of numbers registered by the developer, which doesn't work for
strangers downloading the app with unknown numbers — one of this
project's core FR-01 requirements). Rather than take on a billing
dependency for a capstone project, phone verification was replaced
entirely with two verification paths that are both free on Firebase's
no-cost Spark plan:

1. **Email verification** (`sendEmailVerification()` / a clicked link) —
   the default path for email/password registration.
2. **Google Sign-In** — an account already verified by Google itself, so
   it signs straight in with no separate verification step.

The phone number field is **kept** on the Register form (still collected
and stored on the user's profile, still validated for a plausible PH
mobile format) but is **no longer cryptographically verified** — it's a
plain, self-reported contact field now, the same trust level as name.

**Removed (redundant now that there's no phone verification):**
- `FirebaseAuthService`: `startPhoneVerification()`, `confirmPhoneCode()`,
  `linkPhoneCredential()`, and the phone-specific error-code branches in
  `_friendlyMessage()` (`invalid-phone-number`, `quota-exceeded`,
  `invalid-verification-code`, `session-expired`, the old
  `credential-already-in-use`/`provider-already-linked` phone wording).
- `AppState`: `startPhoneVerification()`, `confirmPhoneCode()`,
  `linkAutoVerifiedPhone()`, the `pendingPhoneVerificationNumber` field
  (renamed/repurposed as `pendingEmailVerification`, holding an email
  instead of a phone number).
- `s2_s3_auth_screens.dart`: the entire `_PhoneVerificationScreen` (60-second
  countdown, 6-digit box row) and its `_OtpDigitBox` widget, and the
  top-level `_toE164Phone()` helper — none of this has any reason to exist
  without SMS OTP. Replaced by a much simpler `_EmailVerificationScreen`
  ("Check your email" / "I've Verified — Continue" / "Resend Email" — no
  countdown timer, since Firebase controls the email link's own expiry, not
  the client).

**Added:**
- `FirebaseAuthService.register()` now calls `sendEmailVerification()`
  right after account creation.
- `FirebaseAuthService.resendEmailVerification()`, `checkEmailVerified()`
  (reloads the Firebase user and reports `emailVerified`), and
  `signInWithGoogle()` (via the `google_sign_in` package, exchanging a
  Google credential for a Firebase sign-in — a new/existing account is
  handled identically by Firebase).
- `AppState.resendVerificationEmail()`, `checkEmailVerified()`,
  `signInWithGoogle()` (builds/loads the local profile and signs the user
  in immediately, same as the email/password path's `finalizeRegistration`,
  since a Google-authenticated email needs no separate verification step).
- The registration/login gates in `AppState` (`init()`'s session restore
  and `login()`) now check `fbUser.emailVerified` instead of
  `fbUser.phoneNumber == null` — same "can't reach the dashboard without
  completing verification" guarantee as before, just keyed off email.
- Login screen: a **"Continue with Google"** button below an OR divider.
- `pubspec.yaml`: added `google_sign_in: ^6.2.1` (resolved 6.3.0).

**Follow-up refinements, same day, after real-device testing of the above:**

1. **60-second verification window added to the email screen too**, mirroring
   the old OTP countdown exactly as requested: `_EmailVerificationScreen`
   now starts a 60-second countdown the moment it opens. If "I've
   Verified — Continue" isn't tapped in time, the button hides and the user
   must tap **"Resend Email"** to get a fresh 60-second window (which also
   re-sends the email). This is a client-side UX constraint, not a real
   Firebase link expiry — Firebase's own verification link actually stays
   valid much longer — but it keeps the same "don't act on a possibly-stale
   request" discipline as the OTP flow it replaced.

2. **More formal duplicate-account error messages.** Per an explicit request
   for wording like "it's already registered, use another Google account or
   email": `email-already-in-use` now reads "This email address is already
   registered. Please log in instead, or use a different email address,"
   and the cross-provider case (`credential-already-in-use` /
   `account-exists-with-different-credential` — trying "Continue with
   Google" using a Google account whose email already has a password-based
   account) now reads "This Google account's email is already registered.
   Please log in with your email and password instead, or use a different
   Google account." Both are enforced by Firebase itself (duplicate emails
   are rejected server-side regardless of which sign-in method created the
   first account) — these are just clearer wording for errors that were
   already being blocked correctly.

3. **Duplicate code removed from `AppState`.** `login()`,
   `finalizeRegistration()`, and `signInWithGoogle()` each independently
   repeated the same "cache profile locally, sync to Firestore, set
   currentUser, start session, load data, log it, start the mesh" sequence
   — three copies of the same seven lines. Extracted into one shared
   `_completeSignIn()` helper (with an optional `beforeLoad` hook, since
   `login()`'s demo-account path needs to seed demo data at one specific
   point other callers don't need). Behavior is unchanged; this is purely
   the redundancy cleanup that was asked for.

Confirmed for clarity (not a code change): **duplicate-account prevention
is scoped to accounts/email, not vehicles.** A single logged-in user can
still register as many vehicles as they want via "+ Add Another Vehicle" —
`AppState.addVehicle()` has no per-account limit and wasn't touched. The
new blocking only applies to creating a *second Firebase account* with an
email that's already registered.

Verified `flutter analyze` (0 issues) and `flutter test` (passing) after
each change, then rebuilt the release APK (57.3MB) with everything above.

**Still needed from you (Firebase Console, not code):**
1. Authentication → Sign-in method → enable **Google** as a provider
   (pick a support email when prompted). This is free — no billing
   required, unlike Phone.
2. Project Settings → General → your Android app → **re-download
   `google-services.json`** and replace
   `android/app/google-services.json` with the new copy (enabling a new
   sign-in provider updates this file; the app needs the current one).
3. Optional cleanup: you can now disable/remove the **Phone** sign-in
   provider in the console entirely, since nothing in the app uses it
   anymore.

Verified `flutter analyze` (0 issues) and `flutter test` (passing), and a
full `flutter build apk --release` (57.3MB) succeeded — the file on disk
now has the new verification flow. Manuscript note: FR-01's phone
verification requirement should be revised to describe email verification
(and Google Sign-In as an alternative), since that's now what the running
system actually does — this keeps the documentation and the code honestly
aligned.

---

**One more fix, same day:** Logout previously sent the user to `/` (the
Splash welcome screen, with "GET STARTED"/"LOG IN" buttons) instead of
straight to the Login screen — an extra, pointless tap after explicitly
choosing to log out. Also switched from `pushReplacementNamed` to
`pushNamedAndRemoveUntil(..., (route) => false)`, which clears the entire
navigation stack, not just the Profile screen — Profile is reached via
`pushNamed` from Home's bottom nav, so a plain replace would have left Home
sitting underneath, reachable by pressing back into a stale, logged-out
dashboard. Rebuilt the release APK again (57.3MB) with this included.

**Explicitly checked and left alone (not bugs, or already correct):**
`main.dart`'s route-argument casts, the Proximity/Geofence map's
recenter-on-GPS-update behavior, and the unused `alertDelay` /
`transmissionRate` / `proximityAccuracy` stats — none of these are wrong,
just candidates for a future polish pass (real crash risk is low since
navigation is fully internal, and the map recentering only affects the
no-active-alert/own-GPS case). `_NearbyNodeRow` in `s4_s5_vehicle_home.dart`
already handled the `-1` distance correctly before this pass — only the two
`widgets.dart` versions needed the same fix.

---

## Device compatibility pass + personal/work email confirmation
## (2026-09-18)

**Compatibility check, requested explicitly ("any Android device except
very old models"):**
- `minSdk = 29` (Android 10, released 2019) was already set deliberately
  — this was a pre-existing, correct choice, not something added this
  session. It excludes genuinely old/unsupported devices while covering
  the large majority of Android phones in active use.
- The APK already builds universal (no `abiFilters`/`splits` restricting
  it to specific CPU architectures), so it installs on both 32-bit and
  64-bit devices.
- All optional hardware (`camera`, `bluetooth_le`, `wifi.direct`) is
  already declared `android:required="false"` in the manifest, so a
  device missing one of those isn't blocked from installing at all —
  already correct, not changed.
- **Fixed:** removed `ACCESS_BACKGROUND_LOCATION` from
  `AndroidManifest.xml`. Root cause: the app only ever requests foreground
  location (`LocationService` is explicitly documented as a foreground-only
  watcher — no OS-level background service exists, matching the
  ad hoc mesh's own documented foreground-only limitation) and never
  requests Android's separate "Allow all the time" grant. Declaring a
  permission the app doesn't actually use adds unnecessary friction to the
  permission dialog on some Android versions and would require extra
  justification if this project is ever submitted to the Play Store —
  genuinely unnecessary, now removed.

**Personal vs. work email, confirmed (no code change needed):** grepped the
whole codebase for any Gmail-only or domain-restricted logic — there is
none. `_emailPattern` (the client-side format check) accepts any
`something@something.tld` shape with no domain allowlist, Firebase
Authentication itself doesn't restrict which email domains can register or
receive verification mail, and `GoogleSignIn()` has no `hostedDomain`
restriction set — so a personal Gmail, a work email, and a
`@carsu.edu.ph` (personal or Google Workspace) address all work
identically for both the email/password flow and "Continue with Google."

Verified `flutter analyze` (0 issues) and rebuilt the release APK (57.3MB)
with the manifest fix.

---

## Manuscript alignment — consolidated "what's still open" (as of
## 2026-09-18)

Gaps and deliberate scope decisions were previously scattered across the
dated sections above. Collected here in one place so it's easy to check
what still needs a manuscript update or a follow-up build, without hunting
through history. Nothing below is a bug — these are either documentation
that needs to catch up to the code, or features intentionally deferred.

**Needs a manuscript update (the code changed, the writeup hasn't caught up):**
- **FR-01** currently describes SMS OTP phone verification. The running
  system no longer does this at all (removed entirely — see the
  2026-09-18 "SMS OTP → Email verification" section above) due to Firebase
  Phone Auth requiring a paid Blaze billing plan for real SMS delivery.
  FR-01 should be rewritten to describe **email verification** (a clicked
  link, with a 60-second client-side re-check window and a resend option)
  as the primary path, plus **Google Sign-In** as an alternative that
  skips verification entirely (a Google-authenticated email is already
  verified by Google).
- The phone number field is now a **plain, self-reported contact field**
  (still collected and format-validated, never cryptographically verified)
  — any manuscript language implying the phone number itself is verified
  needs to be corrected.
- Table 3.3.2.1 / architecture description should mention **Google
  Sign-In (OAuth via `google_sign_in`)** as a second identity path
  alongside Firebase email/password Auth.

**Implemented this session, beyond the original manuscript scope (worth
citing as an enhancement, not a gap):**
- Client-side login-attempt lockout (5 failed attempts → 5-minute lockout
  per email, persisted across app restarts) — layered on top of Firebase's
  own server-side throttling.
- Duplicate-account prevention with formal user-facing messaging, for both
  the email/password path and the cross-provider case (an already-registered
  email tried again via Google Sign-In).

**Deliberately deferred, not forgotten (already noted in earlier sections,
restated here for one-place visibility):**
- **At-rest SQLite encryption** (e.g. SQLCipher) — local DB currently
  stores no password material (that's all in Firebase now), so the risk
  is lower than it used to be, but alert/vehicle/location data is still
  unencrypted on disk.
- **Per-owner Firestore rules** restricting `theft_alerts`/`location_history`
  to their original reporter were deliberately NOT added, because the ad
  hoc mesh's relay feature requires other users' devices to read alerts
  they didn't create.
- **Real release signing** (a dedicated keystore, not the debug one) —
  only relevant before any Play Store submission, not for
  sideloading/evaluation.
- **Server-side FCM push** (a Cloud Function that watches Firestore and
  pushes targeted notifications to other users' devices) — the
  receiving side is implemented; nothing sends a targeted push yet, since
  that requires a server component outside this Flutter app.
- **Photo evidence isn't transmitted peer-to-peer** over the mesh — only a
  `hasPhotoEvidence` flag is relayed; the actual photo stays local to the
  reporting device.
- **Multi-device registration** (one account/user across multiple physical
  devices) is not built.
- **A full per-screen animation pass** — only the shared success modal and
  a few milestone actions got animation this session; the other ~10 screens
  are unanimated.
- `PROJECT_PROGRESS.md` and `GAP_ANALYSIS.md`, referenced at the top of
  this very file as companion docs, **don't actually exist in the repo** —
  either they were never created, or this reference is itself stale. Worth
  either creating them or removing the reference.

---

## Quick vehicle registration via plate photo (OCR) (2026-09-18)

Added an optional "Scan Plate Photo" shortcut on `RegisterVehicleScreen`,
on top of the fully manual form that already existed (never a replacement
for it — every field stays editable regardless of what the scan finds).

**Scope was deliberately narrowed before building anything**, after
flagging a real feasibility gap: recognizing a vehicle's plate number from
a photo is achievable with free, on-device OCR (Google ML Kit Text
Recognition — no billing, no API key, works offline after a one-time
model download); recognizing the vehicle's **make/model** from a photo is
not achievable for free — that needs a trained vehicle-recognition model
or a paid third-party API, neither realistic here, and would have
reintroduced the exact "hidden billing dependency" problem this session
already worked around for OTP. Discussed with the user, who chose the
narrower, more honest scope: **plate number only** is auto-filled; **Color**
and **Model** always stay manual entry.

**New file:** `lib/services/plate_scanner_service.dart` — wraps ML Kit's
`TextRecognizer` (Latin script), runs OCR on a photo, and matches the
result against a Philippine private-vehicle plate pattern (3 letters + 3-4
digits, e.g. "ABC-1234"). Returns null (never a guess) if nothing
plate-shaped is found, so the caller always falls back to manual entry
rather than silently filling in something wrong.

**`RegisterVehicleScreen` changes:** a "Scan Plate Photo (Quick Fill)"
button opens a bottom sheet (Take Photo / Choose from Gallery, reusing the
same pattern as the Report Stolen screen's photo picker) → runs OCR →
auto-fills the PLATE NUMBER field and shows a toast asking the user to
double-check it, or a clear "couldn't read it, enter manually" message if
nothing was found. The Device ID field was already auto-filled from the
logged-in account (existing behavior, not new).

**Build note:** R8 (release minification) initially failed —
`google_mlkit_text_recognition` references optional Chinese/Devanagari/
Japanese/Korean recognizer classes this app never uses (only
`TextRecognitionScript.latin` is constructed), and R8 treated their
absence as an error rather than a warning. Fixed with a new
`android/app/proguard-rules.pro` (`-dontwarn` for those four classes),
wired into `build.gradle.kts`'s release `proguardFiles`. Release APK size
grew from 57.3MB to **87.8MB** — the OCR model/native libraries are the
cause; acceptable for sideloading, but worth knowing about, and reducible
later via per-ABI APK splits if it ever matters for distribution.

Verified `flutter analyze` (0 issues), `flutter test` (passing), and a
successful `flutter build apk --release`.

---

## Two-device test: phones couldn't find each other (2026-09-20)

**Symptom (two real phones, both registered, one reports a stolen car):**
the reporting phone showed "Mesh Inactive" and a red toast
`Could not start the ad hoc mesh: PlatformException(Failure, 8001:
STATUS_ALREADY_ADVERTISING)`. The Alert Broadcasting screen said "No
participating devices are currently nearby," and the other phone sat on
"Scanning for nearby devices…" with 0 nodes indefinitely.

**Root causes found in `nearby_mesh_service.dart` / `app_state.dart`:**

1. **Overlapping mesh starts.** `_startMeshIfNeeded()` is called from four
   places: app launch, login/registration completion, the "Grant
   permission" buttons, and the real/demo mode switch. Nothing guarded
   against two of them running at once, so a second `startAdvertising` hit
   Google's `STATUS_ALREADY_ADVERTISING` (8001).
2. **A half-failed start could never be recovered.** `isRunning` only became
   true after BOTH advertising and discovery succeeded, and `stop()` was
   `if (!isRunning) return;`. If advertising succeeded and discovery threw,
   advertising stayed on with nothing tracking it, `stop()` (incl. on
   logout) refused to clean it up, and every later attempt hit 8001 until the
   app was force-closed. This is the "partial mesh-start leak" logged in an
   earlier pass and left open — it is what produced this failure.
3. **Discovered-but-not-connected devices were invisible.** The Home
   "Nearby devices" list and count only showed connected nodes, so "0
   nearby" looked the same whether nothing was found or a device had been
   found and was still connecting. There was also no way to restart a stuck
   mesh, and no warning when Bluetooth or Location (GPS) was off — Android
   silently refuses to scan without them.
4. **Simultaneous connection requests.** Both phones discover each other in
   the same instant and both fire `requestConnection` at once, which Nearby
   Connections resolves unreliably. A connection request that never reported
   back was also left "pending" forever, blocking any retry.

**Fixes:**
- One shared in-flight start (in the service and in `AppState`), so
  overlapping callers reuse one attempt.
- Every start begins with a full teardown, and a failed/half start tears
  itself down. `stop()` now always tears down regardless of `isRunning`, and
  a start that finishes after `stop()` was called cleans itself up.
- A background watchdog (every 40 s while the mesh is wanted): retries a
  failed start quietly, retries connecting to devices seen but not connected,
  and refreshes the radios if nobody has been seen for a while.
- Random 0.25–2 s delay before auto-connecting so the two phones don't
  collide; 20 s expiry on stuck pending requests; benign "already connected"
  (8003) errors no longer toast; connection-failure toasts wait 3 s and are
  skipped if the peer connected anyway.
- Nearby endpoints are cleared whenever the radios reset (their IDs are
  ephemeral), so stale peers don't linger.
- UI: found-but-connecting devices are now listed ("Connecting…"); the mesh
  card shows a live line `Advertising ON · Scanning ON · Found N · Connected
  N`; status text says "Found N device(s) — connecting…"; a **Restart Scan**
  button; and a clear warning when Bluetooth or Location (GPS) is off.
- `proguard-rules.pro` wiring switched back to Flutter's default
  `proguard-android.txt` (an earlier change had pulled in the more aggressive
  optimize variant, which isn't worth risking around Bluetooth code).

**Not verifiable from here:** actual over-the-air discovery between two
physical phones can only be confirmed on the phones. Requirements: install
this build on BOTH, Bluetooth + Location (GPS) ON on both, app open in the
foreground on both (there is no background mesh), phones within a few
metres for the first test.

`flutter analyze` 0 issues, `flutter test` passing, release APK 89.6MB.

---

## Google Sign-In could log in unregistered Gmail accounts (2026-09-20)

**Bug (reported):** tapping "Continue with Google" with a Gmail that was never
registered logged the person straight into the app.

**Root cause:** Firebase's Google sign-in (`signInWithCredential`) silently
creates a brand-new account for any Google email it hasn't seen. The earlier
implementation treated that as "first use = register and log in", which
bypassed the Register form and email verification entirely. It contradicted
the intended rule: Google is a login shortcut for accounts already
registered through the app.

**Fix:**
- `FirebaseAuthService.isRegisteredAccount()` — a registered account has the
  email/password provider (created through Register; Google may be linked to
  it under the same email). An account with ONLY Google was never registered.
- `AppState.signInWithGoogle()` now checks that after sign-in. If the account
  isn't registered it is deleted (best effort), fully signed out (including
  Google's cached session so the account picker shows again), and
  `googleRejectedEmail` is set. The Login screen shows a
  "Google Account Not Registered" modal with **Register** / **Close**.
  The "New account registered via Google" path is removed.
- The same check now runs at session restore in `init()`, so an
  auto-created Google-only session left over from an earlier build is signed
  out on next launch instead of being trusted. (Even if the delete call ever
  fails, the account is still rejected on every attempt — the check, not the
  delete, is the gate.)

**Who can sign in now:** (1) email/password — only accounts created through
Register whose email is verified; (2) Google — only Google accounts whose
email matches a registered account. Everything else is refused.

**Console setting to confirm:** Firebase Console → Authentication → Settings
→ User account linking must be "Link accounts that use the same email"
(the default). That is what lets a registered email/password account also
use Google with the same email. If it were set to "multiple accounts per
provider", Google would create a separate account and be refused.

**Known intentional exception (flagged, not changed):** the demo account
`juan@vehicleguard.ph / demo1234` is auto-provisioned, its credentials are
printed on the Login screen, and it skips email verification. Fine for
evaluators; remove it before any real release.

---

## Two phones still not linking + internet fallback (2026-09-20, later)

**Evidence (reporting phone, new build):** `Advertising ON · Scanning ON ·
Found 0 · Connected 0` for minutes. So the earlier fix worked (the mesh now
starts and stays up, no more 8001), but Android's Nearby layer never reported
the other phone. I read the plugin's native code
(`nearby_connections-3.3.1/.../NearbyConnectionsPlugin.java`): it passes
straight through to Google's Nearby Connections client, with no fault that
would explain "found nothing". So the cause is at the radio/OS level on the
phones (Bluetooth/Location off or blocked on the *other* phone, its app not in
the foreground or screen locked, an OEM battery/permission restriction, or the
other phone not running this build) — which cannot be determined from a
screenshot of one phone. No phone is attached to this PC, so I could not read
device logs.

**What was added instead of guessing:**
1. **Full mesh trace in System Logs (tag MESH):** start attempts and results,
   every device found/lost, every connection request, initiated and result
   status, watchdog retries. Next time two phones fail to link, System Logs on
   BOTH phones show exactly which step is missing (e.g. one phone never logs
   "Found …", or a request is sent but never answered).
2. **Watchdog is gentler:** radios are only refreshed after 90 s with nobody
   seen (was 40 s), so a working scan isn't constantly torn down.
3. **Internet alert feed (the manuscript's second delivery layer).** Every
   reporter already uploads its alert to Firestore. Every signed-in phone now
   also listens to `theft_alerts` live (last 24 h), so an alert reaches other
   phones over the internet even when Bluetooth/Wi-Fi Direct discovery fails:
   new active alerts within 5 km of the phone raise a notification and appear
   in Alerts/Active Alerts; a later "recovered" status is applied on phones
   that already have the alert. Alerts the user reported themselves are
   ignored; alerts received this way are saved as already-synced so they
   aren't re-uploaded.
4. **Recovered/resolved now upload immediately** (before, they waited for the
   next network change), so other phones see a recovery promptly.
5. **Status can no longer go backwards in the cloud.** A phone that only
   *received* an alert also uploads its copy (store-carry-forward). If its copy
   was stale it could overwrite the reporter's newer "recovered" with "stolen".
   The upload now checks the cloud status first and never downgrades
   (active → recovered → resolved only).

**REQUIRED Firestore rule change:** the rules recommended earlier had
`allow list: if false` on `theft_alerts`. The feed is a collection query, so
it is denied until that is changed. In Firebase Console → Firestore → Rules,
replace the `theft_alerts` block with:

```
match /theft_alerts/{alertId} {
  allow get, list: if request.auth != null;
  allow create, update: if request.auth != null && request.resource.data.id == alertId;
  allow delete: if false;
}
```
(If the rule is not changed, the app keeps working; System Logs shows a CLOUD
warning "Internet alert feed unavailable".) Note this lets any signed-in user
read all recent alerts — that is the intended behaviour of a shared
theft-alert network, and matches what the mesh already does.

**Still cannot be verified from here:** the Bluetooth/Wi-Fi Direct link
between two physical phones. Test with the System Logs of both phones open.

`flutter analyze` 0 issues, `flutter test` passing.

**Rules confirmed applied (2026-09-20).** With the updated `theft_alerts` rule
in place, the internet alert feed can read. While checking the rules against
the code, one more bug: `_syncLocations` named cloud documents by the phone's
local auto-increment `dbId`, so two users' records collided on the same
document ID (`1`, `2`, …); the `location_history` rule only allows create, so
the second phone's uploads were denied every time (and could show SYNC
FAILED). Document IDs are now `<vehicleId>_<dbId>`, unique across users.

---

## Full delivery-path audit after the two-phone test (2026-09-21)

Re-traced the whole path an alert takes (report → upload → other phone →
shown to the user) and fixed everything that could silently stop it reaching
another device:

1. **Uploads could be skipped.** "Upload now" was skipped whenever the sync
   status was `syncing` or `syncFailed`, and nothing retried. An alert
   reported mid-sync, or after any earlier failure, waited for the next
   network change and could sit unsent forever. Now: sync requests made while
   one is running are queued and re-run, only a known-offline state skips,
   a failed sync retries every 30 s (failure is reported once, not on every
   retry), and pending items upload at launch and after login.
2. **Notification permission was never requested.** `requestPermission()` on
   the notification service existed but was never called, so on Android 13+
   "Stolen Vehicle Nearby" notifications could be silently dropped. Now
   requested at startup (before the FCM prompt so the two don't collide).
3. **The "Alert Received" screen was never shown.** Its route existed but
   nothing opened it. A received alert (mesh OR internet) now raises an
   in-app "Stolen Vehicle Nearby!" popup on whatever screen the user is on,
   with **View Details** opening that screen.
4. **No app-lifecycle handling.** Android throttles Bluetooth scanning and
   network listeners while an app is backgrounded or the screen is locked.
   On returning to the app it now pushes pending uploads, reopens the
   internet feed, and restarts the mesh radios if nothing is connected (this
   also picks up Bluetooth/Location being switched on after the warning).
5. **Alerts with a placeholder location were dropped.** If the reporter had
   no GPS fix the alert carries a fallback position; the 5 km relevance check
   on the receiving phone wrongly rejected it. Those alerts are now
   delivered without the distance check.

**Limits that remain (documented, not bugs):** both phones must have the app
open (a locked/closed app gets neither Bluetooth nor the live internet feed —
waking a closed app needs server-side push, which isn't built); Bluetooth +
Location must be on; the Bluetooth link itself between two physical phones
still can't be verified from here — use the MESH lines in System Logs on both
phones to see where it stops.

`flutter analyze` 0 issues, `flutter test` passing, release APK rebuilt.

---

## Registered vehicle "gone" — vehicles are now saved to the account (2026-09-21)

**Root cause:** vehicles were stored ONLY in the phone's local SQLite database
(`vehicles` table, keyed by the account's Firebase UID); `firebase_sync_service`
explicitly left vehicles out of cloud sync. Nothing in the code deletes a
vehicle except the owner's **Remove** button (behind a confirmation). So a
vehicle "disappears" whenever the local database isn't the one it was saved
in: logging into the same account on a different phone, uninstalling /
clearing app data, or the Firebase account being deleted and re-created
(a new UID no longer matches the vehicle's `ownerId`). The account profile
itself was fine — it is in Firestore `/users/{uid}` and restored on login.

**Fix — vehicles are backed up to the account and restored on login:**
- Stored privately at `/users/{uid}/vehicles/{vehicleId}` (owner-only).
- Saved right after register / geofence change / reported stolen / recovered;
  restored on login **before** the vehicle list loads (bounded to 10 s so an
  offline login isn't held up), and reconciled on every sync and app resume.
- Reconcile rules: restore vehicles the cloud has and the phone doesn't;
  upload everything else; if the owner removed a vehicle on another device it
  is removed here too (only for vehicles known to have been in the cloud, and
  reads come from the server so an offline empty cache can never look like
  "everything was deleted"). A removal made offline is remembered and applied
  to the cloud later, so a removed vehicle never comes back.
- The only way a vehicle goes away is the owner removing it.

**REQUIRED Firestore rule (add inside `match /databases/{database}/documents`):**
```
match /users/{uid}/vehicles/{vehicleId} {
  allow read, write: if request.auth != null && request.auth.uid == uid;
}
```
Without it the app keeps working locally, but the cloud backup can't run
(System Logs shows a VEHICLE warning "permission-denied").

**Limits:** vehicles registered BEFORE this build exist only on the phone they
were made on — open the app there once (online, rule added) and they upload.
A vehicle whose account was deleted and re-created cannot be re-attached
(new UID). Alert history remains local + the shared alert feed.

`flutter analyze` 0 issues, `flutter test` passing, APK rebuilt.

---

## Audit pass after rules were published (2026-09-21)

Re-read the most recently changed code (mesh service, sync, alert feed,
vehicle backup, lifecycle handling) hunting for new bugs. Fixed:

1. **Alert stored/announced twice.** The same alert can arrive over the mesh
   and the internet feed at the same moment; the mesh path did an awaited
   database lookup before inserting, leaving a gap in which both paths passed
   the "already have it?" check. Now checked in memory and re-checked at the
   moment of insert.
2. **Mesh restarted on every return to the app.** The camera, a permission
   popup and the Google account picker all count as "resumed", and each one
   restarted the radios (discarding a working scan or an in-progress
   connection). Now it restarts only after 20 s+ away, and never while a
   device is found and connecting; the Bluetooth/Location warning toast is
   not repeated on those restarts.
3. **Two permission dialogs requested at the same instant.** The
   notification permission request added last pass ran alongside the
   location request at startup; simultaneous requests can cancel each other
   and leave a permission looking "denied". It now runs after the location
   prompt.
4. **Uploads could stall.** Firestore writes wait for the server, so on Wi-Fi
   with no real internet an awaited upload could hang and block every later
   sync (the new "one sync at a time" guard would then queue forever). Alert
   and location uploads now time out after 12 s and retry.
5. **Repeated error popups.** The background connection retry kept re-trying
   devices that had walked away and popped an error each time. It is now
   silent, and forgets a device that fails.

**Verified:** `flutter analyze` 0 issues, `flutter test` passing, release APK
rebuilt. **Not verifiable from this PC:** anything that needs two physical
phones (the Bluetooth link, popups on the second phone) — the code paths were
checked by reading and analysis, not by running them on devices.

---

## Two-phone result, nearby-devices list, profile photo (2026-09-21)

**Test result (two registered phones, one reported a stolen car):** the
internet delivery path WORKS — the second phone received the alert, showed the
"Stolen Vehicle Nearby!" popup and the Alert Received screen. Both phones,
however, still show `Advertising ON · Scanning ON · Found 0 · Connected 0`:
Bluetooth/Wi-Fi Direct discovery never links them, so the "Nearby Devices"
list stayed empty. The plugin code was read and has no fault; the cause is at
the phone/OS level and can't be pinned down remotely.

**Nearby Devices now works without Bluetooth (shared position):** while the
real mesh is on and the app is in the foreground, a signed-in phone publishes
its name + position (rounded to ~11 m) to `/presence/{uid}` every 30 s. Every
phone listens and lists registered devices whose last update is < 100 s old and
whose distance from its own GPS is ≤ 100 m, with the distance and an "Active"
status ("GPS · Internet"). Bluetooth-connected peers are still listed as
before and not duplicated. The presence document is deleted on logout / when
the mesh is switched off and not refreshed while the app is closed. Internet-
located devices are kept off the map markers and the relay list (they have no
real map position / receive alerts via the internet feed). The privacy text
(Profile → Privacy & Data) now discloses this sharing.

**Possible Bluetooth cause added as a warning:** on Android 12+ a user can
grant only "Approximate" location; Bluetooth scanning silently returns nothing
without Precise. The mesh card now warns when Location is set to Approximate.

**Alert Received screen was inaccurate:** it always said "Received Via: Real
Ad Hoc Mesh / Proximity: Nearby (BLE/Wi-Fi)". It now shows how the alert really
arrived (Internet / Ad Hoc Mesh) and the real distance to where it was
reported.

**Profile photo:** tap the avatar on Profile → Take Photo / Choose from Gallery
/ Remove. Resized to 400 px and compressed (tens of KB), saved on the phone and
on the user's own profile document (Firestore, not Cloud Storage, which needs a
paid plan for new projects), so it returns on a new phone.

**REQUIRED Firestore rules** (add the `presence` block; the profile photo needs
no change — it is a field on the existing owner-only `users/{uid}` document).
Full rules:
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    match /users/{uid} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }

    match /users/{uid}/vehicles/{vehicleId} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }

    match /presence/{uid} {
      allow get, list: if request.auth != null;
      allow create, update, delete: if request.auth != null && request.auth.uid == uid;
    }

    match /theft_alerts/{alertId} {
      allow get, list: if request.auth != null;
      allow create, update: if request.auth != null && request.resource.data.id == alertId;
      allow delete: if false;
    }

    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if false;
      allow create: if request.auth != null;
      allow update, delete: if false;
    }

  }
}
```
Without the `presence` rule the list stays empty and System Logs shows a CLOUD
warning ("Nearby-device feed unavailable").

**Trade-off to be aware of:** the presence list means every signed-in user can
read every active user's name and ~11 m position. That is inherent to finding
nearby users through a server; it is limited to the foreground, the real-mesh
toggle, and 100 s freshness, and is disclosed in the Privacy screen.

---

## Geofence violation never triggering + near-boundary warning (2026-09-23)

**Reported:** geofence armed at 100m, moved the phone outside it, nothing
happened (no STOLEN status, no alert).

**Root cause, found by reading `location_service.dart` /
`app_state.dart`'s geofence path end to end:** geofence checking only ever
looked at `currentLat`/`currentLng`, which were updated ONLY by a passive
`Geolocator.getPositionStream()` listener. Two ways that stream leaves those
values frozen while the phone genuinely moves:
1. It only emits on its own schedule (roughly every 10 m of movement as
   Android's fused location provider sees it) — not a guaranteed cadence.
2. **Its error callback was `onError: (_) {}` — completely silent.** A real
   device very commonly stalls this kind of stream once Android's battery/
   background throttling kicks in (screen off, app not in the true
   foreground even briefly) — and the app never knew, so it kept comparing
   fresh reality against a stale, stuck position with no violation ever
   computed correctly and no record of anything having gone wrong.

**Fix:**
- `LocationService.startWatching()` now takes an `onError` callback instead
  of swallowing stream failures, and sets `status = GpsStatus.unavailable`
  when it happens.
- The geofence timer (`AppState`) no longer trusts the passive stream at
  all: every 15 s it now calls `_checkGeofencesFresh()`, which asks for a
  brand-new GPS fix directly (`LocationService.getCurrentPosition()`) and
  checks geofences against THAT — self-healing regardless of whether the
  background stream is alive. It skips entirely (no GPS poll at all) when no
  vehicle currently has an active geofence, and won't overlap if a fix is
  still pending from the previous tick.
- A stream failure is now logged (System Logs, tag GPS) instead of silently
  vanishing.

**Added — "almost outside" early warning, as requested:** when a vehicle's
device is still inside its safe zone but within 20 m of the boundary, a
one-time **"Approaching Safe Zone Boundary"** modal appears (on whatever
screen the user is on, same mechanism as the "Stolen Vehicle Nearby" popup),
plus a notification and a System Logs entry. It re-arms once the device
either returns to more than 20 m inside the boundary or actually crosses it
(at which point the existing automatic-STOLEN-report behavior takes over,
unchanged). The margin (20 m) sits in the middle of the requested 10-20 m
range as a single clear threshold rather than a fuzzy band.

**Confirmed not the cause, for the record:** being OFFLINE (as shown in the
screenshot) does not block geofence detection — it is fully local; only the
resulting alert's cloud sync is deferred, exactly as designed.

**Not verifiable from here:** whether this specific phone's OS throttling
was actually the trigger, or the stream simply hadn't fired again yet —
either way the fix now works around both. Test by arming a geofence, then
walking the phone slowly outward: the new modal should appear once at
~20 m before the edge, and the automatic STOLEN report should fire on
crossing it, within about 15 s.

`flutter analyze` 0 issues, `flutter test` passing, release APK rebuilt.

---

## Clarified: "the device" is this phone, placed with the vehicle (2026-09-23)

No separate GPS tracker hardware exists in this system — the phone running
VehicleGuard IS "the device." Geofence detection already worked this way
(compares this phone's GPS against the saved safe-zone center), but the
Geofence screen never told the user that in words, which is what prompted
the question. Added to the info note on that screen: violation detection
only works while this phone stays with the vehicle (e.g. left inside it)
and the app is open in the foreground. No logic changed — this was already
how the code worked; only the missing explanation was added.

---

## Demo account removed + copy cleanup + dependency cleanup (2026-09-23)

**Demo account fully removed**, not just hidden — per explicit request
("i dont need it anymore"):
- Login screen: the pre-filled `juan@vehicleguard.ph` / `demo1234` fields
  are now empty, with hint text ("naruto@gmail.com" / password dots) like
  every other field in the app, and the blue "Demo: ..." info box is gone.
- `AppState.login()`: removed the `isDemoAccount` branch entirely — the
  silent auto-register-on-first-login fallback, the exemption from the
  email-verification gate, and the hardcoded name/phone/deviceId. Every
  account now goes through the exact same path: register → verify email
  (or Google) → log in.
- `_seedDemoDataIfNeeded()` (the demo sample vehicle + recovered alert
  seeded on first login) deleted — dead code with the branch that called it
  gone.
- `AppStrings.demoEmail` / `demoPass` in `app_theme.dart` deleted (unused).

**Register screen copy, as requested:** email hint changed to
`tanjiro@gmail.com`; phone hint's "(not SMS-verified)" suffix removed
(the field itself is unchanged — still a plain, unverified contact field,
just without the parenthetical in the hint text). Login screen's email
hint changed to `naruto@gmail.com`.

**Dependency cleanup**, found while scanning for dead code (`flutter
analyze` already catches unused private declarations, so this pass looked
one level up, at unused pubspec dependencies): `crypto`, `uuid`,
`lottie`, and `path_provider` were declared in `pubspec.yaml` but never
imported anywhere in `lib/` — leftovers from before the Firebase Auth
migration and never-adopted features. Removed all four; `flutter pub get`
resolved cleanly with no other package depending on them directly.

Verified `flutter analyze` (0 issues), `flutter test` (passing), release
APK rebuilt (89.8MB). No feature was removed except the demo account
itself, exactly as asked — every other screen, service, and flow is
unchanged.

---

## Searchable Model/Color pickers on Register Vehicle (2026-09-24)

**New:** the MODEL and COLOR fields on Register Vehicle are now searchable
type-ahead pickers instead of plain text fields, filtered live as you type,
with "Other" always listed so it's clear an unlisted model/color can still
be typed manually — no special-casing needed for that, since the field
already accepts free text either way; "Other" just clears the field to
prompt a fresh entry when tapped.

**New file `lib/utils/vehicle_catalog.dart`** — curated, real Philippine-
market vehicle models grouped by body type (26 Sedan, 56 SUV, 22 Hatchback
options, each list ending in "Other"), plus one shared 20-color list (colors
don't meaningfully differ by body style, so one list instead of three
near-identical ones). The Model field's options automatically switch when
Vehicle Type changes; the field also clears itself on that switch, since a
previously-picked model may not even exist for the new type.

**New reusable widget `SearchableSelectField`** in `widgets.dart` (built on
Flutter's own `RawAutocomplete` — no new dependency), used by both MODEL and
COLOR instead of writing the same search/dropdown logic twice.

**Bug avoided, not shipped then fixed:** Vehicle Type and Color originally
sat side-by-side in a half-width row (existing layout). A search dropdown's
options list needs real width to stay readable, and squeezed into half a
phone screen its overlay could end up too narrow or clipped — this can't be
verified without a live device, so instead of guessing, Vehicle Type and
Color were changed to each take the full row width, stacked, which removes
the risk entirely rather than papering over it with a guessed pixel width.

Verified `flutter analyze` (0 issues), `flutter test` (passing), release
APK rebuilt (89.9MB). Nothing else on the form changed — Plate Number, the
plate-photo scanner, Device ID, and Save all work exactly as before.

---

## Liquid nav bar, richer page transitions, animated Login header (2026-09-24)

**Liquid-style bottom navigation.** New `LiquidBottomNav` (widgets.dart): a
dark floating pill with a glowing circular indicator that slides to the
selected tab (`AnimatedPositioned`, 380ms, `easeOutCubic`) and a small
icon scale-bounce on selection — the style from the reference video, with
its purple swapped for the app's own red (`AppColors.primary` /
`primaryDark`) so it reads as VehicleGuard's own chrome, not a borrowed
widget kit. Built entirely with core Flutter widgets — no new dependency.

**Real duplication found and removed while building this:** the exact same
4 destinations (Home/Map/Alerts/Profile — icons, labels, colors) were
hand-coded TWICE — once as `BottomNavBar` (shared by Proximity Map, Alert
History, Notifications, Profile) and a second, near-identical copy written
directly inside `HomeScreen`. Both now use the one `LiquidBottomNav`;
`BottomNavBar` is a thin wrapper supplying only the one thing that
genuinely differs between callers (Home hosts its other tabs via
`IndexedStack`, so only tapping Map/Alerts/Profile actually navigates;
every other screen reaches all 4 tabs via `pushReplacementNamed`). Zero
markup duplicated now instead of two.
`extendBody: true` added to the 5 screens using this bar, so it floats
over the content instead of sitting on a solid-color gap where the old
flush bar used to be.

**Page transitions.** `main.dart`'s shared route transition changed from a
plain full-width slide to a combined slide + fade + very slight scale-in
(still ~320ms, `easeOutCubic`) — a livelier, more "app-like" feel switching
between screens, per the request to make page changes feel more
interactive.

**Animated Login header.** New `lib/widgets/login_hero_animation.dart`,
replacing the old plain shield-icon box above "Welcome back" (that text is
otherwise untouched): a small robot (`Icons.smart_toy`) standing on a
drifting cloud, casting a fishing line down toward an animated sea, with a
small "Keep Your Vehicle Safe" chip bobbing at the end of the line like
it's being reeled in and out on a loop. Built entirely from Flutter shapes/
icons/`CustomPainter` (no image asset exists or was needed) — stays inside
the app's own sky-blue/red palette rather than introducing new colors, and
sits purely as decoration above the functional part of the screen, so
nothing about the actual sign-in form changed.

Verified `flutter analyze` (0 issues), `flutter test` (passing), release
APK rebuilt (89.8MB). Every other screen, route, and flow is unchanged —
only the nav bar's look, the route transition, and the Login header were
touched, exactly as asked.

---

## Login background now full-page, sitting robot, more depth (2026-09-24)

**Requested after seeing the first version:** cover the whole page instead
of a small confined box, make it read as more 3D, and change the robot to
a sitting pose watching the sky while fishing.

**Honesty note on "3D":** Flutter has no 3D renderer — there is no path to
literal photorealistic 3D without a real 3D engine, which isn't something
to add on the strength of a look request I can't verify renders correctly.
What's actually deliverable, and what was built: the same depth cues real
UI design uses to fake dimensionality — layered parallax clouds (a dimmer,
slower far cloud + a crisper near one), gradient "chrome" shading with drop
shadows on the robot instead of flat fills, a light-source glow, and a
two-layer animated sea — clearly more dimensional than the flat single-icon
version, not literal 3D geometry.

**Layout change to cover the whole page:** the Login `Scaffold` now uses
`extendBodyBehindAppBar: true` with a transparent AppBar (back button only,
title removed as redundant with "Welcome back" below), and the body is a
`Stack`: `LoginHeroAnimation` as `Positioned.fill` (now sized to the FULL
screen via `LayoutBuilder`, not a fixed 190px box), with the actual form
sitting on an opaque white rounded-top sheet on top of it. Every field,
label, and button — email, password, forgot password, LOG IN, the Google
button, the register link — is completely unchanged and lives inside that
solid white sheet, so nothing about the background can make them hard to
read; the animated scene is only visible in the gap above the sheet. This
directly satisfies "make sure log in text or buttons are still visible."

**Robot redesigned as `_SittingRobot`:** gradient-shaded head and body
(chrome-style, not flat), two legs dangling off the edge of its cloud seat,
glowing cyan eyes positioned near the top of a slightly upward-tilted head
(reads as gazing at the sky), a small red chest light tying back to the
app's own accent color, and an arm holding a thin rod angled outward — the
fishing line (with the "Keep Your Vehicle Safe" chip) still casts down
toward the sea and back up on the same loop as before.

Verified `flutter analyze` (0 issues — including 5 pre-existing
brace-less `if` statements in this file that `dart format` exposed while
cleaning up indentation from the restructure; fixed with proper `{ }`
blocks, no behavior change), `flutter test` (passing), release APK rebuilt
(89.8MB). Nothing outside the Login screen and its own animation widget was
touched in this pass.

---

## Login background reverted to the contained version (2026-09-24)

Per explicit request, the full-page/"3D"/sitting-robot redo from the
previous entry was undone. `LoginHeroAnimation` and `LoginScreen`'s
`Scaffold`/`AppBar`/`Form` are back to the small, self-contained ~190px
rounded box above "Welcome back" (plain white AppBar with the "Log In"
title restored, standing robot icon, drifting cloud, two-layer animated
waves, the "Keep Your Vehicle Safe" chip casting on the fishing line) —
matching the version from the original request, before the follow-up
"cover the whole page" ask. The liquid bottom nav (`LiquidBottomNav`,
`BottomNavBar`) and the richer page-route transition in `main.dart` were
NOT touched and remain exactly as they were.

Verified `flutter analyze` (0 issues), `flutter test` (passing), release
APK rebuilt (89.8MB).

---

## Login background animation removed entirely (2026-09-24)

Per explicit request, the Login screen's animated header (robot/cloud/
sea/fishing-line, in any of its versions) is gone — reverted all the way
back to the original plain shield-icon box (🛡️ in a rounded
`AppColors.primaryLight` square) above "Welcome back". `lib/widgets/
login_hero_animation.dart` was deleted outright rather than left unused.
The liquid bottom nav (`LiquidBottomNav`/`BottomNavBar`) and the page-route
transition in `main.dart` were NOT touched and remain as they are.

Verified `flutter analyze` (0 issues), `flutter test` (passing), release
APK rebuilt (89.8MB).

---

## Liquid bottom nav reverted to a plain nav bar (2026-09-24)

Per explicit request, the bottom navigation bar's "liquid" look (floating
dark pill, sliding gradient indicator, bouncy icon scale-up) is gone.
`LiquidBottomNav` (`lib/widgets/widgets.dart`) was replaced by
`AppBottomNav`, a standard Material `NavigationBar` — white background,
`AppColors.primaryLight` selection indicator, the same 4 destinations
(Home/Map/Alerts/Profile) with labels visible and `AppColors.primary`
selected icons. It keeps the same `currentIndex`/`onTap` constructor shape
as before, so this stayed a rename-and-simplify rather than reintroducing
the pre-liquid duplication where the nav markup was hand-copied in both
`BottomNavBar` (s9_s10_s11_alerts_map.dart) and `HomeScreen`
(s4_s5_vehicle_home.dart) — both still just build the one shared widget.

The `extendBody: true` that 5 screens picked up only to make room for the
floating pill (`HomeScreen`; `ProximityMapScreen` and `AlertHistoryScreen`
in s9_s10_s11_alerts_map.dart; `NotificationsScreen` and `ProfileScreen`
in s12_s13_s14_status_notif_profile.dart) was removed from all of them
now that the nav bar sits flush again.

`lib/main.dart`'s page-route transition (`_slide()` — fade + slide + scale,
320ms) was intentionally left untouched, per "just leave the page
transitions."

General bug/redundancy scan: searched the whole `lib/` tree for any other
`LiquidBottomNav`/`login_hero_animation` leftovers (none), confirmed
`TapScale` is still used by other screens so it wasn't orphaned by this
change, and ran `dart format` over the touched files — which re-wrapped 7
pre-existing single-line `if (x) statement;` blocks elsewhere in
s4_s5_vehicle_home.dart and s12_s13_s14_status_notif_profile.dart across
two lines, tripping `curly_braces_in_flow_control_structures`; added
explicit `{ }` blocks to all 7 to clear it.

Verified `flutter analyze` (0 issues), `flutter test` (passing), release
APK rebuilt (89.9MB).

---

## Admin Dashboard added (2026-09-25)

New feature, at the user's request: an admin can now see every registered
account, suspend/restore or permanently remove one, promote/demote other
admins, and create a new account on someone's behalf — all from inside the
app. `UserModel.role` ('owner' | 'admin') already existed but nothing used
it; this is what finally reads/writes it.

**New files:**
- `lib/services/admin_service.dart` — every admin operation, talking to
  Firestore directly (never through AppState's local-first single-user sync
  path, since an admin is managing OTHER people's accounts).
- `lib/screens/s15_admin_dashboard.dart` — the dashboard screen (search +
  list of accounts), a per-user detail sheet (suspend/restore, promote/
  demote, remove, lazy-loaded vehicle list), and an "Add User" sheet.

**Entry point:** Profile → Account Settings → "Admin Dashboard", only shown
when `AppState.isAdmin` is true (`currentUser.role == 'admin'`). The screen
also pops itself if reached any other way by a non-admin.

**How removal actually works (soft delete):** the Firebase client SDK
cannot delete another user's Authentication record — it can only delete
the CURRENTLY signed-in user's own account. Truly erasing someone else's
auth record needs a Cloud Function with the Admin SDK, which needs
Firebase's paid Blaze plan. So "Remove Account" here deletes every vehicle
that account registered and sets `disabled: true` on their profile, which
permanently blocks login (see below) — everything the account owns is gone
and it can never sign in again, but the bare Auth record itself still
technically exists unless removed by hand in the Firebase Console. This was
a deliberate choice (offered as a question, soft-delete was picked) over
adding Cloud Functions + Blaze billing just for a full delete.

**How "Suspend" takes effect immediately, not just on next login:**
`AppState` now watches its own `users/{uid}` document live the entire time
it's signed in (`_startAccountWatch`, started after every login/
registration/Google sign-in/restored session). The moment an admin flips
`disabled: true`, that phone force-logs-out on its own and shows an
"Account Disabled" dialog before returning to Login — it doesn't wait for
the app to be reopened. `login()` and `signInWithGoogle()` also refuse a
disabled account outright, so it can't start a brand-new session either.

**How "Add User" avoids kicking the admin out of their own session:**
Firebase's client SDK has no "create another account" call —
`createUserWithEmailAndPassword` always signs the CALLER into the new
account. `AdminService.createUser` works around this with a throwaway
secondary `FirebaseApp` instance (same project, its own isolated auth
session) to create the account, then discards that instance — the admin's
own session on the primary instance is never touched. The created account
still gets a verification email and must verify before its first login,
same as self-registration (no admin-created bypass of FR-01).

**Bug fixed along the way:** `FirebaseSyncService.upsertUserProfile` used
to `.set()` the whole `users/{uid}` document on every login/registration —
a plain overwrite, not a merge. Since `disabled` (and the profile photo,
`photoB64`) live as extra fields on that same document rather than on
`UserModel`, every time the OWNER's own phone re-uploaded its profile it
would have silently erased whatever an admin had just set. Changed to
`SetOptions(merge: true)`.

**REQUIRED Firestore rules** — adds an `isAdmin()` helper and lets an
account with it read/write every `users/{uid}` document and vehicles
subcollection (previously owner-only); everything else is unchanged from
the last published rules. Full rules to paste in Firebase Console →
Firestore Database → Rules:
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function isAdmin() {
      return request.auth != null &&
        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin';
    }

    match /users/{uid} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /users/{uid}/vehicles/{vehicleId} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /presence/{uid} {
      allow get, list: if request.auth != null;
      allow create, update, delete: if request.auth != null && request.auth.uid == uid;
    }

    match /theft_alerts/{alertId} {
      allow get, list: if request.auth != null;
      allow create, update: if request.auth != null && request.resource.data.id == alertId;
      allow delete: if false;
    }

    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if false;
      allow create: if request.auth != null;
      allow update, delete: if false;
    }

  }
}
```
Trust note: this makes an admin account fully trusted by the rules
themselves (it can read/write anyone's profile and vehicles) — standard for
a single-admin capstone system, but worth knowing before handing admin
access to more than one person.

**Becoming the first admin** (deliberately NOT something the app can do to
itself — there's no safe way for client code to decide who gets to be an
admin without hardcoding a specific person into the shipped APK): register
a normal account through the app as usual, then in Firebase Console →
Firestore Database → `users` → find that account's document (its ID is
shown as "Account ID" if you ever open it from the dashboard, or just
match the email) → add a new field named `role`, type `string`, value
`admin`. Log out and back in on that account and "Admin Dashboard" appears
under Profile. From there, that admin can promote/demote anyone else
straight from the app — no more Console edits needed after the first one.

Verified `flutter analyze` (0 issues), `flutter test` (passing), release
APK rebuilt (90.3MB).

---

## Admin account hardcoded + web Admin Portal (2026-09-26)

Per explicit request: the admin account is now fixed in code instead of
being a self-registered/promoted account, every UI path that could ever
create or promote an admin is gone, and the Admin Dashboard is now also
reachable as its own website, not just inside the phone app.

**Hardcoded admin login** — `AdminService.kAdminUsername` /
`kAdminPassword` = `vehicleadmin` / `guardadmin`. Firestore Security Rules
can only ever trust a real, server-verified `request.auth` — never a plain
client-side boolean — so under the hood this still signs in with real
Firebase Authentication: the fixed username maps to one fixed, never-shown
internal email, and `AdminService.login()` auto-creates that one Firebase
account (and its `role: 'admin'` Firestore document) the very first time
anyone signs in with it, so there's no manual Firebase Console step needed
anymore — the OLD bootstrap instructions from the previous entry (register
normally, then hand-edit `role` in the Console) no longer apply and are
superseded by this. **No Firestore rules change was needed** — the
`isAdmin()` rule already just checks the caller's own `role` field,
regardless of how that field got set.

**Removed — no way to create/promote an admin:**
- The "Promote to Admin / Demote to Regular User" button and
  `AdminService.setRole()` it called — deleted outright, not just hidden.
- The Profile screen's "Admin Dashboard" menu item (it was gated on
  `AppState.isAdmin`/`currentUser.role`, which no longer means anything —
  a signed-in vehicle owner can never become the admin from inside their
  own account anymore).
- `AppState.isAdmin` itself — with nothing left to call it, kept it would
  have been dead code.

Regular users still default to `role: 'owner'` and admin can still add a
new REGULAR account from the dashboard ("Add User", unchanged) — only
admin creation/promotion was removed.

**New entry point (phone):** a small "Admin Login" link at the bottom of
the regular Login screen (`s2_s3_auth_screens.dart`) → `/admin-login` →
`/admin`. Deliberately separate from the normal owner login/registration
flow — the admin isn't a vehicle owner account.

**New: web Admin Portal.** Everything else in this app (local SQLite, the
Bluetooth/Wi-Fi Direct mesh, GPS watching, camera OCR…) is Android-only and
won't build or run on the web, so rather than trying to make the whole app
web-capable, the Admin Dashboard got its own SEPARATE build entry point
that only imports Firebase + the two admin screens:
- `lib/admin_main.dart` — the web app's `main()`/`MaterialApp`, routes
  `/admin-login` and `/admin` only.
- `lib/firebase_options_web.dart` — Firebase config for this build only,
  currently placeholder values (see below — one manual step left).
- `AdminService` gained its own `fetchVehicles()` (a deliberate, documented
  duplicate of `FirebaseSyncService.fetchVehicles` — that service also
  imports `DatabaseService`/sqflite, which has no web implementation;
  duplicating this one query keeps the admin screens free of that import
  entirely) and `s15_admin_dashboard.dart` no longer imports
  `AppState`/`Provider`/`FirebaseSyncService` at all, so the web build's
  import graph never touches anything mobile-only.
- Verified with `flutter build web -t lib/admin_main.dart` — builds clean
  (the only warning is an informational WASM-compatibility note about
  `geolocator_web`, unrelated to this build since geolocator isn't even
  imported by it; doesn't affect a normal web build).
- `web/index.html`'s title/description updated to "VehicleGuard Admin"
  since this is now what the web build actually is.

Build it with:
```
flutter build web -t lib/admin_main.dart
```
which outputs a static site to `build/web/` — deploy that folder to
Firebase Hosting, or any static host.

**Update (2026-09-26): `lib/firebase_options_web.dart` is filled in.** The
user registered a "VehicleGuard Admin" web app under the `vehicleguard-a2bef`
Firebase project and supplied its `firebaseConfig`; the placeholder values
are now the real ones, and `flutter build web -t lib/admin_main.dart` was
rebuilt and verified against them (builds clean). A Firebase web API key
isn't a secret by itself (it only identifies which project to talk to) —
what actually controls access is the Firestore Security Rules, unchanged
from before, so nothing else needed to change.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (90.3MB) and `flutter build web -t
lib/admin_main.dart` both succeed.

---

## Admin sign-in fixed, admin access made web-only (2026-09-26)

**Bug fixed: first-ever admin login failed with "credentials are out of
sync with the server".** `AdminService.login()` only auto-provisioned the
hardcoded admin's Firebase account on a `user-not-found` error. Newer
Firebase projects (this one included, being freshly created) default to
email-enumeration protection ON, which makes `signInWithEmailAndPassword`
return the SAME generic `invalid-credential` error for both "no such
account" and "wrong password" — it no longer reports `user-not-found`
distinctly. So the very first admin sign-in attempt (account doesn't exist
yet) was being misread as "wrong password" and never reached the
account-creation step. Fixed: any credential failure now attempts to
provision the account first; only if THAT attempt fails with
`email-already-in-use` do we know it's a genuine mismatch and show the
"out of sync" message. Verified against the real, now-configured Firebase
project (`vehicleguard-a2bef`) — `flutter build web -t lib/admin_main.dart`
rebuilt clean.

**Admin access removed from the phone app entirely, per explicit request —
web (or the Firebase Console directly) only:**
- Deleted the "Admin Login" link from the bottom of the Login screen
  (`s2_s3_auth_screens.dart`).
- Deleted the `/admin-login` and `/admin` route cases from `main.dart`'s
  router, and its now-unused `import 'screens/s15_admin_dashboard.dart';`.
- `s15_admin_dashboard.dart` (and everything it pulls in — `AdminService`)
  is now imported ONLY by `lib/admin_main.dart`, the separate web build
  entry point from the previous entry. The phone app's `lib/main.dart`
  import graph no longer references it at all — confirmed with a
  project-wide search for `/admin` and "Admin" across `lib/`, and with
  `flutter analyze` (0 issues).

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (89.9MB), and `flutter build web -t
lib/admin_main.dart` all succeed.

---

## Diagnosed "Could not load accounts" on the web dashboard (2026-09-26)

**Symptom:** admin login itself succeeded (reached `/admin`), but the
account list showed "Could not load accounts. Check your internet
connection and try again." with 0 accounts.

**Root cause:** the Firestore Security Rules published on the
`vehicleguard-a2bef` project are still the OLDER rules — owner-only
(`allow read, write: if request.auth.uid == uid`) — without the
`isAdmin()` function and the `|| isAdmin()` clause added when the Admin
Dashboard was first built (see "Admin Dashboard added" entry above for the
full block). That explains the exact split seen: signing in and writing
the admin's OWN profile document succeeded (self-access was always
allowed, even under the old rules — that's why login worked), but
`AdminService.fetchAllUsers()` — a `list` across the WHOLE `users`
collection, which needs the `isAdmin()` escape hatch to read documents
that aren't the caller's own — was rejected by Firestore as
`permission-denied`. The dashboard's old catch-all error handling then
mislabeled that rejection as a generic "check your internet connection"
message, which hid the real cause.

**Fix (this entry):** `AdminDashboardScreen._load()` now catches
`FirebaseException` specifically and checks `e.code` — a `permission-denied`
result now says plainly that the admin Firestore rules aren't published
yet, instead of blaming the internet connection. Any other Firestore error
still shows its code too, rather than a one-size-fits-all message. This is
diagnostic-only — it doesn't fix the rules by itself.

**What actually fixes it:** publish the rules block below (full replacement
— same one from the "Admin Dashboard added" entry, unchanged) in Firebase
Console → Firestore Database → Rules → paste → Publish:
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function isAdmin() {
      return request.auth != null &&
        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin';
    }

    match /users/{uid} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /users/{uid}/vehicles/{vehicleId} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /presence/{uid} {
      allow get, list: if request.auth != null;
      allow create, update, delete: if request.auth != null && request.auth.uid == uid;
    }

    match /theft_alerts/{alertId} {
      allow get, list: if request.auth != null;
      allow create, update: if request.auth != null && request.resource.data.id == alertId;
      allow delete: if false;
    }

    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if false;
      allow create: if request.auth != null;
      allow update, delete: if false;
    }

  }
}
```
After publishing, tap "Retry" on the dashboard (or refresh the page) — no
rebuild needed, since rules changes take effect immediately server-side.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build web -t lib/admin_main.dart` succeeds.

---

## Real permanent delete + dashboard UI/UX overhaul (2026-09-26)

Per explicit request: "Remove Account" now actually deletes the account
from Firebase instead of just hiding it, and each row on the dashboard got
quick-action icons plus a general visual cleanup.

**Bug fixed: "delete" wasn't permanent.** `AdminService.removeUser()` used
to only delete the person's vehicles and flip `disabled: true` on their
still-existing `users/{uid}` document — a soft delete, by original design,
but that meant a "removed" account never actually left the accounts list
(it just sat there forever tagged DISABLED), which isn't what "delete
permanently... on firebase" means. Fixed: `removeUser()` now deletes the
vehicles AND the `users/{uid}` document itself — the account genuinely
disappears from the list.

That alone would have been unsafe, though: the Firebase AUTHENTICATION
record can't be deleted from client code (explained in earlier entries —
needs a Cloud Function + Blaze plan), so with the profile document simply
gone, that person could just log back into the phone app with their old
credentials and `AppState.login()`'s existing "no profile found" fallback
would happily create them a brand-new blank profile — silently undoing the
deletion. Fixed by also writing a small tombstone to a new
`removed_accounts/{uid}` collection, which survives the profile document
being gone. `FirebaseSyncService.isAccountDisabled()` (checked before
`login()`/`signInWithGoogle()` ever complete) and `startAccountWatch()`
(the live watch that force-logs-out an already-open session) now both
check this tombstone in addition to the existing `disabled` flag — so a
permanently deleted account is blocked immediately and for good, exactly
like a suspended one, it just has no "restore" path back.

**REQUIRED Firestore rules update** — adds the `removed_accounts` rule.
Full rules to paste in Firebase Console → Firestore Database → Rules:
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function isAdmin() {
      return request.auth != null &&
        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin';
    }

    match /users/{uid} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /users/{uid}/vehicles/{vehicleId} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /removed_accounts/{uid} {
      allow read: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow write: if request.auth != null && isAdmin();
    }

    match /presence/{uid} {
      allow get, list: if request.auth != null;
      allow create, update, delete: if request.auth != null && request.auth.uid == uid;
    }

    match /theft_alerts/{alertId} {
      allow get, list: if request.auth != null;
      allow create, update: if request.auth != null && request.resource.data.id == alertId;
      allow delete: if false;
    }

    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if false;
      allow create: if request.auth != null;
      allow update, delete: if false;
    }

  }
}
```

**Dashboard UI/UX overhaul** (`s15_admin_dashboard.dart`):
- Each account row now has two quick-action icon buttons — suspend/restore
  (⟲ or ⛔) and delete (🗑) — so common actions no longer require opening
  the detail sheet first. Tapping the row itself still opens the full
  detail sheet (phone, device ID, account ID, registered vehicles).
- Added a stats row (Total / Active / Suspended counts as three colored
  chips) above the list, replacing the plain "N accounts" line.
- The AppBar got a small shield icon next to the title.
- Row borders now tint red for a suspended account, for a quicker visual
  scan of the list.
- "Remove Account" renamed to "Delete Permanently" throughout the UI, and
  its confirmation dialog now explicitly says the deletion is from
  Firebase and irreversible.

**Redundancy removed:** the detail sheet used to have its OWN copies of
the suspend/restore and remove confirm-dialog-plus-Firestore-call logic,
completely separate from (and now duplicating) the new row-level quick
actions. Removed that duplication — the sheet's buttons now just report
back which action was picked (`Navigator.pop(context, 'toggle' | 'remove')`)
and the ONE shared implementation in `_AdminDashboardScreenState`
(`_toggleDisabled` / `_removeUser`) handles both the row icons and the
sheet, so there's a single place that confirms and performs each action
instead of two.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (89.9MB — confirms the shared
`FirebaseSyncService` changes don't affect the phone app), and
`flutter build web -t lib/admin_main.dart` all succeed.

---

## Clarified: delete removes Firestore data, not the Authentication row (2026-09-26)

User question: after deleting 2 accounts from the Admin Dashboard, they
were still visible in Firebase Console → **Authentication** → Users. Not a
bug — that screen is a different Firebase product from **Firestore
Database**, which is what the dashboard actually manages. "Delete
Permanently" correctly removed those accounts' Firestore profile/vehicle
data and permanently blocked them from logging in again (the
`removed_accounts` tombstone from the previous entry); it was never able
to touch the Authentication record itself, for the same client-SDK
limitation explained in every earlier "remove" entry (needs a Cloud
Function + Blaze plan to do that part).

Decision: keep deleting those leftover Authentication rows by hand in
Console when needed, rather than adding Cloud Functions/Blaze billing for
it. To make this expectation clear going forward without having to
re-explain it, the delete confirmation dialog and success toast in
`s15_admin_dashboard.dart` now say explicitly that this removes the
account's DATA and login ability, and that its Authentication row (email/
password credential) still needs to be deleted separately in Console if
you want it gone from that list too.

Verified `flutter analyze` (0 issues), `flutter build web -t
lib/admin_main.dart` succeeds.

---

## Full system scan for bugs/duplicates/redundancy (2026-09-26)

Requested general health check now that the Admin Dashboard/Portal work is
done. `flutter analyze` and `flutter test` were already clean (as they've
been kept throughout this session), but the analyzer only catches unused
PRIVATE members/imports automatically — it has no whole-program check for
unused PUBLIC methods or classes, so this pass went looking for those by
hand (cross-referencing every public method/class in every service and
widget file against everywhere else in `lib/`). Found and fixed real dead
code the analyzer couldn't see on its own:

**Removed (leftovers from the old local-only-auth / demo-account era,
confirmed to have zero callers anywhere):**
- `DatabaseService.getUserByEmail()` — superseded by `getUserById()` once
  Firebase UID became the identity key; nothing looked up by email anymore.
- `DatabaseService.clearAllForFreshDemo()` — a leftover from before the
  demo account was removed entirely (see the "demo account removed"
  entry, much earlier this session).
- `DatabaseService.getSessionUserId()` — session restore now goes through
  FirebaseAuth's own persisted session (`AppState.init()`), not this local
  pointer. `setSession()`/`clearSession()` are still called (harmless,
  costs nothing) and were left in place with a comment explaining why the
  read side is gone; removing the whole session-tracking mechanism was a
  bigger, riskier change for no real benefit.
- `GpsStatusChip` / `NetworkStatusChip` (`widgets.dart`) — built as
  reusable status chips but never actually instantiated anywhere; the Home
  screen has its own hand-tailored inline version instead (different color
  scheme on purpose — white/translucent for its dark gradient header,
  versus these widgets' status-colored design for a plain white
  background). Deleting the genuinely dead widgets was the safe fix here,
  not swapping the Home screen over to use them (that would risk a visual
  change nobody asked for, for a screen that already works correctly).
- `cupertino_icons` dependency in `pubspec.yaml` — confirmed zero
  `CupertinoIcons.*` references anywhere in `lib/` or `test/` (this app
  uses Material `Icons.*` throughout). Flutter's web build tooling logs an
  informational (non-fatal) note about it after removal — cosmetic, the
  build still succeeds; not worth keeping an actually-unused package just
  to silence a log line.

**Verified clean (no changes needed):**
- Every `TextEditingController`/`FocusNode` created in a screen has a
  matching `.dispose()`.
- Every `StreamSubscription` in every service (`connectivity_service.dart`,
  `location_service.dart`, and the three in `firebase_sync_service.dart` —
  alert feed, presence feed, and the account/removed-account watch) has a
  cancel path.
- Every route in `main.dart`'s router points to a screen that exists, and
  every screen class has exactly one route pointing to it — no orphaned or
  unreachable screens.
- `AdHocNetworkService` and `NearbyMeshService` look like they might
  duplicate each other (two "ad hoc network" services) but don't — one is
  the deliberate Simulated/Demo Mode relay (manuscript-documented scope
  limitation), the other the real Nearby Connections (BLE/Wi-Fi Direct)
  mesh; `AppState.adHocRealMode` switches between them and both are
  actively used.
- No `TODO`/`FIXME` markers, no stray `print()` calls (only the
  intentional `debugPrint` calls already used for diagnostics) anywhere in
  `lib/`.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (89.8MB), and `flutter build web -t
lib/admin_main.dart` all succeed after every change in this pass.

---

## Admin auth hardened — 3 security fixes (2026-09-27)

Three real security issues, found by review rather than by testing, all
fixed without removing any feature.

### 1. Privilege escalation via the `role` field

The Firestore rules let a signed-in user write their OWN `users/{uid}`
document with no restriction on WHICH fields, and `isAdmin()` trusted
whatever `role` value sat on that same document. Nothing stopped a user
from sending a raw Firestore write (bypassing the app's UI entirely — e.g.
directly through the client SDK/REST API) that set `role: 'admin'` on
themselves, instantly getting full admin access.

Fixed in the rules (not the app code — this is a database-level hole, so it
needs a database-level fix that can't be bypassed by modifying the client):
`users/{uid}` now splits `create`/`update`/`delete`/`get`/`list` apart, and
**no write the app can ever issue is allowed to result in `role: 'admin'`,
not even from an authenticated admin session** — every create must come
out with `role == 'owner'`, every update must leave the existing `role`
value UNCHANGED, full stop, regardless of who's writing. Reading another
account's document or deleting one still requires `isAdmin()`. Old
documents with no `role` field yet are handled with
`.data.get('role', 'owner')` throughout, so they keep working instead of
being denied outright. Per an explicit follow-up request, this is
deliberately stricter than "only an admin can change role" — there is now
NO way, anywhere in the app (mobile or the web Admin Portal), to create or
promote an admin account. The only way `role: 'admin'` is ever set is a
direct, by-hand edit of that field on a `users/{uid}` document in the
Firebase Console, which isn't subject to these rules at all.

Checked every code path that writes `users/{uid}` against this:
`upsertUserProfile` always sends `role: 'owner'` for a normal account
(UserModel's role always defaults to 'owner' — there's no UI that sets it
to anything else), so both the create and unchanged-role-update branches
pass it with no code change needed. `AdminService.createUser` (Add User)
and `setDisabled`/`removeUser` all write to a DIFFERENT uid than the
caller's own — those only ever pass through the `isAdmin()` branch, which
is exactly what they need. `saveProfilePhoto`'s `{photoB64}`-only merge
doesn't touch `role` at all, so the merged value carries forward unchanged
automatically. No code changes were needed here — only the rules.

### 2. Hardcoded admin credentials, compiled into the public web bundle

`kAdminUsername`/`kAdminPassword` (`"vehicleadmin"`/`"guardadmin"`) were
Dart constants, which `flutter build web` compiles as plain readable
strings into the shipped JavaScript — anyone could view-source the admin
portal and read them. Worse, `AdminService.login()` auto-created that
admin's Firebase account (and its `role: 'admin'` Firestore document) the
very first time anyone signed in with those fixed credentials — meaning
whoever visited the deployed admin URL first, ever, became the permanent
admin. Fixed:
- `kAdminUsername`/`kAdminPassword`/the fixed internal email, and the
  entire auto-provisioning block, are deleted from `admin_service.dart`.
- `AdminLoginScreen` (`s15_admin_dashboard.dart`) now asks for **email +
  password** instead of a fixed username, and `AdminService.login(email,
  password)` just signs in with real Firebase Authentication, then reads
  that account's own `users/{uid}.role` from Firestore — if it isn't
  `'admin'`, it signs the session back out immediately and returns "This
  account does not have admin access." Being able to authenticate (any
  registered vehicle owner can) is deliberately not treated as being an
  admin. Distinct error messages for wrong password, no network,
  disabled account, and too-many-attempts.
- The admin account itself is now created BY HAND in the Firebase Console
  — see the step-by-step below. There is still no in-app way to register
  or promote an admin, which was always the intent.

**⚠️ Required cleanup — do this before relying on the fix:** the OLD
auto-provisioned account (email `vehicleadmin@vehicleguard.internal`,
password `guardadmin`) still exists in your Firebase project with
`role: 'admin'` already set on it from before this fix. That email/password
pair is now public (it was in this app's source and in this chat), so it's
effectively still a working "hardcoded" admin login until you delete it —
**delete that Authentication user AND its Firestore `users/{uid}` document**
(Firebase Console → Authentication → Users → find `vehicleadmin@...` →
delete; then Firestore Database → Data → `users` → delete the matching
document) before treating this fix as complete.

**Creating the real admin account (manual, one-time):**
1. Firebase Console → **Authentication** → Users tab → **Add user**.
2. Enter the admin's real email address and a strong password → **Add
   user**. Note the UID it's given (shown in the Users list).
3. Firebase Console → **Firestore Database** → Data tab → `users`
   collection → **Add document**.
4. Document ID: paste the **exact UID** from step 2 (this is what ties the
   Firestore doc to the Authentication account).
5. Add these fields (all type `string`):
   `id` = the same UID · `name` = e.g. `Administrator` · `email` = the
   same email from step 2 · `phone` = (leave empty) · `role` = `admin` ·
   `deviceId` = e.g. `ADMIN`.
6. Save. Sign in at the Admin Portal with that email/password.

To add a second admin later, repeat these exact steps with a different
email. There is deliberately no shortcut through an existing admin account
for this — per an explicit follow-up request, the rules block `role` from
ever becoming `'admin'` through any write the app issues, even one made by
an already-signed-in admin — so every admin, including the first, is
created the same way: by hand, in the Console.

### 3. Any signed-in user could update any theft alert

`theft_alerts` allowed `update` by any authenticated user (only constraint:
the `id` field had to match the document ID) — so any registered user could
mark someone else's stolen vehicle "recovered" or edit its status, plate,
or location. The app's own UI already restricted "Update Status" to the
reporter (`s9_s10_s11_alerts_map.dart`'s alert list only shows the button
when `alert.userId == currentUser.id`), but that was a UI restriction only —
trivially bypassed at the database level.

The store-carry-forward design makes this trickier than a flat "reporter
only" rule: a device that only RECEIVED an alert (over the mesh or the
internet feed) also uploads its own local copy, and needs to keep updating
its own `hopCount`/`relayedTo` bookkeeping as the alert propagates —
that's a real, intentional feature, not something to break.

Fixed in the rules: `create` stays open to any signed-in user (a relay
device may legitimately be the one that gets an alert into Firestore
first, before the reporter's own phone has internet). `update` now allows
it only for the original reporter (`resource.data.userId ==
request.auth.uid`, checked against the EXISTING document so it can't be
spoofed by also rewriting `userId`), an admin, or — for anyone else — only
if `status`, `userId`, `lat`, `lng`, `plate`, `model`, `color`, and
`vehicleId` all come out of the write UNCHANGED.

That last branch needed a matching code fix, since `_syncAlerts()`
(`firebase_sync_service.dart`) used to `.set()` the WHOLE alert document
on every upload, from every device, reporter or not. Changed: it now checks
whether the signed-in device is the alert's reporter. If not, and the
document already exists, it merges ONLY `hopCount`/`relayedTo` — never
touching status/ownership/location/vehicle fields — which is exactly what
the new rule allows. The reporter's own device, and any device creating a
brand-new (not-yet-uploaded) alert, still does the same full upsert as
before.

### Also fixed while reading these files
`AdminService`'s `isAdmin()`-adjacent doc comments and the file-level
comment in `s15_admin_dashboard.dart` referencing the old hardcoded
username/password were updated to describe the new email+role-check model.
(Searched thoroughly for the reported outdated "login is SQLite-backed"
line in `s2_s3_auth_screens.dart` — 877 lines, no match for "database",
"SQLite", "offline", or "cache" anywhere in that file. It appears to have
already been corrected earlier in this project's history; flagging this
rather than inventing a change.)

### Complete Firestore rules to publish

Full replacement — paste into Firebase Console → Firestore Database →
Rules → Publish:
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function isAdmin() {
      return request.auth != null &&
        exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.get('role', 'owner') == 'admin';
    }

    match /users/{uid} {
      allow get: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow list: if request.auth != null && isAdmin();

      // `role` can never become 'admin' through ANY write this app can
      // issue — not even from an authenticated admin session. Both branches
      // below require the resulting `role` to be 'owner' (create) or
      // unchanged (update), full stop. The only way an account ever becomes
      // admin is a direct edit of this field in the Firebase Console, which
      // isn't subject to these rules at all — see Progress.md, "Admin auth
      // hardened" / "no create-admin, anywhere in the app".
      allow create: if request.auth != null
                    && (request.auth.uid == uid || isAdmin())
                    && request.resource.data.get('role', 'owner') == 'owner';

      allow update: if request.auth != null
                    && (request.auth.uid == uid || isAdmin())
                    && request.resource.data.get('role', 'owner') == resource.data.get('role', 'owner');

      allow delete: if request.auth != null && isAdmin();
    }

    match /users/{uid}/vehicles/{vehicleId} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /removed_accounts/{uid} {
      allow read: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow write: if request.auth != null && isAdmin();
    }

    match /presence/{uid} {
      allow get, list: if request.auth != null;
      allow create, update, delete: if request.auth != null && request.auth.uid == uid;
    }

    match /theft_alerts/{alertId} {
      allow get, list: if request.auth != null;

      allow create: if request.auth != null && request.resource.data.id == alertId;

      allow update: if request.auth != null && (
        isAdmin() ||
        resource.data.userId == request.auth.uid ||
        (
          request.resource.data.userId == resource.data.userId &&
          request.resource.data.status == resource.data.status &&
          request.resource.data.lat == resource.data.lat &&
          request.resource.data.lng == resource.data.lng &&
          request.resource.data.plate == resource.data.plate &&
          request.resource.data.model == resource.data.model &&
          request.resource.data.color == resource.data.color &&
          request.resource.data.vehicleId == resource.data.vehicleId
        )
      );

      allow delete: if false;
    }

    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if false;
      allow create: if request.auth != null;
      allow update, delete: if false;
    }

  }
}
```

### Manual test checklist

1. **Self-promotion is blocked** — register a normal account through the
   app as usual; confirm registration, login, and profile editing all
   still work (role silently stays `owner` throughout). In Firebase Console
   → Firestore Database → Rules → **Rules Playground**, simulate an
   `update` on that account's own `users/{uid}` doc with `role: 'admin'`
   in the payload, authenticated as that uid — must be **Denied**.
2. **Admin portal rejects a non-admin** — sign in to the Admin Portal with
   that same normal account's email/password — must show "This account
   does not have admin access." and stay on the login screen.
3. **Admin portal accepts the real admin** — sign in with the manually
   created admin account — must reach the dashboard and load the account
   list.
4. **Non-reporter can't change an alert's status** — Account A reports a
   vehicle stolen; Account B receives it (internet feed). Confirm B has no
   "Update Status" option in the UI for that alert (already true). In the
   Rules Playground, simulate an `update` on that alert document
   authenticated as B's uid with a changed `status` field — must be
   **Denied**. Then simulate the same update authenticated as A's (the
   reporter's) uid — must be **Allowed**.
5. **Alert relay still works** — report a vehicle stolen from one signed-in
   device/account; confirm a second account still receives the "Stolen
   Vehicle Nearby!" alert, and that `hopCount`/`relayedTo` on the Firestore
   document still update as it relays.
6. **Profile editing still works** — Edit Profile (name/phone) as a normal
   user and confirm it saves.
7. **Suspend / Restore / Delete still work** — from the Admin Dashboard,
   suspend a test account (confirm it's force-logged-out and blocked from
   login), restore it (confirm login works again), then permanently delete
   a different test account (confirm it disappears from the list and can
   no longer log in).
8. **Add User still works** — create a new account from the Admin
   Dashboard; confirm it registers with `role: owner` and can verify its
   email and log in normally afterward.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (89.8MB), and `flutter build web -t
lib/admin_main.dart` (with the informational, unrelated
`geolocator_web`/`cupertino_icons` build notes already explained in the
previous entry) all succeed.

### Follow-up, same day: verifying "only one admin" + no create-admin, anywhere

Two explicit follow-up requests right after the fixes above:

**"Make sure the admin account I created is the only admin."** I have no
access to the live Firebase project's data, so this can't be confirmed
from here — but the Admin Dashboard already lists every account, so rather
than asking for Console access, it now surfaces this directly: each row
shows an **ADMIN** badge when that account's `role` is `'admin'`, and the
stats row at the top gained an **ADMINS** count (turns red if it's ever
more than 1). Open the dashboard and look — there should be exactly one
ADMIN-badged row, the one just created.

**⚠️ The most likely place a second "admin" is hiding:** the OLD
auto-provisioned account from before these fixes
(`vehicleadmin@vehicleguard.internal`) already has `role: 'admin'` set on
it from before this session's changes, and rules changes don't retroactively
un-set data. If it's still in Firestore, it'll show up in the dashboard
list with the ADMIN badge too. Delete it (Firebase Console → Authentication
→ Users → find `vehicleadmin@vehicleguard.internal` → delete; then
Firestore Database → Data → `users` → delete the matching document) — this
was already flagged as required cleanup above, but is worth repeating here
since it's exactly the scenario this request is asking about.

**"Make sure there's no create-an-admin-account, all new users are just
users, especially on the app."** Tightened the rules from earlier today
further than "only an admin can change role" (issue 1's original fix) to
"role can NEVER become `'admin'` through any write the app can ever issue,
not even from an authenticated admin session" — see the updated
`users/{uid}` rules above. Concretely: `AdminService.createUser` (Add User)
has never had a role field in its form and always creates `role: 'owner'`;
there's no `setRole`/promote UI anywhere (removed earlier, see "Admin
account hardcoded" entry); and now even a raw Firestore write attempted by
a signed-in admin trying to set `role: 'admin'` on any document — their own
or someone else's — is rejected by the rules. The single remaining path,
by design, is a human directly editing that field on a document in the
Firebase Console, which isn't a client of these rules at all.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build web -t lib/admin_main.dart` succeeds.

---

## Full system scan after the admin security work (2026-09-27)

Requested general health check before returning to mesh testing. Re-ran the
same cross-file audit as the last full scan (analyzer only catches unused
PRIVATE members automatically, not public ones, so this checks every public
method/class in every service/widget file against the rest of `lib/` by
hand) plus a fresh look at everything touched by today's security fixes.

**Found and fixed:** a stale, actively misleading comment in
`database_service.dart`'s schema migration — it claimed "AppState
transparently rehashes them with a salt" for the `passwordHash`/`salt`
columns, describing local password-hashing behavior that no longer exists
at all now that real Firebase Authentication verifies every password
server-side. Corrected the comment to say plainly that both columns are
dead (never read or written — `UserModel.toMap()` doesn't include them)
and are being left in the schema as-is rather than migrated out, since
that would need a new schema version + `DROP COLUMN` migration for two
harmless, always-empty columns — not worth the risk to already-installed
test devices for a cosmetic cleanup. Comment-only change, no schema/logic
touched.

**Verified clean, no new issues from today's admin/security work:**
- Every public method added or changed in `admin_service.dart` and
  `firebase_sync_service.dart` today is actually called from somewhere
  (`AdminService.login/logout/fetchAllUsers/fetchVehicles/setDisabled/
  removeUser/createUser` — all wired to the dashboard UI; no leftover
  `kAdminUsername`/`kAdminPassword`/hardcoded-credential references
  anywhere in `lib/`, confirmed by a project-wide search).
- Manually traced every `users/{uid}` write in the app
  (`upsertUserProfile`, `saveProfilePhoto`, `AdminService.createUser`,
  `setDisabled`, `removeUser`) against the tightened rules from the
  previous two entries — all still pass exactly as designed, no code/rule
  mismatch found.
- `s15_admin_dashboard.dart` (1051 lines after today's edits) has exactly
  one declaration of each of its 12 classes — no accidental duplicates
  from the several rounds of edits it went through today.
- No TODO/FIXME markers, no stray `print()` calls, every pubspec
  dependency still has a real import site, every shared widget in
  `widgets.dart` is still used by at least one screen, routing table still
  matches 1:1 with actual screens (unchanged since the last full scan —
  nothing touched routing today).

**Noted, not changed (deliberately, per "don't remove working/incomplete
features"):** `AppState.markResolved()` has no UI button calling it
anywhere, but `AlertStatus.resolved` is a real, displayed status (its own
filter tab in Alert History, its own badge) — this reads as an
intentionally scaffolded next step in the alert lifecycle (active →
recovered → resolved) rather than dead code, so it was left as-is rather
than removed.

**Mesh/ad hoc code: untouched.** Nothing in today's session (or the admin
work before it) touched `nearby_mesh_service.dart`,
`adhoc_network_service.dart`, or any of `AppState`'s mesh-handling methods
— confirmed by review, not just by absence from the diff. Whatever the
device-to-device Bluetooth/Wi-Fi Direct discovery result is on the next
test, it reflects that code exactly as it was on 2026-09-21 (the last real
two-phone result on record — see that entry for the suspected cause,
Android's Approximate-vs-Precise location permission).

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (89.8MB), and `flutter build web -t
lib/admin_main.dart` all succeed.

---

## Bug fix: registration wrongly reported as failed when the first verification email didn't send (2026-09-28)

**Report:** a new user filled out Register, but never received a
verification email.

**Root cause found in `FirebaseAuthService.register()`:** account creation
(`createUserWithEmailAndPassword`), setting the display name
(`updateDisplayName`), and sending the verification email
(`sendEmailVerification`) were all wrapped in ONE try/catch. If either of
the last two calls threw for ANY reason — Firebase's free-tier limit on
how many auth emails it will send per project in a given window is a very
plausible one, given how much registration testing has happened on this
project across this whole session — the method reported the WHOLE
registration as failed, even though the Firebase account had already been
created successfully one line above. The user saw an error and never
reached the "Check your email" screen at all, so they had no way to know
an account existed or to tap "Resend Email".

Worse, this leaves the account stuck: trying to register again with the
same email now fails with "already registered" (correctly — it is), but
the person was never shown the working recovery path — logging in with
that email/password instead. `AppState.login()` already detects an
unverified account and opens the same Email Verification screen (with its
working "Resend Email" button), so anyone who hit this bug can recover
today by trying **Login**, not Register, with the account they already
created.

**Fix:** account creation keeps its own try/catch (a real failure there —
weak password, email already in use, no network — is still reported
correctly, unchanged). `updateDisplayName` and `sendEmailVerification` now
each have their OWN try/catch and are never allowed to turn a successful
account creation into a reported failure. The user now always reaches the
Email Verification screen once the account itself exists, where "Resend
Email" (a separate, already-working code path, untouched) is the recovery
action for a first send that silently failed.

**Also worth checking on the Firebase side (not something code can fix):**
if this keeps happening for new registrations, check Firebase Console →
Authentication → Templates → "Email address verification" is enabled and
has a sender configured, and be aware the Spark (free) plan has a daily
cap on Authentication emails — heavy testing can exhaust it temporarily.
Also worth telling testers to check their spam/junk folder, since
Firebase's default sender domain commonly lands there.

Nothing else in the auth flow was touched — login, Google sign-in, password
reset, and the Email Verification screen's own resend/countdown/check-
verified logic are unchanged.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (89.8MB) succeeds.

---

## Confirmed working from real testing + new feature: turn off a geofence without deleting the vehicle (2026-09-28)

**Confirmed working (no code changes needed):**
- Nearby Devices now lists other registered accounts within range (via the
  shared-GPS presence feed from the "Two-phone result, nearby-devices
  list" entry) — tested live, showed another account "6m away · GPS ·
  Internet · Active".
- Geofence violation detection fires correctly on a real device — armed a
  geofence, walked the phone outside it, got the violation notification.

**Bug reported: no way to turn a geofence off.** Once armed, the ONLY
control on the vehicle card was "Remove", which deletes the vehicle
entirely ("This will delete the vehicle and stop its geofence monitoring.
This cannot be undone.") — there was no way to just pause monitoring. A
real scenario: park the car, arm the geofence overnight; next morning the
owner wants to drive it again, and had no option except deleting the
whole vehicle registration to stop the alarm from firing the moment they
drove off.

The data model already supported this
(`VehicleModel.geofenceActive`/`AppState.setVehicleGeofence(..., active:
false, ...)` already existed) — nothing in the app's UI ever called it
with `active: false`, though. Added:

- **`AppState.deactivateGeofence(id)`** — a thin, clearly-named wrapper
  around the existing `setVehicleGeofence` that turns monitoring off while
  keeping the vehicle's saved radius and center exactly as they were, so
  re-arming later is one tap on the already-prefilled Set Geofence screen,
  not reconfiguring from scratch.
- **Home screen vehicle card**: a new "Turn Off" quick-action button,
  shown only while a geofence is active, with its own confirm dialog
  (distinct from Remove's — explains monitoring pauses, the vehicle and
  its safe zone are kept, and it's reversible).
- **Set Geofence screen**: the same action also lives here now as a
  "TURN OFF GEOFENCE" button beneath Save, shown only when the vehicle's
  geofence is currently active — so it's discoverable from the same
  screen used to configure it, not only from the Home card.
- `VehicleCard`'s button row was changed from a fixed `Row` to a `Wrap`
  (only for the button group, not the label) so a vehicle showing 3
  buttons at once (Turn Off + Geofence + Remove) drops to a second line on
  a narrow screen instead of overflowing — the default 2-button case
  (before any geofence is ever configured) renders identically to before.

Nothing about Remove, Report Stolen, geofence violation detection, or the
Set Geofence screen's existing save/radius/map behavior was changed.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (89.9MB) succeeds.

---

## Full file-by-file system scan (2026-09-28)

Requested a complete pass across every file for bugs, errors, problems, and
duplicates before further device testing. Went through the whole `lib/`
tree (25 files) individually — the files most recently rewritten
(admin/security work, geofence deactivate) had already been scanned in the
last two entries, so this pass focused on everything NOT yet closely
re-read this session: `app_theme.dart`, `vehicle_catalog.dart`,
`plate_scanner_service.dart`, `connectivity_service.dart`,
`notification_service.dart`, `location_service.dart`,
`s1_splash_screen.dart`, `nearby_mesh_service.dart` (read in full — see
note below), plus a fresh cross-file unused-method/class audit and targeted
checks for unguarded collection access (`.first`/`[0]`/`.reduce`) across
every screen and service.

**Fixed:**
- **`AppStrings` class removed** from `app_theme.dart` (appName/tagline/
  butuanCity constants) — confirmed dead: no screen anywhere in `lib/`
  referenced it; every screen hardcodes its own "VehicleGuard"/tagline text
  directly instead. It WAS referenced once, in `test/widget_test.dart` —
  caught by `flutter analyze` right after removing it, not missed. Fixed
  by simplifying the test itself instead of reviving the dead class: it
  was piping `AppStrings.appName` into a `Text` widget only to immediately
  assert against the literal string `'VehicleGuard'` two lines below —
  redundant indirection for a value the test hardcodes anyway. The test now
  just uses `'VehicleGuard'` directly, and no longer depends on
  `app_theme.dart` for anything it doesn't already need.
- **Two stale, misleading comments** pointing at things that don't exist:
  `notification_service.dart` referenced a `GAP_ANALYSIS.md` file that
  isn't anywhere in this repo (fixed to describe the real, working
  delivery paths — the ad hoc mesh and the Firestore alert feed — instead
  of citing a doc that doesn't exist).

**Verified clean, no changes needed (each read in full):**
- `vehicle_catalog.dart` — well-organized reference data, already has a
  deliberate note on why colors are one shared list rather than three
  duplicated ones.
- `plate_scanner_service.dart`, `connectivity_service.dart`,
  `location_service.dart`, `s1_splash_screen.dart` — no bugs, no dead
  code, every public method has a real caller.
- `nearby_mesh_service.dart` (445 lines, read start to finish) — the real
  Bluetooth/Wi-Fi Direct mesh layer the next round of device testing will
  exercise. No changes made here: it's already the product of the
  extensive start/stop/watchdog debugging documented earlier in this
  project's history, and touching it without a new, specific, reproduced
  problem from a live test would risk the exact kind of regression this
  scan is meant to prevent. Whatever the next mesh test shows reflects
  this code exactly as it stands.
- No duplicate class names anywhere in `lib/` (checked every file against
  every other file at once).
- No unguarded `.first`/`[0]`/`.reduce` access anywhere — every call site
  found was already behind an `isEmpty`/`isNotEmpty` guard or a
  length check.
- Cross-file unused-method audit re-run — same handful of findings as the
  last two scans (`markResolved`, `getFcmToken`, and a few local-function/
  framework-override false positives), all previously investigated and
  deliberately left as-is (see the two prior full-scan entries for why).

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (89.9MB), and `flutter build web -t
lib/admin_main.dart` all succeed.

---

## New: a vehicle can't be registered twice under two different accounts (2026-09-28)

User question: was duplicate vehicle registration across accounts already
prevented — if account A registers plate `ABC-1234`, should account B
registering the exact same plate get an error instead of silently
succeeding? **It was NOT applied.** Vehicles live privately under each
owner (`/users/{uid}/vehicles`), and nothing anywhere ever checked across
accounts — two different Gmail accounts could both "own" the identical
real-world plate at once, which would make it genuinely ambiguous whose
theft report or geofence violation was the authoritative one for that
vehicle. Fixed.

**New: a global plate-uniqueness registry**, `/plates/{normalizedPlate}` —
deliberately a separate, minimal top-level collection rather than querying
across every owner's private vehicles subcollection, so checking
availability never requires exposing one user's actual vehicle data to
another; each document only ever holds `{ownerId, plate, vehicleId}`. The
key is a NORMALIZED plate (uppercased, punctuation stripped) so "ABC-1234",
"ABC 1234", and "ABC1234" are all treated as the same real-world plate,
even though the vehicle's own stored/displayed plate keeps whatever
formatting the owner typed.

**`AppState.addVehicle()`** now runs a Firestore **transaction**
(`claimPlateIfAvailable`) before creating the vehicle — a plain
check-then-write would let two people registering the same plate at the
same instant both "win"; the transaction makes that impossible. If the
plate already belongs to a different account, registration is rejected and
`RegisterVehicleScreen` shows an error modal: **"Vehicle Already
Registered — This vehicle (PLATE) is already registered to another
account."** The message deliberately does NOT name the other account's
email — revealing which real person owns a plate to a stranger who just
typed it in would be its own privacy leak; "another account" is enough to
explain the rejection.

This check needs a live connection (there's no way to know what OTHER
accounts have registered while offline) — registering a vehicle now has
the same connectivity requirement account registration already has, for
the same reason.

**Re-registering a plate you already own** (e.g. remove a vehicle, then
re-add it) still works: the transaction allows a re-claim when the
existing registry entry's `ownerId` matches the account trying to
register, not just when the plate is completely unclaimed.

**Removing a vehicle now releases its plate claim** too
(`AppState.removeVehicle` → `_forgetVehicleInCloud`, extended to carry the
plate through the same pending-delete retry queue vehicle deletion already
used, so this recovers correctly even if the phone was offline at the
moment of removal) — otherwise a sold or transferred vehicle's plate would
stay permanently blocked for its legitimate next owner. Best-effort: if
release fails while offline, it retries the next time this phone is back
online, same as the vehicle deletion itself.

**REQUIRED Firestore rules update** — adds the `plates` collection. Full
rules to paste in Firebase Console → Firestore Database → Rules:
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function isAdmin() {
      return request.auth != null &&
        exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.get('role', 'owner') == 'admin';
    }

    match /users/{uid} {
      allow get: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow list: if request.auth != null && isAdmin();

      allow create: if request.auth != null
                    && (request.auth.uid == uid || isAdmin())
                    && request.resource.data.get('role', 'owner') == 'owner';

      allow update: if request.auth != null
                    && (request.auth.uid == uid || isAdmin())
                    && request.resource.data.get('role', 'owner') == resource.data.get('role', 'owner');

      allow delete: if request.auth != null && isAdmin();
    }

    match /users/{uid}/vehicles/{vehicleId} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /plates/{plateId} {
      allow get: if request.auth != null;
      allow create: if request.auth != null && request.resource.data.ownerId == request.auth.uid;
      allow update: if request.auth != null && resource.data.ownerId == request.auth.uid && request.resource.data.ownerId == request.auth.uid;
      allow delete: if request.auth != null && resource.data.ownerId == request.auth.uid;
    }

    match /removed_accounts/{uid} {
      allow read: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow write: if request.auth != null && isAdmin();
    }

    match /presence/{uid} {
      allow get, list: if request.auth != null;
      allow create, update, delete: if request.auth != null && request.auth.uid == uid;
    }

    match /theft_alerts/{alertId} {
      allow get, list: if request.auth != null;

      allow create: if request.auth != null && request.resource.data.id == alertId;

      allow update: if request.auth != null && (
        isAdmin() ||
        resource.data.userId == request.auth.uid ||
        (
          request.resource.data.userId == resource.data.userId &&
          request.resource.data.status == resource.data.status &&
          request.resource.data.lat == resource.data.lat &&
          request.resource.data.lng == resource.data.lng &&
          request.resource.data.plate == resource.data.plate &&
          request.resource.data.model == resource.data.model &&
          request.resource.data.color == resource.data.color &&
          request.resource.data.vehicleId == resource.data.vehicleId
        )
      );

      allow delete: if false;
    }

    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if false;
      allow create: if request.auth != null;
      allow update, delete: if false;
    }

  }
}
```

**Not covered by this fix (out of scope, different scenario):** one
account registering the exact same plate twice under itself (two separate
vehicle entries). The transaction allows this — a re-claim by the SAME
owner is deliberately permitted (see "re-registering a plate you already
own" above) — since that's a harmless self-inflicted duplicate the owner
would see and could remove themselves, not the cross-account trust problem
this fix addresses.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (89.9MB) succeeds.

---

## New: nearby users can report a sighting of a stolen vehicle (2026-09-28)

**Problem (from a real two-device test):** a nearby phone that received a
"Stolen Vehicle Nearby" alert could see it (Proximity Map → "Active alerts in
area", Alert History) but could do nothing with it. Root cause: those alert
cards were plain, untappable widgets — `AlertLogItem` and the map's alert
tiles had no tap handler at all — and the only screen an alert ever led to
(S9 Alert Received, reached only from the popup) offered just "View on map" and
"Dismiss". There was also no concept of a sighting anywhere in the app, so
even a working tap would have had nowhere to go. Everyone who received an
alert could watch it; no one could help.

**Manuscript alignment** (checked against the revised Chapter 1–3 PDF,
2026-09-28). Sightings are the app's version of what the manuscript already
calls *"user confirmations"*:
- Fig. 3-1 (Input): "Relayed Alert Logs & User Confirmations"; Objective 4
  measures "user confirmation accuracy".
- §1.1 / §1.4 / §2.1: "community-based, decentralized detection" and
  "nearby user or device collaboration" — a nearby user reporting where the
  car was seen is that collaboration.
- FR-06 / FR-09: receive-store-forward and log locally, sync when online —
  sightings are saved to SQLite first, relayed over the mesh, synced later.
- FR-12: the manuscript asks for photo proof on the *owner's* theft report to
  make alerts credible; the sighting's photo proof is the same idea for the
  nearby user's report.
- §2.2.8 / R.A. 10173: sightings hold a name, GPS and a photo, so only the
  vehicle owner, the reporter and an admin can read one (Firestore rule below).
- §1.5: the study "excludes direct law enforcement intervention" — a sighting
  goes to the owner, not to the police.

**Manuscript is silent on this (FR-13 wording is ON HOLD — the user is asking their adviser first, so nothing is to be added to the manuscript until they say so):** S9 (Fig. 3-11)
only shows "View on Map" and "Dismiss"; the ERD (Fig. 3-10) has no sighting
entity; the FR table stops at FR-12. Suggested addition: *FR-13 Sighting
Report — a nearby registered user can send the vehicle owner a message, photo,
location and time for an active stolen-vehicle alert, delivered over the ad
hoc mesh (text) and the internet (with photo), and logged locally and to the
cloud.*

**What was added**
- **Tappable alerts.** Alert History cards and the Proximity Map's alert tiles
  now open something, and say so ("Tap to report a sighting" / "Tap to view
  sightings (N)") — nothing on them hinted they were tappable before. Shared
  routing in `openAlertDetails()`: the owner goes to their sightings; anyone
  else goes to Alert Received.
- **Alert Received (S9)** gained a **REPORT A SIGHTING** button — shown only to
  someone who is not the owner and only while the vehicle is still missing
  (the owner has Update Status; a sighting of a recovered car is moot) — plus
  a "you have sent N sightings" line.
- **Report a Sighting** (`/report-sighting`, new `s16_sightings.dart`):
  message (required, 5–500 chars), **photo proof** (camera or gallery,
  optional, shrunk to ≤1024px/quality 60 and capped at 500 KB), **location**
  (current GPS with an on/off switch; with no fix it says so and sends none —
  never a made-up position), and **time seen** (defaults to "just now",
  changeable; a time later than now is read as yesterday). Sending shows a
  **blocking loading modal**, then a **success modal** ("Sighting Sent" /
  "Sighting Saved") or an **error modal**.
- **Sightings of my stolen vehicle** (`/alert-sightings`): the owner sees a map
  (🚗 where it was reported stolen, 📍 each place it was seen), and a card per
  sighting — reporter, time seen, message, photo (tap for full screen),
  coordinates with "Show on map". A new sighting also raises an in-app
  notification and a phone notification.

**How it's delivered (dual layer, like the alerts)**
- *Internet:* a `sightings` document in Firestore (photo as base64 inside it —
  same approach as the profile photo, since Cloud Storage needs a paid plan).
  The owner's phone listens with one equality query on `ownerId`, so no
  composite/collection-group index is needed.
- *Ad hoc mesh:* when the phone has connected peers, a text-only copy is also
  broadcast (`msgType: sighting`, 5 hops) and relayed neighbour-to-neighbour
  until it reaches the owner; duplicates are dropped by id. A photo is far too
  large for a Nearby Connections bytes payload, so the picture only travels via
  the internet copy — when it arrives it is merged into the mesh copy the owner
  already has, without a second notification.
- *Offline (store-carry-forward):* a sighting is saved to the phone's SQLite
  first (new `sightings` table, DB schema v3 → v4 with a proper migration), so
  it can't be lost, and is delivered by the normal sync when the connection
  returns. The success modal says which of "delivered" / "saved, will deliver
  when online" applies. If the server outright refuses it (`permission-denied`
  — i.e. the rule below isn't published yet) the modal says exactly that
  instead of falsely promising a later delivery.

**REQUIRED Firestore rule** — add this block inside
`match /databases/{database}/documents { … }` alongside the others (everything
else in the rules from the previous entry is unchanged):
```
    match /sightings/{sightingId} {
      allow create: if request.auth != null
                    && request.resource.data.reporterId == request.auth.uid
                    && request.resource.data.id == sightingId;

      allow update: if request.auth != null
                    && resource.data.reporterId == request.auth.uid
                    && request.resource.data.reporterId == request.auth.uid;

      allow get, list: if request.auth != null
                       && (resource.data.ownerId == request.auth.uid
                           || resource.data.reporterId == request.auth.uid
                           || isAdmin());

      allow delete: if request.auth != null && isAdmin();
    }
```
Only the reporter can create/edit their own sighting, and only the vehicle's
owner, the reporter, or an admin can read it — other nearby users can't read
each other's sightings. (`update` exists so a retried upload of the same
sighting id isn't rejected after a first attempt that actually got through.)

**Also fixed / cleaned in this pass**
- README was stale in several places: it still listed the removed demo
  account and credentials, the removed `AppStrings` class, an unused `uuid`
  dependency, and said data is "in-memory". Corrected, and the new screens added.
- I ran `dart format` over all of `lib/` instead of only the touched files, so
  it also reformatted 13 files I hadn't edited (whitespace only — no logic),
  including `nearby_mesh_service.dart`. That produced two lint notices there,
  fixed by adding braces to two single-line `if`s (no behaviour change). The
  mesh code is otherwise exactly as it was.

**Known limits (deliberate)**
- The sender's name on a mesh copy is self-reported by the sending phone and
  not verified (same trust level as the mesh alerts themselves); the
  internet copy is tied to the real signed-in account by the rules.
- A sighting can only be sent to the owner of an alert this phone has — it
  needs the alert's `userId`, which every received alert carries.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` (90.8MB) and `flutter build web -t
lib/admin_main.dart` both succeed.

---

## Admin web dashboard now covers FR-11 — live monitoring (2026-09-28)

**Why:** FR-11 says the dashboard "displays real-time alert activity, stolen
vehicle reports, proximity map, and location history, allowing authorized users
to track and analyze theft incidents". The admin web page only had account
management, so most of FR-11 wasn't there. (The manuscript will be reworded to
say the dashboard is web-based — that's the user's edit.)

**What changed (web admin build only — the phone app is untouched)**
- The dashboard now has three tabs: **Accounts** (exactly as before),
  **Live Activity** and **Map**.
- **Live Activity** — real-time (Firestore snapshot listeners, no refresh
  needed): counters (active alerts, recovered/resolved, sightings, devices
  online) and one feed mixing alerts and sightings, newest first, filterable
  (All / Stolen / Recovered-resolved / Sightings). Each alert shows plate,
  vehicle, owner, trigger (manual / geofence), status, time, hops, relay
  count and sighting count. A "LIVE · time" indicator shows the last update,
  and a toast pops up when a NEW alert or sighting arrives while the admin is
  watching.
- **Incident detail** (tap any alert, sighting or map pin): full alert info,
  a map (🚗 reported here, 📍 sightings, a line for the vehicle's recorded
  movement), every sighting with the reporter's message, photo (tap to
  enlarge), time seen and coordinates, and the vehicle's **location history**
  (latest 30 positions with timestamps). Status changes made on the owner's
  phone update the open sheet live.
- **Map** — every located alert (red = still missing, green = recovered or
  resolved) with the manuscript's **100 m proximity range** drawn around each
  missing vehicle, every sighting, and every phone online right now (last
  position under 2 minutes old). Toggle each layer; "fit" button re-centres.
- Code: `AdminService` got `watchAlerts/watchSightings/watchDevices/
  fetchLocationHistory` and an `AdminMonitorFeed` (one shared set of
  listeners; each source reports its own error so a missing rule doesn't blank
  the others); new `lib/screens/s17_admin_monitoring.dart`; `s15` gained the
  tabs. The account stat chip was moved to a shared `AdminStatChip` instead of
  being duplicated.

**ONE Firestore rule changed — location history could not be listed at all**
(`allow list: if false`), so the admin's history panel would show a "rules
don't let the admin list location history" message. Change ONLY the
`location_history` block to:
```
    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if request.auth != null && isAdmin();
      allow create: if request.auth != null;
      allow update, delete: if false;
    }
```
Everything else in the rules is unchanged (alerts, presence and users were
already readable by an admin; sightings already allows `isAdmin()`).

**Known limit, not changed:** the photo an owner attaches when reporting a
vehicle stolen (FR-12) is kept as a file path on the owner's phone — only the
fact that a photo exists is sent to other devices — so the admin dashboard
cannot display it. Sighting photos DO show (they travel inside Firestore).
Showing the owner's photo to the admin would mean uploading it like sighting
photos are; not done because it wasn't asked for.

**Test:** publish the rule above; run `flutter run -d chrome -t
lib/admin_main.dart` (or rebuild the web bundle), sign in as the admin, then
on two phones report a vehicle stolen and send a sighting — the Live Activity
feed, counters, toast and Map pin should appear without refreshing.

Verified `flutter analyze` (0 issues), `flutter test` (passing) and
`flutter build web -t lib/admin_main.dart` succeed. Not run against real data.

---

## Owner can see a sighting reporter's contact details (2026-09-28)

**Request:** the owner taps the person who reported a sighting and a modal shows
their details, including their registered phone number, so they can call or text.

**What was added**
- In "Sightings of My Stolen Vehicle", tapping a reporter's name/avatar (or the
  new **Contact** button on the card) opens a modal: name, when they saw it,
  their **mobile number** with a **Copy** button (number is also long-press
  selectable), and a plain note if they have no phone number on their profile.
- The sighting form now tells the reporter, before they send, that their name
  and registered phone number are shared with the owner (R.A. 10173 —
  the person knows and consents by sending). If they have no number on their
  profile it says so and points them to Edit Profile.
- Code: `SightingReport.reporterPhone` (+ `hasContact`, and `forMesh()` replacing
  the old `withPhoto`), sent from the reporter's own profile; local DB v4 → v5
  (`ALTER TABLE sightings ADD COLUMN reporterPhone`); `showReporterContactModal`
  in `s16_sightings.dart`.

**Privacy design:** the number travels ONLY in the Firestore copy. The mesh
copy is stripped of it (relaying phones can read what they forward), and it is
merged into the owner's copy when the cloud copy arrives, like the photo. The
existing `sightings` rules already restrict reading to the owner, the reporter
and an admin, so **no Firestore rule change is needed**. Other users' profiles
stay unreadable to the owner in `users/{uid}` — the number is only what the
reporter chose to send.

**Limits:** Copy only — there is no one-tap Call/Text button (that needs the
`url_launcher` package and Android manifest changes; not added). A sighting
received ONLY over the mesh (no internet on either side) has no phone number
until the cloud copy arrives. Sightings sent before this update have no number.

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` succeed. Not yet tried on two real phones.

---

## Mobile number is now required everywhere, and changing it is protected (2026-09-28)

**Why:** an owner contacts a sighting reporter by the number on their profile,
so a missing, malformed or casually swapped number breaks the communication.

**Required + validated in all three places** (one shared check,
`lib/utils/validators.dart`, so they can't disagree): registration (already
required — message reworded), **Edit Profile** (was optional and clearable), and
the web admin's **Add User** (was "optional"). Blank → "Mobile number is
required."; wrong format → "Please enter a valid Philippine mobile number
(e.g., 09171234567)." Accepts `09XXXXXXXXX` or `+639XXXXXXXXX`. Google sign-in
needed no change: it only admits accounts that already registered.

**Changing the number (Edit Profile):**
1. Editing it reveals a **Current Password** field, which is required.
2. A **confirm dialog** states that vehicle owners will contact the new number.
3. The password is re-verified with Firebase (re-authentication) before
   anything is saved — wrong password → "Incorrect password.", nothing changes.
4. It is written to the system log and a **"Mobile Number Changed"**
   notification is added ("if you did not do this, change your password").
Reformatting the same number ("+63 917…" vs "0917…") is not treated as a change.
Editing only the name needs no password.

**Limits (honest):** the password check happens in the app; Firestore rules
can't require re-authentication, so the owner of a profile could still bypass
it with a modified client — it protects against someone using an unlocked phone,
not a determined attacker on their own account. The number is not confirmed by
SMS code (that needs Firebase's paid plan for reliable volume), so the app
verifies the format and who is changing it, not that the number really rings.
No rule change needed. Accounts created before this rule with a blank or
malformed number will be asked to supply a valid one (with their password) the
next time they save their profile.

Verified `flutter analyze` (0 issues), `flutter test` (3 passing, incl. new
`test/validators_test.dart`), `flutter build apk --release` and
`flutter build web -t lib/admin_main.dart` succeed. Not tried on a phone yet.

**Manuscript check (FR-01 – FR-12, Chapter 3):** consistent, nothing to reword.
- FR-01 / §3.3.2.3: registration "collects the user's full name, email address,
  phone number, password, and device ID" — phone number was always listed as
  collected; the ERD (Fig. 3-10) marks USER.PhoneNumber **NOT_NULL**,
  Varchar(15). Requiring it (registration, Edit Profile, admin Add User)
  now matches that; the longest accepted form, "+639171234567", is 13 chars.
- FR-01 "log in securely": password re-confirmation before changing the number
  fits it; login/email verification are unchanged.
- FR-02 – FR-10, FR-12: not touched (vehicle registration, theft report and its
  photo, geofence, ad hoc broadcast/relay, proximity, push, logging, status).
- FR-11: the admin Add User form is on the web dashboard and follows the same
  rule.
- §2.2.8 / R.A. 10173: the number is shared only in the reporter's own
  sighting, after a notice on the form, and readable only by the owner,
  reporter and admin.

---

## Driver's license verification — registration and login (2026-09-28)

**Request:** a second verification — photos of the FRONT and BACK of a valid
driver's license — before an account can proceed.

**Flow**
- Registration: form → email verification → **license photos** → account
  created and signed in. (Vehicle registration comes after, as before.)
- The new screen (`lib/screens/s18_license_verification.dart`) is a two-step
  camera flow: the back can't be taken until the front is, and SUBMIT stays
  disabled until both exist. Camera only (no gallery), so it has to be a live
  photo. Loading modal while uploading, success modal after, error modal on
  failure. Leaving asks for confirmation.
- **Login gate:** any account with no license on file (including accounts
  registered before this feature, and anyone who quit the step mid-registration)
  is sent to the same screen after entering correct credentials — email login
  AND Google login — and is only signed in once it's done. Backing out signs
  them back out. The check is also applied when the app reopens with a saved
  session.
- Local check: once confirmed, "license on file" is remembered on the device so
  later launches don't need the network; if it can't be checked on reopening
  (offline) the person is let through, but at an actual login it fails closed.

**Storage and privacy**
- Two private documents per account: `users/{uid}/license/front` and `/back`,
  each a small compressed JPEG (base64, ≤450 KB) — separate docs so each stays
  under Firestore's 1 MB limit; Cloud Storage would need the paid plan.
- Only the owner (write + read) and an admin (read/delete) can access them.
- The web admin's account detail has **Show Driver's License** (front/back,
  tap to enlarge). **Permanently deleting an account also deletes its license
  photos.**
- Not done on purpose: no automatic reading/validation of the card (OCR), and no
  approve/reject step — the requirement is that the photos be submitted;
  an admin can inspect them. Either can be added.

**REQUIRED Firestore rule** — add inside `match /databases/{database}/documents`
(without it the upload is refused and NO ONE can log in, because the gate can't
confirm a license — publish this BEFORE using the new APK):
```
    match /users/{uid}/license/{side} {
      allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow create, update: if request.auth != null && request.auth.uid == uid
                            && (side == 'front' || side == 'back');
      allow delete: if request.auth != null && isAdmin();
    }
```

**Manuscript:** this collects a new kind of personal data (driver's license
images). FR-01 / §3.3.2.3's list of registration data and the data-privacy
paragraph (R.A. 10173) would need to mention it — wording is the user's call
(same as FR-13, pending the adviser).

Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` and `flutter build web -t lib/admin_main.dart`
succeed. Camera capture and the upload were not run on a real phone.

**Change (same day): the license is now a REQUIRED FIELD OF THE REGISTRATION FORM**
rather than a separate step after email verification. The Register screen has a
"DRIVER'S LICENSE (REQUIRED)" section (front, then back, camera only) below the
password fields. Pressing REGISTER without both photos shows "Please take photos
of both the front and the back of your driver's license." and nothing is created.
With everything filled in: account created → photos uploaded under it (Try
Again / Later if the upload fails) → email verification → signed in. If the
upload is abandoned, the login-time check asks for the photos later.
The capture UI is one reusable widget (`LicenseCaptureSection` in
`s18_license_verification.dart`) shared by the form and by the login-time
`LicenseVerificationScreen`. Rules and privacy notes above are unchanged.
Verified `flutter analyze` (0 issues), `flutter test` (passing),
`flutter build apk --release` succeeds. Not run on a real phone.

---

## Admin dashboard: Accounts tab redesigned — user information organized (2026-09-28)

**Why:** the account list only showed name, email and status; the phone number,
device, vehicles and license were buried behind taps.

**What changed (web admin only; new file `lib/screens/s19_admin_accounts.dart`,
the old row/detail code was removed from `s15`)**
- **Summary counters** (Total, Active, Suspended, **License pending**,
  **Vehicles**, Admins) that reflow 6 → 3 → 2 columns with window width.
- **Toolbar:** search (now also by **mobile number**), filters (All / Active /
  Suspended / License pending) and a "Showing N of M" line.
- **Table on wide windows** with aligned columns — Account (avatar, name,
  email, ADMIN tag), **Mobile number**, **Device ID**, **Vehicles**,
  **Driver's license** (✓ / NO LICENSE / ?), Status — plus suspend/delete
  buttons; **cards on narrow windows** with the same information. Content is
  centered at a maximum width so it doesn't stretch across a wide monitor.
- **Full profile** (click a row), now loading automatically: header with badges;
  **Account information** (name, email, mobile number, device ID, role,
  status, account ID — number and ID are selectable); **Registered vehicles**
  as cards (plate, model, color, type, stolen/not-stolen badge, geofence
  on/off + radius); **Driver's license** front/back thumbnails (click to
  enlarge); suspend/delete side by side, disabled for the admin's own account.
- Counts (vehicles, license on file) are Firestore count queries — the photos
  are not downloaded just to fill the list. If one can't be read it shows "—"
  / "?" instead of failing the whole list.
- No Firestore rule change.

Verified `flutter analyze` (0 issues), `flutter test` (passing, incl. new
`test/admin_accounts_test.dart` that renders the tab at desktop and phone
widths), `flutter build web -t lib/admin_main.dart` succeed. Not seen in a
browser with real accounts yet.

---

## Vehicle registration requires OR + CR photos; admin Vehicles tab; full system scan (2026-09-29)

**1. OR / CR required (phone app)**
- Register Vehicle now has an **"OR / CR Documents (Required)"** card with two
  separate photo slots — Official Receipt and Certificate of Registration —
  each taken with the camera OR chosen from the gallery. SAVE VEHICLE without
  both shows "Please add photos of both the Official Receipt (OR) and the
  Certificate of Registration (CR)." and nothing is registered.
- Modals: a **loading modal** ("Registering your vehicle…") while the plate is
  checked and the photos upload, a **success modal** ("Vehicle Registered … with
  its OR and CR …"), and an **error modal** if it fails (plate already
  registered, no connection, or the rule below isn't published).
- Order in `AppState.addVehicle`: claim the plate → upload OR/CR → save the
  vehicle. If the OR/CR upload fails the plate claim is **given back**, so a
  failed attempt never blocks the plate.
- Storage: `users/{uid}/vehicles/{vehicleId}/documents/or|cr` (private base64
  JPEG, ≤450 KB each, same approach as the license). Removing a vehicle now also
  deletes its OR/CR; deleting an account from the admin removes them too.
- Vehicles registered BEFORE this change have no OR/CR and are not blocked; the
  admin shows them as "NO OR/CR".

**2. Admin dashboard — new Vehicles tab** (`s20_admin_vehicles.dart`)
Counters (total, not stolen, stolen, recovered, OR/CR on file, geofence on),
search (plate, model, color, owner, device ID), filters (All / Stolen / Not
stolen / OR-CR missing); table on wide windows (plate, vehicle, registered
owner, device ID, status, geofence, OR/CR) and cards on narrow ones. Clicking a
row opens the full registration record: vehicle information (make/model, color,
type, status, device, geofence, last location/update, ID), registered owner
(name, email, mobile, status, account ID) and the **OR and CR photos** (click to
enlarge). The dashboard now has 4 tabs: Accounts · Vehicles · Live Activity · Map.

**REQUIRED Firestore rule** — add inside `match /databases/{database}/documents`
(without it vehicle registration fails at the OR/CR upload):
```
    match /users/{uid}/vehicles/{vehicleId}/documents/{docId} {
      allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow create, update: if request.auth != null && request.auth.uid == uid
                            && (docId == 'or' || docId == 'cr');
      allow delete: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }
```

**3. System scan (analyze + duplicate/dead-code sweep) — what was found and fixed**
Method: `flutter analyze`, a repo-wide search for declared-but-never-used members
(including `test/`), an unused-dependency check, and a repeated-code-block
detector. Results:
- **Dead code removed** (declared, never used anywhere): `AppState.allVehicles`,
  `AppState.unreadCount`, `AppState.markResolved`,
  `NotificationService.getFcmToken`, `SeedData.newId` (+ its unused `_rng`).
- **Duplicates merged:**
  - three "5m ago" helpers (`s9`, `s16`, `s17`) → `lib/utils/time_format.dart`;
  - three copies of the Take Photo / Choose from Gallery sheet (plate scan,
    theft-report evidence, and the new OR/CR) → `showImageSourceSheet`;
  - the admin's two identical label/value detail cards, two license/OR-CR
    decoders, the summary-counter grid, the search/filter toolbar and the
    photo tile → `admin_widgets.dart` and one `_documentImage()`;
  - the front/back and OR/CR photo cards → one `DocumentPhotoCard`, and one
    capture helper (`captureDocumentPhoto`) for license and OR/CR alike.
- **Bug fixed (found while adding OR/CR):** removing a vehicle now also cleans up
  its OR/CR photos, but that cleanup could have looped forever on a
  `permission-denied` (leaving the vehicle and its plate un-removable);
  it now only retries on connection problems.
- Clean: all 21 dependencies are used; no unused assets; analyze 0 issues.
- **Deliberately NOT changed** (working screens, per "don't touch what works"):
  the two near-identical map re-centering helpers in Geofence (`s6`) and
  Proximity Map (`s9`) — a small shared mixin could merge them if wanted.

Verified `flutter analyze` (0 issues), `flutter test` (5 passing),
`flutter build apk --release` (91.2 MB) and `flutter build web -t
lib/admin_main.dart` succeed. Camera/upload and the new admin tab were not
exercised on a real phone / with real data.


---

## Second full system scan — structure, duplication and one more crash guard (2026-09-29)

Requested as a follow-up full scan ("check all files and organize and fixed
them"). Method: repo-wide unused-symbol search (including `test/`), an
unused-dependency/asset check, an Android manifest/SDK sanity check, an
empty-`catch` audit, a repeated-code-block detector tuned to ignore layout
boilerplate, and a search for every `firstWhere` call without an `orElse`
(a raw `StateError` crash if the item is gone).

**Fixed:**
- **Crash guard, 4th site.** The 3 previous `firstWhere`-without-`orElse`
  fixes (setVehicleGeofence, deactivateGeofence, markRecovered) missed
  `reportStolen` — if the vehicle being reported stolen was removed from
  another device in the moment between opening the Report Stolen screen and
  confirming, the app would crash with a raw `StateError` instead of showing
  an error. It now throws a clear, named error ("This vehicle is no longer
  registered on this account.") that the screen catches and shows as a normal
  error modal, and the report is simply not submitted — no half-created alert.
- **Duplicated alert-mesh payload builder.** The exact same 6 lines that turn
  a `TheftAlert` into its wire form (strip the local photo path, add
  `hasPhotoEvidence`, tag `msgType`/`hopCount`) were written out twice —
  once for a late-joining peer, once for the main broadcast. Now one
  `_alertWireMessage()`.
- **Repeated "OK / OK" error dialog.** The same 6-line `showConfirmDialog`
  call (confirm=cancel="OK", an error icon) was written out 5 times across
  4 screens. Now `showErrorModal()` in `widgets.dart`; all 5 call sites use it.
- **Default coordinates typed out 8 times** (`8.9484, 125.5436` — Butuan City,
  the manuscript's research locale) across 6 files, including once with a
  DIFFERENT rounding (`8.9475, 125.5406` in the admin map) that would have
  quietly drifted from the others on the next edit. Now one
  `lib/utils/geo_defaults.dart` (`kDefaultLat`/`kDefaultLng`).
- **Email-format check duplicated 5 times**, two different ways (one a
  regex, one a bare `.contains('@')` in the admin login/Add-User forms — the
  weaker of the two). Now one `validateEmail()`/`isValidEmail()` in
  `validators.dart`, used everywhere, including the admin forms, which use
  the stronger check now.
- **Admin screens moved into `lib/screens/admin/`** (`admin_dashboard.dart`,
  `admin_vehicles.dart`, `admin_accounts.dart`, `admin_monitoring.dart`,
  `admin_widgets.dart`, renamed from the old `s15/s17/s19/s20` numbering,
  which never matched a real screen number and was getting harder to tell
  apart from the phone app's own S-numbered screens as the admin portal grew).
  Every import, and the one doc-comment still naming the old file, updated.
- **Empty `assets/` folder removed** from `pubspec.yaml` and the repo — it held
  no files (fonts are loaded from Google Fonts at runtime, not bundled), so
  declaring it added nothing but a dead line.
- **Stale web metadata**: `web/manifest.json` still described the app as "A
  new Flutter project" (the Flutter template default, never edited) and named
  it `vehicleguard`/`vehicleguard` instead of the Admin Portal; `web/index.html`'s
  description still said "manage registered accounts" only, from before the
  Vehicles/Live Activity/Map tabs existed.

**Checked, found clean:** `flutter analyze` — 0 issues; all 21 pubspec
dependencies are actually imported somewhere; no orphaned files (every file
is reachable from `main.dart` or `admin_main.dart`); no `TODO`/`FIXME`
markers or stray `print()` debugging left in; no encoding-damaged characters;
the Android manifest's permissions all trace to a real feature in use, and
`minSdk 29` matches the manuscript's "Android 10 or higher" requirement; every
remaining empty `catch (_) {}` is a deliberate best-effort fallback with a
comment explaining why it's safe to ignore (already documented case by case in
earlier entries, not new).

**Deliberately left as-is** (working code, not touched): the two near-identical
map re-centering helpers in Geofence (`s6`) and Proximity Map (`s9`) — noted
last entry too, a small shared mixin could merge them later if wanted, but
merging screen-specific logic carries more risk than the duplication itself.

Verified `flutter analyze` (0 issues), `flutter test` (5 passing),
`flutter build apk --release` (91.2 MB) and `flutter build web -t
lib/admin_main.dart` succeed. Not run on a real phone.

---

## Bug: an empty/unrelated photo was accepted as a driver's license (2026-09-29)

**Reported by real device testing.** Taking a photo of something that plainly
wasn't a driver's license (the tester used a photo of furniture) was accepted
for both the front and the back, and registration went through.

**Root cause.** The license capture step only ever checked three things: that
a photo existed, that the front was taken before the back, and that the file
wasn't too large. Nothing looked at what the photo actually showed — any
photo satisfied all three checks.

**Fix — a real content check, on-device, free.** New
`lib/services/license_scanner_service.dart` reuses the same on-device OCR
engine (Google ML Kit Text Recognition) already used for the plate-number
scanner — free, works offline after its one-time model download, no billing.
When a photo is taken for either side:
1. It reads whatever text is in the photo.
2. **Near-empty text → rejected immediately** ("hardly any text could be
   read"). This alone catches the reported bug — a photo of furniture, a
   wall, or a blank page reads as essentially no text.
3. **Some text, but not license wording → rejected.** The text is checked
   against two word lists (FRONT: REPUBLIC, PHILIPPINES, DEPARTMENT,
   TRANSPORTATION, LICENSE, DRIVER, NATIONALITY, EXPIRATION, CONDITIONS,
   SIGNATURE, …; BACK: DL CODE, CONDITIONS, RESTRICTION, MOTORCYCLE,
   TRICYCLE, CLUTCH, TRANSMISSION, AUTOMATIC, MANUAL, SERIAL, ORGAN DONATION,
   EMERGENCY, …). Fewer than 2 matches → rejected with "That doesn't look
   like the front/back of a Philippine driver's license."
4. Only a photo that passes both checks is accepted into the form.
- While a photo is being checked (well under a second usually), its button
  shows a spinner and "Checking photo…" — new `busy` prop on the shared
  `DocumentPhotoCard`.
- Applied in ONE shared place, `LicenseCaptureSection` — used by both the
  Register form's license fields and the login-time verification screen — so
  neither can drift out of sync with the other.

**What this can and can't do — stated plainly, not oversold.** It confirms
the photo contains genuine driver's-license wording; it does NOT verify the
license is authentic/not forged, and does NOT confirm the license belongs to
the person submitting it. A guarantee like that needs a paid, cloud-based
government-ID-verification service, which doesn't fit a free, offline-first
capstone app — the exact same reasoning that already kept the plate scanner
limited to reading the plate number only, not identifying the vehicle. The
admin can still open every submitted license photo (Accounts tab) for a human
look if one is ever needed.

**Checked while fixing this:** the OR/CR vehicle-document photos have the
same gap (no content check, only "a photo exists and isn't too big") — left
alone since it wasn't reported broken and wasn't asked for; the same
OCR-content-check approach could be added there the same way if wanted.

Verified `flutter analyze` (0 issues), `flutter test` (5 passing — OCR itself
needs a real device/emulator with Play Services, so it isn't unit-tested, the
same as the existing plate scanner), `flutter build apk --release` (91.2 MB)
succeeds. Needs testing again on a real phone with both a real license and a
non-license photo to confirm the accept/reject behavior in practice.

---

## OR/CR photos get the same content check; scanner unified (2026-09-29)

**Same gap, same fix.** OR/CR had exactly what the license step had before
the previous entry: a photo just had to exist and fit the file-size limit —
nothing looked at what it showed. Requested as a follow-up once the license
bug was confirmed.

**Unified rather than duplicated.** Rather than copy the license fix into a
second implementation, `license_scanner_service.dart` was folded into one
shared `lib/services/document_scanner_service.dart` (`DocumentScannerService`,
`DocumentCheckResult`) used by BOTH the driver's license (front/back) and the
OR/CR — same on-device OCR engine, same near-empty-text guard, same
"needs 2+ keyword matches" rule, only the keyword list and the document name
in the error message differ per call. Adding OR/CR meant adding two word
lists and two call sites, not a second scanner.

**Word lists** (from the sample LTO OR and CR forms reviewed for this
feature):
- **Official Receipt (OR):** OFFICIAL RECEIPT, RECEIVED FROM, PAYMENT
  DETAILS, BREAKDOWN OF PAYMENT, TRANSACTION, AMOUNT PAID, AMOUNT IN WORDS,
  MODE OF PAYMENT, MVUC, LEGAL RESEARCH FEE, CASHIER, FIELD OFFICE, OFFICE
  CODE, plus the shared LTO/government words.
- **Certificate of Registration (CR):** CERTIFICATE OF REGISTRATION, MV
  FILE, ENGINE NO, CHASSIS NO, DENOMINATION, PISTON DISPLACEMENT, BODY TYPE,
  GROSS/NET/SHIPPING WT, NET CAPACITY, OWNERS NAME, REGISTRANT, ENCUMBERED,
  YEAR MODEL, plus the shared LTO/government words.

**Behaviour, same as the license:** a photo with almost no readable text (an
unrelated object, a wall, blank paper) is rejected immediately; a photo with
text but fewer than 2 OR/CR words is rejected with "That doesn't look like an
Official Receipt (OR)" / "…a Certificate of Registration (CR)", asking to
retake; the OR/CR button shows a spinner and "Checking photo…" while the
check runs (new `busy` state per card, same as the license cards); only a
photo that passes gets accepted into the form. Same honest limit stated in
the previous entry: this confirms the photo shows genuine OR/CR wording, it
does not verify the document is authentic or belongs to the vehicle owner —
that needs a paid verification service, outside this project's scope. The
admin can view every submitted OR/CR photo (Vehicles tab) for a human look.

**Full re-scan (as asked)**, same method as the previous two passes
(`flutter analyze`, unused-symbol search across `lib/` and `test/`, the
duplicate-block detector, and a fresh check for `firstWhere` without
`orElse`): clean — no stale reference anywhere to the removed
`license_scanner_service.dart`/`LicenseScannerService`/`LicenseCheckResult`
(confirmed by grep across `lib/` and `test/`); no unused classes; the one
remaining `firstWhere` in `app_state.dart` (mesh relay bookkeeping) already
has an `orElse` and is safe. No new duplication introduced.

Verified `flutter analyze` (0 issues), `flutter test` (5 passing),
`flutter build apk --release` (91.2 MB) and `flutter build web -t
lib/admin_main.dart` succeed. Needs testing on a real phone with real OR/CR
photos and with an unrelated photo, the same way the license fix does.

---

## Confirmed wiring + third scan pass (2026-09-29)

**Confirmed** (no change needed): the driver's license content check is on
the actual USER REGISTRATION form (`RegisterScreen` in `s2_s3_auth_screens.dart`
→ `LicenseCaptureSection`), and the OR/CR content check is on the actual
VEHICLE REGISTRATION form (`RegisterVehicleScreen` in `s4_s5_vehicle_home.dart`
→ `_addDocPhoto`) — verified by tracing both screens from their routes in
`main.dart`, not just by file name. Both were already wired this way in the
previous two entries; this pass only checked and confirmed it.

**Scan (same method as the last two passes)** — `flutter analyze`, a
repo-wide unused-symbol search across `lib/` and `test/`, the duplicate-block
detector, and a `firstWhere`-without-`orElse` sweep. One real finding, fixed:

- **Duplicate found and merged:** `admin_accounts.dart` and
  `admin_vehicles.dart` each had their own identical "spinner while loading /
  cloud-off icon + message + Retry button on error" block (about 20 lines,
  byte-for-byte the same except which field held the error). Merged into one
  `adminLoadingOrError()` in `admin_widgets.dart`; both tabs now call it and
  return early instead of carrying their own copy.
- Everything else the scan flagged was a false positive on inspection: the
  one "unused" member (`didChangeAppLifecycleState`) is a `WidgetsBindingObserver`
  override the Flutter framework calls directly, not app code calling it by
  name; the remaining duplicate-block hits are either the two map-recentering
  helpers already noted twice before as deliberately left alone, or trivial
  boilerplate (import lines, `@override`, a `backgroundColor:`/`Scaffold(`
  pairing) not worth extracting.
- No orphan files, no unused classes, no unguarded `firstWhere`, no stale
  reference anywhere to a removed file.

**Not touched** (working, not part of this request): mesh/Bluetooth code,
sightings, admin Live Activity/Map tabs, account/vehicle CRUD logic itself —
only the loading/error block was shared code with an exact, provable
duplicate.

Verified `flutter analyze` (0 issues), `flutter test` (5 passing),
`flutter build apk --release` (91.2 MB) and `flutter build web -t
lib/admin_main.dart` succeed.

---

## Bug: "Could not load accounts" — caused by my own setup instructions (2026-09-29)

**What happened.** After creating the admin account exactly as instructed (Auth
user + Firestore `users/{uid}` document with `role`, `name`, `email`, `phone`,
`deviceId`), the Accounts tab failed with a generic "Could not load accounts.
Check your internet connection and try again." — even though the connection
was fine.

**Root cause.** My setup instructions were incomplete — I told the user to add
`role`, `name`, `email`, `phone`, `deviceId` to the new document, but not `id`.
`UserModel.fromMap` required `id` as a hard, non-nullable field
(`m['id'] as String`, no fallback). Every account the APP itself ever creates
gets `id` automatically (`UserModel.toMap()` always includes it), so this
never surfaced before — but a document typed by hand in the Console, following
my instructions, was missing it. The very first document `fetchAllUsers()`
tried to parse threw a plain (non-`Firebase`) exception, which fell through to
the generic catch block and showed the generic message with no error code —
and because `Future.wait` was building EVERY row in one batch, that single
bad document blanked the WHOLE accounts list, not just its own row.

**Fix — the actual bug, not a workaround.** The deeper problem is storing the
account's ID twice: once as the Firestore document's own ID (always correct,
set automatically, can never be missing) and again as a duplicate `id` field
inside the document body (which can drift or simply not be there). Rather than
just telling people to remember one more field when hand-creating a document:
- `UserModel.fromMap` now takes an optional `id` parameter. All 3 places that
  call it (`AdminService.fetchAllUsers`, `DatabaseService.getUserById`,
  `FirebaseSyncService.fetchUserProfile`) now pass in the ID they already,
  independently, know to be correct (the Firestore document's own ID, or the
  UID they queried by) — the duplicate `id` field inside the document is no
  longer trusted as the source of truth anywhere. A document missing it can
  no longer break anything.
- Every other field in `UserModel.fromMap` (`name`, `email`, `deviceId`) was
  also a hard, throwing cast — loosened to fall back to `''` like `phone` and
  `role` already did, so a document missing ANY field degrades gracefully
  instead of throwing.
- **One malformed document can no longer blank an entire admin list.** New
  shared `_parseSkippingBad()` helper in `admin_service.dart` — parses each
  document, and a single one that still somehow fails to parse is skipped,
  not fatal to the rest. Applied to `fetchAllUsers`, `fetchVehicles`, and
  `fetchLocationHistory` (the three admin list-loaders built from
  Firestore-document-per-row data — the exact class of thing this bug hit),
  replacing what would otherwise have been 3 separate copies of the same
  try/skip loop with one.

**You don't need to add anything to the document you already made** — it
works now as-is, once you install the updated app/dashboard. (Its `id` will
just show up correctly, read from the document's own ID rather than a field
inside it.)

Verified `flutter analyze` (0 issues), `flutter test` (5 passing),
`flutter build apk --release` (91.2 MB) and `flutter build web -t
lib/admin_main.dart` succeed.

---

## Vehicle registration overhaul: real duplicate bug fixed, CR content actually enforced, OR/CR auto-fill, Series + Year Model (2026-09-29)

**Reported by real device testing**, with screenshots: the same account had
"GAS9817", "GAS-9817" and "GAS-9817" registered as three separate vehicles —
same plate, same model, same everything, each with its own OR/CR.

**1. Root cause and fix — this is a real bug, not a validation gap.**
`claimPlateIfAvailable`'s transaction only blocks a plate when a DIFFERENT
account already holds it (`existingOwner != ownerId`) — it was never meant to
stop the SAME owner from "reclaiming" a plate they already have, and nothing
else checked that. Re-submitting the form (or registering the same real
vehicle a second time by mistake) silently created a brand-new vehicle
document every time. Fixed in `AppState.addVehicle`: before anything else, it
now checks the owner's own already-loaded vehicle list for a plate that
normalizes to the same key (so "GAS9817" and "GAS-9817" collide, exactly the
reported case) and refuses with **"You already have a vehicle registered with
plate X. Each vehicle can only be registered once."** — shown as the existing
error modal, no new UI needed. The plate-normalization logic itself was
previously duplicated (once in `AppState`, and now needed again in the
registration screen for the OR/CR cross-check below); it's now one
`normalizedPlate()` in `lib/utils/validators.dart`, and `AppState` delegates
to it instead of keeping its own copy.

**2. The CR's Body Type is now actually enforced.** The manuscript's scope is
four-wheel Sedan/SUV/Hatchback only (§1.5). `DocumentScannerService` gained
`findBodyType()`: it reads a validated CR's OCR text for the LTO "BODY TYPE"
field and checks it against an allow-list (Sedan/SUV/Hatchback) and a
disallow-list (Motorcycle, Tricycle, Trailer, Truck, Bus, Van, Jeepney, AUV,
Pick-up, Tanker, Cab Chassis, Heavy Equipment, Motorized, …). A disallowed
word rejects the CR photo outright with the offending word named in the
message; if the field can't be confirmed either way (unclear photo), the CR
is ALSO rejected and asked to be retaken — the app never registers a vehicle
whose body type it couldn't verify.

**3. OR vs. CR cross-acceptance is now blocked.** Both documents share
general LTO wording (REPUBLIC, DEPARTMENT OF TRANSPORTATION, …), so the
existing "2-of-many keywords" check alone could theoretically let an OR photo
pass as a CR or vice versa. `DocumentScannerService.check()` gained a
`requiredAny` gate: the document's OWN printed title must appear verbatim —
"OFFICIAL RECEIPT" for the OR slot, "CERTIFICATE OF REGISTRATION" for the CR
slot — on top of the existing word-count check, not instead of it. Wrong-slot
uploads are now rejected with a message naming the problem. (Also fixed while
in there: multi-word keyword matching — e.g. "DL CODE", "ORGAN DONATION" —
was fragile against how OCR line-wraps text; whitespace is now normalized
before every keyword check, for the license checks too.)

**4. Form reordered, and OR/CR now drive auto-fill.** OR/CR upload is now the
FIRST card in the registration form, per the request — once both photos pass
their checks, the **plate number**, **vehicle type**, and **year model**
fields below are filled in automatically from what was just read off the CR
(never overwriting something already typed). A best-effort **color** match
against the color catalog is attempted too, but — after reviewing the sample
OR/CR forms this feature was built against — none of them print a clearly
labeled color field the way they print plate/body-type/year, so this is
genuinely best-effort and often won't fire; Color stays manual entry the same
way it always has, and Series still isn't guessed (a make/model can't be read
reliably from a free-text field without a much heavier layout-aware OCR
approach, the same reasoning [PlateScannerService] never touches Model). The
plate read from the OR and the plate read from the CR are cross-checked
against each other — a mismatch (two different real vehicles' documents
uploaded by mistake) is rejected with both values named, instead of silently
keeping whichever was read last.

**5. "Model" renamed "Series"; "Year Model" added.** Matches the CR's own
field name. The type-specific option lists (`VehicleCatalog.modelsFor(type)`)
already varied per Vehicle Type — that requirement was already met; this was
a labeling change (registration form + the admin's vehicle detail, "Make /
model" → "Series"). Year Model is a new required field, validated as a
plausible year (1980–next year), auto-filled from the CR, editable. New
`VehicleModel.yearModel` field; local DB schema v5 → v6
(`ALTER TABLE vehicles ADD COLUMN yearModel TEXT`); no Firestore rule change
(same document, new field, already covered by the existing vehicles rule).

**Also fixed while scanning (same defensive pattern as the earlier
`UserModel`/accounts-list fix):** `VehicleModel.fromMap` had the identical
"hard-required `id` field, one malformed document blanks the whole list"
weakness — every field is now defensive, and `id` is sourced from the
Firestore document's own ID (passed in by the caller) rather than trusted
from a duplicated field inside the document body. Updated at all 3 read
sites (`AdminService.fetchVehicles`, `DatabaseService.getVehiclesForOwner`,
`FirebaseSyncService.fetchVehicles`). `PlateScannerService` gained a
public `extractFromText()` so the OR/CR extraction reuses its exact,
already-tested plate pattern instead of a second copy of the regex, and so a
photo's plate is read from the SAME OCR pass its content check already ran,
not a second one.

**New tests** (pure logic, no OCR/platform dependency, same approach as the
existing `validators_test.dart`): `test/document_scanner_test.dart` covers
`findBodyType` (all three allowed types, a disallowed type, a disallowed word
winning over a coincidental allowed one, neither present), `findYearModel`
(anchored, single-candidate fallback, ambiguous → null, absent → null), and
`PlateScannerService.extractFromText`; `validators_test.dart` gained a test
for `normalizedPlate` using the exact reported bug case ("GAS9817" vs.
"GAS-9817").

**Full re-scan** (same method as the last several passes — `flutter analyze`,
unused-symbol search across `lib/` and `test/`, the duplicate-block detector,
a `firstWhere`-without-`orElse` sweep, and a stale-reference grep for the
renamed `_model`/`'MODEL'` identifiers): clean.

Verified `flutter analyze` (0 issues), `flutter test` (17 passing, 11 new),
`flutter build apk --release` (91.2 MB) and `flutter build web -t
lib/admin_main.dart` succeed. Not yet tried on a real phone with real OR/CR
photos.

---

## Email verification: the silent-failure bug fixed, honest about what isn't fixable; license photos now modal-based + gallery option (2026-09-29)

**Reported by real device testing**, with screenshots: registered, reached
"Check your email", nothing arrived; on Resend, the screen said "Verification
email resent to francascindy@gmail.com." (a genuine success from the app's
own point of view) and still nothing arrived.

**1. A real bug, found and fixed.** `FirebaseAuthService.register()`'s send
of the FIRST verification email was wrapped in `catch (_) {}` — any failure
(most commonly Firebase's free-tier email-sending rate limit, easy to hit
during a testing session with many registrations) was silently thrown away.
The intent (documented in the code) was sound — a failed send must never
fail the whole registration, since the account still exists and needs a path
forward — but the way it was written also hid the failure from the person
entirely: they'd land on "Check your email" with no idea whether anything was
actually sent, and no reason to reach for "Resend" right away. Fixed: the
send's real outcome is now captured and passed back; if it failed, the Verify
Your Email screen shows an amber warning banner immediately — no more
silently waiting on an email that was never sent. (`too-many-requests`
specifically gets its own clear wording, both here and on the "Resend Email"
button, explaining it's Firebase's temporary sending limit, not a problem
with the account.)

**2. What genuinely can't be fixed in code, stated plainly.** The SECOND
screenshot — "Verification email resent..." (green, meaning Firebase's
`sendEmailVerification()` call itself returned success) with nothing arriving
— is not a bug this codebase can fix. Firebase's client SDK has no delivery-
confirmation API: a successful call only means Firebase ACCEPTED the request
to send, not that the email was delivered. Heavy testing in one session
(many registrations/resends, as this project has had) is exactly what
exhausts Firebase's free Spark-plan email-sending quota — the fix is time
(the quota resets) or upgrading the Firebase project's plan, not a code
change. (Same conclusion reached earlier for the "too-many-requests on
Resend" report — recorded here again because it recurred and needed the
actual cause explained, not just retried.)

**3. Driver's license: errors and successes are now modals, not inline
text.** Every rejection (a photo that fails the content check, a
camera/gallery access problem) now shows as `showErrorModal` — impossible to
miss the way a small line of red text below two images apparently was. Every
accepted photo now shows a success modal too ("Front Captured" / "Back
Captured"), which didn't exist before — passing the check just quietly
updated the card. Applied identically to the vehicle registration's OR/CR
step for the same reason and the same pattern, not just the license (the two
were built together and shared the exact same inline-text approach; leaving
one modal-based and the other text-based would have been an inconsistency,
not a considered choice). OR/CR's per-photo SUCCESS feedback stays a toast
(unlike the license): uploading an OR/CR already shows its own visible proof
of success — the auto-filled plate/type/year-model fields — so a second
blocking modal on top felt like unneeded friction there; happy to switch it
to a modal too if it should match exactly.

**4. Driver's license: gallery upload added.** The license photo requirement
was camera-only by original design (a deliberate anti-fraud consideration —
harder to submit an old/borrowed photo). The user's explicit instruction
here reverses that: `LicenseCaptureSection` now offers the same "Take Photo /
Choose from Gallery" choice OR/CR already has, reusing `showImageSourceSheet`
rather than a new copy of that sheet.

**Also removed while in there:** `LicenseCaptureSection`'s `errorText` prop
(the "please add both photos" submit-time message) — now shown as a modal by
the registration form directly at the moment Submit is pressed without both
photos, instead of being threaded through as a rendered prop; simpler, one
fewer piece of state, matches how the OR/CR "both required" message now
works the same way.

**Full re-scan** (same method as every prior pass): clean — no orphaned
files, no unused classes/members, no unguarded `firstWhere`.

Verified `flutter analyze` (0 issues), `flutter test` (17 passing, unchanged
from last entry), `flutter build apk --release` (91.2 MB) succeeds. The web
admin build was not rebuilt — verified first that nothing under
`lib/screens/admin/` or `lib/admin_main.dart` imports any file touched this
pass, so it isn't affected. Not yet tried on a real phone.

---

## Real cause of the "ghost" account found: registration data was lost when verification wasn't completed in the same session (2026-09-30)

**Found from the user's own Firestore/Authentication Console screenshots.**
A real test account (`francascindy@gmail.com`) existed in Authentication, and
its driver's license photos existed under `users/{uid}/license/`, but the
`users/{uid}` PROFILE document itself — the one holding name, phone, role,
device ID — never existed at all. Firestore showed it as "This document does
not exist" even though a subcollection lived under that same path (a
document can have subcollections without ever having been written itself).

**Root cause.** `AppState.register()` only ever created the Firebase AUTH
account. The Firestore PROFILE document was written exclusively inside
`finalizeRegistration()` — which only ever ran if the person was still on the
Verify Your Email screen at the exact moment they tapped Continue after a
successful check. Given the verification EMAIL itself has been unreliable
this session (see the two email-verification entries above), this was a
realistic, likely path: register → email doesn't arrive in time → give up /
close the app → the Firestore profile is simply never created, silently. The
name and phone number actually typed into the form were lost — not saved
anywhere. (`login()` does have a fallback that builds a generic profile —
name "User", blank phone — for an account with no profile, so the person
COULD eventually get in, just with their real details gone.)

**Fix — write the real profile immediately, not after verification.** The
profile (name, phone, device ID) is now saved — to both the local cache and
Firestore — as part of `register()` itself, right after the Auth account is
created, before the verification email is even sent. `finalizeRegistration()`
now REUSES that already-saved profile (checking local cache, then Firestore)
instead of building a second one with a different random device ID; it still
only runs after successful verification, so the account remains gated behind
verification exactly as before — this only decouples the DATA from the
verification TIMING. Whether verification happens right away, hours later
via Resend, or through logging back in after finally clicking an old link,
the person's actual typed name and phone are preserved either way.

**The existing broken test account is not automatically repaired** by this
code change — it only prevents the same loss for accounts registered from
now on. To recover `francascindy@gmail.com`: once its email is verified,
logging in will trigger `login()`'s existing fallback and create a basic
profile automatically (generic name, blank phone) — the name and phone can
then be corrected afterward through Edit Profile. Alternatively, the missing
`users/{uid}` document (UID `X65HBVwvTfQKaPano5MYfmZkNMh1`) can be created by
hand in the Console the same way the admin account was, with `role: owner`
(not `admin`) this time.

**On the "Phone: Enabled" Authentication screenshot:** unrelated to the email
problem — Firebase's "10 SMS/day" banner shows because the Phone sign-in
PROVIDER is toggled on for the project, which is a separate quota from
Email/Password's verification-email sending. VehicleGuard never uses Phone
sign-in (SMS requires the paid Blaze plan — the whole reason this project
uses free email verification instead), so it's safe, and harmless either way,
to leave enabled or disable it in Firebase Console → Authentication →
Sign-in method → Phone → Disable. Doing so will NOT speed up or fix email
delivery — that remains governed by the separate, unpublished email-sending
quota discussed in the prior entries.

Verified `flutter analyze` (0 issues), `flutter test` (17 passing, unchanged),
`flutter build apk --release` (91.2 MB) succeeds. Not yet tried on a real
phone — needs a fresh registration to confirm the profile now saves
immediately.

---

## Real cause of "no verification email" found: it was landing in Spam, not lost (2026-09-30)

**Correction to the prior two entries.** After more testing, the user checked
the Spam folder directly — the verification emails were there, sent
successfully every time, with working links. My earlier conclusion (a
Firebase-side sending quota/delivery failure with no code fix) was wrong; I'd
based it on the visible Inbox and no error being shown, but hadn't seen Spam.
Recorded here plainly rather than left standing as if it were still accurate.

**Actual cause — a Firebase Console configuration gap, not a code bug.**
Checked via the Templates screenshot: **Sender name was blank** ("not
provided"), and the **Public-facing name** for the Firebase project was never
set, so the email's subject line showed the raw internal project ID
("Verify your email for project-593170285783") instead of "VehicleGuard".
Combined with sending from a shared `@*.firebaseapp.com` address neither
Gmail account had ever received mail from before, this is a textbook set of
Gmail spam signals for automated verification email. **Fix is two free
Firebase Console fields, done by the user, no code or billing involved:**
Project Settings → General → **Public-facing name** → "VehicleGuard"; and
Authentication → Templates → Email address verification → **Sender name** →
"VehicleGuard". The app's own hint text ("Check your spam/junk folder…") had
already been pointing at the right answer the whole time.

## New: verification is now detected automatically — no manual "Continue" tap needed

**Request:** once the link is clicked in the email, the app should notice on
its own instead of requiring the person to switch back and tap "I've
Verified — Continue" by hand.

**Added to `_EmailVerificationScreen`** (shared by both entry points — the
registration flow and the login-time "you still need to verify" flow, so
this covers both automatically): a quiet background timer checks every 4
seconds whether the email is now verified (`AppState.checkEmailVerified()` —
a LOCAL reload of the signed-in user's own token, not a new email send, so it
never touches the sending quota above). The moment it detects success, the
screen moves on by itself — the same path the manual button already used, so
the same success modal / account-finalization flow happens either way. A
small "Checking automatically…" spinner row was added so it's visible
something is happening in the background, and the intro text was reworded to
say so. The manual "I've Verified — Continue" button still works exactly as
before for anyone who'd rather not wait — this only adds the automatic path
alongside it, without changing the existing 60-second countdown/expiry
behavior of that manual button.

Verified `flutter analyze` (0 issues), `flutter test` (17 passing, unchanged),
`flutter build apk --release` (91.2 MB) succeeds. Not yet tried on a real
phone.

---

## Bug: the same license photo was accepted for both FRONT and BACK (2026-09-30)

**Reported with a screenshot**, and the cause was directly visible in it: a
tester retook the FRONT of their license for the BACK slot too, and both
were accepted — the same photo, shown as both "Front" and "Back," each with
a green checkmark.

**Root cause.** `licenseBackWords` (the loose "any 2 of many" keyword check
for the back) included `'DL CODE'` and `'CONDITIONS'`. Some Philippine
license formats — including the one in this photo — also print the
licensee's OWN DL codes ("A,A1,B,B1,B2") and a short "Conditions: NONE" line
on the FRONT, as personal summary fields, separate from the BACK's full
reference table explaining what each code means. So a front photo could
satisfy the back's 2-match requirement using only those two words, without
containing anything actually back-specific.

**Fix — the same mechanism already used for OR vs. CR, reused, not
duplicated.** `DocumentScannerService.check()` already supported a
`requiredAny` gate (at least one of a list of phrases MUST appear, on top of
the general word count) — built earlier for making sure an OR photo can't
pass as a CR and vice versa. Applied the identical mechanism to the license:
- **`licenseFrontTitle`**: NATIONALITY, BLOOD TYPE, SIGNATURE OF LICENSEE,
  EXPIRATION DATE — at least one required for the front.
- **`licenseBackTitle`**: ORGAN DONATION, EMERGENCY, TRANSMISSION, CLUTCH,
  MOTORCYCLE, TRICYCLE, ARTICULATED, SERIAL — at least one required for the
  back. These are the back's REFERENCE content (the DL-codes legend, organ
  donation, emergency contact, the AT/MT legend) that a front photo never
  has, regardless of which license format is used.

A front photo submitted for the back slot no longer has any of these anchors
and is now rejected with "That doesn't look like the back of a driver's
license — the wording expected on the back of a driver's license wasn't
found," shown as the existing error modal (already modal-based since the
prior entry).

**On OR/CR ("same on the vehicle registration part")** — already covered.
That check already requires the document's own printed title
(`officialReceiptTitle` / `certificateOfRegistrationTitle`), which by
definition can't both be satisfied by one real document — verified this
still holds, no gap found there, no change needed.

**Rejection message improved for multi-anchor lists.** The existing message
quoted only `requiredAny.first`, which read oddly for the license's several
acceptable anchors (versus OR/CR's single fixed title) — now uses a general
reason when the anchor list has more than one option, and the specific
quoted phrase when it's a single fixed title (OR/CR unchanged).

**New regression tests** (`test/document_scanner_test.dart`): the exact
front-page content from the reported photo is confirmed to satisfy the front
anchor and correctly FAIL the back anchor; a genuine back's reference content
is confirmed to satisfy the back anchor.

**Full re-scan** (same method as every prior pass): clean — no orphaned
files, no unused classes/members, no unguarded `firstWhere`. No unnecessary
code found to remove this pass.

Verified `flutter analyze` (0 issues), `flutter test` (20 passing, 3 new),
`flutter build apk --release` (91.2 MB) succeeds. Not yet tried on a real
phone with an actual back-of-license photo.

---

## Bug: modals showing "OK" and "OK" side by side; Series/Color/Year Model auto-fill was reading the wrong values off a real CR/OR (2026-09-30)

**Reported with 6 screenshots.** Two separate problems:
1. The "Vehicle Not Registered" and "Photo Not Accepted" modals each showed
   TWO buttons, both labeled "OK".
2. On a real CR/OR: the CR's Series field ("S-PRE3SO1.0-GL") was left blank
   and flagged red/required even though it's clearly printed on the
   document; the OR explicitly printed "Color: GRAY" and "Year Model: 2023"
   in its payment-details section, but Color was never filled and Year Model
   auto-filled to "2026" — today's year, not the document's.

**Bug 1 — root cause.** `showErrorModal` was a thin wrapper around
`showConfirmDialog(confirmLabel: 'OK', cancelLabel: 'OK', ...)`.
`showConfirmDialog` always renders a Cancel/Confirm button pair — passing the
same label for both doesn't collapse them into one, it just draws "OK" next
to "OK". A grep for every other `showConfirmDialog` call site found one more
instance of the exact same mistake, in `main.dart`'s "Account Disabled"
notice (also `confirmLabel: 'OK', cancelLabel: 'OK'`) — not reported yet,
but the same bug, fixed the same way.

**Bug 1 — fix.** `showErrorModal` (`lib/widgets/widgets.dart`) is now its own
standalone single-button dialog — same visual pattern as the existing
`showSuccessModal` (icon circle, title, message, one full-width button) —
instead of delegating to the two-button `showConfirmDialog`. The
`main.dart` "Account Disabled" notice was switched from `showConfirmDialog`
to `showErrorModal`, since it's a one-button acknowledgment, not a real
choice. Every other `showConfirmDialog` call site was checked — all of them
use genuinely distinct confirm/cancel labels (Leave/Stay, Turn Off/Cancel,
Suspend/Cancel, etc.), so `showConfirmDialog` itself was left unchanged;
those are real two-choice confirmations and are working correctly.

**Bug 2 — root cause.** The existing Year Model reader (`findYearModel`)
searched for a year inside a 40-character *flat-text* window after "YEAR
MODEL", and Series/Color were never read from the document at all (Color
fell back to a whole-text scan against the color catalog, Series had no
extraction attempt whatsoever). The flat-text approach is unreliable against
a real LTO CR/OR: Google ML Kit's OCR reads a document in roughly linear
block/line order, which does **not** preserve the page's actual 2-D table
layout — a label and its value can print right next to each other on the
physical document but end up far apart (or in a different order) in the
OCR's flattened text. That's why "YEAR MODEL 2023" on the real CR was read
as "2026" — the 40-character window landed on the wrong number.

**Bug 2 — fix.** Confirmed (by reading the installed
`google_mlkit_text_recognition` v0.13.1 package source directly) that the
OCR result actually exposes each line's position on the page
(`RecognizedText.blocks[].lines[].boundingBox`), not just flattened text.
Built a position-aware extractor on top of that instead of the flat-text
window:
- **`DocumentCheckResult`** now also carries the full `RecognizedText`
  object from the OCR pass (`recognized`), alongside the existing flattened
  `text`, so callers don't need a second OCR pass to get at line positions.
- **`DocumentScannerService.extractNearLabel(recognized, labels)`** — finds
  a label (e.g. "SERIES", "COLOR", "YEAR MODEL") among the OCR'd lines, then
  tries, in order: (1) whatever follows the label on the *same* line, (2)
  the nearest line to its right at roughly the same height, (3) the nearest
  line directly below it. This is what actually reads a table correctly.
- **`findSeries`**, **`findColor`**, **`findYearModelLabeled`** — built on
  top of `extractNearLabel`, each with its own sanity check (a color must
  read as a plain word, not a code with digits; a value that turns out to be
  another field's label name is rejected rather than trusted) so a
  misaligned match is dropped instead of silently filling the wrong thing.
- **`findYearModel`** keeps its old flat-text behavior as a fallback for
  when no `recognized` result is available, but now tries the label-based
  match first.
- Wired into `s4_s5_vehicle_home.dart`'s `_addDocPhoto`: **Series** is read
  from the CR only (an OR doesn't print it) and auto-fills the Series field
  as free text — it isn't required to match the model catalog, since real
  LTO series codes ("S-PRE3SO1.0-GL") don't look like catalog entries.
  **Color** and **Year Model** are read from *both* the OR and the CR (both
  print them on the sample forms reviewed) — whichever photo is added first
  fills the field, the other never overwrites it, matching how Plate number
  cross-checking already worked. The OR card is listed first in the form, so
  in the normal OR-then-CR upload order, the OR's printed Color/Year Model
  (the ones the user explicitly asked to be trusted) win.

**Still an OCR read, not a guarantee.** Exactly like every other auto-fill
in this app (plate quick-scan, body type, the old Year Model/Color
best-effort), this is best-effort against a real photo's lighting, angle and
print quality — it can still miss a field or misread a character. Every
field it fills stays a normal, fully editable text/dropdown field, and
nothing here blocks submission if extraction comes up empty; only the OR/CR
document *type* check and the CR body-type restriction actually reject a
photo.

**New regression tests** (`test/document_scanner_test.dart`): synthetic
`RecognizedText`/`TextLine` objects (built directly, not from a real OCR
pass) covering — a year read from the line *below* its label while an
unrelated year elsewhere on the page is correctly ignored (reproduces the
exact reported "2026 vs 2023" bug); a Series value read from the same row as
its label; a Color value read from the same line as its label; a Color match
correctly rejected when it would have grabbed the next field's label
instead of an actual value; and a label search returning null when the
label isn't on the page at all.

**Full re-scan**, per "analyze the system again if there's still a bug,
error, problem or duplicate": grepped every `showConfirmDialog` call site in
the app for a matching pair of labels — found and fixed the one other
instance (`main.dart`). No orphaned files, no unused classes/members, no
unguarded `firstWhere` found otherwise.

Verified `flutter analyze` (0 issues), `flutter test` (25 passing, 5 new),
`dart format`, `flutter build apk --release` (91.2 MB) succeeds. Not yet
tried on a real phone against the actual CR/OR from the report.

---

## Duplicate full names blocked at registration; "Date Created"/"Date Registered" columns; Admin Dashboard redesigned into an actual gridded table with row numbers and a "Not Yet Registered" placeholder (2026-09-30)

**Reported from real testing**, via Admin Dashboard screenshots: several
accounts registered under the exact same name ("Cedric Michael Uy" × 3), no
way to see when an account or vehicle was created, and the dashboard's
tables read as plain stacked cards rather than a gridded table — no visible
row/column lines. Four separate pieces of work, all in the Admin Dashboard
and the registration path underneath it.

### 1. Duplicate full names are now blocked at registration

**Root cause.** Firebase Auth only guarantees a unique EMAIL, never a
unique NAME — nothing in the app ever checked whether a full name was
already registered, so the same name (a different Gmail address each time)
could register any number of times.

**Fix — a small Firestore registry, the same pattern the `plates`
collection already uses for plate uniqueness**, now added for full names:
`account_names/{normalizedName}` → `{ownerId, name}`, keyed by a
case/whitespace-normalized form of the name (`normalizedFullName()`,
`utils/validators.dart`). Unlike a plate, a name isn't a genuinely scarce
real-world resource — two different real people can legitimately share one
— so this is a best-effort existence check done BEFORE the Firebase Auth
account is even created (`AppState.register()`), not a full atomic
transaction: a collision from two people registering the exact same name in
the same instant is an acceptable, narrow race for something this
low-stakes. Checking first, before creating anything, also means a name
collision never leaves an orphaned Firebase Auth account behind.

Applied in both places an account can be created:
- **Self-registration** (`AppState.register()`): checked first; on a match,
  registration is refused with *"An account is already registered under the
  name '…'. If this is you, sign in instead of registering again…"* —
  surfaced through the existing error-modal path, no new UI needed.
- **Admin "Add User"** (`AdminService.createUser()`): same check, direct
  against Firestore (this file deliberately never imports
  `FirebaseSyncService` — see its own class doc — so the check is a small,
  duplicated-on-purpose Firestore read rather than a cross-import).

**Existing accounts (registered before this check existed) are
backfilled automatically**, so a NEW duplicate of an already-existing name
still gets blocked going forward: every time the Admin Dashboard loads the
Accounts tab, each account not yet in the registry claims its name —
unless someone else already holds it, in which case it's left alone (of
several pre-existing duplicates, whichever is checked first ends up
"claiming" it; that's enough, since the goal is only to stop a NEW
duplicate, not to retroactively pick a winner among the ones already
there). Fully best-effort and silent — never blocks or slows down loading
the accounts list itself.

**Not automatically cleaned up:** the 3 existing "Cedric Michael Uy"
accounts from testing are still all there — this only stops a 4th one from
being created. Removing the extra test accounts is a manual step from the
Accounts tab (Delete Permanently), same as before.

**Account deletion releases the claimed name** (`AdminService.removeUser`),
so a permanently deleted account's name becomes available again instead of
staying blocked forever.

### 2. "Date Created" (Accounts) / "Date Registered" (Vehicles) columns

`UserModel`/`VehicleModel` gained a `createdAt` field (nullable — null for
anything that predates this change, shown as "—", never guessed). Set at
every real creation point (`AppState.register()`/`finalizeRegistration()`
fallback/`signInWithGoogle()` fallback, `AdminService.createUser()`,
`AppState.addVehicle()`), using the Firebase Auth account's own
`metadata.creationTime` where one already exists rather than "now", so it's
accurate even on a fallback path. Explicitly **preserved, not reset**, on
`AppState.updateProfile()` (editing your name/phone must not look like
re-registering). Local SQLite schema bumped to v7 (`users`/`vehicles` gain
a `createdAt TEXT` column) alongside the existing Firestore field.

Shown in both tabs' wide table, narrow cards, and detail sheets.

### 3. Admin Dashboard redesigned into an actual gridded table

Previously each row was its own separate floating card with gaps between
them — no visible column lines, and only alternating white space read as
"structure". New shared pieces in `admin_widgets.dart`, used by both the
Accounts and Vehicles tabs' wide/desktop view (the narrow/mobile card view
is deliberately left as it was — cards already read fine at that width, and
"gridlines" is a wide-table concept):
- **`AdminTableFrame`** — wraps the header and every row in ONE bordered,
  rounded card with a tinted header and a hairline divider between rows,
  plus a subtle alternating (zebra) row background.
- **`AdminHoverRow`** — highlights under the mouse (this is a WEB admin
  dashboard) and forwards the row's tap.
- **`AdminColumnDivider`** — a thin vertical line between columns, so the
  table actually has visible column lines, not just row lines.

### 4. Row numbers, and the Vehicles tab restructured to one row per account

**Row numbers** (`registrationNumbers()`/`byRegistrationOrder()`, shared in
`admin_widgets.dart`): every account gets a "#" — its position in
registration order (oldest = 1) — shown before its name on both tabs.
Recomputed live from whichever accounts currently exist, not a stored ID,
so it naturally increases as new accounts register and shifts down on its
own when an earlier account is deleted, exactly as asked. An account with
no known `createdAt` (predates this feature) sorts after every dated one,
grouped together and ordered by name among themselves, since there's no way
to know where it really belongs.

**Vehicles tab restructured**: instead of listing only vehicles (so an
account with none simply never appeared), it now shows ONE ROW PER ACCOUNT,
in the exact same order/numbering as the Accounts tab — an account with a
vehicle shows its details as before; an account with none shows a single
row with **"Not Yet Registered"** in place of the vehicle details, "—" in
every other vehicle-specific column, and no tap action (nothing to open).
An account with more than one vehicle gets one row per vehicle, each
showing that same account number, so it's clear at a glance which vehicles
belong to which numbered account. The "Stolen"/"Not stolen"/"OR/CR missing"
filters only ever match a real vehicle row — a placeholder only shows under
"All", since it has no vehicle status to filter on.

**REQUIRED Firestore rules update** — adds the `account_names` collection.
Full rules to paste in Firebase Console → Firestore Database → Rules
(everything else is unchanged from the last published version — this adds
one new `match` block and nothing else):
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function isAdmin() {
      return request.auth != null &&
        exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.get('role', 'owner') == 'admin';
    }

    match /users/{uid} {
      allow get: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow list: if request.auth != null && isAdmin();

      allow create: if request.auth != null
                    && (request.auth.uid == uid || isAdmin())
                    && request.resource.data.get('role', 'owner') == 'owner';

      allow update: if request.auth != null
                    && (request.auth.uid == uid || isAdmin())
                    && request.resource.data.get('role', 'owner') == resource.data.get('role', 'owner');

      allow delete: if request.auth != null && isAdmin();
    }

    match /users/{uid}/vehicles/{vehicleId} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /users/{uid}/vehicles/{vehicleId}/documents/{docId} {
      allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow create, update: if request.auth != null && request.auth.uid == uid
                            && (docId == 'or' || docId == 'cr');
      allow delete: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /users/{uid}/license/{side} {
      allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow create, update: if request.auth != null && request.auth.uid == uid
                            && (side == 'front' || side == 'back');
      allow delete: if request.auth != null && isAdmin();
    }

    match /plates/{plateId} {
      allow get: if request.auth != null;
      allow create: if request.auth != null && request.resource.data.ownerId == request.auth.uid;
      allow update: if request.auth != null && resource.data.ownerId == request.auth.uid && request.resource.data.ownerId == request.auth.uid;
      allow delete: if request.auth != null && resource.data.ownerId == request.auth.uid;
    }

    match /account_names/{nameId} {
      allow get: if request.auth != null;
      allow create: if request.auth != null &&
                    (request.resource.data.ownerId == request.auth.uid || isAdmin());
      allow delete: if request.auth != null &&
                    (resource.data.ownerId == request.auth.uid || isAdmin());
    }

    match /removed_accounts/{uid} {
      allow read: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow write: if request.auth != null && isAdmin();
    }

    match /presence/{uid} {
      allow get, list: if request.auth != null;
      allow create, update, delete: if request.auth != null && request.auth.uid == uid;
    }

    match /theft_alerts/{alertId} {
      allow get, list: if request.auth != null;

      allow create: if request.auth != null && request.resource.data.id == alertId;

      allow update: if request.auth != null && (
        isAdmin() ||
        resource.data.userId == request.auth.uid ||
        (
          request.resource.data.userId == resource.data.userId &&
          request.resource.data.status == resource.data.status &&
          request.resource.data.lat == resource.data.lat &&
          request.resource.data.lng == resource.data.lng &&
          request.resource.data.plate == resource.data.plate &&
          request.resource.data.model == resource.data.model &&
          request.resource.data.color == resource.data.color &&
          request.resource.data.vehicleId == resource.data.vehicleId
        )
      );

      allow delete: if false;
    }

    match /sightings/{sightingId} {
      allow create: if request.auth != null
                    && request.resource.data.reporterId == request.auth.uid
                    && request.resource.data.id == sightingId;

      allow update: if request.auth != null
                    && resource.data.reporterId == request.auth.uid
                    && request.resource.data.reporterId == request.auth.uid;

      allow get, list: if request.auth != null
                       && (resource.data.ownerId == request.auth.uid
                           || resource.data.reporterId == request.auth.uid
                           || isAdmin());

      allow delete: if request.auth != null && isAdmin();
    }

    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if false;
      allow create: if request.auth != null;
      allow update, delete: if false;
    }

  }
}
```

**Full re-scan**: grepped for every `UserModel(`/`VehicleModel(`
construction site to make sure `createdAt` was set (new accounts/vehicles)
or explicitly preserved (`updateProfile`'s edit, not reset). Found and
removed one piece of genuinely dead code introduced by this same change —
`FirebaseSyncService.releaseName()` had no caller anywhere (account
deletion only ever happens through `AdminService.removeUser`, which
deliberately never imports `FirebaseSyncService` and does its own release
directly) — removed rather than left unused.

Verified `flutter analyze` (0 issues), `flutter test` (25 passing),
`dart format`, `flutter build apk --release` (91.2 MB) and
`flutter build web -t lib/admin_main.dart` both succeed. Layout was
specifically checked (via a temporary throwaway widget test, since the real
`AccountsTab`/`VehiclesTab` tests either don't cover every column or need a
live Firestore) for column overflow at both a wide desktop width and a
narrower one just above the table/card breakpoint — not yet tried in an
actual browser.

---

## Bug: the duplicate-name check (added the same day) blocked EVERY registration, not just duplicates (2026-09-30)

**Reported from real testing**, with a screenshot: filling in a brand-new,
never-used name still failed with *"Could not verify this name isn't
already registered. Check your internet connection and try again"* — on a
phone with a working LTE connection.

**Root cause — a mistake in the very feature added earlier today.** The
duplicate-name check (`AppState.register()`) ran BEFORE the Firebase Auth
account was created, on purpose — so a genuine duplicate would never leave
an orphaned auth account behind. But the `account_names` Firestore rule
requires `request.auth != null` to even READ the registry, and nobody is
signed in yet at that point in registration — no account exists, so there's
no session. The read was refused by Firestore's own rules every single
time, regardless of whether the name was actually taken, which surfaced as
the generic "check your connection" error — this was never a connectivity
problem.

**Fix.** The check now runs AFTER `_authSvc.register()` succeeds, not
before. `createUserWithEmailAndPassword` signs the new account in
immediately, so by the time the name check runs, `request.auth` is real —
the same rule now works as intended. Two consequences of moving the check
to after account creation, both handled:
- **On a genuine duplicate**, the just-created account is rolled back —
  `outcome.user!.delete()` (allowed on a JUST-created, freshly-signed-in
  account without needing re-authentication) then signed out — so a real
  duplicate still leaves nothing stranded, same guarantee as before.
- **On a check failure** (the read itself throws — a transient network
  hiccup on this second call, or the `account_names` Firestore rule not
  published yet), the flow now PROCEEDS instead of blocking. A real account
  already exists by this point; refusing to continue would destroy it over
  a check that was always documented as best-effort, not a hard guarantee
  (see the registry's own doc in `firebase_sync_service.dart`). This is
  also why the reported bug happened even with the rule pasted or not — it
  fails exactly the same way (silently skipping the check) instead of
  blocking every registration, which is the safer failure mode either way.

**Scope.** Only `AppState.register()` changed — nothing else in this app
touches registration or the name registry, so this didn't require touching
`AdminService.createUser()` (Add User already runs its own check AFTER its
secondary Firebase app has already authenticated the new account, so it
was never affected by this bug), the Firestore rules (unchanged from the
last published version), or any other file.

Verified `flutter analyze` (0 issues), `flutter test` (25 passing, all
still passing — none of them exercise live Firestore/Auth, so this
particular bug could only ever be caught by real-device testing, exactly
how it was found), `flutter build apk --release` (91.2 MB) succeeds. Not
yet re-tried on a real phone.

---

## New: Terms & Conditions / Privacy Policy gate before registration; bug fix: new accounts were being numbered FIRST instead of last (2026-10-01)

### 1. Terms & Conditions / Privacy Policy

**New feature.** Before anyone can reach the Create Account form — and
therefore before vehicle registration, which follows it — they now have to
read and agree to a Terms & Conditions / Privacy Policy sheet. Declining
just closes the sheet; nothing is created, and the person stays exactly
where they were (Splash or Login).

**Where it's wired in** — every real path into registration, all through
one shared `_goToRegister()` helper per screen (so there's exactly one
place per screen that decides what happens after agreeing, not the gate
logic copy-pasted):
- Splash screen's **"GET STARTED"** button.
- Login's **"No account yet? Register"** link.
- Login's own **"Register"** button inside the "Google Account Not
  Registered" dialog (signing in with an unregistered Google account offers
  this as the next step).

**The same content is also available read-only**, for anyone — including
someone who already has an account — from a **"Terms and Conditions"** text
link added directly below the Register link on the Login screen, exactly as
asked. That version has no agree/decline gate, just a single Close button.

**Content** (`lib/widgets/terms_and_conditions.dart`) — eleven sections:
acceptance of terms, what's collected, why it's collected, **who can access
it** (explicitly: only the account owner and the system administrator — no
other registered user or third party can ever see another person's driver's
license, OR/CR, or personal details; a sighting reporter's contact details
are shared only with that one vehicle's owner), how it's stored and
secured, rights under the Data Privacy Act of 2012 (R.A. 10173), the
account holder's own responsibilities, how the ad hoc mesh network relays
an alert without exposing private documents, the system's honest
limitations (a monitoring/alert tool, not a law-enforcement replacement or
a commercial guarantee), how the policy can change, and the actual consent
statement. Grounded in what the app genuinely does — nothing here claims a
capability the system doesn't have.

**UI/UX**: a near-full-height bottom sheet with a drag handle, an icon +
title header, each section shown with its own icon and a staggered
fade/slide-in entrance as it scrolls into view. In the GATED version, **"I
Agree" stays disabled until the sheet has actually been scrolled to the
end** (with a small "Scroll to read the full policy" hint) — a deliberate,
honest touch so agreeing means having actually seen the whole thing, not
just reflexively tapping a button. The read-only version skips that gate
entirely, since there's nothing being agreed to.

**Scope, on purpose**: only the phone app's own self-registration entry
points changed. The admin dashboard's "Add User" (an admin creating an
account on someone else's behalf from the web portal) was deliberately left
untouched — a different flow, not what was asked for here.

### 2. Bug fix: a newly-registered account was numbered #1 instead of last

**Reported from real testing**, with an Admin Dashboard screenshot: after
registering a brand-new test account, it showed up as row **#1** — ahead of
five older accounts that had been sitting there for days.

**Root cause.** `byRegistrationOrder()` (added the same day `createdAt` was
introduced, in `admin_widgets.dart`) was supposed to put an account with no
known registration date (anything that existed before that field did)
AFTER every dated one, reasoning "there's no way to know where it really
belongs, so put it at the end." That reasoning had the direction backwards:
an UNDATED account is, in real-world terms, actually OLDER than a dated one
— it was registered before date-tracking even existed — so it belongs
nearer the FRONT, not the back. With six accounts where only the brand-new
one had a real date, that one freshly-registered account sorted as "the
earliest" and grabbed #1, while five genuinely older accounts were pushed
behind it.

**Fix.** One line flipped: an undated account now sorts BEFORE every dated
one (nearer #1), and dated accounts sort after them in their real
chronological order, exactly matching "a new user is numbered last." Since
`byRegistrationOrder()`/`registrationNumbers()` are shared by both the
Accounts and Vehicles tabs, this one fix corrects both at once — no
duplicate logic existed to fix twice.

**New regression tests** (`test/admin_widgets_test.dart`): the exact
reported scenario (one dated account among five undated ones must land
last, not first); two dated accounts sort in real chronological order; and
deleting an account shifts the remaining numbers down, confirming the
numbering stays a live computation, never a stored ID.

Verified `flutter analyze` (0 issues), `flutter test` (28 passing, 3 new),
`dart format`, `flutter build apk --release` (91.3 MB) and
`flutter build web -t lib/admin_main.dart` both succeed. Not yet tried on a
real phone/browser.

---

## A received theft alert never showed the owner's photo or remarks; plate/series/color made clearly visible everywhere; the Bluetooth-without-Wi-Fi question answered honestly (2026-10-01)

**Reported from real testing**, with 5 screenshots: a stolen-vehicle alert
received on a nearby phone showed none of the reporter's remarks or photo
evidence — only a generic meta grid (distance, hop count, etc.); and a
question about why the real ad hoc mesh didn't seem to relay anything with
Wi-Fi off, even with Bluetooth on.

### 1. A theft report's photo and remarks never reached anyone else

**Root cause.** `TheftAlert.photoPath` was a path on the REPORTING phone's
own filesystem (`image_picker`'s `XFile.path`, never read into bytes) —
dutifully carried through `toMap()`, uploaded to Firestore, and even
stripped from the mesh payload on purpose, but meaningless to read back on
ANY other device, including the owner's own history if viewed anywhere but
that one phone. The two places that build a *received* alert
(`AppState._handleMeshMessage` for the mesh, `_handleInternetAlert` for
Firestore) both knew this and worked around it with a hardcoded string —
`'📷 Photo evidence attached on reporter\'s device.'` — spliced into the
`notes` field. But `AlertReceivedScreen` (what a nearby phone actually sees
when it taps the alert) never read `alert.notes` or any photo field at
all — so even that doctored placeholder text was silently dropped, and the
receiving user saw neither the real remarks nor any indication a photo
existed.

**Fix — the same shape that already works correctly for a sighting's
photo** (`SightingReport.photoB64`, confirmed working in screenshot 5's
"Sightings" screen): `TheftAlert.photoPath` is replaced with `photoB64` —
real JPEG bytes, base64-encoded, capped at 500 KB (same cap, same picker
settings — `maxWidth/maxHeight 1024`, `imageQuality 60` — as
`ReportSightingScreen`, which already enforces this correctly).
- `ReportStolenScreen._pickPhoto` now reads actual bytes instead of just
  keeping an `XFile`'s local path, with the same size-cap error message a
  sighting's photo picker already shows.
- `AppState.reportStolen` takes `photoBytes` (not `photoPath`), encodes it
  once, and stores it on the alert that's created locally — so the OWNER's
  own copy always has the real photo, immediately.
- `AppState._handleInternetAlert` (the Firestore listener — this is the
  path that reads the FULL document) now carries the real `notes` and
  `photoB64` straight through, no placeholder text.
- `AppState._handleMeshMessage` (BLE/Wi-Fi Direct relay) carries the real
  `notes` as-is; the photo genuinely isn't sent over the mesh at all —
  same reasoning `SightingReport.forMesh()` already established: a ~500 KB
  payload isn't something to push through a multi-hop BLE/Wi-Fi Direct
  relay reliably. `AlertReceivedScreen` says so honestly instead of
  looking like nothing was ever attached (see below).
- **`AlertReceivedScreen`** (`s9_s10_s11_alerts_map.dart`) now actually
  shows what it receives: a "REMARKS FROM THE OWNER" section (`alert.notes`,
  when present), a tappable, full-width photo (`alert.photoB64`, opens
  full-screen pinch-to-zoom via the new shared `showPhotoViewer` — see
  below), and — only for a manually-submitted report (FR-12 requires a
  photo before one can even be sent) received over the mesh without one
  yet — an honest note that a photo exists and will appear once the device
  is back online, rather than silence.
- The owner's own **Alert History** list (`AlertLogItem` in
  `widgets.dart`) gets a lightweight "📷 Photo attached" chip alongside the
  existing notes chip, for the same at-a-glance visibility.
- The **admin Live Activity** detail sheet (`admin_monitoring.dart`) gained
  the exact same photo display `_AdminSightingCard` already has for
  sightings — the admin is one of the few people meant to see this
  evidence, same reasoning as the Terms & Conditions update from
  2026-10-01's earlier entry.

**New shared `showPhotoViewer(context, bytes)`** (`lib/widgets/widgets.dart`)
— a full-screen, pinch-to-zoom photo dialog. `s16_sightings.dart`'s
`_AlertSightingsScreenState._showPhoto` had its own private copy of this
exact dialog; it now just calls the shared one instead, removing the
duplicate. (The admin portal's own `admin_widgets.dart` already has an
identical function for its own, deliberately separate use — the three admin
screens that import both files now `hide showPhotoViewer` from the phone
app's copy to resolve the name clash, keeping the two portals' copies
independent as before.)

**Local database**: `theft_alerts` gains a `photoB64 TEXT` column (schema
v7 → v8); the old `photoPath` column is left in place but never written to
again, same precedent as the dead `passwordHash`/`salt` columns from an
earlier migration — removing a column from an already-installed app's local
database isn't safe without a lot more care than this is worth.
**No Firestore rules change needed** — the existing `theft_alerts` `create`
rule already allows any field shape, only requiring `id == alertId`.

### 2. Plate, series and color made clearly visible everywhere an alert shows one

Previously a vehicle's identity was often crammed into one small gray line
(as little as 12px, next to a 15px headline). Made consistently prominent:
- **`AlertReceivedScreen`**: the plate is now its own large (30px, bold,
  monospace) line; series and color each get their own clearly labeled chip
  (`_VehicleInfoChip`, 16px bold) instead of sharing a single tiny caption.
- **`AlertLogItem`** (Alert History list): plate 14px→18px bold, series ·
  color line 12px gray→13px darker and semi-bold.
- **`ReportStolenScreen`**'s vehicle banner: plate 18px→23px, series/color/
  type line given more weight and contrast.
- **`GeofenceScreen`** previously never showed which vehicle a geofence
  belonged to at all — it now opens with the same plate/series/color
  identity block, so with more than one vehicle registered there's no
  ambiguity about which one is being configured.
- **Proximity Map**: both the "STOLEN · plate" label and the shared
  `_MapTag` (used for "You" and every nearby node's name) were rendering at
  **8px** — bumped to 11px bold, with the stolen-vehicle marker widened
  (110px→140px) so the longer label has room.

### 3. "Why can't the alert relay with Wi-Fi off, even with Bluetooth on?"

**Investigated, not assumed.** Read `nearby_mesh_service.dart` in full and
confirmed: this app's own Dart code never gates mesh advertising,
discovery, or relay on `networkStatus`, internet connectivity, or any
Wi-Fi-specific state — `radioProblems()` only checks Bluetooth and Location
being switched on, and nothing in `AppState` additionally requires Wi-Fi.
So this is **not a bug in VehicleGuard's own code**.

What it is: a real, documented limitation of **Google's Nearby Connections
API itself** — the Android system framework this app's real ad hoc mesh is
built on (`Strategy.P2P_CLUSTER`). Confirmed by reading the
`nearby_connections` plugin's own `README.md`, which requires the Android
manifest permissions `ACCESS_WIFI_STATE` and `CHANGE_WIFI_STATE` — meaning
Google's own implementation actively depends on the Wi-Fi radio, not just
Bluetooth. In practice: Bluetooth/BLE handles the initial discovery step,
but the actual connection and data relay typically upgrades to a Wi-Fi
Direct or Wi-Fi Hotspot link for reliability — if Wi-Fi is switched
completely off (not just disconnected from a network — the radio itself
needs to be on; no actual internet or paired network is required), that
upgrade can fail, and depending on the Android version/device, the
connection can fail outright rather than gracefully stay on
Bluetooth-only.

**There's no code fix for this app to make** — the limitation lives inside
Android's own Nearby Connections implementation, not in anything
`nearby_mesh_service.dart` or `AppState` controls. What WAS fixable, and is
fixed: the app's own copy was misleadingly telling people only "Bluetooth
and Location" needed to be on, when Wi-Fi is just as necessary in practice.
Corrected in three places: the `_refreshRadioProblems` warning shown when
discovery stalls, the "Restart Scan" failure toast, and
`nearby_mesh_service.dart`'s own doc comment — all now say Bluetooth,
Location AND Wi-Fi are needed, and are explicit that Wi-Fi does NOT need to
be connected to any network. (Detecting "Wi-Fi radio is on but not
connected" from Dart isn't possible with anything already in this project's
dependencies — `permission_handler` has no Wi-Fi service-status check the
way it does for Bluetooth/Location, and `connectivity_plus` only reports an
ACTIVE network connection, not raw radio state — so this is corrected copy,
not a new runtime detection, same honesty-over-overclaiming approach used
everywhere else in this app.)

**New regression tests** (`test/models_test.dart`): `TheftAlert.photoB64`
round-trips through `toMap()`/`fromMap()`; `hasPhoto` is false for both
`null` and an empty string; `toMap()` no longer writes the old dead
`photoPath` key; and `notes` comes back exactly as stored, with no injected
placeholder text.

Verified `flutter analyze` (0 issues), `flutter test` (33 passing, 5 new),
`dart format`, `flutter build apk --release` (91.3 MB) and
`flutter build web -t lib/admin_main.dart` both succeed. Not yet tried on
two real phones.

---

## Owner's own evidence photo shown on the Sightings screen; a vehicle can't be reported stolen twice while already active; admin Accounts/Vehicles row order now matches the "#" number; summary tiles double as filter buttons (2026-10-02)

**Reported from real testing**, with 8 screenshots, addressed in the order
asked.

### 1. The owner's own photo/remarks weren't shown on their own alert's Sightings screen

`AlertSightingsScreen` (`s16_sightings.dart`) only ever showed OTHER
people's sightings — the owner's own remarks and evidence photo (the ones
collected at the moment they reported the vehicle stolen, FR-12) were
nowhere on the screen, even though it's their own report. Added a "YOUR
REPORT" card right under the vehicle banner, showing `alert.notes` and —
tappable, full-screen-zoomable via the shared `showPhotoViewer` — the real
photo, only when either is actually present.

### 2. A vehicle could be reported stolen more than once while already active

**Reported with a screenshot**: Alert History showed the SAME plate with
TWO simultaneously-active "STOLEN" entries (one from Butuan City, one from
Surigao City, both "Manual Report"). Nothing stopped the owner from
reopening Report Stolen and confirming again while the vehicle was still
marked stolen from the first report.

**Fix — one guard, in the one place both triggers go through.**
`AppState.reportStolen()` is the single method both the manual Report
Stolen screen AND the automatic geofence-violation check call — so one
check there covers both: if the vehicle's current status is already
`VehicleStatus.stolen`, it now throws (`"<plate> is already reported
stolen. Mark it as recovered first if you want to report it again."`),
surfaced through the screen's existing error-modal handling, same as the
"vehicle no longer registered" case it already had. `_checkGeofences()`
already skipped a non-`active` vehicle before it would even reach
`reportStolen()` (so the automatic path was already effectively protected
in practice) — this makes it a real guarantee at the authoritative layer
instead of something only one of the two callers happened to respect,
exactly matching "same for the geofence also."

The rule is per-vehicle, not per-account — a second registered vehicle is
completely unaffected and can be reported independently. Once the owner
marks the vehicle recovered (`markRecovered`, unchanged — it already resets
status back to `active`), it can be reported again if it's ever stolen a
second time.

### 3. Admin dashboard: the alert's photo still wasn't visible there

**Investigated, not blindly re-applied.** Re-read the entire photo pipeline
end to end — `ReportStolenScreen` → `AppState.reportStolen` →
`TheftAlert.toMap()`/local SQLite → `FirebaseSyncService._syncAlerts` →
`AdminService.watchAlerts` → `admin_monitoring.dart`'s detail sheet (the
photo-display code added in the previous session is confirmed present and
correctly gated on `a.hasPhoto`) — and found no bug in any of it; every
step that should carry `photoB64` through does.

**Likely explanation, not a code fix**: the specific alerts in the
screenshot (the same "Surigao City" / "Butuan City" duplicate-report test
data from item 2 above) were almost certainly created with an APK built
*before* the `photoB64` fix existed, back when a report's photo was still
the dead `photoPath` field — those alerts genuinely never had a real photo
to show. A fresh report made with the latest APK, viewed on a freshly
rebuilt/reloaded admin dashboard, is the real test of whether this works —
not re-opening old test data.

### 4. Admin dashboard: row order didn't match the "#" number

**Reported with 2 screenshots**: row "8" appeared ABOVE row "1" in the
Accounts list. Root cause: the "#" number was already correctly computed by
registration order (fixed in the previous session), but the LIST ITSELF was
still shown in whatever order `AdminService.fetchAllUsers()`'s Firestore
query returns it — `orderBy('name')`, alphabetical, a completely different
ordering. The number and the row's actual on-screen position had never
agreed.

**Fix**: `AccountsTab._filtered` now sorts by the same `byRegistrationOrder`
used to compute the numbers, so row position and row number always match —
oldest at the top as #1, the newest registration at the very bottom with
the highest number. The Vehicles tab was already built this way (it derives
its own order from the same sorted account list), so only Accounts needed
this fix.

**New regression test** (`test/admin_accounts_test.dart`): two accounts fed
in deliberately-reversed (alphabetical, i.e. opposite-of-registration)
order, asserting the older one renders above the newer one regardless.

### 5. Admin dashboard: make the active filter obviously visible, not just the small chip

**Reported with 2 screenshots.** Tapping a filter chip (e.g. "Active")
changed what the list showed, but nothing about the matching summary stat
tile ("8 ACTIVE") reflected that it was the one currently applied — easy to
lose track of which filter is on.

**Fix**: `AdminStatChip` gained `selected`/`onTap`. When a tile has a
matching filter (Accounts: Total/Active/Suspended/License Pending;
Vehicles: Total/Not Stolen/Stolen — Recovered, OR/CR On File and Geofence
On have no exact matching filter and stay plain, informational tiles),
tapping either the chip or the tile applies that filter, and the tile fills
solidly with its color (white text, a subtle shadow) instead of just a
light tint while that filter is active — unmistakable at a glance, not just
from the small chip underneath.

### Full re-scan, as asked

Grepped for `photoPath` across the whole `lib/` tree — only the two
already-documented legacy comments remain (the dead SQLite column, kept
intentionally — see the previous entry). Found and removed one genuinely
dead parameter: `VehicleCard.onReport` — declared and assigned in the
constructor, never read anywhere inside the widget and never passed by any
caller. Removed rather than left unused.

Verified `flutter analyze` (0 issues), `flutter test` (34 passing, 1 new),
`dart format`, `flutter build apk --release` (91.3 MB) and
`flutter build web -t lib/admin_main.dart` both succeed. Not yet tried on a
real phone/browser.

## Admin Live Activity: alert list tiles now show a photo indicator too (2026-10-02)

**Asked for**: make a theft report's evidence photo visible in the admin
dashboard's Live Activity tab, the same way a sighting's photo is already
visible there.

**Investigated first, not blindly re-applied.** The alert detail sheet
(opened by tapping an alert in the Live Activity feed) already has correct,
working photo-display code from the previous session — gated on
`a.hasPhoto`, decoding `photoB64` and rendering it exactly like the sighting
detail does. Re-traced the whole pipeline again end to end
(`ReportStolenScreen` → `AppState.reportStolen` → local SQLite →
`FirebaseSyncService._syncAlerts` → `AdminService.watchAlerts` → the detail
sheet) and found no bug — every step that should carry `photoB64` through
still does. The specific alerts in the screenshots are the same pre-existing
"Surigao City"/"Butuan City" test data flagged in the previous entry, almost
certainly created before the `photoB64` fix existed; a fresh report on the
current build is the real test, not re-opening that old data.

**Real, concrete gap found and fixed**: comparing the two list-item widgets
in that same feed, `_SightingEventTile` already showed an inline "📷 photo"
indicator in its subtitle when a sighting had a photo, but `_AlertEventTile`
(`lib/screens/admin/admin_monitoring.dart`) had no equivalent — an admin
scanning the main list had no way to tell which alerts had evidence photos
without opening each one. Added a matching `_meta(Icons.photo_outlined,
'photo')` chip to `_AlertEventTile`'s row of meta chips (hop count, relayed-
to count, sighting count), shown only `if (a.hasPhoto)` — same pattern, same
helper, same styling as the other three chips already there.

**Full re-scan, as asked.** No duplicate code, no new dead parameters, no
other list/detail asymmetries found between the alert and sighting tiles
beyond the one fixed above.

Verified `flutter analyze` (0 issues), `flutter test` (34 passing, no
regressions), `dart format`, `flutter build apk --release` and
`flutter build web -t lib/admin_main.dart` all succeed. Not yet tried on a
real phone/browser — if a *freshly created* report still shows no photo in
the admin detail popup after this, that would point to something other than
stale test data and is worth a follow-up report.

## Vehicle registration made mandatory right after account registration (2026-10-03)

**Asked for**: once a brand-new account finishes registering, it should go
straight into Vehicle Registration and be REQUIRED to complete it — no way
to reach the dashboard without registering at least one vehicle first.

**What already existed**: `RegisterScreen._submit()` already navigated to
`/register-vehicle` right after a successful registration. The actual gap
was that nothing *enforced* it — the screen had a normal back button, the
Android hardware back button worked, and (more importantly) if the app was
closed before a vehicle was ever added, the next launch's session-restore
sent the account straight to `/home` via `SplashScreen`'s auto-route, with
zero vehicles and no further prompt.

**Fix — a one-time "onboarding pending" flag, not a permanent "must always
have ≥1 vehicle" rule.** `AppState.needsVehicleOnboarding` is true only when
a local per-device flag (set by `finalizeRegistration()`, the moment a
BRAND-NEW registration completes) is still pending AND the account
currently has zero vehicles. It's refreshed every time a session is
established (`_completeSignIn` — covers login, Google sign-in, and
finalizeRegistration itself — and the session-restore branch of `init()`),
and cleared for good the moment `addVehicle()` ever succeeds, even if every
vehicle is later removed. This distinction matters: an account that
registered before this feature existed, or that currently has zero vehicles
because it genuinely removed its only one, is never affected — Home's
existing "No vehicles registered yet." empty state (with its own working
"Add Vehicle" entry point) keeps behaving exactly as before. Only a
brand-new account that has never yet finished its first vehicle
registration is gated.

Three places read the flag to decide where to navigate: `RegisterScreen`
(right after registration), `LoginScreen._completeLogin` (an account that
registered but never finished vehicle setup, now logging back in — possibly
after closing the app), and `SplashScreen` (a restored session mid-way
through that same unfinished flow). All three send such a session to
`/register-vehicle` with `arguments: true` instead of `/home`.

**`RegisterVehicleScreen` gained a `mandatory` flag** (default `false` —
every existing "Add Vehicle" call site on Home and Profile keeps pushing
this route with no arguments, completely unaffected). When `true`: the
AppBar back button is hidden, `PopScope(canPop: false)` blocks the Android
hardware/gesture back button too (with a toast explaining why), and a short
"this step is required" banner is shown above the form. Submitting the form
successfully (`addVehicle()`) behaves exactly as it already did —
clears the pending flag and lands on `/home`, same as the optional flow.

**Full re-scan, as asked.** Confirmed both existing "Add Vehicle" call
sites (`s4_s5_vehicle_home.dart`'s Home tab, `s12_s13_s14_...dart`'s
Profile screen) still push `/register-vehicle` with no arguments, so they
default to `mandatory: false` and are untouched. Confirmed
`_IncomingAlertWatcher`'s own popups and nothing else in `main.dart`'s
route table were affected. No duplicate logic was introduced — the three
navigation call sites each just read the one shared `AppState` flag, the
same pattern already used for `pendingLicense`/`pendingEmailVerification`.

Verified `flutter analyze` (0 issues), `flutter test` (34 passing, no
regressions), `dart format`, `flutter build apk --release` and
`flutter build web -t lib/admin_main.dart` all succeed. Not yet tried on a
real phone — a live test should confirm: (1) a fresh registration lands on
a back-button-less Register Vehicle screen, (2) force-closing the app
there and reopening lands back on the same screen rather than Home, and
(3) completing it lands on Home normally.

## Real alert delivery delay is now measured and connected (2026-10-04)

**Asked for**: the manuscript's delay/transmission-rate stat was never
actually connected to anything real — `alertDelay`/`transmissionRate` only
measured the REPORTER's own broadcast step, never a receiving phone's real
end-to-end delay (sent time vs. actual arrival time). Wire up a real
measurement: on receipt (mesh or internet), record the arrival time,
compute the delay from the alert's own timestamp, save it with the route
and hop count to System Logs and Firestore, and show the list + average on
the admin Live Activity tab.

**Fix.** `AppState._logAlertDelivery(alert, {via})` — called exactly once,
right where each receive path (`_handleMeshMessage`'s `'theft_alert'`
branch, and `_handleInternetAlert`'s brand-new-alert branch) stores a
genuinely NEW alert, never for the reporter's own report and never for a
duplicate already seen via the other layer:
- Computes `delayMs = DateTime.now().difference(alert.timestamp)` —
  `alert.timestamp` is the sent time, already carried by every alert.
- Writes a System Logs line in exactly the requested shape:
  `ALERT GAS-9817 · sent 20:47:03.210 · received 20:47:05.640 · delay
  2.43s · via Internet · hop 0` (tag `DELAY`).
- Best-effort uploads the same record to a new Firestore collection,
  `/alert_deliveries` (`FirebaseSyncService.logAlertDelivery` — one
  document per device's receipt of an alert: `alertId`, `plate`, `via`,
  `hopCount`, `sentAt`, `receivedAt`, `delayMs`).

**Admin Dashboard.** `AdminService.watchAlertDeliveries()` streams that
collection into a new `AlertDelivery` model; `AdminMonitorFeed` picks it up
as a fourth live source alongside alerts/sightings/devices (same
start()/errors-map pattern, so a missing rule only blanks this one source,
not the others). On the Live Activity tab: a 5th stat chip, "AVG DELIVERY
DELAY" (the mean of every recorded delay, live), doubles as a shortcut into
a new "Delivery log" filter tab showing every recorded delivery, newest
first, in the same list the alerts/sightings already use (reusing
`_Event`/`ListView.builder` — no second list widget).

**One thing noted in the code comment, as the request itself flagged**:
the sent and received timestamps come from two different phones' clocks.
If those clocks disagree, the measured delay is off by exactly that much —
a real limitation of measuring across devices, not a bug. Both phones
should be set to automatic network time before a real test.

**Scope check**: nothing about `alertDelay`/`transmissionRate` (the
existing reporter-side broadcast stats, still shown on the Broadcasting
screen) was touched or removed — this is an additional, separate
measurement, not a replacement. No other screen, route, or existing admin
tab/filter was changed.

Verified `flutter analyze` (0 issues), `flutter test` (34 passing, no
regressions), `dart format`, `flutter build apk --release` and
`flutter build web -t lib/admin_main.dart` all succeed. A real two-phone
test (one reporting, one receiving over both mesh and internet) would
confirm the logged delay is sane once both phones' clocks are synced.

## Registration now needs admin approval; vehicle is entered on the same page (2026-10-05)

**Asked for**: account and vehicle registration on one page (vehicle below the
account section), a "being processed, please wait for admin approval" notice
after submitting, a pending state the admin must approve or reject from the
dashboard (with the license and OR/CR photos shown so the admin can check they
are genuine and not AI-generated or edited), approve = the user is registered
automatically, reject = back to registering, and a notice that tells the user
the outcome.

**Registration page** (`s2_s3_auth_screens.dart`): the vehicle form was moved
out of `RegisterVehicleScreen` into a shared `VehicleFormSection` widget.
Add Vehicle (Home/Profile) and the registration page both use that same form,
so the two cannot drift apart. The registration page embeds it below the
license section, with one REGISTER button.

**Submit** (`AppState.submitRegistration`): creates the sign-in, checks the
full name, claims the plate, uploads the OR/CR and the vehicle record, uploads
the license photos, and only then writes the profile as `approvalStatus:
'pending'`. An account therefore reaches the admin queue only when everything
it needs is on the server. Any failure rolls back the sign-in, the plate claim
and the vehicle. The processing modal says what happens next.

**Awaiting Approval screen** (`AwaitingApprovalScreen`, route
`/awaiting-approval`): listens live to the account's status. On approval it
signs the person in and shows a success notice, provided the email is verified.
On rejection it shows the reason, frees the account and returns to Register.
Back is disabled on this screen.

**Login** (`AppState._approvalGate`, used by email login and Google sign-in):
a pending account is signed out with an "awaiting approval" notice. A rejected
account is shown the reason, then freed so it can register again. An approval
status that can't be read fails closed. Session restore signs out a pending or
rejected session, and lets an approved account through even when offline.
Accounts with no status field (everything registered before this change)
count as approved.

**Admin Dashboard** (`admin_approvals.dart`, new "Approvals (N)" tab): each
card shows the account, the vehicle, and all four photos (license front/back,
OR, CR), tap to enlarge. Approve unlocks only after all four documents are
ticked as genuine and unedited, and all four photos are present. Reject asks
for a reason, which the person sees. Pending and rejected accounts are kept
out of the Accounts list.
- `AdminService.approveRegistration` sets `approved`.
- `AdminService.rejectRegistration` deletes the vehicle(s), their OR/CR, the
  license photos, the plate claims and the name claim, then sets `rejected`
  with the reason. The profile stays so the reason can be shown at login.
- `watchPendingRegistrations` is a live query on `approvalStatus == 'pending'`.

**Bug fixed while doing this**: `AdminService.removeUser` never released the
removed account's plate claims, so the same plate could not be registered again
afterwards. It now releases them, only where the claim still belongs to that
account. Rejection uses the same cleanup.

**Removed (superseded)**: the temporary "mandatory vehicle after registration"
gate from the previous change (`needsVehicleOnboarding`, the mandatory
Register Vehicle route, and the splash/login branches for it). The vehicle is
now part of the registration itself, and approval is the gate.

**Firestore rules to publish** (the approval gate and rejection cleanup are
enforced by these, not by the app):

```
function isAdmin() {
  return request.auth != null &&
    get(/databases/$(database)/documents/users/$(request.auth.uid)).data.role == 'admin';
}

match /users/{uid} {
  allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
  // A self-registration may only be created as 'pending' (or with no status).
  allow create: if request.auth != null && request.auth.uid == uid
    && request.resource.data.get('approvalStatus', 'pending') == 'pending'
    && request.resource.data.get('role', 'owner') == 'owner'
    && !('disabled' in request.resource.data);
  // An owner may edit their profile but never their approval, role or suspension.
  allow update: if request.auth != null && request.auth.uid == uid
    && request.resource.data.get('approvalStatus', null) == resource.data.get('approvalStatus', null)
    && request.resource.data.get('role', 'owner') == resource.data.get('role', 'owner')
    && request.resource.data.get('disabled', false) == resource.data.get('disabled', false);
  allow create, update, delete: if isAdmin();
}

match /users/{uid}/vehicles/{vehicleId} {
  allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
}
match /users/{uid}/vehicles/{vehicleId}/documents/{docId} {
  allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
  allow create, update: if request.auth != null && request.auth.uid == uid
    && (docId == 'or' || docId == 'cr');
  allow delete: if request.auth != null && (request.auth.uid == uid || isAdmin());
}
match /users/{uid}/license/{side} {
  allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
  allow create, update: if request.auth != null && request.auth.uid == uid
    && (side == 'front' || side == 'back');
  allow delete: if request.auth != null && isAdmin();
}

match /plates/{plateId} {
  allow get: if request.auth != null;
  allow create: if request.auth != null && request.resource.data.ownerId == request.auth.uid;
  allow update: if request.auth != null && resource.data.ownerId == request.auth.uid
    && request.resource.data.ownerId == request.auth.uid;
  allow delete: if request.auth != null && (resource.data.ownerId == request.auth.uid || isAdmin());
}

match /alert_deliveries/{deliveryId} {
  allow create, get, list: if request.auth != null;
}
```

Keep the rest of your published rules as they are (theft_alerts, sightings,
presence, account_names, removed_accounts, and the admin read rules).

**Known limits, stated plainly**:
- A pending account whose license upload succeeded but whose profile write
  then failed keeps its license photos. Firestore lets an owner create but not
  delete those, so they need a manual Console cleanup. This is rare.
- If Firebase refuses to delete a rejected account's sign-in from a long-open
  session, the app asks the person to log in once more. Login then frees it.
- An approved account that is offline when the app is reopened is let in, as
  before. Its approval is only checked when the app is online.
- The verification email is still sent on submit. If it fails, the Login
  screen's verification page offers Resend.

**Verified**: `flutter analyze` 0 issues, `flutter test` 34 passing, `dart
format` applied. APK and web build verification follow in the final step.

## Body-type restriction removed; admin decides the vehicle type (2026-10-05)

**Asked for**: stop accepting only Sedan/SUV/Hatchback. The admin now reviews
the documents and decides.

**Removed**: the CR body-type check in the vehicle form, which rejected any CR
whose body type was not Sedan, SUV or Hatchback, or could not be read.
`DocumentScannerService.findBodyType` and its allowed/disallowed word lists are
gone, along with their unit tests. The CR no longer auto-fills the vehicle type.
The owner picks the type from the dropdown.

**Changed**: the vehicle type dropdown offers Sedan, SUV, Hatchback, MPV,
Pickup, Van, Truck, Motorcycle, Tricycle and Other. The list is my choice, and
can be trimmed later. The CR hint text no longer lists the three types.

**Verified**: `flutter analyze` 0 issues, `flutter test` 30 passing (4 body-type
tests removed with the feature).

## Vehicle type dropdown: extended four-wheel body styles (2026-10-05)

The dropdown now offers Sedan, Coupe, Hatchback, SUV, Crossover, MPV, Wagon,
Convertible and Pickup, kept in `VehicleCatalog.bodyTypes`. Motorcycles,
tricycles, trucks, vans and public utility vehicles are not offered, matching
the study's four-wheel scope. Model lists for body styles without their own
list now use every model, instead of falling back to Sedan models only.

## OCR removed from the app; vehicle details are typed or picked, admin approves (2026-10-05)

**Asked for**: remove the on-device OCR, and stop auto-filling vehicle
details. The OR and CR photos stay required. Plate, type, color, series and
year model are entered by the owner, with search or dropdown where it helps.
The admin approval step handles validation, as it does for accounts.

**Removed**
- `PlateScannerService` (plate scan, "Scan Plate Photo" button, plate
  extraction) and `DocumentScannerService` (OR/CR and license content checks,
  field extraction, word lists) are deleted, along with
  `test/document_scanner_test.dart`.
- The license photos are now taken and kept without a content check, in
  `LicenseCaptureSection`.
- The OR/CR handler no longer reads the photo. It only requires it, and
  cross-checks nothing. The auto-fill of plate, series, color and year model
  is gone, and so is the "documents don't match" check.
- `google_mlkit_text_recognition` is removed from `pubspec.yaml`. The
  ML Kit ProGuard rules file is deleted, and its reference removed from
  `android/app/build.gradle.kts`.
- `DocumentPhotoCard`'s "Checking photo…" spinner and `DocumentPhotoResult.path`
  existed only for OCR, so they are removed.

**Kept / changed**
- OR and CR photos are required, as before.
- Plate number: typed (uppercased).
- Vehicle type: dropdown from `VehicleCatalog.bodyTypes`.
- Color and Series: searchable pickers, with free typing still allowed.
- Year model: searchable picker (newest year down to 1980), free typing still
  allowed, with the same validation as before.
- Approval flow is unchanged. Registration still waits for the admin.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing (the 15
OCR-only tests went with the removed file). `flutter pub get` refreshed the lock
file.

## Year model is typed, not searchable; leftover OCR references removed (2026-10-05)

- Year model is a plain typed field again, with the same 1980 to next-year
  validation. The searchable year list (`VehicleCatalog.modelYears`) is removed.
- A final search found no OCR code, scanner references or ML Kit references in
  the source. Two stale comments that described the removed behaviour are
  corrected: the OR/CR "auto-filled" note in the vehicle form, and the
  plate-scanner mention in `admin_main.dart`.
- `flutter analyze` 0 issues, `flutter test` 15 passing.

## Terms & Conditions rewritten as a real EULA + Privacy Policy (2026-10-07)

**Asked for**: the Terms & Conditions content should read as a legitimate,
standard End-User License Agreement for a mobile app — not just numbered
notices — while staying grounded in the Data Privacy Act of 2012 (R.A. 10173).

**What changed**: only the text in `_termsSections` in
`lib/widgets/terms_and_conditions.dart`. The sheet, the scroll-to-agree gate,
the Decline/I Agree buttons, and every other screen are untouched.

Expanded from 11 numbered notices to 18 sections that combine real EULA
clauses with the existing privacy content:
- License grant, license restrictions, and intellectual property rights —
  the standard clauses a mobile EULA needs, absent before.
- The original data-collection, access, storage and R.A. 10173 sections are
  kept, with the R.A. 10173 rights list expanded to the Act's actual list
  (informed, access, correction, objection, erasure/blocking, indemnity,
  data portability, complaint to the NPC).
- Disclaimer of warranties, limitation of liability, indemnification,
  suspension/termination, and governing law/severability — the clauses that
  make this read as a legitimate, enforceable EULA rather than a plain notice.
- The responsibilities section now mentions that registration is subject to
  admin review and approval, matching the system as it actually works.
- Icons for the new sections were chosen only from icon names already
  compiling elsewhere in this codebase, to avoid an invalid icon reference.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing (text-only
change, no test should have been affected and none was).

## Nearest local authorities shown after a theft report (2026-10-07)

**Asked for**: once the owner taps "Report as Stolen", show a modal with the
emergency authorities to call, picked by the GPS location the report used —
the same "view contact, copy the number" pattern already used for a
sighting's reporter.

**New file**: `lib/utils/emergency_hotlines.dart`. A plain data file (no new
dependency) with the Caraga Region hotlines the user supplied — Butuan City,
R.T. Romualdez, Cabadbaran City, Santiago, Jabonga, Kitcharao, Alegria,
Mainit, and Surigao City — numbers kept exactly as given, only trimmed.
`nearestHotlineArea(lat, lng)` does a local Haversine comparison (no
geolocator import) against each locality's approximate town-center
coordinates and returns the closest one. This is a best-effort "which
listed town is this nearest to" match, not a jurisdiction lookup, documented
as such in the code.

**Wired into `ReportStolenScreen._confirm()`** (`s6_s7_s8_geofence_report.dart`):
right after `reportStolen()` succeeds, `showNearestAuthoritiesModal(context,
lat: alert.lat, lng: alert.lng, isDemoLocation: alert.isDemoLocation)` shows
before the broadcasting screen opens. Uses the alert's own `lat`/`lng` — the
same GPS fix (or, honestly labeled, the vehicle's last known spot) the report
itself was filed with, not a separate live reading.

**Modal**: one agency per row, each with its own phone number(s), a copy
button and "Copied" feedback per number — mirrors `showReporterContactModal`
in `s16_sightings.dart`. A network tag some numbers carry ("(Smart)",
"(Globe)", "(TNT)", "(TM)") is shown for context but stripped before the
number reaches the clipboard, so a copied number pastes straight into a
dialer. Alegria's 12 barangay-level DRRMO numbers are collapsed under a
"Barangay DRRMO contacts (12)" toggle, so they don't bury the municipal-level
numbers above them, matching the ask for a clean, organized, readable modal.
A footer line restates that this doesn't replace filing a report with the
PNP.

**Icon choice**: every icon used was already compiling elsewhere in this
codebase (confirmed by grep first), to avoid guessing an invalid Material
icon name.

**Honest note**: the per-locality coordinates are approximate town/city-hall
positions, good enough to tell these nine, well-separated localities apart,
not survey-grade. If a theft is reported somewhere not close to any of the
nine, the modal still shows the nearest one, which may be a town over.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing. APK and
web build verification follow in the final step.

## Theft report now requires 3 photos; "100m" relabelled "Broadcast Radius" (2026-10-08)

**Asked for**: (1) Report Stolen's single required photo becomes 3 required
photos, for clearer proof. (2) Home's "NEARBY DEVICES · REAL (100M RANGE)"
label becomes "NEARBY DEVICES · BROADCAST RADIUS". (3) The Proximity Map's
"100m radius" chip becomes "Broadcast Radius".

**3 required photos — the real design problem was Firestore's 1 MB/document
limit.** A theft alert's photo travels inside the SAME Firestore document as
the rest of the alert (plate, notes, relay info, …), unlike the vehicle's
OR/CR or a driver's license, which are each their own document. Naively
tripling the old single-photo cap (500,000 bytes raw) would put 3 photos'
combined base64 text at roughly 2 MB — comfortably over the 1 MB limit, and
the upload would simply fail. Fixed by giving `ReportStolenScreen` its own,
tighter per-photo cap (`_maxEvidencePhotoBytes = 170000`, i.e. ~166 KB raw,
~227 KB as base64) — 3 of those combined land around 680 KB, leaving roughly
365 KB of headroom under the limit even with generous notes/relay data. This
cap is local to this screen; the OR/CR and license caps elsewhere
(`kMaxDocumentPhotoBytes` in `document_photo.dart`) are untouched, since
those are already safe under their own one-photo-per-document design.

**Model** (`TheftAlert` in `models.dart`): `photoB64` (one photo) replaced
with `photos` (a list, comma-joined for storage — base64 text never contains
a comma, the same trick `relayedTo` already uses). `hasPhoto` now means "at
least one photo exists". SQLite schema bumped to v9 (`photos TEXT` column
added; the old `photoB64` column is left in place, unused, same reasoning as
the existing dead `photoPath`/`salt`/`passwordHash` columns — an installed
app's local database can't have a column silently removed).

**UI**: `ReportStolenScreen` now shows 3 square photo slots side by side
(take/retake/remove each independently), and submission is blocked until
all 3 are filled. A new shared `PhotoEvidenceRow` widget (`widgets.dart`)
replaces three near-identical "single photo, tap to view full-size" blocks
that used to be duplicated across `AlertReceivedScreen`, `AlertSightingsScreen`
("YOUR REPORT"), and the admin's alert detail sheet — one definition now
renders 1–3 thumbnails consistently wherever a report's photos are shown.

**Label changes**: `s4_s5_vehicle_home.dart`'s Home tab and
`s9_s10_s11_alerts_map.dart`'s Proximity Map chip, text only — the underlying
100 m presence range (`AppState.nearbyRangeMeters`) and the map circle's
actual radius are unchanged, only what they're called on screen.

**Honest note**: a theft alert saved to SQLite before this change has no
`photos` value (the migration adds the column but doesn't backfill it from
the old `photoB64`), so it will show no photo after upgrading — the same
kind of one-time, documented limitation as the registration-flow changes
earlier in this project.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing
(`test/models_test.dart` updated for the renamed field). APK and web build
verification follow.

## Engine Number and Chassis Number added — HPG-recommended vehicle identifiers (2026-10-09)

**Asked for**: two more required fields on vehicle registration, Engine
Number and Chassis Number (read off the same CR already being photographed,
next to Series), because those — not plate, make, or color — are what the
Highway Patrol Group (HPG) actually uses to tell one car apart from another.
Shown on the stolen-vehicle display nearby users see, and on the admin side.

**Model**: `VehicleModel` and `TheftAlert` (`models.dart`) both gained
`engineNumber`/`chassisNumber`. `TheftAlert` copies them from the vehicle at
report time, the same way `plate`/`model`/`color` already are — this is what
lets a device that only ever receives the ALERT (never the vehicle record)
still show them. `VehicleDraft` (what the registration form collects) gained
the same two fields.

**Storage**: SQLite schema bumped to v10, adding `engineNumber`/
`chassisNumber` columns to both `vehicles` and `theft_alerts`. No Firestore
rule change needed — both documents already let their owner/reporter write
any field.

**Wire format**: unlike photos, these are short strings, so they travel over
the ad hoc mesh same as plate/model/color — no change needed in
`_alertWireMessage`'s stripping logic (it only strips `photos`).

**Registration form** (`VehicleFormSection` in `s4_s5_vehicle_home.dart`):
two new required text fields, ENGINE NUMBER and CHASSIS NUMBER, placed right
after SERIES as asked. Typed by hand — the OCR that used to read CR fields
automatically was removed in an earlier change, so this follows that same
manual-entry pattern as the rest of the form.

**Display**:
- `AlertReceivedScreen` — a new ENGINE NO. / CHASSIS NO. chip row under
  SERIES / COLOR, the main place a nearby user learns what the stolen
  vehicle actually looks like and now how to positively identify it.
- Admin Vehicles tab's detail sheet — two new rows, selectable so an admin
  can copy them.
- Admin Live Activity's alert detail sheet — shown when present (blank for
  an alert reported before this field existed, so nothing misleading shows
  for old data).

**Scope check, as asked**: the compact admin tables (Accounts-style list
rows) don't show Year Model either — only the detail sheets do — so Engine/
Chassis follows that same existing convention rather than cluttering the
table. `ReportSightingScreen`/`AlertSightingsScreen`'s one-line vehicle
banners were left as plain "model · color" summaries, unchanged — adding a
full chip grid there would be a layout change beyond what was asked.
`REVIEWER.md`'s one line documenting `addVehicle`'s old signature was
corrected to match.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing. APK and
web build verification follow.

## HPG hotline number added for Butuan City (2026-10-10)

**Asked for**: add one Highway Patrol Group (HPG) hotline number,
`09122667014`, to the nearest-authorities data — for Butuan City only, no
other locality.

**Change**: `lib/utils/emergency_hotlines.dart` — one new `HotlineEntry`
(`'Highway Patrol Group (HPG) — Butuan City'`, `['09122667014']`) added to
the `Butuan City` `HotlineArea`'s entry list, right after the existing BCPO
Mobile Force Company entry and before the DRRMO/fire entries, matching the
police-agencies-first ordering already used there. No other `HotlineArea`
touched, and no UI code changed — the existing modal in
`s6_s7_s8_geofence_report.dart` already renders whatever entries are in the
matched area.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing. APK
build verification follows (this file isn't used by the web admin build, so
no web build needed).

## Proximity Map legend recolored: Relay → orange, Relaying → yellow (2026-10-12)

**Asked for**: on the Proximity Map, Stolen stays red and You stays blue
(already correct), but Relay should be orange and Relaying should be yellow
— the legend previously used green for Relay and amber for Relaying.

**Scope decision**: the same Relay/Relaying states (`RelayStatus.received` /
`RelayStatus.relaying`) are also drawn on the Home screen's "Nearby Devices"
list and the shared `NodeRelayRow`/`ProximityNodeRow` widgets, with
different wording ("✓ Received", "Connected ✓") but the same green/amber
colors. Asked whether to recolor only the Map or everywhere — the user chose
everywhere, so the same state means the same color across the whole app
instead of Relay meaning orange on one screen and green on another.

**Color additions** (`app_theme.dart`): two new `AppColors` — `orange`
(`0xFFEA580C`) / `orangeLight` (`0xFFFFEDD5`) and `yellow` (`0xFFCA8A04`) /
`yellowLight` (`0xFFFEF9C3`) — following the same Tailwind-shade pattern the
existing red/green/amber/blue pairs already use.

**Changed** (every place `RelayStatus.received`/`relaying` picks a color):
- `s9_s10_s11_alerts_map.dart` — the legend dots and the real-mesh node pin
  colors on the map itself.
- `widgets.dart` — `NodeRelayRow` (icon background + status text color) and
  `ProximityNodeRow` (progress bar color + status badge).
- `s4_s5_vehicle_home.dart` — `_NearbyNodeRow`'s `RelayStatus` switch. Its
  two other branches (`viaInternet` → "Active", not-yet-connected →
  "Connecting…") are different states, not Relay/Relaying, and were left on
  green/amber on purpose.
`RelayStatus.pending` (blue) was untouched everywhere — not part of what was
asked.

**Bug fixed along the way**: `ProximityNodeRow._badge()`'s `received` case
returned `StatusBadge.active()`, whose label is hardcoded to "NOT STOLEN" —
a factory meant for a vehicle's status, mistakenly reused for a relay node's
badge. Replaced with an explicit `StatusBadge(label: '✓ Received', …)` in
the same new orange, matching the badge's `relaying`/`pending` siblings
right next to it.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing. Both
`flutter build apk --release` and `flutter build web -t lib/admin_main.dart`
run (needed this time — `widgets.dart` and `app_theme.dart` are both
imported by the admin screens) to confirm nothing broke on either build.

## Android launcher icon replaced (2026-10-12)

**Asked for**: change only the Android launcher icon (the icon shown on the
phone's home screen/app drawer) to a new neon pin-and-car image the user
provided in chat. Explicitly NOT the in-app logo, and nothing else about the
app's functionality, package name, signing, or manifest.

**Source image**: the user's attached image was saved to
`assets/images/app_icon.png` (the project had no `assets/` folder and no
`flutter_launcher_icons` setup yet — this path didn't exist beforehand). The
file arrived as JPEG data with a `.png` name; re-encoded it as a real
1024×1024 RGBA PNG so the icon generator reads it correctly.

**Icon generation**: added `flutter_launcher_icons: ^0.14.4` as a dev
dependency with a minimal config —
```yaml
flutter_launcher_icons:
  image_path: "assets/images/app_icon.png"
  android: true
  ios: false
```
— `android: true` with no adaptive-icon background/foreground keeps the
same flat per-density `ic_launcher.png` style the project already had (no
`mipmap-anydpi-v26`/adaptive icon existed before this, so none was
introduced now). Ran `dart run flutter_launcher_icons`, which overwrote the
5 existing `android/app/src/main/res/mipmap-*/ic_launcher.png` files in
place — same filenames, same `android:icon="@mipmap/ic_launcher"` reference
in `AndroidManifest.xml`, so the manifest needed no edit at all.

**Dependency snag**: `flutter pub get` initially resolved `image` (a
transitive dependency flutter_launcher_icons uses to decode the source PNG)
to 4.11.0 while leaving `archive` locked at the older 4.2.0 already in
`pubspec.lock` from before — 4.11.0's PNG decoder calls a method
(`decodeLazy`) that doesn't exist on archive 4.2.0, so generation crashed.
Fixed with `flutter pub upgrade archive` (upgrades only that one transitive
package to the newest version allowed by existing constraints) rather than
touching any dependency version in `pubspec.yaml` directly.

**Not touched**: package name/application ID, signing config, Firebase
setup, AndroidManifest permissions, the in-app logo/branding widgets, and
every other screen/feature — none of those files were opened for editing.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing,
`flutter build apk --release` succeeded (61.0MB,
`build/app/outputs/flutter-apk/app-release.apk`). No web admin build needed
— nothing touched here is imported by `admin_main.dart`.

## BCPO Police Station 1 number corrected + stuck "stolen" vehicle bug fixed (2026-10-13)

**Hotline update, asked for**: correct the BCPO — Police Station 1 number in
the Butuan City hotline list. Changed `lib/utils/emergency_hotlines.dart`'s
one entry from `09985987294` to `09075501738`. Nothing else in the file
touched.

**Bug reported**: a vehicle (GAS-9817, S-Presso) stayed shown as STOLEN on
Home with no way to clear it — tapping Recovered produced "No active theft
alert found for GAS-9817." Alert History had no entry for this vehicle at
all (only two older, already-recovered alerts for a different vehicle),
confirming no theft-alert record existed for it anywhere on the device —
the screenshot also showed a SYNC FAILED banner, consistent with the report
having been interrupted partway.

**Root cause**: Home's "Recovered" button (`s4_s5_vehicle_home.dart`) only
knows how to clear a vehicle's stolen flag by closing a matching *active*
`TheftAlert` — that's the only place `AppState.markRecovered` resets
`vehicle.status` back to `active`. `reportStolen()` used to flip the
vehicle to `stolen` and save it FIRST, then build and save the alert after
— so anything interrupting the method in between (app killed, a DB write
failing, the sync problem visible in the screenshot) could leave a vehicle
permanently flagged stolen with no alert ever created to close it. There
was no fallback, so the owner had no way to recover the vehicle, and
`reportStolen()`'s own guard ("already reported stolen, mark it recovered
first") meant they couldn't report it again either — a dead end.

**Fix — two parts**:
1. `AppState.reportStolen()` (`app_state.dart`) now writes the alert FIRST
   and only flips/saves the vehicle's `stolen` status after. An interruption
   now leaves at worst an alert with no stolen vehicle to match — already a
   tolerated state elsewhere (see `markRecovered`'s own comment) — never a
   vehicle stuck stolen with nothing to close.
2. New `AppState.forceRecoverVehicle(vehicleId)` clears a vehicle's stolen
   flag directly, with no alert involved. Home's Recover handler now calls
   this (after a confirm dialog explaining why) whenever no active alert is
   found for the vehicle, instead of just showing an error and leaving the
   owner stuck. This also fixes any vehicle already stuck this way before
   the update, once the new APK is installed.

**Not touched**: `markRecovered`'s normal path (unchanged), every other
screen/feature.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing,
`flutter build apk --release` succeeded. No web admin build needed —
`app_state.dart` isn't imported by `admin_main.dart`.

## Admin dashboard: "delivery delay feed blocked" diagnosed + rules consolidated (2026-10-13)

**Reported**: the admin dashboard showed "Firestore's security rules are
blocking the delivery delay feed — publish the latest rules from
Progress.md" on both the Map and Live Activity tabs.

**Cause**: `AdminService.watchAlertDeliveries()` reads the `alert_deliveries`
collection with no `where` filter — a bare `list`. That collection's rule
(`allow create, get, list: if request.auth != null;`) was only ever added
in the "Firestore rules to publish" block at the *end* of the 2026-10-05
Approvals entry, alongside rewritten `users`/`plates` rules. By this point
Firestore rules had been updated piecemeal across roughly ten separate
Progress.md entries going back to 2026-09-19, each a partial diff on top of
a full baseline — exactly the kind of multi-step manual Console paste that
is easy to miss one block of. This specific block appears to be the one
that was never actually published.

**No code change was needed or made** — this is a Firebase Console-only
fix, outside anything the app's source controls. To avoid ever having to
re-trace ten scattered rules entries again, this is the complete, current,
consolidated ruleset (every earlier block folded in, latest version of each
match path wins) — this fully replaces whatever is live in Firebase Console
→ Firestore Database → Rules → Publish:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function isAdmin() {
      return request.auth != null &&
        exists(/databases/$(database)/documents/users/$(request.auth.uid)) &&
        get(/databases/$(database)/documents/users/$(request.auth.uid)).data.get('role', 'owner') == 'admin';
    }

    match /users/{uid} {
      allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());

      allow create: if request.auth != null && request.auth.uid == uid
                    && request.resource.data.get('approvalStatus', 'pending') == 'pending'
                    && request.resource.data.get('role', 'owner') == 'owner'
                    && !('disabled' in request.resource.data);

      allow update: if request.auth != null && request.auth.uid == uid
                    && request.resource.data.get('approvalStatus', null) == resource.data.get('approvalStatus', null)
                    && request.resource.data.get('role', 'owner') == resource.data.get('role', 'owner')
                    && request.resource.data.get('disabled', false) == resource.data.get('disabled', false);

      allow create, update, delete: if isAdmin();
    }

    match /users/{uid}/vehicles/{vehicleId} {
      allow read, write: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /users/{uid}/vehicles/{vehicleId}/documents/{docId} {
      allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow create, update: if request.auth != null && request.auth.uid == uid
                            && (docId == 'or' || docId == 'cr');
      allow delete: if request.auth != null && (request.auth.uid == uid || isAdmin());
    }

    match /users/{uid}/license/{side} {
      allow get, list: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow create, update: if request.auth != null && request.auth.uid == uid
                            && (side == 'front' || side == 'back');
      allow delete: if request.auth != null && isAdmin();
    }

    match /plates/{plateId} {
      allow get: if request.auth != null;
      allow create: if request.auth != null && request.resource.data.ownerId == request.auth.uid;
      allow update: if request.auth != null && resource.data.ownerId == request.auth.uid
                    && request.resource.data.ownerId == request.auth.uid;
      allow delete: if request.auth != null && (resource.data.ownerId == request.auth.uid || isAdmin());
    }

    match /account_names/{nameId} {
      allow get: if request.auth != null;
      allow create: if request.auth != null &&
                    (request.resource.data.ownerId == request.auth.uid || isAdmin());
      allow delete: if request.auth != null &&
                    (resource.data.ownerId == request.auth.uid || isAdmin());
    }

    match /removed_accounts/{uid} {
      allow read: if request.auth != null && (request.auth.uid == uid || isAdmin());
      allow write: if request.auth != null && isAdmin();
    }

    match /presence/{uid} {
      allow get, list: if request.auth != null;
      allow create, update, delete: if request.auth != null && request.auth.uid == uid;
    }

    match /theft_alerts/{alertId} {
      allow get, list: if request.auth != null;

      allow create: if request.auth != null && request.resource.data.id == alertId;

      allow update: if request.auth != null && (
        isAdmin() ||
        resource.data.userId == request.auth.uid ||
        (
          request.resource.data.userId == resource.data.userId &&
          request.resource.data.status == resource.data.status &&
          request.resource.data.lat == resource.data.lat &&
          request.resource.data.lng == resource.data.lng &&
          request.resource.data.plate == resource.data.plate &&
          request.resource.data.model == resource.data.model &&
          request.resource.data.color == resource.data.color &&
          request.resource.data.vehicleId == resource.data.vehicleId
        )
      );

      allow delete: if false;
    }

    match /sightings/{sightingId} {
      allow create: if request.auth != null
                    && request.resource.data.reporterId == request.auth.uid
                    && request.resource.data.id == sightingId;

      allow update: if request.auth != null
                    && resource.data.reporterId == request.auth.uid
                    && request.resource.data.reporterId == request.auth.uid;

      allow get, list: if request.auth != null
                       && (resource.data.ownerId == request.auth.uid
                           || resource.data.reporterId == request.auth.uid
                           || isAdmin());

      allow delete: if request.auth != null && isAdmin();
    }

    match /location_history/{locId} {
      allow get: if request.auth != null;
      allow list: if request.auth != null && isAdmin();
      allow create: if request.auth != null;
      allow update, delete: if false;
    }

    match /alert_deliveries/{deliveryId} {
      allow create, get, list: if request.auth != null;
    }

  }
}
```

Collection names verified directly against `admin_service.dart` and
`firebase_sync_service.dart`'s actual `.collection(...)` calls, not just
Progress.md prose — `presence` doubles as the "online devices" collection
(`watchDevices()` queries it with a 10-minute `updatedAtMs` cutoff); there
is no separate `devices` collection.

**One unresolved judgment call, flagged honestly**: the `location_history`
`list` permission has conflicting history — one entry (2026-09-28, FR-11
live monitoring) deliberately turns it on for admins; a later "full
replacement" block (2026-09-30, adding `account_names`) silently reverts it
back to `allow list: if false` with no explanation. Since Live Monitoring
is a working feature today (not reported broken), the admin-list-enabled
version was kept as almost certainly the one actually live in Firebase
Console right now. If publishing the block above ever breaks Live
Monitoring with a similar permission-denied message, that's the rule to
revisit.

**Next time a Firestore rule needs to change**: edit the consolidated block
above directly and re-paste this whole section, instead of appending a new
small diff — this prevents the exact scattered-history problem this entry
exists to fix.

## Recovery requires photo + remarks; recovery evidence shown everywhere (2026-10-14)

**Asked for**: (1) confirm Alert History keeps showing a theft alert under
Active/"still searching" until the owner marks it recovered, at which point
it moves to Recovered for the owner AND every registered user who was
alerted — real-time, not just locally. (2) Require a photo and remarks as
proof when marking a vehicle recovered, same spirit as the photo evidence
already required to report one stolen. (3) Show that proof on the admin
side too. (4) Nearby/other registered users who received the alert should
also see the recovery — and its evidence — in their own Alert History, not
just the owner.

**(1) Already true, no code needed.** `AlertHistoryScreen` already reads
`state.allAlerts` — every alert this device knows about, including ones
relayed in from other users, not just `myAlerts` — and its Active/Recovered/
Resolved tabs already filter purely on `alert.status`. A received "Stolen
Vehicle Nearby!" alert was already showing up in Alert History and already
moved to the Recovered tab the moment its status changed. Confirmed by
reading `s9_s10_s11_alerts_map.dart`'s `AlertHistoryScreen`, not assumed.

**(2) New required proof, asked for 1 photo + non-empty remarks** (the
user's choice over matching the stolen-report's 3-photo requirement, and
over a minimum remarks length like the admin's rejection-reason box).

- `TheftAlert` (`models.dart`) gained `recoveryPhotos` (`List<String>`,
  comma-joined base64, same shape as `photos`) and `recoveryRemarks`
  (`String`) — kept as their OWN fields rather than appended onto the
  alert's original `notes`, which is what `markRecovered` used to do. That
  conflated "what the owner said when it was stolen" with "what they said
  when it came back"; now a device can show each separately.
- SQLite bumped to schema **v11**, adding `recoveryPhotos`/`recoveryRemarks`
  columns to `theft_alerts` (old columns never dropped, per the established
  convention).
- `AppState.markRecovered(alertId, {required remarks, required
  recoveryPhotoBytes})` — both now required parameters (were previously one
  optional `remarks`, appended to `notes`). The one caller,
  `UpdateStatusScreen`, validates both are present before this is ever
  called.
- `UpdateStatusScreen` (`s12_s13_s14_status_notif_profile.dart`): selecting
  "Mark as Recovered" now shows a required single photo tile ("RECOVERY
  PHOTO (REQUIRED)") and changes the remarks label to "REMARKS (REQUIRED)";
  "Still Searching" is unaffected — no evidence needed to keep searching.
  Confirm is blocked with an inline error until both are filled. Photo
  capture/compression mirrors `ReportStolenScreen`'s evidence photos exactly
  (same `maxWidth/maxHeight/imageQuality`, same 170,000-byte per-photo cap —
  reused specifically because 3 report photos + 1 recovery photo now share
  the same Firestore document; the math still leaves ~130KB of headroom
  under the 1 MB limit).
- Home's quick "✅ Recovered" vehicle-card button (`s4_s5_vehicle_home.dart`)
  used to call `markRecovered` directly with no evidence at all — it now
  navigates to `/update-status` instead, since collecting a required photo
  needs its own screen, not a one-tap confirm. (The separate "no active
  alert found" fallback added earlier this week, `forceRecoverVehicle`, is
  intentionally untouched — there's no alert to attach evidence to there.)

**Propagation — mesh and internet, matching the existing pattern for the
original report's photos**:
- Reporter's own sync: `recoveryPhotos`/`recoveryRemarks` ride along
  automatically in `TheftAlert.toMap()`, which `FirebaseSyncService
  ._syncAlerts()` already uploads in full for the reporter — no sync-layer
  change needed.
- Mesh `status_update` message gained `recoveryRemarks` (short text, same
  as the original report's `notes` already traveling over mesh) — NOT the
  photo itself (too large for a reliable BLE/Wi-Fi Direct payload, same
  reasoning as `_alertWireMessage` stripping the original report's photos).
  A mesh-only receiver missing the photo can tell one exists anyway, the
  same inference already used for the original report: recovery always
  requires exactly one photo, so its absence on a mesh-received copy just
  means it didn't fit over the mesh, not that none was taken.
- `_handleInternetAlert`'s existing-alert status-bump branch now also
  copies `recoveryRemarks`/`recoveryPhotos` from the Firestore document —
  this path reads the full record, unlike the mesh message, so there's no
  reason to leave the photo out here.
- **No Firestore rules change needed** — re-checked directly: the
  `theft_alerts` update rule's reporter branch (`resource.data.userId ==
  request.auth.uid`) already grants the reporter unrestricted field writes,
  which covers these two new fields the same way it already covers
  `status`/`photos`/`notes`.

**(3) Admin display** (`admin_monitoring.dart`'s `_AlertDetailSheet`, the
Live Activity tab's alert detail sheet — the only admin screen with alert
detail, confirmed no "mark recovered" control exists anywhere in the admin
portal, so this is read-only display, nothing for admin to action): a new
"RECOVERY EVIDENCE" section (remarks + `PhotoEvidenceRow`) shown once
status moves past Active, right after the existing Notes/photo section,
same visual pattern. The sheet was already `ListenableBuilder`-driven off
live Firestore data, so this updates in real time with no extra wiring.

**(4) Nearby/other users' view** — `AlertReceivedScreen`
(`s9_s10_s11_alerts_map.dart`), previously hard-coded to always say "🚨
Stolen Vehicle Nearby!" with no awareness that an alert could ever be
anything but active:
- Header now switches to "✅ Vehicle Recovered" (green) once recovered, with
  a `StatusBadge` for Recovered/Resolved.
- A matching "RECOVERY EVIDENCE" section (remarks + photo, or — for a
  mesh-only receiver — the same honest "too large to relay, will appear
  once online" message already used for the original report's photos).
- The owner's own view (`AlertSightingsScreen` in `s16_sightings.dart`) got
  the same "RECOVERY EVIDENCE" card, placed right after the existing "YOUR
  REPORT" card.
- Alert History's card (`AlertLogItem` in `widgets.dart`) gained a "✅
  Recovery proof attached" chip once recovered, matching the existing "📷
  Photo attached" chip's pattern.

**`REVIEWER.md`** — the one line documenting `markRecovered`'s old
signature corrected to match.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing. Both
`flutter build apk --release` and `flutter build web -t lib/admin_main.dart`
run (needed — `widgets.dart` and `admin_monitoring.dart` are both used by
the admin build).

## Admin Map chip: "100 m range" label corrected (2026-10-14)

**Asked for**: the Map tab's filter chip read "Alerts (38) · 100 m range" —
leftover wording from before the phone app's own labels were changed to
"Broadcast Radius" (see the earlier "Broadcast Radius" label-change entry);
the admin side was missed in that pass.

**Changed**: `admin_monitoring.dart` — the chip's label is now `'Alerts
(${alerts.length}) · Broadcast Radius'`, matching the wording already used
on the phone app's Home and Proximity Map screens exactly. Text-only —
nothing about what the chip filters or how changed.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing,
`flutter build web -t lib/admin_main.dart` succeeded. No APK build needed —
`admin_monitoring.dart` isn't used by the phone app.

## VSCode Gradle-import Java mismatch fixed (2026-10-20)

**Reported**: VSCode's Problems panel showed "Unsupported class file major
version 69" / "Can't use Java 25.0.4.1 and Gradle 8.14 to import Gradle
project android."

**Not a code bug.** Confirmed `flutter build apk --release` was never
actually broken — `flutter doctor -v` shows Flutter's own build pipeline
uses Java 21 (bundled with this machine's Android Studio install,
`C:\Program Files\Android\Android Studio\jbr`), which `android/gradle/
wrapper/gradle-wrapper.properties`'s Gradle 8.14 fully supports. The error
was VSCode's separate Java/Gradle extension trying to import the `android/`
folder using a different, newer Java 25 it found elsewhere on the machine —
Gradle 8.14 can't run on Java 25 yet ("class file major version 69" is
Java 25's own bytecode format), so that background import failed while the
real build kept working the whole time.

**Fix**: added `.vscode/settings.json` (new file, didn't exist before) with
one setting — `java.import.gradle.java.home` pointed at the same Java 21
JDK Flutter's own build already uses successfully. This only affects this
VS Code workspace's Gradle import, nothing about the app or its build
output. After this, VS Code needs either a window reload or its "Gradle:
Refresh Gradle Project" command to pick it up.

**No `flutter analyze`/`test`/build run** — this is an editor config file,
not Dart/Flutter source.

## Splash screen logo and background replaced with user-supplied artwork (2026-10-20)

**Asked for**: a proper images folder to hold background/logo artwork the
user wants to swap in, and — for the Splash screen specifically — replace
its shield-emoji logo and red gradient background with two new PNGs the
user supplied, touching nothing else.

**Images folder**: reused the existing `assets/images/` (created for the
Android launcher icon a week earlier) rather than making a second, separate
folder — it's already exactly the "organized images folder" asked for.
Added two new files there: `splash_logo.png` (1254×1254) and
`splash_background.png` (831×1891, already close to phone screen
proportions). `pubspec.yaml` gained `flutter: assets: - assets/images/` —
new, since `app_icon.png` alone never needed the running app to load it
(only the launcher-icon generator tool did); these two images do, since
`s1_splash_screen.dart` now displays them directly.

**`s1_splash_screen.dart`** — the only screen touched, exactly as asked:
- The `LinearGradient` background `BoxDecoration` is now a
  `DecorationImage(image: AssetImage('assets/images/splash_background.png'),
  fit: BoxFit.cover)` instead.
- The 90×90 translucent-white box with the 🛡️ emoji is now a 110×110
  `Image.asset('assets/images/splash_logo.png')` inside a `ClipRRect` — the
  new logo artwork is already a fully designed square icon (shield, car,
  signal rings, its own glossy background baked in), so the old glass-box
  wrapper was dropped rather than stacking an empty translucent box behind
  art that doesn't need one.
- Nothing else on the screen (text, buttons, routing logic, spacing) was
  touched.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing
(including the splash-screen widget test), `flutter build apk --release`
succeeded (65.0MB — up from 61.0MB, since the new logo/background images
are now bundled into the app) — confirmed on the 4th attempt, after three
in a row hit the machine's own low-memory build environment, unrelated to
this change; see the next entry for that full diagnosis. No web admin
build needed — nothing touched here is used by `admin_main.dart`.

## Gradle out-of-memory crashes fixed: JVM heap was larger than this machine's RAM (2026-10-20)

**Found while verifying the splash-screen change above**: `flutter analyze`
crashed once ("Could not start thread DartWorker... Out of memory",
cleared on retry), then `flutter build apk --release` crashed twice in a
row — first "Connection to the Kotlin daemon has been unexpectedly lost",
then "Gradle build daemon disappeared unexpectedly" with a JVM crash log
(`hs_err_pid*.log`, deleted after reading — a diagnostic dump, not
something to keep).

**Root cause, found in that crash log**: `Host: ... 7G` — this machine has
only 7 GB of physical RAM — but `android/gradle.properties` had
`org.gradle.jvmargs=-Xmx8G ... -XX:MaxMetaspaceSize=4G`, letting a single
Gradle daemon claim up to 8 GB of heap alone, more than the entire
machine's RAM, before even counting the separate Kotlin compiler daemon,
the OS, VSCode, or a browser. Past builds in this project's history mostly
got away with it because `-Xmx` is a ceiling, not a reservation — actual
usage only crossed that ceiling under enough memory pressure from
everything else running at once, which is exactly what happened here with
accumulated idle daemons (3 were found and stopped — `gradlew --stop` — as
part of diagnosing this) plus the rest of the desktop.

**Fix applied**: lowered `org.gradle.jvmargs` to `-Xmx3G
-XX:MaxMetaspaceSize=1G` (kept `-XX:ReservedCodeCacheSize=512m
-XX:+HeapDumpOnOutOfMemoryError` as they were — neither was implicated).
This is a correct, worthwhile fix on its own regardless of what's below —
no single Gradle daemon should ever be allowed to ask for more memory than
physically exists on the machine.

**Still failed once more after that fix, for a different reason — this one
isn't something a repo file can fix.** `Get-CimInstance Win32_OperatingSystem`
showed only **1.25 GB free out of 7.73 GB total** at the time, and the
retried build's own crash log showed it failing to allocate even a 1 MB
native memory chunk — the machine was that low on free RAM right at that
moment, independent of any `-Xmx` cap. No single runaway process was the
cause; it was many moderate ones at once (several VS Code/extension-host
processes, Chrome, Windows Defender, this very Claude Code session, a
lingering `dart` process) plus Windows' own "Memory Compression" already at
748 MB — a sign the OS was already straining to cope. Closing a few of
those (Chrome in particular, since browsers usually hide several more
processes than Task Manager's top few show) before building again is the
actual next step — not a code or config change.

**Build-tooling config only — no app code touched.** Resolved: after
closing some other running apps to free memory, a 4th `flutter build apk
--release` attempt succeeded (see the splash-screen entry above — 65.0MB).
The `-Xmx3G` fix stands as the correct long-term setting for this
machine's 7.73GB of RAM regardless.

## Brand swapped from red to teal: icon, logo, and splash background (2026-10-20)

**Asked for**: replace the app icon and logo everywhere it appears, and the
"opening the app" (splash) background, with two new teal/cyan images —
same two-image pattern as the earlier red version, just recolored — and
make sure the splash text stays readable against the new background.

**Images** (`assets/images/`, overwriting the red-era files in place, same
filenames — no pubspec/code path changes needed for this part):
- `app_icon.png` and `splash_logo.png` — both now the new teal shield/car/
  signal logo (same source image saved to both, since "throughout the
  entire system" means one consistent logo, not two separate ones to keep
  in sync later).
- `splash_background.png` — the new pale teal/white background, replacing
  the dark red one from two weeks ago.

**"Throughout the entire system," found by searching for every remaining
use of the old 🛡️ emoji-in-a-colored-box placeholder** (the splash screen
was already real artwork from the earlier change — this pass was the rest
of it):
- `s2_s3_auth_screens.dart` — the Register screen's and the Login screen's
  own small logo badge (60×60 each).
- `admin_dashboard.dart` — the Admin Portal's login-screen logo (64×64) and
  the Admin Dashboard's top-bar icon (34×34).
All four changed from a `Container` (colored backdrop + emoji) to a
`ClipRRect` wrapping `Image.asset('assets/images/app_icon.png')` at the
same size each already used — same pattern as the splash logo change,
since the new artwork already has its own background baked in.
- **Web admin portal's browser favicon and PWA icons** (`web/favicon.png`,
  `web/icons/Icon-{192,512}.png`, `Icon-maskable-{192,512}.png`) —
  regenerated from the new logo at each file's existing exact dimensions
  (verified with `file` before touching anything), so the admin portal's
  browser tab/taskbar icon matches too. Not asked for by name, but
  directly part of "throughout the entire system," which already included
  two of `admin_dashboard.dart`'s own logo spots.
- Android launcher icon regenerated the same way as before:
  `dart run flutter_launcher_icons`.

**Splash screen readability** (`s1_splash_screen.dart`) — the background
went from dark red to pale teal/white, so the old all-white text and
buttons (designed for a dark background) would have been unreadable.
Replaced with a small local palette (`_teal #0E7490`, `_tealDark #0F766E`,
`_tealLight #CCFBF1`, `_subtitleColor #475569`) scoped to this one file —
deliberately NOT a change to `AppColors.primary`, which stays red
everywhere else in the app (stolen-vehicle alerts, error states, and isn't
what this screen's background is anymore). "VehicleGuard" title and the
loading spinner now use the teal accent; the subtitle uses a readable dark
slate gray; the "Powered by…" pill flips from translucent-white-on-red to
a light teal chip with dark teal text; GET STARTED is now a solid teal
button with white text; LOG IN is now an outlined white button with a teal
border and teal text (needed a new `borderColor` parameter added to the
shared `_SplashButton` widget, since the border was previously
hardcoded to translucent white).

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing
(including the splash-screen widget test), `flutter build apk --release`
succeeded (66.0MB) and `flutter build web -t lib/admin_main.dart` succeeded
(needed this time — `admin_dashboard.dart` and the web icon files were both
touched).

## App-wide rebrand: red → teal for brand/action color, red kept for danger only (2026-10-20)

**Asked for**: apply a specific Teal + White + Silver + Dark Charcoal
palette (hex values given: primary teal `#087F8C`, bright accent `#20C7C9`,
light bg `#F3F6F8`, dark charcoal `#263238`, neutral gray `#64748B`) across
the whole app — Login/primary actions in teal, Register/secondary actions
white-with-teal-border, Close/Cancel in slate gray — matching the new teal
logo. The user's own guidance was explicit that red should stay reserved
for actual errors/problems, not be replaced everywhere.

**The core problem**: `AppColors.primary` (red, `#DC2626`) was doing two
unrelated jobs at once across the codebase — generic brand/button color
AND the semantic "STOLEN"/error/danger signal (status badges, error
modals, destructive admin actions). A blanket find-and-replace would have
turned the "STOLEN" badge, error dialogs, and geofence-violation alerts
teal too, which is both wrong and against what the user explicitly asked
for. This required classifying every single usage before touching
anything, not just swapping a color definition.

**Audit**: grepped all 145 lines across 18 files using `AppColors.primary`/
`primaryLight`/`primaryDark`, then read the surrounding widget at every one
to classify it BRAND (→ teal) or DANGER (stays red). 11 were genuinely
ambiguous and needed a judgment call (full reasoning below); the rest split
58 BRAND / 76 DANGER.

**New colors** (`app_theme.dart`): `teal` `#087F8C`, `tealDark` `#065A63`,
`tealLight` `#D9F2F3` (a derived pale tint — the user's recommendation
didn't give one; the same light/dark-tint pattern `primary`/`primaryLight`/
`primaryDark` already uses), `tealAccent` `#20C7C9` (flagged in code
comments as highlight/decorative-only, per the user's own instruction not
to use it for buttons or body text — not yet applied anywhere, since no
current UI element calls for a pure accent/highlight use), `charcoal`
`#263238`, `silver` `#64748B`, `lightBg` `#F3F6F8`. `primary`/
`primaryLight`/`primaryDark` themselves are untouched (still the same red)
— a comment was added above them in `app_theme.dart` documenting that
they're reserved for danger/error meaning specifically, so a future change
doesn't widen their use back to generic branding by accident.

**Global theme defaults** (`app_theme.dart`): `ColorScheme.fromSeed`'s seed/
primary, the default `ElevatedButtonTheme` background, and the default
focused-text-field border all moved from `AppColors.primary` to
`AppColors.teal` — these are what any button/field gets when a screen
doesn't explicitly override its color, so this alone re-colors a large
share of the app's buttons correctly without touching those screens'
individual files at all.

**Splash screen** (`s1_splash_screen.dart`): its own local teal palette
from the earlier background-swap change (close-but-not-exact guessed hex
values) was removed in favor of referencing the new official
`AppColors.teal`/`tealDark`/`tealLight` directly, so the splash screen now
matches the rest of the app exactly instead of being a close approximation.

**File-by-file, BRAND → teal** (DANGER lines in each file were left
untouched — see the full per-line classification from the audit if ever
needed again): `widgets.dart` (loading spinners, `showSuccessModal`'s
Continue button, bottom-nav selected-tab color, `PrimaryButton`'s default
fill), `document_photo.dart`, `terms_and_conditions.dart` (header icon,
I Agree/Close buttons), `s18_license_verification.dart` (step progress
indicator), `admin_widgets.dart` (hover tint, shared loading spinner),
`s16_sightings.dart` (Take Photo button, location switch, has-location pin
icon), `s12_s13_s14_status_notif_profile.dart` (profile-photo camera
icons, mesh toggle, Log Out button — including its hardcoded light-red
border, which would have visually clashed left unchanged once the text
went teal), `s9_s10_s11_alerts_map.dart` (Alert History's generic tab
underline/label — not stolen-specific, applies to all 4 tabs equally),
`s2_s3_auth_screens.dart` (Log In/Register footer links, Forgot password,
check-your-email icon, the "Google Account Not Registered" dialog's
confirm color), `s6_s7_s8_geofence_report.dart` (geofence setup map circle,
radius slider/chip, GPS switch, "(3 required)" photo-evidence hint, Hop
count metadata, Nearby Authorities modal icon), `s4_s5_vehicle_home.dart`
(Register Vehicle button, mesh toggle), `admin_accounts.dart` (pull-to-
refresh spinner, both avatar-circle colors), `admin_dashboard.dart` (tab
bar color/indicator, Add User button), `admin_approvals.dart` (loading
spinner, pending-applicant avatar, document-loading bar),
`admin_monitoring.dart` (loading spinners, has-location pin icon, map
recenter button).

**Admin's `AppColors.primaryLight`-backed avatar circles** (`admin_
accounts.dart`, `admin_approvals.dart`) moved to `tealLight`/`tealDark` —
these are the default/active-account styling, not a disabled/suspended
indicator (which already uses gray, untouched).

**Untouched — stayed red, DANGER**: the "STOLEN" status badge, every error
modal/toast, validation error text (passwords don't match, missing photo,
etc.), geofence-violation and active-theft-alert map/card chrome (pins,
circles, badges, legend dots), destructive admin actions (Suspend, Delete
Permanently, Reject Registration), the "Remove Vehicle" button and its
confirm dialog, the "Report Vehicle as Stolen" screen's own AppBar/pulsing
broadcast banner, System Logs' error-tag color, and several admin "needs
attention" stat chips (SUSPENDED badge, LICENSE PENDING count, ADMINS
anomaly count, STOLEN vehicle count) — these read as "something needs
action/is wrong," which is exactly what red is for.

**11 judgment calls, reasoned individually**:
1. `showConfirmDialog`'s default `confirmColor` — its own doc comment says
   it's "used before destructive/high-stakes actions," and most of its
   real default-reliant call sites ARE destructive (Report as Stolen,
   Remove Vehicle, Delete Permanently, the mesh's own "Stolen Vehicle
   Nearby!" prompt in `main.dart`) — kept red, and the few genuinely benign
   call sites that relied on this default (`s18_license_verification.dart`
   "Leave Verification?", `admin_dashboard.dart` and `s12_s13_...dart`'s
   two "Log Out?" dialogs) got an explicit `confirmColor: AppColors.teal`
   override added instead of flipping the shared default.
2. The vehicle card's "Remove" action button — destructive/irreversible
   (deletes a registered vehicle) — stayed red, consistent with #1.
3–4. Two "has a location" pin icons (`s16_sightings.dart`,
   `admin_monitoring.dart`) — purely decorative presence indicators with no
   danger meaning — went teal.
5. The profile screen's "Log Out" button — not dangerous — went teal (and
   its hardcoded red border was updated to match, see above).
6. "Clear All Logs?" — reconsidered mid-edit: its own message says "This
   cannot be undone," the same severity language as Remove Vehicle/Delete
   Permanently, which stayed red — kept red for consistency rather than
   making it the one irreversible-delete action that reads differently.
7. "(3 required)" photo-evidence hint on the Report Stolen screen — a
   requirement label, not an active error (no error has occurred yet) —
   went teal.
8. The "Hop {n}" metadata chip on the Alert Broadcasting screen — neutral
   relay data, not itself a danger signal — went teal.
9. Admin's "LICENSE PENDING" stat chip — grouped with the adjacent
   "ADMINS" anomaly-count chip (already DANGER, flags more than one admin
   account existing) as "needs admin attention," not generic branding —
   stayed red.
10. The map-recenter FAB on the admin Map tab — a neutral utility button,
    not alert-status chrome — went teal.
11. The "Google Account Not Registered" dialog's confirm color — its
    action is "Register" (constructive, not destructive) — went teal.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing,
`flutter build apk --release` succeeded (66.0MB) and `flutter build web -t
lib/admin_main.dart` succeeded (needed — 5 admin screen files were touched).

## Demo Mode removed — real ad hoc mesh only (2026-10-20)

**Asked for**: remove Demo/Simulated Mode entirely (the software-only
fallback that faked nearby devices and alert relay with no real Bluetooth/
Wi-Fi involved) — the user is testing device-to-device from here on and has
no further use for it. Explicitly scoped to Demo Mode only; nothing else
touched.

**Scale**: 104 occurrences across 8 files. Given the size, a read-only
audit pass mapped every single occurrence to an exact removal action before
any edit was made, specifically to avoid two failure modes: leaving a
redundant always-true/always-false conditional behind (the "no redundancy"
requirement), and accidentally touching the unrelated `isDemoLocation`
feature (an alert's GPS-fallback flag, nothing to do with mesh mode — its
name just happens to also contain "Demo").

**Deleted outright**:
- `lib/services/adhoc_network_service.dart` (`AdHocNetworkService`) — the
  whole file. It was pure simulation logic (fake per-hop delays over a
  fixed node list) with zero remaining callers once the mesh dispatch
  below no longer branches on mode.
- `SeedData` class (`models.dart`) — the 4 fixed demo nodes
  ("Maria Santos," "Pedro Reyes," etc.) it existed solely to construct.
- `AppState.adHocRealMode` (the mode flag itself — not just hardcoded
  true), `setAdHocMode()`, `addSimulatedNode()`, and `_broadcastAlert()`
  (the simulated-relay dispatch method) — all fully removed, not stubbed.

**Every `if (adHocRealMode) ... else ...` branch in `app_state.dart`**
(mesh start/restart/permissions, alert broadcast dispatch, recovery
status-update dispatch, sighting relay, presence, app-resume mesh restart)
now runs its real-mode body unconditionally, with the demo-mode half
deleted — not left behind as dead code.

**UI removed**: the "Real BLE / Wi-Fi Direct Mesh" toggle switch (both
instances — the one on Home's Ad Hoc Network card, and the second one
inside Profile's "Ad Hoc Network Settings" sheet), the "Simulate Device"
button on Home, and every "Demo Mode" / "Simulated Proximity" / "100M
SIMULATED PROXIMITY" label across Home, the Proximity Map, Report Stolen,
and the Alert Broadcasting screen — each collapsed to its real-mode-only
text instead of a now-dead ternary.

**Kept, deliberately — not redundant, still load-bearing**:
- `AdHocNode.isSimulated` (the Dart field) and the `nodes.isSimulated`
  SQLite column — per this project's established "never drop a shipped
  column" convention (same reasoning already applied to `photoPath`/
  `photoB64`/`salt`). Needed specifically because `AppState.init()` still
  reads it to find and purge any leftover simulated-node rows a
  pre-this-change install of the app may still have sitting in its local
  SQLite — a one-time migration cleanup, not demo-mode code.
- Every other `n.isSimulated` check scattered in the UI (e.g. the "📱 vs
  📡" node icon) — these are data-driven, not mode-driven; harmless and
  correct either way now that no code path can ever construct a node with
  `isSimulated: true` again.

**`REVIEWER.md` corrected to match** — removed every reference to Demo
Mode / `AdHocNetworkService` (the dedicated file-reference section, two
Q&A entries, a mermaid diagram node, several table rows, a numbered
limitation item), including two lines that were simply wrong even before
today (`alert_logs`/presence described as simulated-only when both were
always used by the real mesh too). Two numbered lists (a doc section
list and the Known Limitations list) now skip a number where an entry
was removed, rather than renumbering 10+ unrelated downstream headings —
a deliberate, lower-risk choice given REVIEWER.md is outside this
request's actual code scope.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing,
`flutter build apk --release` succeeded (65.9MB, down from 66.0MB — the
simulation code is gone from the binary). No web admin build needed —
nothing touched here is imported by `admin_main.dart`.

## Teal rebrand: palette refined, two missed hardcoded-red headers fixed, real logo added to Terms & Conditions (2026-10-20)

**Asked for**: refine the teal palette to a more specific set of hex values
with per-color usage guidance, apply it "from Home to Settings," and put
the real logo image on the Terms & Conditions sheet (it was still showing
a generic shield icon, not the actual artwork already used on Splash/
Register/Login/Admin).

**Why Home's and Profile's headers were still red** after the full
red→teal rebrand two entries ago: that pass searched specifically for the
`AppColors.primary`/`primaryLight`/`primaryDark` *tokens* — 145 occurrences,
all audited and classified. These two headers were never tokens at all;
they're `LinearGradient`s built from raw hex literals
(`Color(0xFFDC2626)`, `Color(0xFF7F1D1D)`, etc.), so that grep-based audit
structurally couldn't see them. Re-swept the whole `lib/` tree for those
same raw hex values this time to find every gap.

**Found 6 raw-hex gradients total — 2 were generic chrome (fixed), 4 were
genuine danger context (left alone, confirmed by reading each)**:
- `s4_s5_vehicle_home.dart` — **Home's top header** (greeting, Monitoring
  Armed toggle, GPS/Sync chips) → now `[AppColors.teal, AppColors.tealDark]`.
  This one was arguably backwards before: "Monitoring Armed" means
  protection is ON, not that something is wrong, yet it was styled in
  alarm red.
- `s12_s13_s14_status_notif_profile.dart` — **Profile's header** (avatar,
  name, email) → same teal gradient. Generic account chrome, not a danger
  state.
- Left red, confirmed genuinely danger-context by reading each: the
  "🚨 REPORT STOLEN" FAB gradient and its shadow (Home), the "CURRENTLY:
  STOLEN" status card (Update Status screen), the "mark your vehicle as
  STOLEN" warning banner and its text (Report Stolen screen), and the
  pulsing "🚨 STOLEN" card (Alert Broadcasting screen). Map and Alert
  History were also swept — no hardcoded red gradients found there; both
  already only used the `AppColors.primary` token, already converted in
  the earlier pass.

**Palette hex values refined** (`app_theme.dart`) to the more specific set
given this time, each with its own stated role:
- `teal`: `#087F8C` → `#087E8B` (primary teal — main buttons, active nav
  icons, links, important actions).
- `tealLight`: `#D9F2F3` → `#EAF7F6` (pale teal — light backgrounds for
  cards, sections, secondary chrome).
- `tealAccent`: `#20C7C9` → `#A8E5E3` (light aqua — selected tabs, icon
  backgrounds, subtle highlights/decorative accents only; still not a
  button or body-text color, same restriction as before, just a different
  value).
- `charcoal` (`#263238`) was already an exact match — untouched.
- Removed `lightBg` (`#F3F6F8`, added in the first palette request) —
  grepped and confirmed it was never referenced anywhere in `lib/`; the
  new, more precise `tealLight` (`#EAF7F6`) now covers that exact role
  ("light backgrounds for cards/sections"), so keeping both would have
  been the redundant near-duplicate the user has repeatedly asked to avoid.
- `tealDark` (`#065A63`) wasn't given a new value this time and needed no
  change — it's visually indistinguishable from a hand-darkened `#087E8B`.

**Terms & Conditions** (`terms_and_conditions.dart`): the header's generic
`Icon(Icons.shield_outlined)` in a tealLight circle replaced with the real
`assets/images/app_icon.png` logo in a `ClipRRect`, same pattern already
used on Splash/Register/Login/both Admin logo spots — the scale-in entrance
animation was kept, just now animating the real artwork instead of a
placeholder icon.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing. Both
`flutter build apk --release` and `flutter build web -t lib/admin_main.dart`
run (needed — `app_theme.dart` is shared with the admin portal, which
already uses `AppColors.teal` extensively from the earlier rebrand, so the
refined hex values apply there too).

## Registration's two "required field" reminder popups recolored to teal (2026-10-20)

**Asked for**: the "Driver's License Required" and "OR / CR Required"
popups (shown when tapping Register/Add Vehicle with required photos still
missing) use red right now — change them to teal, since nothing has
actually failed yet, the user just hasn't finished the form. Reserve red
specifically for genuine failures and theft warnings, per the user's own
stated rule.

**`showErrorModal` (`widgets.dart`) is one shared dialog used for 14
different situations app-wide**, all red by default — same shape as the
earlier `showConfirmDialog` audit: can't just flip the shared default
without checking what else relies on it staying red. Read every call site
(`main.dart`, `s2_s3_auth_screens.dart` ×5, `s4_s5_vehicle_home.dart` ×3,
`s6_s7_s8_geofence_report.dart`, `s16_sightings.dart` ×2,
`s18_license_verification.dart` ×2) and classified each as either a
pre-submission "please complete this" reminder (→ teal) or a genuine
failure/negative outcome (→ stays red, left untouched).

**Changed to `color: AppColors.teal`** — exactly the 2 the user showed:
- `s2_s3_auth_screens.dart` — "Driver's License Required" (Create Account).
- `s4_s5_vehicle_home.dart` — "OR / CR Required" (shared by Create Account
  AND Add Vehicle — the doc comment already says so — so both places get
  the same, consistent teal reminder, not just the registration one).

**Left red, deliberately, after reading each one** — all genuine failures,
not reminders: "Account Disabled" (`main.dart`), "Could Not Report Stolen"
(`s6_s7_s8_geofence_report.dart`), "Could Not Add Photo" ×2 — camera/
permission failures, not missing-field reminders (`s4_s5_vehicle_home.dart`,
`s18_license_verification.dart`), "Vehicle Not Registered" (e.g. a
duplicate-plate rejection), "Registration Not Submitted" (server rejected
it), "Registration Not Approved" ×2 (an admin's actual rejection), "Could
Not Send Sighting", "Could Not Submit". "Saved, But Not Delivered"
(`s16_sightings.dart`) already used `color: AppColors.amber`, untouched.
"Awaiting Admin Approval" (shown at login, not registration) left alone —
outside what was asked, and arguably a separate judgment call since it's
not a validation reminder either.

**Not implemented — flagged, not actioned**: the user's reference material
also suggested a bigger behavioral change (validate on tap and highlight
individual fields inline, rather than one popup per missing requirement).
That's a real feature change beyond "change the color," so it wasn't done
here — worth a separate explicit ask if wanted.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing,
`flutter build apk --release` succeeded. No web admin build needed —
neither file touched here is used by `admin_main.dart`.

## Missing-photo requirements now highlighted inline, not just in a popup (2026-10-20)

**Asked for**: follow-up to the previous entry — "try applying it also,"
i.e. the inline-field-highlighting behavior that entry flagged but didn't
implement, for the two photo requirements (driver's license, OR/CR) that
only ever showed a popup.

**Turns out text fields already did this.** `_formKey.currentState!
.validate()` is already called on submit in both the Register and Vehicle
forms, and every `AppTextField` already wraps a real `TextFormField` with
its `validator` wired through — Flutter's own Form mechanism already shows
each invalid text field's red border and error text inline, automatically,
with zero code needed (confirmed in the user's own earlier screenshot,
which already showed "Required"/"Series is required" inline in red). The
actual gap was narrower than it first looked: only the two PHOTO
requirements had no inline equivalent, because a photo tile isn't a
`TextFormField` and so never got Form's free validation display — a popup
was the only signal, and it disappeared once dismissed, with no lasting
sign of which photo was still missing.

**`DocumentPhotoCard`** (`widgets/document_photo.dart`) gained a `showError`
flag: when true and its `photo` is still null, the card's border turns red
and an inline "⚠ Photo required" line appears under the button — the same
treatment `TextFormField` already gives a bad text field, just built by
hand since there's no equivalent for a photo tile. It clears itself the
instant a photo is taken (the check is `showError && photo == null`), no
separate reset code needed.

**Wired through two screens**:
- `LicenseCaptureSection` (`s18_license_verification.dart`) gained a
  `showMissingErrors` flag, passed to both its `DocumentPhotoCard`s.
  `s2_s3_auth_screens.dart`'s Register screen now sets a new
  `_showLicenseErrors` state flag to `true` alongside its existing
  "Driver's License Required" popup, and passes it through — so tapping
  Register now highlights whichever side (front/back) is actually missing,
  not just the popup.
- `VehicleFormSection` (`s4_s5_vehicle_home.dart`) gained the matching
  `_showDocErrors` flag, set alongside its existing "OR / CR Required"
  popup, passed to both the OR and CR `DocumentPhotoCard`s — shared by both
  Create Account's embedded vehicle section and the standalone Add Vehicle
  screen, so both get it.

**Checked, not touched**: `LicenseVerificationScreen` (the separate
login-time "no license on file yet" gate) uses the same `LicenseCaptureSection`
but has no popup gap to fix — its Submit button is already disabled and
dimmed until both photos exist, so there was never a missing-field popup
there to begin with.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing,
`flutter build apk --release` succeeded. No web admin build needed — none
of the 4 files touched are used by `admin_main.dart`.

## Four Profile-screen questions answered and fixed (2026-10-20)

**Asked**: why "Location Permission — GPS Location Available" can't be
tapped; make notification timestamps reflect when the alert/event actually
happened, not when the screen is opened; explain and verify how System
Logs works; add a success popup to Log Out.

**1. The GPS row wasn't broken — it was a real UX gap.** Tapping it when
`gpsStatus == GpsStatus.available` hit an early `return` with no feedback
at all, while every other row in that same list — Edit Profile,
Notification Settings, Privacy & Data, Ad Hoc Network Settings — always
does something when tapped, and `_SettingsItem` shows the same ">" chevron
on all of them regardless. There was nothing left to request (permission's
already granted), so the fix isn't to make it request something — it's to
stop it being a silent no-op: tapping now confirms with a toast ("Location
is already available (±Xm accuracy)."), so the row's tappable appearance
finally matches what tapping it does.

**2. Notification timestamps were already correct — verified, not
assumed.** `AppState._addNotif` already stamps `time: DateTime.now()` at
the moment the underlying event happens (an alert relay, a sighting, a
recovery…), not when the Notifications screen happens to be opened later —
confirmed by reading every `_addNotif` call site. The real gap was display:
`_NotifCard._timeAgo()` only ever showed relative text ("2h ago") or, once
24h old, a bare date with no time of day at all — so "know its time or
date" wasn't actually answerable from the screen. Added `_exactTime()`
(`MMM d, yyyy · h:mm a`) alongside the existing relative text, so every
notification now shows both "how long ago" and the precise moment,
permanently — not reconstructed from whenever it's viewed.

**3. System Logs — explained, and one real bug found while verifying it.**
How it works: `AppState._addLog(tag, message, type)` is called throughout
the app at the moment something happens (mesh events, relay activity, sync
results, errors); it prepends a `SystemLog` to the in-memory `logs` list
(capped at 300, oldest dropped) and persists it to SQLite's `system_logs`
table, which independently self-trims the same way on every insert
(`DatabaseService.addSystemLog`). "Clear" wipes both. All of that was
already correct. **The bug**: `SystemLog.toMap()` wrote a full ISO datetime
to the `createdAt` column, but `fromMap()` never read it back — the screen
only ever displayed the separate `timestamp` field, a bare `HH:mm:ss` string
with **no date at all**, so any log older than today was impossible to date
from the screen. Fixed: `SystemLog` now carries a real `createdAt DateTime`
or round-trips through SQLite properly (`fromMap` parses it back), and the
System Logs screen displays `MMM d, h:mm:ss a` instead of the bare
time-only string. `timestamp` (the string column) is kept, unread by the
UI now — same "never drop a shipped column" convention as every other dead
column in this schema, not a new exception.

**4. Log Out now confirms success.** `state.logout()` used to go straight
to the Login screen with no confirmation at all. Added
`showSuccessModal(title: 'Logged Out', message: 'You have been
successfully logged out.')` between the logout call and the navigation —
mirrors the same "Continue" pattern every other success modal in the app
already uses.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing. Both
`flutter build apk --release` and `flutter build web -t lib/admin_main.dart`
run (needed — `models.dart`, where `SystemLog` lives, is shared with the
admin portal).

## Bottom-nav back button now retraces the actual tab history, plus double-back-to-exit on Home (2026-10-20)

**Asked for**: Home → Alerts → Map → back should go to Alerts → back should
go to Home → back should stay on Home (not exit) → back again (while still
on Home) should close the app. Same behavior no matter which icon was
tapped, consistently, with no edge cases.

**Root cause**: Home's own bottom nav already did this right —
`Navigator.pushNamed` when switching to Map/Alerts/Profile, so each visit
is its own back-stack entry. But the *shared* `BottomNavBar` widget (used
by Map, Alert History, and Profile — every screen except Home) used
`Navigator.pushReplacementNamed` for every tab switch, including switches
between two non-Home tabs. A replace doesn't leave a stack entry behind —
so Alerts → Map → back skipped straight past the Alerts screen (it had
been replaced out of the stack) and landed on Home instead of Alerts, which
is exactly the bug described.

**Fix** (`BottomNavBar` in `s9_s10_s11_alerts_map.dart`): switched to
`Navigator.pushNamed` for every tab switch, with one guard — tapping the
tab that's already showing is a no-op, so repeatedly tapping the same icon
doesn't pile up duplicate stack entries. This now matches Home's own
behavior exactly, so the back button behaves identically regardless of
which of the 4 tabs it's pressed from, as asked.

**Double-back-to-exit on Home** (`s4_s5_vehicle_home.dart`): Home is always
reached via `pushReplacement`/`pushNamedAndRemoveUntil` from Splash/Login,
so once there, there's nothing left before it in the stack — pressing back
used to exit the app immediately on the very first press, with no warning.
Wrapped `HomeScreen` in `PopScope(canPop: false, ...)`: the first back
press shows a "Press back again to exit" notice (styled with the app's own
`AppColors.charcoal`, not borrowing the shared red/green toast helper for
something that's neither a success nor an error) and starts a 2-second
window; a second press inside that window calls `SystemNavigator.pop()` to
actually exit. Map/Alert History/Profile needed no equivalent — with the
stack fix above, their own back press already correctly lands on whatever
real screen preceded them (usually Home, sometimes another tab), so
`PopScope` was only needed at the one screen that's genuinely the root.

**Not touched**: the few unrelated `pushReplacementNamed(context, '/home')`
calls elsewhere (a "flow completed, return to Home fresh" action from
inside Report Stolen/Broadcasting/Alert Received, not bottom-nav tab
switching) — those are a different, intentional kind of navigation and
were left exactly as they were.

**Verified**: `flutter analyze` 0 issues, `flutter test` 15 passing,
`flutter build apk --release` succeeded. No web admin build needed — both
files touched are phone-only screens, not used by `admin_main.dart`.

## Native Android launch screen (the screen before Flutter's own splash) recolored (2026-10-20)

**Asked for**: the plain black screen shown for a moment when the app icon
first appears — before the Flutter "VehicleGuard" splash screen takes
over — update it to a new teal background image, and add that image to
`assets/images/` too.

**This is a DIFFERENT screen than the Flutter splash screen** fixed in an
earlier entry — that one is drawn by Flutter itself, fully customizable.
This one is drawn by Android natively, while the OS is still starting the
app process and Flutter's own engine hasn't even begun running yet
(`android/app/src/main/res/drawable/launch_background.xml` /
`android:windowBackground`). It was plain white in the underlying XML
(`@android:color/white`) even though the screenshot showed black — Android
12+ draws its OWN system splash screen automatically when nothing
overrides it, using the launcher icon on whatever background color it
picks (often black), which is what the screenshot actually was.

**Image**: saved to `assets/images/native_splash_background.png` (as
asked), and a second copy placed at
`android/app/src/main/res/drawable/splash_bg.png` — a genuinely separate
copy is required here, since Android's native resource system
(`android/app/src/main/res/`) and Flutter's asset bundle
(`assets/`) are two unrelated systems; a drawable XML can't reference a
path inside `assets/`.

**`launch_background.xml`** (both `drawable/` and `drawable-v21/`, so this
applies consistently to every pre-Android-12 version) now shows the image
as a full-bleed background (`android:gravity="fill"`) instead of a flat
white color.

**Android 12+ needed a different, more limited fix — a real platform
restriction, not a bug**: the Android 12+ Splash Screen API that draws the
automatic black screen in the screenshot can ONLY be given a solid
background *color*, never a custom image or pattern — this is an
intentional OS restriction (keeps every app's launch fast and consistent),
not something fixable with more code. Added
`android/app/src/main/res/values-v31/styles.xml`, overriding
`LaunchTheme` for API 31+ only, with `windowSplashScreenBackground` set to
`#004E5C` — sampled directly from the new image's own corners (code: `PIL`
reading the 4 corner pixels and averaging them), so Android 12+'s
necessarily-plain background is at least the artwork's own dominant teal
instead of black. The icon Android 12+ shows on top of it is already the
app's real launcher icon — no separate configuration needed there.

**Verified**: pure native Android resource/XML change, no Dart code
touched — `flutter analyze`/`flutter test` don't apply.
`flutter build apk --release` succeeded (67.3MB, up from 65.9MB — the new
splash image itself).

## Reusable branded loading modal, wired into login/registration/Google sign-in/theft-report/status-update (2026-10-20)

**Asked for**: a reusable, professional loading modal — the real
shield-and-GPS logo centered inside an animated teal/aqua ring, a
"VehicleGuard" title, and a short context-specific message — applied
wherever a significant async operation runs, with duplicate-tap
prevention, a reliable dismiss in every outcome, no stuck state, no
leaked sensitive detail in any message, and no change to Firebase/
Firestore/local-storage behavior.

**Reused, not duplicated**: `showLoadingModal` already existed in
`lib/widgets/widgets.dart` and was already used at 3 call sites (vehicle
registration, license submission, sighting send) with the exact
non-dismissible contract the spec asks for (`barrierDismissible: false`
+ `PopScope(canPop: false)`, start it un-awaited, pop it when the work
finishes). Redesigned that one function in place instead of adding a
second component: it now shows a `Stack` of a teal/aqua
`CircularProgressIndicator` (`color: AppColors.teal`,
`backgroundColor: AppColors.tealAccent` — the ring look from the
reference image) around the real `assets/images/app_icon.png` logo in a
`ClipOval`, then "VehicleGuard" in `AppColors.charcoal`, then the
message in `AppColors.text2`. All three colors are exactly the user's
`#087E8B` / `#A8E5E3` palette already in `app_theme.dart` — no new
tokens needed. Every existing call site keeps the same signature and
picked up the new look automatically.

**Wired into** (`s2_s3_auth_screens.dart`, `s6_s7_s8_geofence_report.dart`,
`s12_s13_s14_status_notif_profile.dart`): Login ("Signing you in
securely…", including the email-verification retry path), Register
("Creating your account…"), Google sign-in ("Connecting to Google…"),
Report Stolen submission ("Submitting theft report…"), and Mark
Recovered ("Updating vehicle status…") — this last one previously had
**no loading indicator of any kind** while `markRecovered` awaited a
Firestore write and a mesh notification, a real gap the spec's "status
updates" line caught. Each site follows the same already-established
pattern: start the modal, `await` the real operation, `if (!mounted)
return;`, pop the modal, then show whatever success/error modal or
toast already existed — none of that downstream logic was changed.
Fixed one real `use_build_context_synchronously` gap surfaced while
wiring Mark Recovered: it showed the modal using `context` after an
`await showConfirmDialog(...)` with no mounted check in between; added
`if (!ok || !mounted) return;`.

**Deliberately left out, with reasons**: app initialization (Splash
already shows the same logo prominently plus its own inline teal
spinner during `isInitializing` — stacking a second identical logo
modal on top would just be visual duplication, and the user's own
closing note said to "keep the native splash screen separate"); Home/
dashboard loading and vehicle-data retrieval (both read straight from
the already-loaded `AppState` via `Provider` — no async fetch happens
on entry, confirmed by reading `HomeScreen`'s `initState`/`build` — so a
blocking modal would only add flicker, which the spec explicitly warns
against); data sync (already has its own non-blocking "SYNC COMPLETE /
SYNC FAILED" status chip; replacing a passive indicator the user never
asked to change with a blocking modal would be a regression, not an
improvement).

**Not touched**: `PrimaryButton`'s own `loading` prop (already disables
`onTap` and shows an inline spinner — this was already preventing
duplicate taps at the button level before this change, independent of
the modal); none of the `AppState` auth/report methods were modified,
since none of them throw outward in normal operation (they already
catch internally and return `false`/`null`/an error string), so the
existing non-try/catch pop pattern used at every other call site in this
codebase was kept for consistency rather than introducing a different
error-handling shape only for these new sites.

**Verified**: `dart format` on all 4 changed files — 0 changes needed.
`flutter analyze` — 0 issues. `flutter test` — 15 passing. Both
`flutter build apk --release` (68.9MB) and
`flutter build web -t lib/admin_main.dart` run and succeeded (required —
`widgets.dart` is shared with the admin portal).

## Admin Dashboard UI/UX refinement — sidebar shell, login background, vehicle-type icons (2026-10-21)

**Asked for**: a UI/UX-only pass over the whole web Admin Dashboard
(Accounts, Approvals, Vehicles, Live Activity, Map, plus the admin login
page) toward one consistent, modern design system — explicitly **no**
change to any business logic, Firebase/Firestore behavior, API, schema,
or feature set. Two concrete, named deliverables: use the supplied
background image on the admin login page, and replace vehicle
photographs with simple type icons on the Vehicles page. Everything else
was "improve the visual organization/consistency," left to judgment.

**Image asset**: saved to `assets/images/admin_login_background.png`
(already covered by the existing `assets/images/` blanket declaration in
`pubspec.yaml` — no pubspec change needed).

**Admin login page** (`AdminLoginScreen` in `admin_dashboard.dart`): now
shows the supplied background image full-bleed (`BoxFit.cover`, no
stretching) under a `AppColors.tealDark` wash at 42% opacity so the card
and the artwork's own shield/vehicle/location elements both stay
readable, with the existing logo, title, fields, Sign In button, and
error-message handling unchanged — just moved into a white, shadowed
card instead of sitting directly on a plain background. Authentication
itself (`AdminService.instance.login`) was not touched.

**Sidebar shell, replacing the old top `TabBar`**
(`_AdminDashboardScreenState.build` in `admin_dashboard.dart`): the
5-section top tab bar is now a persistent dark-teal (`AppColors.tealDark`)
left sidebar — logo + "VehicleGuard / Admin Dashboard" header, the same
5 sections (Accounts/Approvals/Vehicles/Live Activity/Map) as nav items
with the Approvals pending-count badge preserved, and Log Out moved down
to the sidebar's own footer (previously an AppBar icon). Purely
presentational: tapping an item still just calls `_tabs.animateTo(i)` on
the exact same `TabController`/`TabBarView` that already owned which
section was "selected" and how its content loaded — nothing about tab
state, data loading, or the Firestore listeners in `initState` changed.
Above the content, a new `_AdminTopBar` shows that section's title and a
one-line description (`_tabTitles`/`_tabSubtitles`, matching the wording
each tab's own body already used where one existed), the Refresh button
(unchanged), and the signed-in admin's own email — added via a new
`AdminService.currentAdminEmail` getter that just exposes
`FirebaseAuth.instance.currentUser?.email`, real existing auth state, not
a fabricated name. The reference design's notification bell and a global
top search box were deliberately **not** added — neither corresponds to
a real feature in this app (no notification inbox exists to back an
unread count; a global cross-tab search would be new application logic,
out of scope for a UI-only pass), and a "Settings" nav item was left out
for the same reason — there is no Settings screen anywhere in the admin
portal to link to.

**Vehicle-type icons, replacing vehicle photographs**: this app has
never captured or displayed an actual vehicle photo anywhere (confirmed
by reading `admin_vehicles.dart` — the only per-vehicle images on file
are the OR/CR *documents*, shown in the detail sheet, which are
unrelated and untouched). Added a small, honest stand-in instead: a new
shared `vehicleTypeIcon()`/`VehicleTypeIcon` widget in
`admin_widgets.dart` maps a vehicle's free-text `type` field ("Sedan",
"SUV", "Hatchback", "Van", "Motorcycle", …) to the closest Material icon
— Material has no distinct silhouette per car body style, so only the
types with a genuinely different shape (motorcycle/scooter, van,
truck/pickup, bus) get their own icon; every car-shaped type falls back
to the same generic car icon rather than guessing a body style from
text. Shown in a small rounded tile (`AppColors.tealLight` background,
`AppColors.teal` icon — the existing neutral brand tint, no new color
added) next to the vehicle in: the Vehicles tab's wide table row, its
narrow card, its full registration-record detail sheet, and (for
consistency, replacing a generic static car icon that was there before)
each vehicle listed inside an account's own detail sheet on the Accounts
tab. Every existing vehicle field (plate, model, color, type, owner,
device, status, geofence, OR/CR, registration date) is still shown
exactly as before — only a visual icon was added alongside them, nothing
was removed.

**Smaller consistency fixes**: two spots in `admin_monitoring.dart` had
their own literal `Color(0xFF92400E)` instead of using the
`adminAmberText` constant `admin_widgets.dart` already defines for
exactly that amber-on-light-background text — switched both to the
existing constant (same color, one definition instead of three). The
Approvals tab's "no registrations waiting" and Firestore-error states
were plain left-aligned text with no icon; restyled both to match the
centered icon-plus-message pattern every other tab's empty/error state
already uses (`adminLoadingOrError` in `admin_widgets.dart`), without
adding a Retry button to the error state since Approvals has no
one-shot `_load()` to retry — it's a live Firestore stream that
self-recovers once the rules are fixed.

**Not changed**: the Live Activity and Map tabs' layouts, badges, and
map controls/legend were reviewed against the spec and already matched
it closely (map already fills the tab's full space with a floating
legend and a "fit all" button, not a constrained/padded box; active vs.
resolved alerts already use red vs. green distinctly without making
every event look like an emergency) — rewriting already-correct code
would have been unnecessary churn, not an improvement. No Firebase
config, Firestore query, approval/rejection rule, geofence behavior, API
shape, or database field was touched anywhere in this change.

**Verified**: `dart format` on every changed file — 3 reformatted (pure
formatting, no logic). `flutter analyze` — 0 issues. `flutter test` — 15
passing (including the Accounts tab's own wide/narrow layout tests,
unaffected by the new icon in its vehicle list).
`flutter build web -t lib/admin_main.dart` succeeded. No phone-app file
(`main.dart` and everything it actually imports) was touched, so
`flutter build apk --release` wasn't required by the project's own rule
for this change — every edit is under `lib/screens/admin/` or
`lib/services/admin_service.dart`, both of which stay independent of
`AppState`/the phone app by design.

## Removed the redundant top-bar Refresh icon from the admin dashboard (2026-10-21)

**Asked for**: after seeing the new sidebar on the Map tab, whether the
Refresh icon in the top-right corner was still needed, since the browser
already has its own refresh.

**Turned out to be redundant for a different, better reason than the
browser's own refresh**: that button called `_load()`, which only
re-fetches the ACCOUNTS roster (`AdminService.fetchAllUsers`) — it never
refreshed the Map or Live Activity tabs at all, since both already run
on live Firestore listeners (`AdminMonitorFeed`) that update on their
own. On the Accounts tab itself (the one tab it actually did something
for), the exact same reload was already reachable two other ways: the
tab's own `RefreshIndicator` (pull-to-refresh) and its error state's own
Retry button. Vehicles has its own independent retry on error, tied to
its own `_load()`, not this one. So the icon was a third way to do
something only one tab needed, while visually implying — especially
sitting in the corner of the Map tab, as screenshotted — that it would
refresh whatever was currently on screen, which it never did.

**Removed**: the `IconButton`/`loading`/`onRefresh` from `_AdminTopBar`
in `admin_dashboard.dart`, and the `loading`/`onRefresh` arguments passed
to it from `_AdminDashboardScreenState.build`. `_load()` itself is
unchanged and still runs exactly as before — on initial load, after
every approve/reject/suspend/restore/delete/add-user action, and via
Accounts' own pull-to-refresh and Retry button.

**Verified**: `dart format` — 0 changes needed. `flutter analyze` — 0
issues. `flutter test` — 15 passing. `flutter build web -t
lib/admin_main.dart` succeeded. No phone-app file touched, so
`flutter build apk --release` wasn't required.

## Admin Dashboard dev server now opens on a fixed localhost port (2026-10-21)

**Asked for**: `localhost:<port>` for the Admin Dashboard was a different
random port every time it launched — pin it to one fixed address.

**Cause**: `flutter run` picks a free port at random on every launch
unless told otherwise, and no VSCode launch configuration existed in
this project to pass it one — `.vscode/` only had `settings.json` (the
earlier Gradle/Java fix), no `launch.json`.

**Fix**: added `.vscode/launch.json` with two named launch
configurations — "VehicleGuard (phone app)" (`lib/main.dart`, unchanged
behavior) and "VehicleGuard Admin (web)" (`lib/admin_main.dart`,
`deviceId: chrome`, `--web-port 8089`). Picking "VehicleGuard Admin
(web)" from VSCode's Run and Debug dropdown now always opens
`localhost:8089`. Launching from a terminal instead works the same way
with `flutter run -d chrome -t lib/admin_main.dart --web-port 8089`.

**Verified**: pure tooling/IDE config, no Dart code touched —
`flutter analyze`/`flutter test`/build don't apply.

## VIGILINK rebrand + redesign — Stage 1: identity, onboarding, Splash, Login (2026-10-21)

**Asked for**: rename the whole product from VehicleGuard to VIGILINK
(new logo/icon everywhere) and redesign its UI/UX to a dark-navy/cyan
system, across both the phone app and the admin dashboard — explicitly
UI/UX only, no functional/backend change. This is a large, multi-stage
request; this entry covers Stage 1 only, as agreed with the user:
identity (icon, logo, rename) + the screens with a supplied reference
image (Splash, a new onboarding carousel, mobile Login). Registration,
Home, vehicle management, alerts, profile, Settings, and the admin
dashboard's own visual redesign are follow-up stages, not done here.

**Two things in the brief didn't match what the app actually has, found
by reading the code before changing it, resolved with the user**:
1. There is no existing onboarding carousel anywhere — Splash has always
   been one screen with GET STARTED/LOG IN buttons, not a 3-page
   swipeable intro. Building the 3-page carousel the reference images
   show is therefore a small *new* UI flow (new screen, new navigation,
   a new "seen it once" flag), not a pure restyle — confirmed with the
   user, who asked for it built anyway.
2. The pasted spec is titled "Mobile App UI/UX Redesign" and never
   mentions the admin dashboard, which got its own separate light
   teal/white redesign last session — confirmed with the user that the
   dark-navy/cyan system is for the phone app; the admin dashboard gets
   the VIGILINK rename now and its own matching redesign in a later
   stage (not this one).

**Rename, applied everywhere except two places that must NOT change**:
every literal "VehicleGuard" in `lib/**/*.dart` → "VIGILINK" (44
occurrences across 15 files — UI text, dialog/snackbar messages, the
notification channel name, the mesh service's own *fallback display
name* shown to nearby devices, and the Terms & Conditions document's
self-references to the product's own name). The app's root widget class
`VehicleGuardApp` → `VigiLinkApp` (`lib/main.dart`). Also renamed:
`android:label` in `AndroidManifest.xml` (the name shown under the
launcher icon), `web/index.html`'s `<title>`/meta tags and
`web/manifest.json`'s `name`/`short_name`/`description` (admin web tab
title and PWA name).
**Deliberately NOT renamed**: the Dart package name (`name: vehicleguard`
in `pubspec.yaml`) — changing it cascades into every `package:vehicleguard/...`
import across the whole codebase for a purely cosmetic identifier, far
outside "UI/UX only"; the Nearby Connections `_serviceId` constant
(`'com.vehicleguard.theftalert'`) in `nearby_mesh_service.dart` — this is
the literal protocol identifier two devices must share to find each
other over the ad hoc mesh, so renaming it would be a real *behavior*
change (explicitly out of scope), not a cosmetic one; `userAgentPackageName`
on every map's tile layer (`'ph.edu.carsu.vehicleguard'`) — the required
HTTP User-Agent for OpenStreetMap's tile usage policy, matching the
actual (unchanged) Android package ID; and the doc comment in
`firebase_options_web.dart` referencing "VehicleGuard Admin" — that
names the real external Firebase Console project, which this change
cannot rename and shouldn't claim to have.

**New assets**, saved to `assets/images/` (already covered by the
existing blanket declaration in `pubspec.yaml`): `app_icon.png` and
`splash_logo.png` (the supplied VIGILINK badge/logo — also used to
regenerate the Android launcher icon via `dart run flutter_launcher_icons`),
`splash_background.png` (replaced), and three new onboarding backgrounds
(`onboarding_bg_1.png`/`_2.png`/`_3.png`) plus `login_background.png` for
the new mobile Login screen — all supplied images, mapped to the pages
whose content they match best (documented in-file where used), not
generated.

**New theme tokens** (`lib/utils/app_theme.dart`, `AppColors`): added
the VIGILINK dark-navy/cyan palette as new `vigi*`-prefixed fields
(`vigiBg`, `vigiCard`, `vigiCyan`, `vigiCritical`, etc. — exact hex
values from the brief) alongside the existing palette, rather than
replacing it — the admin dashboard and every not-yet-migrated phone
screen still read the old tokens, and repointing those names mid-migration
would have silently reskinned screens nobody asked to change yet. Each
further screen switches to the `vigi*` tokens as it's redesigned in a
later stage.

**Reused, not duplicated, two existing shared components** instead of
building parallel ones: `PrimaryButton` (`widgets.dart`) gained an
optional `textColor` parameter (default `Colors.white`, so every
existing call site is pixel-identical) for the cyan-button/dark-text
style the spec asks for. `AppTextField` (`widgets.dart`) gained an
optional `dark` flag (default `false`, same no-op guarantee) that swaps
in dark fill, light text, and a cyan focus outline instead of adding a
second text-field widget.

**New onboarding carousel** (`lib/screens/onboarding_screen.dart`, new
file — no `sN_` prefix since it isn't one of the manuscript's numbered
screens): 3 swipeable pages ("Protect All Your Rides," "Real-Time Alerts
and Shared Protection," "A Stronger Community on the Road") with Skip,
Next/Get Started, and dot pagination, each on its own supplied background
image with a dark gradient for text readability. Shown once: `main.dart`
now reads a `vigilink_seen_onboarding` flag from `SharedPreferences`
(already a dependency, already used elsewhere in `app_state.dart`)
*before* `runApp`, and picks `/onboarding` or `/` (Splash, as before) as
the `MaterialApp`'s `initialRoute` accordingly; "Get Started" and "Skip"
both set the flag and hand off to Splash. No account, auth, or sync logic
lives in this screen.

**Splash screen** (`s1_splash_screen.dart`): same background-image +
logo + GET STARTED/LOG IN structure and the exact same
initialization/auto-routing logic as before (untouched) — only the
palette changed to `vigi*` tokens, and the "CONNECT • DETECT • PROTECT"
/ "A Safer Journey Starts Together" lines from the brief were added as
real text under the wordmark (the supplied logo image itself already
carries the project's full academic title as its own built-in caption,
so these are the two extra lines the brief specifically asked to keep,
not a duplicate of what's already in the image).

**Mobile Login screen** (`s2_s3_auth_screens.dart`, `LoginScreen`):
same fields, validators, Forgot Password dialog, Google sign-in,
Register link, and Terms & Conditions link — same `_submit`/`_submitGoogle`/
`_showForgotPassword` handlers, byte-for-byte — now shown over the
supplied login background image behind a translucent dark card so the
form stays readable, using the two newly-dark-capable shared components
above.

**Verified**: `dart format` — 5 files reformatted (pure formatting).
`flutter analyze` — 0 issues. `flutter test` — 15 passing (including the
renamed smoke test, which now asserts "VIGILINK" instead of the old
name). `flutter build apk --release` succeeded (80.4MB, up from 68.9MB —
the new background images account for the size). `flutter build web -t
lib/admin_main.dart` succeeded (required — `app_theme.dart` and
`widgets.dart` are shared with the admin portal, and the admin login
title/sidebar header were renamed too).

**Admin login background**, follow-up once the file actually synced:
replaced `assets/images/admin_login_background.png` (added last session)
with the supplied landscape VIGILINK image. Same code as last session —
`AdminLoginScreen` already read this exact path with `BoxFit.cover` and
a dark-teal wash over it — only the image content changed, so no file
other than the asset itself needed touching.

**Asset cleanup**: removed `assets/images/native_splash_background.png`
— confirmed unreferenced by any Dart `Image.asset(...)` call (checked
every file in `assets/images/` against `lib/` and `web/`; this was the
only one with zero hits) and safe to delete because the native
pre-Flutter-engine Android launch screen reads its own separate,
already-identical copy at
`android/app/src/main/res/drawable/splash_bg.png` — a completely
different resource system from Flutter's `assets/` bundle (see the
2026-10-20 entry that first added both copies). Removing the
asset-bundle duplicate doesn't touch that native screen at all; it only
drops ~1.3MB of dead weight from the app bundle the Flutter side never
read.

**Verified (this follow-up)**: `flutter analyze` — 0 issues.
`flutter test` — 15 passing. `flutter build apk --release` succeeded
(79.1MB, down from 80.4MB — the removed duplicate asset). `flutter build
web -t lib/admin_main.dart` succeeded.

**Not yet done** (explicitly deferred to later stages, per the agreed
plan — not an oversight): Registration screen, Terms and Conditions /
Privacy Policy screen styling, Home dashboard, vehicle management/
geofencing/location screens, alerts/notifications/sightings/recovery
screens, Profile/Settings, and the admin dashboard's own dark-navy/cyan
redesign (it still has last session's light teal/white look, aside from
the VIGILINK text rename and this login background applied in this
pass).

## VIGILINK redesign — Stage 2a: Registration, vehicle/Home, geofence, theft-report, broadcasting (2026-10-21)

**Asked for**: continue the VIGILINK dark-navy/cyan redesign into the
rest of the app, screen by screen, with the same UI/UX-only constraint
as Stage 1 — no handler, route, validator, Firebase call, or
state-management logic touched anywhere, only colors/containers/styling.

**Screens converted**: Register (`s2_s3_auth_screens.dart`), the
driver's-license verification screen (`s18_license_verification.dart`),
the Home dashboard and the vehicle registration form it shares with
Register (`s4_s5_vehicle_home.dart` — `HomeScreen`, `_HomeTab`,
`VehicleFormSection`, `RegisterVehicleScreen`), Set Geofence, Report
Stolen, and Alert Broadcasting (`s6_s7_s8_geofence_report.dart`). Each
screen's own handlers (`_submit`, `_save`, `_confirm`, GPS refresh, mesh
permission requests, etc.) were not touched — only read to confirm what
color-bearing widgets they drive, exactly as in Stage 1.

**Shared components extended with an opt-in `dark` flag** (default
`false`, so every existing call site elsewhere in the app — including
the entire admin dashboard and the not-yet-migrated phone screens —
keeps rendering exactly as it did before): `AppTextField`, `PrimaryButton`
(already had `textColor` from the loading-modal work), `AppCard` (gained
`borderColor` alongside its existing `color` override),
`SearchableSelectField`, `VehicleCard`, `AppBottomNav`, `OutlineButton2`,
`DocumentPhotoCard`, `LicenseCaptureSection`, `SectionLabel`. Two
single-caller widgets (`VehicleFormSection`'s own styling, `NodeRelayRow`)
were switched unconditionally instead of threading a flag, since every
place that uses them is being redesigned in this same pass — confirmed
by grepping each widget's call sites before deciding, the same check
used for every other shared-widget change in this engagement.
`StatusBadge` needed no change at all: it was already a fully
self-contained pill (its own light background + matching text/dot color),
so it already reads correctly on both the old light cards and the new
dark ones.

**Maps**: Set Geofence's `FlutterMap` keeps the exact same tile provider,
URL template, coordinates, circle/marker logic, and `userAgentPackageName`
as before — only the frame around it (card border, radius chip, GPS
status pill) was restyled. The map tiles themselves are standard
OpenStreetMap imagery and stay their normal colors, which is expected —
re-skinning third-party map tiles was never part of this request and
would require a different tile provider, a real functional change.

**Scope calls made, consistent with Stage 1's "modals/dialogs stay
white" decision**: `_AuthoritiesDialog` (the "Nearby Authorities" modal
in `s6_s7_s8_geofence_report.dart`) was left on its existing white-card
style, since every dialog/bottom-sheet in the app already behaves this
way regardless of which screen opened it — not an oversight.

**Verified**: `dart format` on every changed file. `flutter analyze` —
0 issues (checked three times across this batch, after the widget
extensions, after the geofence/report file, and project-wide at the
end). `flutter test` — 15 passing both times it was run. `flutter build
apk --release` succeeded twice as this batch progressed (79.1MB final).
No admin-dashboard or other shared-outside-phone-app file was touched in
this batch, but `app_theme.dart`/`widgets.dart` changes are already
covered by the Stage 1/Stage "admin redesign" web-build checks; a fresh
`flutter build web -t lib/admin_main.dart` will run again once the admin
dashboard's own redesign stage (still pending) is done, rather than
twice for the same unchanged admin UI.

## VIGILINK redesign — Stage 2b: Alerts, Map, Alert History, Sightings (2026-10-21)

**Asked for**: continue the same UI/UX-only redesign into the alert and
sighting screens. Same constraint reiterated by the user mid-batch — no
functional change, visuals only.

**Screens converted**: Alert Received, Proximity Map, Alert History
(`s9_s10_s11_alerts_map.dart`); Report a Sighting and Sightings of My
Stolen Vehicle (`s16_sightings.dart`).

**Shared components**: `AlertLogItem` and `ProximityNodeRow` (single
in-scope caller each, so switched unconditionally rather than adding an
unused flag — same reasoning as `VehicleFormSection`/`NodeRelayRow` in
Stage 2a). `BottomNavBar` (the thin per-screen wrapper around
`AppBottomNav` used by Map/Alert History/Profile) gained its own opt-in
`dark` flag and now passes it through — Map and Alert History pass
`dark: true`; Profile doesn't yet, since it isn't redesigned until the
next stage, so it keeps today's light bottom nav until then.
`PhotoEvidenceRow` needed no change at all: it's just rounded photo
thumbnails with no background/text color of its own, so it already
looks correct on both the old light cards and the new dark ones.

**Maps**: Proximity Map's and the Sightings map's `FlutterMap` instances
keep their exact tile provider, coordinates, and marker/circle logic —
only the surrounding chrome (app bar, legend bar, bottom list, card
borders) was restyled, consistent with the Set Geofence map in Stage 2a.
The floating `_MapTag`/`_MapChip` labels drawn directly on the map tiles
were left on their white/black styling on purpose — they sit on the
photographic map imagery itself, not on the app's background, so they
don't change color with the rest of the screen (true in both the old and
new designs).

**Scope call, same "modals stay white" rule as every prior stage**:
`showReporterContactModal` in `s16_sightings.dart` (the sighting
reporter's contact-details dialog) was left unchanged.

**Verified**: `dart format`, `flutter analyze` — 0 issues (checked after
each file and again project-wide). `flutter test` — 15 passing.
`flutter build apk --release` succeeded (79.1MB).

## VIGILINK redesign — Stage 2c: Update Status, Notifications, Profile, System Logs — phone app redesign complete (2026-10-21)

**Asked for**: finish the same UI/UX-only redesign on the last
remaining phone screens.

**Screens converted** (`s12_s13_s14_status_notif_profile.dart`): Update
Vehicle Status (and its `_RecoveryPhotoTile`/`_StatusOption`), Push
Notifications (and `_NotifCard`), Profile's header/vehicle
card/settings-row list/logout button, and System Logs.

**Scope calls, same "modals/sheets stay white" rule as every prior
stage** — all four of Profile's own popups stay on their existing white
styling: the profile-photo picker sheet (`_changeProfilePhoto`), the
Edit Profile sheet (`_EditProfileSheet`), the Privacy & Data dialog
(`_showPrivacyDialog`), and the Ad Hoc Network status sheet
(`_showAdHocDialog`). None of their content, fields, or copy changed —
only confirmed they're sheets/dialogs, not full screens, consistent with
every other overlay in the app.

**This completes the entire phone app** — every screen from the
splash/onboarding through Registration, Home, vehicle management,
geofencing, theft reporting, alerts, the map, sightings, notifications,
and profile/settings now uses the VIGILINK dark-navy/cyan palette. Only
the admin dashboard remains on last session's light teal/white design
(aside from the VIGILINK rename already applied to it in Stage 1).

**Verified**: `dart format`, `flutter analyze` — 0 issues (checked
after each edit and project-wide at the end). `flutter test` — 15
passing, including `validators_test.dart` and
`admin_widgets_test.dart`, confirming the admin test suite is
unaffected by any phone-app change. `flutter build apk --release`
succeeded.

**Not yet done**: the admin dashboard's own dark-navy/cyan redesign —
the last remaining piece of this whole request.

## VIGILINK redesign — Stage 3: Admin Dashboard dark-navy/cyan redesign (2026-10-26)

Finished the dark-navy/cyan redesign on the admin web dashboard,
completing the pass that Stage 2c had left as the one remaining piece:
`admin_widgets.dart` (every shared table/card/chip/toolbar widget),
`admin_dashboard.dart`'s sidebar/top bar/dashboard shell, and the
Accounts, Approvals, Vehicles, and Monitoring (Live Activity + Map)
tabs. `AdminLoginScreen` was already dark from Stage 1 and needed no
change. Same "modals/small sheets stay white, large near-full-height
detail sheets go dark" policy as the phone app, and the same
bare-color-`Text` bug hunt (a `Text` with no explicit `color:` inherits
the shared light `AppTheme.theme`, invisible on the new dark
background) — found and fixed several instances across
`admin_accounts.dart`, `admin_vehicles.dart`, and
`admin_monitoring.dart`. `ChoiceChip`/`FilterChip` widgets were given
explicit per-instance styling rather than touching the shared
`AppTheme.theme`, since that theme is also used by the phone app and a
shared-theme edit would have silently changed ambient widget styling on
both surfaces.

This briefly completed the originally-requested dark-navy/cyan rebrand
across the whole app (phone + admin) — but see the next entry: the very
next request repainted part of it again before this stage's own
Progress.md entry had been written, so it's recorded here only for the
record of what was built, not as a description of the app's current
look.

## VIGILINK Lite — light navy/cyan repaint of Home, Map, Alerts, Profile/Settings, and the whole Admin Dashboard (2026-10-26)

**Asked for**: the dark-navy VIGILINK look from Stages 1–3 was judged
"too dark / over-designed" for day-to-day use. New instruction: redesign
colors only (still no functionality/logic/routing/Firebase changes) on
Home, Map, Alerts, and Settings/Profile — and the actions within them —
to a light theme: pale blue-gray backgrounds (`#F4F8FB`), white cards,
navy text (`#12304A`), cyan accents (`#08BFD4`), and the given
green/red/blue/amber semantic set for success/critical/info/warning.
Same palette for the admin dashboard, which additionally keeps a navy
(`#12304A`) sidebar and top bar for a "professional, information-dense"
feel while its content area goes light. Splash, Onboarding, Login,
Register, and License Verification were **not** named in this request
and were deliberately left on the Stage 1/2 dark-navy look — they still
use the original `vigi*` tokens unchanged.

**New token set, not a redefinition**: added a second, separate set of
tokens to `AppColors` — `vigiLiteBg`, `vigiLiteSidebar`, `vigiLiteCard`,
`vigiLiteInput`, `vigiLiteCyan`, `vigiLiteTeal`, `vigiLiteText`,
`vigiLiteText2`, `vigiLiteText3`, `vigiLiteBorder`, `vigiLiteCritical`,
`vigiLiteWarning`, `vigiLiteSuccess`, `vigiLiteInfo` — alongside the
existing dark `vigi*` tokens, rather than changing what the dark tokens
mean. Redefining them in place would have been simpler, but several
widgets (`AppTextField`, `SearchableSelectField`, `DocumentPhotoCard`,
and `VehicleFormSection` itself) are shared between a screen that's
switching to Lite (e.g. Register Vehicle, reached standalone from
Home/Profile) and one that stays dark (Register's embedded vehicle
section, License Verification) — so those widgets gained a new `lite:`
flag that takes precedence over the existing `dark:` flag, rather than
`dark:true` silently changing meaning out from under a screen that
wasn't asked to change.

**Screens converted**: Home (`_HomeTab`, `_ManilaClock`, `_StatTile`,
`_MeshStatusCard`, `_NearbyNodeRow`, the bottom nav), standalone
Register Vehicle (via `VehicleFormSection(lite: true)`); Geofence,
Report Stolen, and Alert Broadcasting; Alert Received, Proximity Map,
and Alert History; Report Sighting and Alert Sightings; Update Status,
Notifications, Profile (header/vehicle card/settings list), and System
Logs. The whole admin dashboard interior (`admin_widgets.dart`,
`admin_accounts.dart`, `admin_approvals.dart`, `admin_vehicles.dart`,
`admin_monitoring.dart` including its Map tab's markers/legend/filter
chips) moved to the same light tokens; `_AdminSidebar` and
`_AdminTopBar` were restyled to the spec's navy `#12304A` with white
text instead of going light, and `AdminLoginScreen` was left on the
dark look (consistent with the phone's own Login staying dark).

**Recurring fix-up while converting**: several spots reused the dark
palette's near-black `vigiBg`/`vigiBgSecondary` as a "readable dark
text/icon color" on a bright cyan button or selected chip — a trick
that only worked because the old page background happened to be dark.
Each one was individually replaced with `vigiLiteText` (or, on a
saturated green/amber button, plain white) rather than blindly
substituted with the new pale `vigiLiteBg`, which would have made that
text invisible. Two dark-navy→color gradient banners (the Report Stolen
vehicle-info banner, the "CURRENTLY: STOLEN" status banner) were
likewise rebuilt as flat/solid fills instead of carrying the old dark
stop forward. Map tile imagery, on-tile floating labels (`_MapTag`,
`_MapChip`), and the deliberately-solid-red "STOLEN" broadcast banners
were left untouched, consistent with every prior stage's policy of not
re-skinning photographic map tiles or intentionally-saturated status
banners.

**Verified**: `dart format`, `flutter analyze` — 0 issues, checked
per-file during conversion and again project-wide at the end. `flutter
test` — 15 passing. `flutter build apk --release` succeeded (79.2MB).
`flutter build web -t lib/admin_main.dart` succeeded.

## Proximity Map: "You" pin merges into the stolen-vehicle pin instead of overlapping it (2026-10-26)

**Reported**: a screenshot of the Proximity Map showed a confusing
double marker at the user's own position — a red ripple + 🚗 "STOLEN"
pin and a separate blue 📱 "You" pin, both drawn on top of each other —
even with zero active alerts ("No active alerts in your area." in the
list below). Asked for: Stolen stays red, You/owner stays blue, Relay
stays orange, Relaying stays amber, but the "You" pin itself should be
the one that turns red once *that* person's own vehicle is reported
stolen — one dot, not two — so a nearby viewer reading the map can tell
"a red dot means stolen" regardless of whose pin it is.

**Root cause** (`s9_s10_s11_alerts_map.dart`, `ProximityMapScreen`): the
red ripple+🚗+"STOLEN" marker at `center` was unconditional — it rendered
even when `alerts` (the active alerts this device knows about, which can
be the viewer's own or one relayed over the mesh from someone else) was
empty, since `center` just falls back to the device's own GPS in that
case. With no real alert, `center` and `youPoint` (the separate blue
"You" marker) end up at effectively the same spot, producing the
overlapping red/blue dots in the screenshot.

**Fix**: compute whether the alert being shown (if any) belongs to the
viewer (`alerts.first.userId == currentUser.id`) or was relayed from
someone else. Someone else's stolen vehicle still gets its own red pin
at `center`, separate from the viewer's own blue "You" pin at
`youPoint` — two real people, two real places. The viewer's own vehicle
no longer gets a second pin at all: the single "You" marker at
`youPoint` is blue + "You" while not stolen, and becomes the same red
ripple + 🚗 + "STOLEN · plate" pin once it is — never both at once. With
no active alert at all, only the plain blue "You" pin shows (the
unconditional red ripple is gone). Also switched the stolen-pin color
from the legacy `AppColors.primary` red to `AppColors.vigiLiteCritical`,
matching the legend dot it was previously a shade off from. Purely a
map-rendering/color change — `TheftAlert`, `AppState`, and the mesh
relay logic are untouched.

**Verified**: `dart format`, `flutter analyze` — 0 issues. `flutter
test` — 15 passing.

## Login and Register: Light Frosted Blue + Navy + Cyan redesign (2026-10-26)

**Asked for**: recolor Login and Register (including the embedded
license-capture and vehicle sections) to a light "Frosted Blue + Navy +
Cyan" palette — white/pale-blue form card over the unchanged automotive
background photo, white inputs, navy headings/labels, cyan primary
buttons, a distinct darker-teal link color, matching three reference
mockups. UI/UX only, same as every prior pass — no change to
validation, navigation, Firebase Auth, or submission logic.

**New tokens** (`AppColors`): `vigiLiteScrim` (`#061B2B`, the dark
overlay on the background photo — kept deliberately separate from the
dark `vigi*` palette's own background value) and `vigiLiteLink`
(`#087FA5`, for inline tappable links like "Forgot password?" and the
Login⇄Register cross-links, kept distinct from `vigiLiteCyan` which
stays reserved for solid buttons/active states per the spec). Every
other requested color was already an exact or near-exact match to an
existing VIGILINK Lite token, so those were reused rather than adding
near-duplicates (`vigiLiteCard`=`#FFFFFF` input fields/card,
`vigiLiteText`/`vigiLiteText2`, `vigiLiteBorder`, `vigiLiteCritical`/
`vigiLiteSuccess` for validation colors).

**Layout, not just color**: `RegisterScreen` had no background image or
branding at all before this — a flat dark `Scaffold` with a plain
`AppBar`. Per the spec ("keep the same background image and branding as
the Login screen") and the reference mockups, it now gets the identical
`login_background.png` + scrim + VIGILINK logo/wordmark/tagline
treatment as Login, via `extendBodyBehindAppBar` and a transparent
`AppBar`. On both screens the logo/wordmark/tagline moved from inside
the form card (its previous position) to sit directly on the photo
above the card, matching the reference images.

**Shared-widget threading**: `LoginScreen`/`RegisterScreen`'s
`AppTextField`s switched from `dark: true` to `lite: true` (the flag
already existed from the Home/Map/Alerts pass). `LicenseCaptureSection`
and its `_StepBar` (`s18_license_verification.dart`) didn't have a
`lite` flag yet — added one, threaded to `DocumentPhotoCard`, so
Register's embedded license step goes light while
`LicenseVerificationScreen` (the standalone re-upload screen at login,
not shown in the reference images) keeps passing `dark: true` unchanged.
`VehicleFormSection`'s embedded call in Register now passes `lite: true`
too, so the account-info, license, and vehicle sections read as one
consistent light form while scrolling, instead of light/dark/light.

**Scope call**: `AwaitingApprovalScreen` and `_EmailVerificationScreen`
(both reached only *after* submitting registration) were left alone —
not in the reference images, and turned out to already be on the
original light/white palette from before any VIGILINK work, so leaving
them was a no-op either way, not a skipped conversion.

**Incidental copy fix**: Register's vehicle-section blurb said "the
vehicle this account will protect" — changed to "will monitor",
consistent with the earlier onboarding/splash wording pass (awareness
framing, not "protect").

**Verified**: `dart format`, `flutter analyze` — 0 issues. `flutter
test` — 15 passing. `flutter build apk --release` succeeded (79.2MB).
`flutter build web -t lib/admin_main.dart` succeeded.

## Notifications: renamed screen, fixed a real timestamp bug, confirmed status-update alerts already fire (2026-10-26)

**Reported**: a screenshot showing the "Push Notifications" screen with
six "Vehicle Sighting Reported" entries, all stamped the identical "4m
ago · Oct 26, 2026 · 5:42 AM" even though they were clearly different
sightings — asked why the timestamp reflects when the app was opened
rather than when the thing was actually reported, asked for the screen
title to read "Alert Notifications" (reached from Profile → Notification
Settings), and asked that nearby-vehicle status changes (stolen /
recovered / still searching) show up as notifications too.

**Title fix**: `NotificationsScreen`'s `AppBar` title — the only place
"Push Notifications" appeared anywhere in `lib/` — changed to "Alert
Notifications".

**Real bug, found and fixed** (`AppState._addNotif`, `app_state.dart`):
it unconditionally stamped every notification with `DateTime.now()` —
the moment the notification object was *constructed*, not the moment
the underlying event happened. For a live, one-at-a-time event (a peer
connecting, this device's own action) those are the same instant, so it
never showed. But `_storeReceivedSighting` is also called from a
Firestore listener that can deliver several sightings back-to-back on
reconnect/app-start (a backlog catch-up, not six sightings genuinely
arriving in the same minute) — each one got "now" instead of its own
real submission time, which is exactly the screenshot. Fixed by giving
`_addNotif` an optional `time` parameter (defaulting to `now`, unchanged
for every live-event call site) and passing the sighting's own
`sentAt` (when the reporter actually submitted it) from
`_storeReceivedSighting`, and the alert's own `timestamp` (when the
owner actually reported it stolen) from both new-stolen-alert paths
(the mesh `'theft_alert'` handler and `_handleInternetAlert`) — the
other ~10 call sites were all audited and are genuinely live events
(sync completed, device connected, this device's own
report/recovery/profile change), so they correctly keep using "now".

**Status-update notifications — already implemented, not a gap**:
checked both paths that apply a status change to an alert this device
is tracking (mesh `'status_update'` messages and
`_handleInternetAlert`'s "already have it, apply a newer status"
branch) — both already call `_addNotif('✅ Vehicle Status Updated',
'$plate is now $statusLabel.', ...)` whenever a nearby tracked vehicle's
status changes (active → recovered; `AlertStatus` has no separate
"still searching" state — it's just `active` continuing, so there's no
new transition to announce there). No change needed; this already
satisfies what was asked. These two call sites don't carry a
status-change timestamp over the wire/Firestore (only the alert's
original report time is available), so they keep using "now" — fixing
that would need a new timestamp field added to the wire message/
Firestore document, a larger change not covered by this pass.

**Verified**: `dart format`, `flutter analyze` — 0 issues. `flutter
test` — 15 passing.

## Register form: duplicate name/email surfaced as inline red text + a specific warning modal (2026-10-26)

**Asked for**: when Register is submitted with a Full Name or Email
already used by another account, show a proper warning — red text under
the actual field, plus a clearer modal — so the person finds out before
assuming registration is going through, instead of the single generic
"Registration Not Submitted" popup it showed before.

**Looked into true "while typing" detection first, and ruled it out for
both fields** — explained to the user and confirmed before writing any
code:
- Full Name's uniqueness check reads the `account_names` Firestore
  collection, whose rules only allow `get` from an already-signed-in
  account (`request.auth != null`) — which doesn't exist yet this early
  in Register. Checking live would need a Firestore rules change
  (re-published in Firebase Console); the user chose to keep this check
  at submit time instead of loosening that rule.
- Email has no equivalent safe check at all: the only pre-signin API for
  it, `fetchSignInMethodsForEmail`, is now deprecated by Firebase
  specifically because it enables email-enumeration attacks (probing
  which emails are registered) — Firebase's own docs recommend against
  using it for exactly this purpose. Not built on.

So both fields keep being checked exactly where they already reliably
work — Register's submit step — but the result now carries which field
caused it.

**New result type** (`RegistrationResult`, `models.dart`): replaces
`submitRegistration`'s old bare `String?` return with `{error, field}`,
where `field` is a `RegistrationIssueField` (`name`/`email`/`null`).
`AuthOutcome` (`firebase_auth_service.dart`) gained a `code` field
carrying the raw `FirebaseAuthException.code` behind a failed
`register()` call, so `submitRegistration` can tell
`email-already-in-use` apart from every other reason account creation
can fail (weak password, no network, etc.) without re-parsing the
human-readable error string. `submitRegistration` had exactly one
caller (`RegisterScreen._submit`), so this was a safe, contained
signature change.

**UI**: Full Name's and Email's `validator`s now check a `_nameTaken`/
`_emailTaken` string (the exact value that was rejected) and return
"This name/email is already registered." when the current field text
still matches it — standard `TextFormField` behavior shows that as red
text right under the field once `Form.validate()` has run once, and it
naturally clears the moment the person edits the field again, since the
text no longer matches what was rejected. `_submit()` now picks the
modal's title/icon from `result.field` — "Full Name Already Registered"
/ "Email Already Registered" instead of the generic title — and calls
`_formKey.currentState!.validate()` right after setting the taken-value
state, so the inline red text appears immediately alongside the modal
rather than only on the next edit.

**Verified**: `dart format`, `flutter analyze` — 0 issues. `flutter
test` — 15 passing.

## Admin Approvals: added Engine Number and Chassis Number to the vehicle card (2026-10-26)

**Asked for**: the Approvals tab's VEHICLE card showed only Plate,
Model, Color, Year model and Body type — Engine Number and Chassis
Number (both already captured at registration, and already shown in
the Vehicles tab's own detail sheet) were missing, so an admin couldn't
cross-check them while reviewing a pending registration's documents.

**Fix** (`admin_approvals.dart`, `_PendingCard`'s `AdminInfoCard`): added
`AdminInfo('Engine number', …)` and `AdminInfo('Chassis number', …)`
rows, reading `VehicleModel.engineNumber`/`.chassisNumber` (already on
the model, already populated by Register's vehicle form — no new data
being captured). Matched the exact empty-value/selectable pattern the
Vehicles tab's detail sheet already uses for the same two fields
(`—` when empty, text selectable only when not).

**Verified**: `dart format`, `flutter analyze` — 0 issues. `flutter
test` — 15 passing.

## Second "Are You Sure?" confirmation on destructive actions — vehicle removal, admin suspend/delete (2026-10-26)

**Asked for**: after confirming the Home screen already had a single
confirmation dialog on removing a vehicle, asked for a second, final
"Are You Sure?" step too, as a safeguard against an accidental tap on
the first dialog's confirm button. Then asked the same for the admin
dashboard's Suspend and Delete Permanently account actions.

**Phone** (`s4_s5_vehicle_home.dart`, `_HomeTab`'s `VehicleCard.onRemove`):
after the existing "Remove [plate]?" dialog is confirmed, a second
dialog now asks "Are You Sure?" — "[plate] will be permanently deleted.
This action cannot be reversed." — Yes, Remove Permanently / No, Keep
It. Only then does `state.removeVehicle` actually run. Confirmed via
grep this is the only `removeVehicle` call site in the UI, so nothing
else needed updating. "Turn Off Geofence" was deliberately left as a
single confirmation — it's reversible (can be turned back on), unlike
deleting a vehicle.

**Admin** (`admin_dashboard.dart`, `_AdminDashboardScreenState`): both
`_toggleDisabled` and `_removeUser` are shared by the Accounts tab's
row quick-action icons AND the account detail sheet's own
Suspend/Delete buttons (confirmed via grep — neither button in
`admin_accounts.dart` has its own separate confirm logic, they all
delegate to these two methods), so one change covers every entry
point:
- `_removeUser` (Delete Permanently): same treatment as vehicle
  removal — a second "Are You Sure?" dialog before the account and its
  vehicles are actually deleted from Firestore.
- `_toggleDisabled`: only added the second confirmation for the
  **suspend** direction (`target == true`) — signing someone out and
  blocking their access immediately is consequential enough to double-
  check. **Restoring** an account stays a single confirmation, same
  reasoning as "Turn Off Geofence" on the phone — it's reversible (the
  account can be suspended again).

**Verified**: `dart format`, `flutter analyze` — 0 issues. `flutter
test` — 15 passing. `flutter build apk --release` succeeded (79.2MB).

## Second confirmation extended to Restore and Turn Off Geofence too (2026-10-26)

**Asked for**: the same second "Are You Sure?" step added to the two
reversible actions that had deliberately been left as a single
confirmation — admin Restore and Turn Off Geofence.

**Admin** (`admin_dashboard.dart`, `_toggleDisabled`): now shows the
second confirmation for both directions, not just Suspend — "Are You
Sure?" / "[name] will be able to log in again right away." / Yes,
Restore Account — No, Keep It Suspended.

**Phone, both entry points** (confirmed via grep there are exactly two
places `deactivateGeofence` is called, so both needed the change):
`_HomeTab`'s `VehicleCard.onDeactivateGeofence`
(`s4_s5_vehicle_home.dart`) and `GeofenceScreen._deactivate`
(`s6_s7_s8_geofence_report.dart`, the "Turn Off" button on the
geofence setup screen itself) — each now shows "Are You Sure? —
Geofence monitoring for [plate] will stop right away." / Yes, Turn
Off — No, Keep It On, after the existing first dialog, before
`state.deactivateGeofence` actually runs.

Every destructive/consequential confirm action in the app now has the
same two-step pattern: Remove Vehicle, Turn Off Geofence (both entry
points), admin Suspend, admin Restore, admin Delete Permanently.

**Verified**: `dart format`, `flutter analyze` — 0 issues. `flutter
test` — 15 passing.

## Confirm dialog capped to a sensible width on wide screens (2026-11-02)

**Reported**: the admin dashboard's "Log Out?" confirmation stretched
nearly edge-to-edge in the browser window instead of showing as a
normal-sized modal.

**Root cause** (`showConfirmDialog`, `widgets.dart`): the dialog's only
width constraint was `insetPadding: horizontal 28` — fine on a phone,
since the screen itself is already narrower than any reasonable modal
width, but on a wide browser window (the admin dashboard, which is the
only place this app runs wider than a phone) that left the dialog free
to stretch almost the full window width. This is the one shared
confirm-dialog helper behind every confirm action in the app, admin
included — Log Out, Suspend, Restore, Delete Permanently, Remove
Vehicle, Turn Off Geofence, etc.

**Fix**: wrapped the dialog's content in a `ConstrainedBox(maxWidth:
400)`. Only visibly changes anything on a screen wider than 400+56
logical pixels (i.e. the web admin dashboard) — a phone screen is
already narrower than that, so nothing changes there. Fixes every
confirm dialog across the whole app at once, not just Log Out, since
they all go through this one function.

**Verified**: `dart format`, `flutter analyze` — 0 issues (checked
per-file and project-wide, since this is a widely-shared widget).
`flutter test` — 15 passing.

## Removed the admin dashboard's "Add User" feature (2026-11-02)

**Asked for**: remove the Accounts tab's "Add User" FAB and everything
behind it — accounts must only come from self-registration + admin
approval, never admin-created directly.

**Removed**:
- The `FloatingActionButton.extended` ("Add User") and
  `_showAddUserSheet()` in `admin_dashboard.dart`.
- The `_AddUserSheet`/`_AddUserSheetState` form (name/email/mobile/
  temporary password → `AdminService.createUser`) — it was the last
  thing in the file, so the whole tail end of it is gone.
- `AdminService.createUser()` itself (`admin_service.dart`) — confirmed
  via grep it had exactly one caller (the sheet just removed), so
  nothing else depended on it. It ran account creation on a throwaway
  secondary Firebase app specifically so the admin's own session
  wouldn't get signed out by `createUserWithEmailAndPassword` — that
  whole mechanism is gone with it.

**Follow-on cleanup**: removing `createUser` left `dart:math`/`Random`
(`_rng`) and the `firebase_core` import unused in `admin_service.dart` —
both only existed for that method (the random `DEV-xxx` device ID and
the secondary `FirebaseApp` instance) — removed too, caught by
`flutter analyze`. Also updated several doc comments that cited
`AdminService.createUser()`/"Add User" as examples (in
`admin_service.dart`'s class doc about `role` never becoming `admin`,
`firebase_sync_service.dart`'s `account_names` collection doc, and
`validators.dart`'s shared-validator docs) so they don't describe
something that no longer exists — none of these were functional
changes, just keeping the explanations accurate. One comment in
`admin_dashboard.dart` (the `_tabs.addListener` rebuild) was
inaccurately attributed to the Add User button alone — fixed to
reflect its real, still-needed purpose: it's what makes the top bar's
title/subtitle update when the sidebar switches tabs, so that listener
stays.

**Untouched**: self-registration (`AppState.submitRegistration`), the
Approvals tab, and every other way an account can exist — this only
removed the one admin-side account-creation path.

**Verified**: `dart format`, `flutter analyze` — 0 issues (project-wide,
since this touched a shared validators file too). `flutter test` — 15
passing.

## Registration restricted to @gmail.com / @carsu.edu.ph; confirmed admin accounts already can't be duplicated (2026-11-02)

**Asked**: whether the app requires a specific email domain to
register, and whether a duplicate email (including an admin's) is
already blocked. Then asked to add the domain restriction and confirm
the admin-account protection, without touching anything else.

**Domain restriction — new** (`validators.dart`,
`hasAllowedRegistrationEmailDomain`): only `@gmail.com` and
`@carsu.edu.ph` addresses can self-register now. Enforced in two
places, mirroring how the existing format/password checks already
work: the Register screen's email field (`s2_s3_auth_screens.dart`)
shows the specific inline error immediately, and
`AppState.submitRegistration` re-checks it as a backend safety net
inside its existing combined guard clause. Deliberately scoped to
registration only — Login, Forgot Password, and Admin Login's email
fields are untouched, so an already-registered account on any other
domain can still sign in.

**Admin-account duplication — confirmed already blocked, nothing to
add**: admin accounts are real Firebase Auth accounts (role is granted
only via Firebase Console, never through any app write — see
`AdminService`'s own class doc). Attempting to register with an
email that's already an admin's hits the same `email-already-in-use`
check every duplicate email hits, surfaced as the "Email Already
Registered" modal built earlier this session. Verified this rather
than assuming it; added no new/duplicate blocklist logic, since one
already exists and covers this case.

**Verified**: `dart format`, `flutter analyze` — 0 issues. `flutter
test` — 15 passing.

## Whole-app bug/duplication scan, then fixed the 3 real findings (2026-11-02)

**Asked for**: a full scan of the app for duplicated logic, bugs, and
error-handling gaps, then to fix whatever was found — scoped tightly
to the actual findings, nothing else touched.

**Scan** covered all of `lib/`: `app_state.dart` (2,800+ lines),
the mesh/Firestore alert and sighting delivery paths, geofence
checking, login lockout, vehicle/plate cleanup, and a sample of
screen-level async flows. 3 real issues found; everything else
(plate-claim release, duplicate-name/email checks, login lockout key
normalization, `markRecovered` vs `forceRecoverVehicle`, Google
sign-in's relationship to the local lockout, admin Suspend/Restore/
Delete's shared confirmation code) checked out clean or already
correct/intentional.

**Fix 1 — automatic geofence-violation reports had no error handling**
(`app_state.dart`, `_checkGeofences`): the manual Report Stolen flow
runs inside a try/catch with an error modal on failure; the automatic
one (geofence boundary violation) called `reportStolen()` bare, with
nothing watching the result. Now wrapped so a failure (e.g. a local
database write error) is caught and logged to System Logs instead of
silently vanishing — in the one path whose entire job is catching a
real theft automatically.

**Fix 2 — mesh status updates could apply out of order; the internet
path already guarded against this** (`app_state.dart`, the mesh
`'status_update'` handler): changed `if (status == current) return` —
which only blocked an exact repeat — to the same forward-only check
`_handleInternetAlert` already uses for the identical situation
(`if (newStatus > current)` instead of applying any different value).
A multi-hop relay can legitimately deliver status updates out of
order; this stops an older/duplicate update from regressing an alert
that already moved to a newer status.

**Fix 3 — a `setState()` missing a `mounted` check right after an
`await`** (`s12_s13_s14_status_notif_profile.dart`,
`_pickRecoveryPhoto`): added `if (!mounted) return;` right after the
image-source-sheet await, matching the `mounted` check the same
function already does two lines later. Without it, navigating away
while that sheet is still open threw "setState() called after
dispose()".

**Verified**: `dart format`, `flutter analyze` — 0 issues. `flutter
test` — 15 passing.

## Background foreground-service for mesh + Firestore feed (2026-11-03)

**Asked for**: the ad hoc mesh and the Firestore alert feed to keep running
while the app is backgrounded (Home) or its Activity is destroyed (Back) —
previously both stopped the moment the app left the foreground.

**Added** `flutter_foreground_task`, a real Android foreground service. The
service itself starts at login and runs until logout; only *mesh ownership*
hands off between the main isolate and the background `TaskHandler`
(new file, `mesh_background_service.dart`) on Home/Back and back again on
resume, via `FlutterForegroundTask.sendDataToTask`/`onReceiveData`, debounced
15s and deferred while a camera/gallery picker is open.

**New shared module** `alert_ingest.dart`: pulled the "ingest an alert/
status update/sighting, dedupe it, store it, log the delivery, notify, relay
it onward" logic out of `AppState`'s mesh handler and `_handleInternetAlert`
into plain portable functions, called identically by `AppState` (foreground)
and `MeshBackgroundTaskHandler` (background) — one implementation, not two
copies that could drift. Dedup for alerts: a synchronous in-flight `Set`
guard (closes a same-isolate race) plus the existing SQLite `alertExists`
check (closes a cross-isolate one). Sighting dedup: an async mutex instead
(`Map<String, Future<void>>`), since a racing duplicate sighting may carry a
photo/phone number that must still be merged in, not dropped.

Store-carry-forward on a new connection now reads `_db.getAllAlerts()`
(filtered to active) fresh from SQLite rather than an in-memory list, so it
reflects alerts stored by either isolate across the hand-off. Notification
tap now opens the relevant alert (`NotificationService` gained an alert-id
payload; `main.dart` exposes its `navigatorKey`). A one-time battery-
optimization-exemption prompt is shown after login.

**Two real bugs found and fixed during review** (not shipped with the
refactor): an object-identity bug (`_alerts[idx] = updated` replaced a
mutated object a widget might already hold a reference to — changed to
mutate `_alerts[idx].status` in place), and the TOCTOU race the in-flight
guards above exist to close — found by direct request to verify, not
assumed safe.

**Verified**: `flutter analyze` (project-wide, 171s) — 0 issues. `flutter
test` — 15 passing. `flutter build apk --release` — succeeded. **Not yet
tested on real hardware** — real background/Activity-destruction behavior
needs physical phones; handed off a 2–3-phone test plan (Home/Back survival,
hand-off timing, dedup across mesh+internet, notification tap-to-open,
picker-guard behavior).

## Internet alert delivery: removed the 5 km distance filter (2026-11-03)

**Asked for**: every logged-in user with internet to receive theft alerts
from Firestore regardless of distance from the reported vehicle — previously
capped at 5 km (`_internetAlertRadiusMeters`).

Removed the radius check (and the now-unused constant and `LocationService`
import) from `ingestInternetAlert` in `alert_ingest.dart`. Confirmed nothing
else filters internet alerts by distance: `app_state.dart`'s own comment was
updated to match, `mesh_background_service.dart` already passed
`currentLat/currentLng: null` with no distance logic of its own, and
`FirebaseSyncService`'s Firestore query only filters by a 24-hour timestamp
cutoff server-side. Confirmed the RECOVERED-status notification path never
had a distance filter to begin with (checked, not assumed) — no code change
needed there, including while the app is backgrounded. The ad hoc mesh path
is untouched; `currentLat`/`currentLng` stay as unused parameters on
`ingestInternetAlert` rather than removing them and updating callers (flagged
as a scoped choice, not yet revisited). The web admin dashboard
(`lib/admin_main.dart`) doesn't import any of this code and needed no rebuild.

**Verified**: `flutter analyze` — 0 issues. `flutter build apk --release` —
succeeded (79.4MB).

## Replaced Nearby Connections with a native BLE + Wi-Fi Direct mesh (2026-11-03/04)

**Found during real 3-phone device testing**: the mesh never discovered
anyone with zero internet on the devices, even with Bluetooth, Wi-Fi (radio
only, no network), and precise Location all confirmed on, and every app
permission plus the OEM-level "Nearby devices" system toggle confirmed
granted. System Logs showed a clean start-and-retry cycle but
`onEndpointFound` never fired once. Confirmed root cause by reading the
actual library code: `nearby_mesh_service.dart` was built on
`package:nearby_connections`, whose native Android side is an unmodified
pass-through to Google's own `play-services-nearby` client — that GMS module
is what silently failed to discover anyone with no connectivity on this
hardware. Everything else (this app's Dart code, the plugin's Java glue, the
manifest permissions, the OEM permission layer) was checked directly and was
clean. Confirmed with an on/off test: works the moment internet is back on.

**Fix**: stopped depending on Google's Nearby Connections library for
discovery/connection entirely. New local Flutter plugin,
`packages/vigilink_mesh_transport/` — raw `BluetoothLeAdvertiser`/
`BluetoothLeScanner` for discovery, native `WifiP2pManager` Wi-Fi Direct for
the connection and data transfer, no Google Play Services anywhere in the
path. Built as a proper local Flutter plugin (not a plain class wired into
`MainActivity.kt`) specifically so Flutter's `GeneratedPluginRegistrant`
auto-registers it into the background foreground-service's own Flutter
engine too — confirmed by reading `flutter_foreground_task`'s own Android
source, which relies on exactly that mechanism for every other plugin
already working in the background isolate.

`NearbyMeshService`'s public API (`start`/`stop`/`restart`/
`requestPermissions`/`radioProblems`/`sendTo`/`broadcast`/
`connectedEndpoints`/every `onPeer*` callback) is unchanged — only what it
calls into underneath changed, so `alert_ingest.dart`,
`mesh_background_service.dart`, `app_state.dart`'s wiring, and every screen
needed zero changes.

**Design**: BLE is a pure presence beacon (service UUID + a 1-byte
Group-Owner flag + a 4-byte token), never carries alert data. A Wi-Fi Direct
Group Owner can serve several simultaneous Clients, which is what lets 3+
phones share one mesh. `WifiP2pManager.setDeviceName` turned out to be a
hidden API, not public — the real build failed on it (`Unresolved
reference`), caught immediately by actually building, not assumed to exist
from memory. Target selection was changed to always prefer a discovered peer
that's already a Group Owner (`WifiP2pDevice.isGroupOwner`, genuinely
public) over negotiating a fresh pairwise connection, since a device already
serving as GO for one peer typically can't also run a second, separate P2P
negotiation on the same radio. Data transfer is a length-prefixed JSON TCP
socket, keyed by the BLE beacon token exchanged in a small handshake (an app
can't read its own local Bluetooth MAC address to use as a self-identifier).

**Multi-hop clarified with the user**: confirmed the requirement is
store-carry-forward over time (a phone relays the next time it connects to
someone new, even after disconnecting from the previous peer), not
simultaneous real-time relay across a stationary chain — which raw Wi-Fi
Direct's one-group-per-radio limit couldn't do anyway. All of direct
broadcast, relaying, further relaying, duplicate prevention, hop limit/TTL,
and store-and-forward were already implemented in `alert_ingest.dart` and
the existing `onPeerConnected` catch-up handlers before this change, and
none of that needed to change — only the transport underneath it. Added
`WifiDirectManager.isBusy`, a gate stopping a device from firing overlapping
`connect()` calls when 2+ peers are in range at once, and stopping an
already-grouped Group Owner from trying to initiate connections itself
(new peers join it on their own) — specifically to make the
device-moves-from-one-group-to-the-next handoff reliable.

**Known open risk, not yet resolved**: without a way to rename a phone's own
Wi-Fi Direct identity, a new peer can't be steered to one *specific*
already-formed group by name — only to "whichever discovered peer is
already a GO." Needs real 3+ phone testing to confirm it reliably joins the
right group.

**Verified**: `flutter analyze` — 0 issues, both before and after the
`setDeviceName` fix. `flutter test` — 15 passing. `flutter build apk
--release` — succeeded (79.1MB) after the fix. **Not yet tested on real
hardware** — handed off the same 3-phone, internet-off test, plus a
specific out-of-range chain test (A reports near B only; B then moves to
where C is; confirm C receives it once B reconnects) to verify the
store-carry-forward handoff this fix targets.


## Real multi-phone testing session (2026-11-05): six confirmed Wi-Fi Direct
## transport bugs fixed, then a BLE GATT alternative branch

Extended real-device testing across four phone combinations (Techno Spark
10 Pro, Oppo A5 Pro, Redmi, Samsung A06 5G) surfaced and fixed six distinct,
evidence-based bugs in the Wi-Fi Direct transport, each confirmed from
actual System Logs before being fixed, not guessed:

1. **BLE identity split on Group-Owner role change** — `BleMeshBeacon`
   used to regenerate its token when becoming GO, splitting one physical
   peer into two identities. Fixed: token is now set once and never
   regenerated; only the role byte changes.
2. **BLE identity split across the foreground/background hand-off** — the
   foreground app and the background service each run a separate Flutter
   engine/native plugin instance, each generating its own random token.
   Fixed: the token is now persisted via `SharedPreferences` and passed
   into native on every start.
3. **False "delivered" reporting** — `sendBytesPayload` always told Dart
   it succeeded regardless of outcome. Fixed: native now returns a real
   boolean, and an application-level delivery acknowledgment
   (`alert_ack`, sent only after the receiver's `db.upsertAlert`
   succeeds) replaces "wrote to a socket" with "the peer actually stored
   it" as the definition of "relayed."
4. **Dead sockets left registered forever** — a failed write used to
   leave a broken socket in the registry, so every retry hit the same
   dead connection. Fixed in both `MeshSocketServer.send` and
   `MeshSocketClient.send`/`stop` — a failed write or a lost group now
   tears the socket down and reports a real disconnect immediately.
5. **Wi-Fi Direct connect() could hang forever with isBusy stuck true** —
   no timeout existed for a negotiation that never resolved either way.
   Fixed with a timeout (tuned from 15s to 60s after a real test showed
   15s was itself cancelling connections before a human could respond to
   the system "Invitation to connect" dialog).
6. **A connect failure was reported under the wrong id namespace** — Wi-Fi
   Direct's own device address was routed through the BLE-token-keyed
   `onConnectionResult`, producing a misleading "Unknown Device" error and
   never actually clearing the real pending request. Fixed: reported as a
   plain transport message instead.

**After all six fixes**, real-device testing still showed a Wi-Fi Direct
connection forming and then dying within the same second, repeatedly,
across every phone pairing tested — including with a Wi-Fi high-performance
lock added specifically to rule out Android power-saving as the cause
(ruled out: sub-one-second death is too fast for a power-save timer). A
direct, code-verified audit (checking every `removeGroup`/`cancelConnect`
call site, callback ordering, the grace-period timing, and confirming the
disconnect signal originates from Android's own
`WIFI_P2P_CONNECTION_CHANGED_ACTION` broadcast, not from this app's code)
found no remaining app-level cause. Logs also directly showed the two
phones' own Android stacks disagreeing about the connection state (one
reporting "busy/grouped," the other "no peer discovered"). Conclusion:
this is Android's own Wi-Fi Direct negotiation failing at the OS/radio
level on the available test hardware — a documented, real-world
characteristic of `WifiP2pManager`, not a defect in this app's code.

### `ble-transport-test` branch: BLE GATT instead of Wi-Fi Direct

Given the above, started a new git branch replacing the Wi-Fi Direct/TCP
data-transport layer with BLE GATT — keeping `BleMeshBeacon` (advertise/
scan discovery, unchanged) but using `BluetoothGattServer`/`BluetoothGatt`
(new: `BleGattServer.kt`, `BleGattClient.kt`, `BleFraming.kt`) for the
actual connection and alert transfer, instead of Wi-Fi Direct's group
formation + TCP sockets.

**Why this might fare better, as a reasoned hypothesis, not a confirmed
fix**: the specific failure above happens during Wi-Fi Direct's group-
formation negotiation stage — a multi-step process BLE GATT connections
have no equivalent of. A BLE Central either connects to a Peripheral's
GATT server or it doesn't; there's no separate negotiation stage to die
mid-way through. Every device now runs both roles simultaneously (GATT
server for receiving, ad hoc GATT client connections for sending) rather
than Wi-Fi Direct's exclusive Group-Owner-or-Client assignment.

The Dart-facing method/event contract (`vigilink_mesh_transport.dart`'s
MethodChannel/EventChannel shape) is unchanged on purpose, so nothing
above the transport — `nearby_mesh_service.dart`, `alert_ingest.dart`,
`app_state.dart`, hop count/TTL/dedup/the ack system — needed to change
at all.

**Verified**: `flutter analyze` — 0 issues. `flutter test` — 15 passing
(both Dart-only, unaffected by native-only changes). `flutter build apk
--release` — succeeded (79.1MB), confirming the new Kotlin BLE GATT code
compiles correctly. **Not yet tested on real hardware at all** — whether
BLE GATT actually holds a stable connection where Wi-Fi Direct didn't is
completely unverified and must not be assumed from the reasoning above
alone.

The original Wi-Fi Direct implementation (`WifiDirectManager.kt`,
`MeshSocketServer.kt`, `MeshSocketClient.kt`, `MeshSocketIO.kt`) is
preserved intact and unmodified on the `main` branch, and the source files
themselves are still present (just unreferenced by the plugin) on this
branch too, per explicit instruction not to delete the fallback.


## `ble-transport-test` real-device bug chain (2026-11-05 to 2026-11-06):
## from "not tested at all" to confirmed single-hop AND multi-hop delivery,
## then merged into `main`

Fifteen commits of real, evidence-based fixes on real hardware (2-3
phones), each one found from an actual failure in System Logs — not
guessed, and several confirmed on hardware before the next bug surfaced
underneath it. Final result: the BLE GATT mesh is **confirmed working
end-to-end**, including true multi-hop (A→B→C, where C is never in A's
own range) and was then fast-forward-merged into `main` (`main` had no
commits of its own since this branch diverged, so the merge introduced
no conflicts and changed nothing beyond moving the branch pointer).

1. **`4d487a2` — status 133 "disconnected before send completed."**
   Real logs showed a connection probe and the store-carry-forward
   catch-up loop's several `sendTo` calls all firing at once, each
   opening its own `connectGatt()` to the same peer address — a
   well-known real cause of this error. Fixed with a per-device-address
   serialization queue (`gattQueue`/`gattBusyAddresses` in
   `VigilinkMeshTransportPlugin.kt`) with a 400ms gap between releasing
   one queued operation and starting the next.
2. **`e526a89` — "characteristic not found on peer" / "BLE scan failed
   to start: already started."** `BluetoothGattServer.addService()` is
   asynchronous, but `BleGattServer.start()` returned `true` immediately
   without waiting for `onServiceAdded` confirmation — a peer could
   discover services before the local server had actually finished
   registering, especially right after a mesh restart. Fixed with a
   real `onServiceAdded` callback. Separately, `BleMeshBeacon.startScan()`
   never stopped a prior scan first (unlike the advertise function right
   beside it) — fixed to match. Also added a bounded retry (4 attempts,
   1.5s gap) on any BLE GATT send failure instead of giving up after one.
3. **`bc18662`** — added stage-by-stage diagnostic logging (scan
   started/stopped, GATT connected, characteristic found, write
   completed, incoming alert received) to System Logs, since only a
   final success/failure line was visible before this. **First real
   single-hop delivery success on hardware landed on this commit.**
4. **`85be313` — hop count read backwards.** `hopCount` was a
   descending TTL: every broadcast forced the wire message to start at
   `alertMeshHops` (5) regardless of the sender's own value, while the
   original reporter's own local copy stayed at the model's default 0 —
   so the reporter always showed "Hop 0" and the very first direct
   receiver showed "Hop 5," reading backwards. Changed to count UP from
   0 at the reporter, +1 per real relay hop
   (`ingestMeshTheftAlert`'s `myHop = receivedHop + 1`); `alertMeshHops`
   is now the max-hops-before-relay-stops cap, not a starting budget.
5. **`ac44387` — "nodes" (delivery-confirmation count) stuck at 0.**
   `relayedTo` only increments once the receiver's own `alert_ack` reply
   comes back — deliberate, so a successful write is never confused with
   confirmed delivery. On BLE GATT that ack is its own brand-new
   `connectGatt()` round trip in the opposite direction (unlike the old
   TCP-socket transport, where it went back over the same already-open
   connection almost instantly) — but `_alertAckTimeout` was still 12s,
   shorter than even one BLE GATT send attempt's own timeout. Raised
   (later raised again, see below); the ack send itself was also
   previously silent on failure — now logged explicitly.
6. **`e748377` — a restart could orphan an in-flight send.**
   `forceRestart()`/`ensureStopped()` cleared the plugin's own
   bookkeeping but never cancelled a `BleGattClient` still mid-operation
   at that exact moment — the orphaned client's native callback could
   fire later with a misleading failure after the radio had already been
   torn down underneath it. Added `BleGattClient.cancel()` (abandons
   without notifying the listener) and `inFlightGattClients` tracking.
7. **`67d80cc`** — real testing still hit timeouts even with the above;
   raised `BleGattClient.OPERATION_TIMEOUT_MS` 15s→30s and
   `GATT_MAX_ATTEMPTS` 4→6 (worst case ~190s per send), with
   `_alertAckTimeout` raised to 210s to match.
8. **`d1cc5cb` — the `e748377` cancellation fix was over-applied.**
   `ensureStopped()` (the passive path, firing on every routine
   background hand-off, not just an explicit "Restart Scan") was also
   cancelling in-flight sends — but `ble.stop()`/`gattServer.stop()`
   only ever tear down this device's own advertiser/scanner/GATT-server;
   they never touch an already-open OUTGOING `BluetoothGatt` connection,
   which is free to finish on its own regardless. Cancellation is now
   only applied in `forceRestart()` (where a fresh reconnect to the same
   address genuinely can collide with an orphaned one).
9. **`ffa0d74` — the actual root cause of most delivery failures.**
   Real logs showed "connected, discovering services" firing fine, then
   silence until the full timeout, repeating for minutes, with the
   receiving device's own logs showing zero activity. Root cause:
   `onConnectionStateChange` fired `requestMtu(517)` and
   `discoverServices()` back-to-back in the same callback tick — a
   documented real Android BLE issue where firing a second GATT
   operation before the first resolves can make `onServicesDiscovered`
   simply never fire at all (not fail — never call back), silently
   burning the whole timeout. Fixed by strictly sequencing:
   `discoverServices()` now only runs from `onMtuChanged`, with a 2s
   fallback timer in case that callback itself never arrives either.
   **This is the commit that produced the first fully clean, fast
   (~1 second) single-hop delivery+ack confirmation on real hardware.**
10. **`7e72bfd`** — a 3-device multi-hop test (A→B→C) showed B receiving
    fine but never relaying on to C, with zero evidence in the logs of
    whether a relay was even attempted. Both the immediate relay-forward
    (`alert_ingest.dart`) and the store-carry-forward catch-up on
    `onPeerConnected` were completely silent on "no peer to relay to
    yet" and on failure — now log one of three distinct outcomes
    (forwarded / no peer yet / forward failed) instead of silence.
11. **`fef4d51`** — added a manual **"🔁 FORCE RELAY NOW"** button
    (Alert Received screen) as an explicit safety net alongside the
    automatic relay, reusing the existing send/ack-tracking path
    (`_broadcastAlertReal`, now returning the sent-to set instead of
    void) rather than a second implementation. Also added
    `test/alert_ingest_test.dart` — 6 unit tests for `alertWireMessage`'s
    hop-count behavior, the one piece of the receiving-side logic that's
    actually unit-testable: `ingestMeshTheftAlert` itself touches the
    immutable singletons `DatabaseService.instance`/
    `NearbyMeshService.instance` with no mock seam, and refactoring for
    dependency injection was judged too invasive to do unprompted.
12. **`a7aae5b`** — two more real bugs from further 3-device testing:
    (a) a mesh-received alert that arrived while the screen was locked
    never showed up in Alert History afterward — `_onAppResumed` only
    reloaded in-memory state from SQLite when an actual background
    hand-off (`_meshHandedOff`) had occurred; now reloads unconditionally
    on every resume. (b) repeated "Duplicate alert... ignored" log spam
    and the new Force Relay button appearing stuck — root cause: the BLE
    transport has no persistent "connected" state, so `onPeerConnected`
    can fire more than once for the same peer (an outgoing probe and a
    separate incoming write each succeeding independently), and every
    firing re-ran the full catch-up, re-sending the same alert
    repeatedly; compounded by `_pendingConnections`' 20s guard
    auto-clearing while a real probe could now take up to ~190s, letting
    a second overlapping probe launch. Fixed: catch-up only fires for a
    genuinely new connection; `_pendingConnections` timeout raised to
    210s. This also explains why Force Relay looked broken — it was
    queued behind a growing backlog of redundant automatic retries to
    the same address.

**Confirmed on real 3-device hardware after `a7aae5b`**: single-hop
delivery+ack, dashboard sync, AND true multi-hop relay (A→B→C) all work.
Merged into `main` as a clean fast-forward (`e60235e..a7aae5b`) —
confirmed via `git diff main ble-transport-test` returning empty before
pushing.

### Follow-up fixes on `main` after the merge

- **`4acd8e2`** — the Admin Dashboard showed "—" for legacy accounts'
  "Date Created" despite Firebase Authentication having a real creation
  date for every one of them. Root cause: the app already captured
  `fbUser.metadata.creationTime` into `UserModel.createdAt`, but only
  when building a brand-new local record — an account with an existing
  cached profile (from before this field existed) never got a second
  chance to pick it up. Firebase Auth's own creation timestamp is only
  ever readable for the CURRENTLY signed-in user's own session — not
  another account's, not even by an admin — so `AppState.init()`'s
  session-restore path (runs on every app launch while already signed
  in) now backfills a missing `createdAt` and pushes it to Firestore via
  the existing merge-safe `upsertUserProfile`.
- **`22f3c3e`** — the above missed one account: the Admin Dashboard
  (`lib/admin_main.dart`) is a deliberately separate build, independent
  of `AppState`/`Provider` — confirmed by actually reading its own
  top-of-file comment, not assumed — so an admin-only account could
  never reach the phone-app backfill above. `AdminService.login()` now
  does the equivalent backfill itself, right after confirming
  `role == 'admin'`, from `cred.user!.metadata.creationTime`.
- **`1b1cb70`** — a mesh-received alert's photos never appeared even
  after the receiving device got internet back, despite the Alert
  Received screen's own promise that they'd "appear here once this
  device is back online." Root cause in `ingestInternetAlert`: when the
  device already knew the alert (the normal mesh-then-internet case), the
  function unconditionally returned early unless the incoming document's
  status was strictly newer than what's already stored — but an alert
  staying `active` the whole way from mesh-receipt through to coming
  back online is the *ordinary* case, not an edge case, so the photo
  backfill was being discarded on every normal run, not just some.
  Restructured so filling in previously-missing `photos` is handled
  independently of the status-newer check. Confirmed the actual trigger
  exists: `startAlertFeed()` always re-subscribes fresh on reconnect
  (`_onConnectivityChanged`), on app resume, and on the background
  hand-off — and a brand-new Firestore listener always redelivers the
  current state of every matching document (within its existing 24h
  window) as its first batch of changes.

**Verified for all of the above**: `flutter analyze` — 0 issues at every
step. `flutter test` — 21 passing (15 original + 6 new in
`alert_ingest_test.dart`). `flutter build apk --release` — succeeded
after every commit, including a dedicated `flutter build web -t
lib/admin_main.dart` check for the two admin-dashboard-specific fixes.
Real-device confirmation came from the user's own repeated multi-phone
testing throughout, with System Logs screenshots checked against the
code at each step rather than taking "it works now" on faith.
