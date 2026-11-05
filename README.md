# 🛡️ VehicleGuard — Real-Time Vehicle Theft Monitoring & Alert System

A Flutter mobile app for real-time vehicle theft detection, alert dissemination via
simulated Ad Hoc Networks (MANET/VANET), and centralized monitoring — built for
Butuan City, Philippines (Capstone Project, Caraga State University).

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
│   └── app_state.dart                 ← ChangeNotifier — all business logic,
│                                        auth, vehicle CRUD, alert broadcasting,
│                                        ad hoc simulation, logging
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
| `nearby_connections` | Real BLE / Wi-Fi Direct ad hoc mesh |
| `shared_preferences` | Small local settings |

---

## 📡 Ad Hoc Network Simulation

Since actual Wi-Fi Direct / BLE APIs require physical devices, the ad hoc relay
is **software-simulated** in `AppState._simulateBroadcast()`:

1. Theft alert generated → alert packet created (vehicle ID, GPS, timestamp)
2. Online nodes iterated with staggered `Timer` delays (1.2s per hop)
3. Each node's `relayStatus` updates: `pending → relaying → received`
4. Hop count increments, alert relayed to next node
5. System log entry + push notification added per relay

To integrate **real** BLE/Wi-Fi Direct in a future version:
- Android: use `flutter_nearby_connections` or `nearby_connections` package
- iOS: use `MultipeerConnectivity` via a platform channel

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
