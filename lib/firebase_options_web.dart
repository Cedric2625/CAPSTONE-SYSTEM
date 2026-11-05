import 'package:firebase_core/firebase_core.dart';

/// Firebase config for the web Admin Portal build ONLY
/// (`lib/admin_main.dart`). The phone app (`lib/main.dart`) never reads
/// this — it gets its Firebase config the normal Android way, from
/// `android/app/google-services.json`.
///
/// Filled in from the "VehicleGuard Admin" web app registered in the
/// `vehicleguard-a2bef` Firebase project (Project Settings → General →
/// Your apps). This is safe to commit / ship: a Firebase web API key isn't
/// a secret by itself, it only identifies which project to talk to. What
/// actually controls who can read/write what is the Firestore Security
/// Rules (see Progress.md for the exact rules this app needs).
const webFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyBPNPml-dFjBlXa487ZHLJ4KcdQuZVaeQA',
  appId: '1:593170285783:web:f2d568c1c4618b0252dc92',
  messagingSenderId: '593170285783',
  projectId: 'vehicleguard-a2bef',
  authDomain: 'vehicleguard-a2bef.firebaseapp.com',
  storageBucket: 'vehicleguard-a2bef.firebasestorage.app',
  measurementId: 'G-KWNX83QYPW',
);
