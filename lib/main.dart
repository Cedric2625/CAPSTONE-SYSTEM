import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/app_state.dart';
import 'utils/app_theme.dart';
import 'utils/nav_key.dart';
import 'models/models.dart';
import 'widgets/widgets.dart';

// Screens
import 'screens/onboarding_screen.dart';
import 'screens/s1_splash_screen.dart';
import 'screens/s2_s3_auth_screens.dart';
import 'screens/s4_s5_vehicle_home.dart';
import 'screens/s6_s7_s8_geofence_report.dart';
import 'screens/s9_s10_s11_alerts_map.dart';
import 'screens/s12_s13_s14_status_notif_profile.dart';
import 'screens/s16_sightings.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(
      [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));
  // Firebase init failure must never block the app from starting — this is
  // an offline-first app by design (see manuscript §6), so cloud sync being
  // unavailable is a degraded state, not a fatal one. AppState's own sync
  // logic already treats "can't reach Firestore" as SYNC FAILED, not a crash.
  //
  // Identity itself (Table 3.3.2.1: "Backend / Database: Firebase
  // (Firestore, Auth)") is handled per-user in AppState.submitRegistration()/login()
  // via FirebaseAuthService — every Firestore request Firestore rules see
  // now carries a real, verified request.auth.uid, not an anonymous one.
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint(
        'Firebase failed to initialize (app continues offline-first): $e');
  }
  // Lets AppState (main isolate) and the background TaskHandler isolate
  // (mesh_background_service.dart) exchange 'startMesh'/'stopMesh' commands
  // via FlutterForegroundTask.sendDataToTask/onReceiveData. Configures the
  // service's own persistent notification — already low-priority and
  // silent by this plugin's defaults (LOW importance/priority, no sound,
  // no vibration) — and disables its periodic onRepeatEvent callback since
  // nothing here needs polling (the mesh and Firestore listeners are both
  // event-driven).
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'vigilink_mesh_service',
      channelName: 'VIGILINK Background Monitoring',
      channelDescription: 'Keeps theft-alert monitoring running in the background.',
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWifiLock: true,
    ),
  );
  final prefs = await SharedPreferences.getInstance();
  final seenOnboarding = prefs.getBool(onboardingSeenKey) ?? false;
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: VigiLinkApp(initialRoute: seenOnboarding ? '/' : '/onboarding'),
    ),
  );
}

class VigiLinkApp extends StatelessWidget {
  final String initialRoute;
  const VigiLinkApp({super.key, required this.initialRoute});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VIGILINK',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      navigatorKey: rootNavigatorKey,
      builder: (context, child) => _IncomingAlertWatcher(
          navigatorKey: rootNavigatorKey,
          child: child ?? const SizedBox.shrink()),
      initialRoute: initialRoute,
      onGenerateRoute: _generateRoute,
    );
  }

  Route<dynamic>? _generateRoute(RouteSettings settings) {
    switch (settings.name) {
      // ── Auth flow ──
      case '/onboarding':
        return _slide(const OnboardingScreen());
      case '/':
        return _slide(const SplashScreen());
      case '/register':
        return _slide(const RegisterScreen());
      case '/login':
        return _slide(const LoginScreen());

      // ── Main flow ──
      case '/home':
        return _slide(const HomeScreen());
      case '/register-vehicle':
        return _slide(const RegisterVehicleScreen());
      case '/awaiting-approval':
        return _slide(const AwaitingApprovalScreen());

      // ── Vehicle management ──
      case '/geofence':
        final vehicle = settings.arguments as VehicleModel;
        return _slide(GeofenceScreen(vehicle: vehicle));

      // ── Alert flow ──
      case '/report':
        final vehicle = settings.arguments as VehicleModel;
        return _slide(ReportStolenScreen(vehicle: vehicle));

      case '/broadcasting':
        final alert = settings.arguments as TheftAlert;
        return _slide(AlertBroadcastingScreen(alert: alert));

      case '/alert-received':
        final alert = settings.arguments as TheftAlert;
        return _slide(AlertReceivedScreen(alert: alert));

      case '/report-sighting':
        final alert = settings.arguments as TheftAlert;
        return _slide(ReportSightingScreen(alert: alert));

      case '/alert-sightings':
        final alert = settings.arguments as TheftAlert;
        return _slide(AlertSightingsScreen(alert: alert));

      // ── Map & Monitoring ──
      case '/prox-map':
        return _slide(const ProximityMapScreen());

      case '/alert-history':
        return _slide(const AlertHistoryScreen());

      case '/update-status':
        final alert = settings.arguments as TheftAlert;
        return _slide(UpdateStatusScreen(alert: alert));

      // ── Profile & Settings ──
      case '/notifications':
        return _slide(const NotificationsScreen());

      case '/profile':
        return _slide(const ProfileScreen());

      case '/logs':
        return _slide(const SystemLogsScreen());

      default:
        return _slide(const SplashScreen());
    }
  }

  // A soft slide-in combined with a fade and a very slight scale — swapped
  // from a plain full-width slide for a livelier, more "app-like" feel
  // between screens, while staying quick enough not to make navigation feel
  // slow.
  PageRouteBuilder _slide(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position:
                Tween<Offset>(begin: const Offset(0.08, 0), end: Offset.zero)
                    .animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        );
      },
      transitionDuration: const Duration(milliseconds: 320),
    );
  }
}

/// Shows a "Stolen Vehicle Nearby" popup whenever this phone receives an
/// alert from someone else (over the ad hoc mesh or the internet feed), on
/// whatever screen the user happens to be on, and opens the Alert Received
/// screen from it. That screen existed but nothing ever opened it, so a
/// received alert used to produce only a notification and a changed counter.
class _IncomingAlertWatcher extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  const _IncomingAlertWatcher(
      {required this.navigatorKey, required this.child});

  @override
  State<_IncomingAlertWatcher> createState() => _IncomingAlertWatcherState();
}

class _IncomingAlertWatcherState extends State<_IncomingAlertWatcher> {
  int? _handledSeq;
  int? _handledGeofenceSeq;
  int? _handledAccountDisabledSeq;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // First build: adopt the current counters so anything that happened
    // before this widget existed doesn't all pop up at once.
    _handledSeq ??= state.incomingAlertSeq;
    if (state.incomingAlertSeq != _handledSeq) {
      _handledSeq = state.incomingAlertSeq;
      final alert = state.incomingAlert;
      if (alert != null && state.isLoggedIn) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showAlert(alert));
      }
    }

    _handledGeofenceSeq ??= state.geofenceNearWarningSeq;
    if (state.geofenceNearWarningSeq != _handledGeofenceSeq) {
      _handledGeofenceSeq = state.geofenceNearWarningSeq;
      final vehicle = state.geofenceNearWarningVehicle;
      final margin = state.geofenceNearWarningMargin;
      if (vehicle != null && margin != null && state.isLoggedIn) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _showGeofenceWarning(vehicle, margin));
      }
    }

    // account was ALREADY signed out by the time this fires (see
    // AppState._forceLogoutDisabled), so this fires regardless of
    // isLoggedIn — unlike the two checks above.
    _handledAccountDisabledSeq ??= state.accountDisabledSeq;
    if (state.accountDisabledSeq != _handledAccountDisabledSeq) {
      _handledAccountDisabledSeq = state.accountDisabledSeq;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _showAccountDisabled());
    }

    return widget.child;
  }

  Future<void> _showAlert(TheftAlert alert) async {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    final view = await showConfirmDialog(
      ctx,
      title: 'Stolen Vehicle Nearby!',
      message:
          '${alert.plate} — ${alert.model} · ${alert.color} was just reported stolen near you.',
      confirmLabel: 'View Details',
      cancelLabel: 'Dismiss',
      icon: Icons.warning_amber_rounded,
    );
    if (view) {
      widget.navigatorKey.currentState
          ?.pushNamed('/alert-received', arguments: alert);
    }
  }

  Future<void> _showGeofenceWarning(VehicleModel vehicle, double margin) async {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    await showConfirmDialog(
      ctx,
      title: 'Approaching Safe Zone Boundary',
      message:
          '${vehicle.plate} is only about ${margin.round()}m from leaving its configured safe zone. It will be automatically reported stolen if it goes past the boundary.',
      confirmLabel: 'Got It',
      cancelLabel: 'Dismiss',
      confirmColor: AppColors.amber,
      icon: Icons.gpp_maybe_outlined,
    );
  }

  /// The account was already signed out by AppState the moment an admin
  /// disabled it (see AppState._forceLogoutDisabled) — this dialog just
  /// explains why, then sends the phone back to Login.
  Future<void> _showAccountDisabled() async {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    // A one-button notice, not a real choice — showConfirmDialog always
    // draws two buttons, which previously showed "OK" next to "OK" here.
    await showErrorModal(
      ctx,
      title: 'Account Disabled',
      message:
          'This account has been disabled by an administrator and you have been signed out. Contact support if you believe this is a mistake.',
      icon: Icons.block,
    );
    widget.navigatorKey.currentState
        ?.pushNamedAndRemoveUntil('/login', (route) => false);
  }
}
