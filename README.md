# 🛡️ VehicleGuard — Real-Time Vehicle Theft Monitoring & Alert System

A Flutter mobile app for real-time vehicle theft detection, alert dissemination via a
real, zero-internet Bluetooth Low Energy ad hoc mesh (MANET/VANET), and centralized
monitoring — built for Butuan City, Philippines (Capstone Project, Caraga State
University).

---

## 📱 Screens Implemented (all 14 from the low-fidelity prototype)

| # | Screen | Route |
|---|--------|-------|
| S1 | Welcome / Splash | `/` |
| S2 | Register Account | `/register` |
| S3 | Login | `/login` |
| S4 | Register Vehicle | `/register-vehicle` |
| S5 | Home Dashboard | `/home` |
| S6 | Set Geofence | `/geofence` |
| S7 | Report Stolen | `/report` |
| S8 | Alert Broadcasting | `/broadcasting` |
| S9 | Alert Received (Nearby User) | `/alert-received` |
| S10 | Proximity Map | `/prox-map` |
| S11 | Alert History | `/alert-history` |
| S12 | Update Vehicle Status | `/update-status` |
| S13 | Push Notifications | `/notifications` |
| S14 | User Profile | `/profile` |
| +  | System Logs | `/logs` |
| S16 | Report a Sighting (nearby user → owner) | `/report-sighting` |
| S16 | Sightings of My Stolen Vehicle (owner) | `/alert-sightings` |
| S18 | Driver's License Verification (login check for accounts with no license on file; at registration it is part of the Register form) | — |

Registration requires a photo of the front and back of a valid driver's license (S2), and vehicle
registration (S4) requires separate photos of the vehicle's OR and CR.

The web-only **Admin Portal** is a separate build (`flutter build web -t lib/admin_main.dart`) and is
intentionally not part of the phone app. It has four tabs: **Accounts** (user information, driver's
license), **Vehicles** (registration records and OR/CR photos), **Live Activity** and **Map** (FR-11).

---

## 🚀 Getting Started

### Prerequisites

1. **Flutter SDK** — Install from https://flutter.dev/docs/get-started/install
   - Recommended: Flutter 3.19+ (Dart 3.x)
2. **Android Studio** — For Android emulator
   - OR connect a physical Android device (Android 10+)
3. **VS Code** or **Cursor** with the Flutter & Dart extensions

### VS Code / Cursor Extensions

Install these from the Extensions panel (`Ctrl+Shift+X`):
- `Dart` (by Dart Code)
- `Flutter` (by Dart Code)

---

## 📦 Installation & Setup

### Step 1 — Open the project
```bash
# Open in VS Code
code vehicleguard/

# Or in Cursor
cursor vehicleguard/
```

### Step 2 — Install dependencies
```bash
flutter pub get
```

### Step 3 — Run on emulator or device
```bash
# List available devices
flutter devices

# Run on a specific device
flutter run

# Run on Chrome (for quick UI testing — no GPS/BLE)
flutter run -d chrome
```

### Step 4 — Build APK (for device installation)
```bash
flutter build apk --release
# APK output: build/app/outputs/flutter-apk/app-release.apk
```

---

## 🔑 Accounts

There is no demo account. Register through the app with a real email address and verify it via the
link Firebase sends. Admin accounts are created by hand in the Firebase Console (see `Progress.md`).

---

## 🗂️ Project Structure

```
lib/
├── main.dart                          ← App entry point & route config
├── models/
│   └── models.dart                    ← UserModel, VehicleModel, TheftAlert,
│                                        AdHocNode, NotifItem, SystemLog, etc.
├── services/
│   ├── app_state.dart                 ← ChangeNotifier — all business logic,
│   │                                    auth, vehicle CRUD, alert broadcasting,
│   │                                    foreground mesh ownership, logging
│   ├── nearby_mesh_service.dart       ← Dart-facing mesh API (wraps the real
│   │                                    BLE transport plugin)
│   ├── alert_ingest.dart              ← shared, portable alert/sighting ingest —
│   │                                    dedup, hop-count, relay — used by BOTH
│   │                                    AppState and the background service
│   └── mesh_background_service.dart   ← foreground-service TaskHandler: keeps
│                                        the mesh + Firestore feeds alive while
│                                        the app is backgrounded
├── utils/
│   ├── app_theme.dart                 ← AppColors, AppTheme
│   ├── validators.dart                ← shared mobile-number check
│   └── time_format.dart               ← shared "5m ago" formatter
├── widgets/
│   └── widgets.dart                   ← Shared: AppCard, AppTextField,
│                                        PrimaryButton, VehicleCard, AlertLogItem,
│                                        NodeRelayRow, ProximityNodeRow, StatusBadge
└── screens/
    ├── s1_splash_screen.dart          ← S1: Welcome/Splash
    ├── s2_s3_auth_screens.dart        ← S2: Register, S3: Login
    ├── s4_s5_vehicle_home.dart        ← S4: Register Vehicle, S5: Home Dashboard
    ├── s6_s7_s8_geofence_report.dart  ← S6: Geofence, S7: Report Stolen,
    │                                    S8: Alert Broadcasting
    ├── s9_s10_s11_alerts_map.dart     ← S9: Alert Received, S10: Proximity Map,
    │                                    S11: Alert History
    ├── s12_s13_s14_status_notif_profile.dart
    │                                  ← S12: Update Status, S13: Notifications,
    │                                     S14: Profile, + System Logs
    ├── s16_sightings.dart             ← report / review sightings
    └── s18_license_verification.dart  ← driver's license capture

lib/widgets/document_photo.dart        ← shared photo card + camera/gallery helper
lib/admin_main.dart + lib/screens/admin/  ← web Admin Portal (dashboard, accounts,
                                             vehicles, live activity/map, shared widgets)

packages/vigilink_mesh_transport/      ← local Flutter plugin: the real BLE ad hoc
                                          mesh (Dart API + native Kotlin GATT
                                          server/client, discovery beacon, framing)
```

---

## 🔧 Key Dependencies

| Package | Purpose |
|---------|---------|
| `provider` | State management (AppState / ChangeNotifier) |
| `google_fonts` | DM Sans + DM Mono typography |
| `geolocator` | GPS location for geofence & theft detection |
| `permission_handler` | BLE, location, notification permissions |
| `flutter_local_notifications` | Push notification simulation |
| `intl` | Date/time formatting |
| `sqflite` | Local offline storage |
| `firebase_auth` / `cloud_firestore` | Accounts, cloud sync, internet alert + sighting delivery |
| `vigilink_mesh_transport` (local plugin, `packages/vigilink_mesh_transport/`) | Real BLE ad hoc mesh — discovery + data transfer, zero internet dependency |
| `flutter_foreground_task` | Keeps the mesh and the Firestore alert feed running in the background (Home/Back press, Activity destruction) |
| `shared_preferences` | Small local settings |

---

## 📡 Ad Hoc Network — real BLE mesh, not simulated

The ad hoc relay is a **real, working** Bluetooth Low Energy mesh — no Play Services,
no internet dependency, confirmed on physical multi-device tests including true
multi-hop relay (a device out of the reporter's own range still receives the alert
via a device in between). It lives in the local Flutter plugin
`packages/vigilink_mesh_transport/`, not in `AppState`.

An earlier implementation used Android's native Wi-Fi Direct for the data-transfer
leg; that was abandoned after real-device testing showed Android's own Wi-Fi Direct
group-formation negotiation failing at the OS/radio level on the test hardware. The
current transport is BLE GATT end to end:

1. Every device runs **both** roles at once — a `BluetoothGattServer` (peripheral,
   for receiving) and, per send, a fresh `BluetoothGatt` central connection (for
   sending) — so there's no "group owner" negotiation step at all.
2. Presence/discovery is a separate, lightweight BLE advertise/scan beacon
   (`BleMeshBeacon`) — it never carries alert data, only "a VIGILINK node is nearby."
3. A theft alert is framed (`BleFraming`), sent as one or more GATT characteristic
   writes, and acknowledged by the receiver (`alert_ack`) so a successful radio write
   is never confused with confirmed delivery.
4. `hopCount` counts **up** from 0 at the original reporter, +1 per real device that
   relays it, capped at 5 hops to prevent infinite relay loops. Store-carry-forward
   means a device doesn't need to be connected to everyone at once — it relays
   automatically the next time it connects to a new peer, even much later. A manual
   **"Force Relay"** button on the Alert Received screen is also available as an
   explicit fallback alongside the automatic relay.
5. Photos are deliberately never sent over the mesh (too large for a reliable BLE
   payload) — only the vehicle's text/JSON details. The real photos sync in later via
   Firestore once a device with the alert gets internet back.
6. The mesh (and the Firestore internet alert feed) keep running even while the app
   is backgrounded, via a foreground service (`flutter_foreground_task`,
   `lib/services/mesh_background_service.dart`) — confirmed working with the app
   fully backgrounded and the phone locked.

The Dart-facing API (`lib/services/nearby_mesh_service.dart`) is intentionally shaped
like a drop-in replacement for a Nearby-Connections-style library, so the rest of the
app (`alert_ingest.dart`, `app_state.dart`, every screen) talks to it the same way
regardless of what's underneath. See `Progress.md` for the detailed, dated history of
every transport bug found and fixed to get here.

---

## 📊 Evaluation Metrics (ISO/IEC 25010 + SUS)

The app is designed to be evaluated using:
- **ISO/IEC 25010**: Functional Suitability, Performance Efficiency, Usability, Reliability, Security
- **System Usability Scale (SUS)**: 10-item Likert questionnaire post-demo

---

## ⚙️ Running on Physical Android Device

1. Enable **Developer Options** on your Android phone
2. Enable **USB Debugging**
3. Connect via USB
4. Run: `flutter run`

Or install the APK directly:
```bash
flutter build apk
adb install build/app/outputs/flutter-apk/app-release.apk
```

---

## 📝 Notes

- The app targets **Android 10+** (API 29+) per Chapter 3 hardware requirements
- Proximity detection uses **simulated GPS** (50–100m radius) as specified in the scope
- No external IoT hardware required — smartphone-only as per study delimitations
- Data is stored locally in SQLite (offline-first) and synced to Firebase Firestore when online

---

*Capstone Project — BS Information Technology*  
*College of Computing and Information Sciences (CCIS)*  
*Caraga State University — Main Campus*  
*SY 2025–2026*
