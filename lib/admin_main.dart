import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options_web.dart';
import 'utils/app_theme.dart';
import 'screens/admin/admin_dashboard.dart';

/// A SEPARATE build target for the web-hosted Admin Portal — this is NOT
/// what `flutter run`/`flutter build apk` use (that's `lib/main.dart`).
/// Build/run this one specifically with:
///   flutter build web -t lib/admin_main.dart
///   flutter run -d chrome -t lib/admin_main.dart
///
/// Why a second entry point rather than teaching lib/main.dart to also run
/// on web: almost everything else in this app — the local SQLite cache, the
/// Bluetooth/Wi-Fi Direct ad hoc mesh and GPS watching — is Android-only and either won't compile or won't work on
/// the web. This file only ever imports Firebase and the admin screens
/// (see screens/admin/admin_dashboard.dart), so building it never touches any of
/// that, and stays small and fast to load as a result.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: webFirebaseOptions);
  } catch (e) {
    debugPrint(
        'Firebase failed to initialize — fill in lib/firebase_options_web.dart. ($e)');
  }
  runApp(const AdminWebApp());
}

class AdminWebApp extends StatelessWidget {
  const AdminWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VIGILINK Admin',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      initialRoute: '/admin-login',
      routes: {
        '/admin-login': (_) => const AdminLoginScreen(),
        '/admin': (_) => const AdminDashboardScreen(),
      },
    );
  }
}
