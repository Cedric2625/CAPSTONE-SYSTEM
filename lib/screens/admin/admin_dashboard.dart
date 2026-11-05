import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import '../../utils/app_theme.dart';
import '../../services/admin_service.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';
import '../../utils/validators.dart';
import 'admin_monitoring.dart';
import 'admin_accounts.dart';
import 'admin_approvals.dart';
import 'admin_vehicles.dart';

// ══════════════════════════════════════
// ADMIN PORTAL — login + dashboard
// ══════════════════════════════════════
// Signs in with a real Firebase email/password account, then AdminService
// checks that account's own Firestore document for `role == 'admin'` —
// there is no registration, promotion, hardcoded credential, or any other
// way to create an admin anywhere in this app; an admin account is created
// by hand in the Firebase Console (see Progress.md). Web-only, on purpose:
// this file is imported ONLY by `lib/admin_main.dart` — a separate build
// entry point (`flutter build web -t lib/admin_main.dart`) — and NOT by
// the phone app's `lib/main.dart`, which has no admin route, link, or
// screen anywhere in it. An admin manages accounts from the website; the
// phone app is for vehicle owners only.
// Deliberately independent of AppState/Provider — a vehicle owner's session
// (mesh, GPS, local SQLite cache…) has nothing to do with managing OTHER
// people's accounts, and staying independent of it is what lets the web
// build stay small and never touch any Android-only plugin.

class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});
  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final error =
        await AdminService.instance.login(_email.text, _password.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pushReplacementNamed(context, '/admin');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.vigiBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/images/admin_login_background.png',
              fit: BoxFit.cover),
          // A subtle dark wash so the form card (and the artwork's own
          // shield/vehicle/location elements behind it) stay readable at any
          // window size, without hiding the background entirely.
          Container(color: AppColors.vigiBg.withValues(alpha: 0.55)),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                    decoration: BoxDecoration(
                      color: AppColors.vigiCard.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.vigiBorder),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 30,
                            offset: const Offset(0, 12)),
                      ],
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: Image.asset('assets/images/app_icon.png',
                                width: 64, height: 64, fit: BoxFit.cover),
                          ),
                          const SizedBox(height: 16),
                          Text('VIGILINK Admin',
                              style: GoogleFonts.dmSans(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.vigiText)),
                          const SizedBox(height: 4),
                          Text(
                              'Sign in to manage accounts and monitor theft activity.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.dmSans(
                                  fontSize: 13, color: AppColors.vigiText2)),
                          const SizedBox(height: 28),
                          AppTextField(
                              label: 'EMAIL',
                              hint: 'admin@example.com',
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              dark: true,
                              validator: validateEmail),
                          AppTextField(
                              label: 'PASSWORD',
                              hint: 'Admin password',
                              controller: _password,
                              obscure: true,
                              dark: true,
                              validator: (v) =>
                                  (v == null || v.isEmpty) ? 'Required' : null),
                          if (_error != null)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              margin: const EdgeInsets.only(bottom: 14),
                              decoration: BoxDecoration(
                                  color: AppColors.vigiCritical
                                      .withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(10)),
                              child: Text(_error!,
                                  style: GoogleFonts.dmSans(
                                      fontSize: 12.5,
                                      color: AppColors.vigiCritical)),
                            ),
                          PrimaryButton(
                              label: 'Sign In',
                              onTap: _submit,
                              loading: _loading,
                              color: AppColors.vigiCyan,
                              textColor: AppColors.vigiBg),
                          if (Navigator.canPop(context)) ...[
                            const SizedBox(height: 12),
                            TextButton(
                                onPressed: () => Navigator.maybePop(context),
                                child: Text('Back',
                                    style: GoogleFonts.dmSans(
                                        fontSize: 13,
                                        color: AppColors.vigiText3))),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});
  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen>
    with SingleTickerProviderStateMixin {
  List<AdminUserRow> _rows = [];
  bool _loading = true;
  String? _error;

  /// New registrations waiting on a decision, live. Shown in the Approvals tab
  /// and counted in its label.
  List<PendingRegistration> _pending = const [];
  bool _pendingLoading = true;
  String? _pendingError;
  StreamSubscription<List<PendingRegistration>>? _pendingSub;

  /// Accounts · Approvals · Vehicles · Live Activity · Map. The two monitoring tabs (FR-11) share
  /// ONE set of real-time Firestore listeners, owned here.
  late final TabController _tabs = TabController(length: 5, vsync: this);
  final AdminMonitorFeed _feed = AdminMonitorFeed();

  @override
  void initState() {
    super.initState();
    // Rebuild so the top bar's title/subtitle (read from _tabs.index in
    // build()) updates when the sidebar switches tabs.
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!AdminService.instance.isSignedIn) {
        Navigator.pushReplacementNamed(context, '/admin-login');
        return;
      }
      _feed
        ..onNewAlert = _onNewAlert
        ..onNewSighting = _onNewSighting
        ..start();
      _pendingSub = AdminService.instance.watchPendingRegistrations().listen(
        (list) {
          if (!mounted) return;
          setState(() {
            _pending = list;
            _pendingLoading = false;
            _pendingError = null;
          });
        },
        onError: (Object e) {
          if (!mounted) return;
          setState(() {
            _pendingLoading = false;
            _pendingError = e is FirebaseException &&
                    e.code == 'permission-denied'
                ? "Firestore's security rules are blocking pending registrations — publish the latest rules from Progress.md."
                : 'Could not load pending registrations right now.';
          });
        },
      );
      _load();
    });
  }

  @override
  void dispose() {
    _pendingSub?.cancel();
    _feed.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _approve(PendingRegistration p) async {
    final name = p.user.name;
    final ok = await showConfirmDialog(
      context,
      title: 'Approve $name?',
      message:
          'You confirmed every document is genuine. $name will be signed in '
          'automatically and gain access to VIGILINK.',
      confirmLabel: 'Approve',
      confirmColor: AppColors.green,
      icon: Icons.verified_outlined,
    );
    if (!ok) return;
    try {
      await AdminService.instance.approveRegistration(p.user.id);
      if (!mounted) return;
      showResultToast(context, message: '$name was approved.', success: true);
      _load();
    } catch (_) {
      if (!mounted) return;
      showResultToast(context,
          message:
              'Could not approve this registration. Check your connection.',
          success: false);
    }
  }

  Future<void> _reject(PendingRegistration p, String reason) async {
    final name = p.user.name;
    try {
      await AdminService.instance.rejectRegistration(p.user.id, reason);
      if (!mounted) return;
      showResultToast(context,
          message:
              "$name's registration was rejected and its documents removed.",
          success: true);
      _load();
    } catch (_) {
      if (!mounted) return;
      showResultToast(context,
          message: 'Could not reject this registration. Check your connection.',
          success: false);
    }
  }

  void _onNewAlert(TheftAlert a) {
    if (!mounted) return;
    showResultToast(context,
        message: 'New alert: ${a.plate} — ${a.triggerLabel}', success: false);
  }

  void _onNewSighting(SightingReport s) {
    if (!mounted) return;
    final plate = _feed.alerts
        .where((a) => a.id == s.alertId)
        .map((a) => a.plate)
        .firstOrNull;
    showResultToast(context,
        message:
            '${s.reporterName} reported a sighting of ${plate ?? 'a vehicle'}.',
        success: true);
  }

  /// Registered-account name for an alert's owner — the monitoring tabs only
  /// know the owner's id.
  String _ownerName(String uid) {
    for (final r in _rows) {
      if (r.user.id == uid) return r.user.name;
    }
    return 'Unknown account';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await AdminService.instance.fetchAllUsers();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } on FirebaseException catch (e) {
      // Distinguish "Firestore refused this" from "couldn't reach Firestore
      // at all" — they used to show the same generic message, which made a
      // rules problem look identical to a dead internet connection.
      if (!mounted) return;
      setState(() {
        _error = e.code == 'permission-denied'
            ? "Access denied by Firestore's security rules. The admin rules "
                "(the `isAdmin()` block — see Progress.md) haven't been "
                'published in Firebase Console → Firestore Database → Rules '
                'yet.'
            : 'Could not load accounts (${e.code}). Check your internet connection and try again.';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error =
            'Could not load accounts. Check your internet connection and try again.';
        _loading = false;
      });
    }
  }

  Future<void> _logout() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Log Out?',
      message: 'You will need to sign in again to manage accounts.',
      confirmLabel: 'Log Out',
      confirmColor: AppColors.teal,
      icon: Icons.logout,
    );
    if (!ok) return;
    await AdminService.instance.logout();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(
        context, '/admin-login', (route) => false);
  }

  /// Suspends (blocks login, reversible) or restores an account. Shared by
  /// both the row's quick-action icon and the detail sheet's button.
  Future<void> _toggleDisabled(AdminUserRow row) async {
    final target = !row.disabled;
    final ok = await showConfirmDialog(
      context,
      title: target ? 'Suspend This Account?' : 'Restore This Account?',
      message: target
          ? "${row.user.name} will be signed out immediately and won't be able to log in until restored."
          : '${row.user.name} will be able to log in again.',
      confirmLabel: target ? 'Suspend' : 'Restore',
      confirmColor: target ? AppColors.primary : AppColors.green,
      icon: target ? Icons.block : Icons.check_circle_outline,
    );
    if (!ok || !mounted) return;
    // Second, final confirmation either way — guards against an accidental
    // tap on the first dialog's confirm button for both directions.
    final reallySure = await showConfirmDialog(
      context,
      title: 'Are You Sure?',
      message: target
          ? '${row.user.name} will be suspended and signed out immediately. '
              'You can restore access later from this same screen.'
          : '${row.user.name} will be able to log in again right away.',
      confirmLabel: target ? 'Yes, Suspend Account' : 'Yes, Restore Account',
      cancelLabel: target ? 'No, Keep It Active' : 'No, Keep It Suspended',
      confirmColor: target ? AppColors.primary : AppColors.green,
      icon: target ? Icons.block : Icons.check_circle_outline,
    );
    if (!reallySure) return;
    try {
      await AdminService.instance.setDisabled(row.user.id, target);
      if (!mounted) return;
      showResultToast(context,
          message: target ? 'Account suspended.' : 'Account restored.',
          success: true);
      _load();
    } catch (_) {
      if (!mounted) return;
      showResultToast(context,
          message:
              'Could not update this account. Check your internet connection.',
          success: false);
    }
  }

  /// Permanently deletes an account and its vehicles from Firestore — see
  /// AdminService.removeUser. Shared by both the row's quick-action icon
  /// and the detail sheet's button.
  Future<void> _removeUser(AdminUserRow row) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Delete ${row.user.name} Permanently?',
      message:
          "This permanently deletes this account's profile and every vehicle it registered from Firestore, and blocks it from ever logging in again. This cannot be undone.\n\n"
          'Note: their sign-in credentials still exist under Firebase Console → Authentication → Users — this only removes their app DATA. Delete that row too if you want it gone from there as well.',
      confirmLabel: 'Delete',
      icon: Icons.delete_forever_outlined,
    );
    if (!ok || !mounted) return;
    // Second, final confirmation — this permanently deletes the account's
    // profile and every vehicle it registered, so an accidental first tap
    // still has one more chance to back out before anything is gone.
    final reallySure = await showConfirmDialog(
      context,
      title: 'Are You Sure?',
      message:
          "${row.user.name}'s account and all of its vehicles will be permanently deleted. This action cannot be reversed.",
      confirmLabel: 'Yes, Delete Permanently',
      cancelLabel: 'No, Keep It',
      icon: Icons.delete_forever,
    );
    if (!reallySure) return;
    try {
      await AdminService.instance.removeUser(row.user.id);
      if (!mounted) return;
      showResultToast(context,
          message:
              "${row.user.name}'s data was deleted and they can no longer log in.",
          success: true);
      _load();
    } catch (_) {
      if (!mounted) return;
      showResultToast(context,
          message:
              'Could not delete this account. Check your internet connection.',
          success: false);
    }
  }

  static const _tabTitles = [
    'Accounts',
    'Approvals',
    'Vehicles',
    'Live Activity',
    'Map',
  ];
  static const _tabSubtitles = [
    'Manage registered users and their account status.',
    'Review submitted documents and approve user registrations.',
    'View and manage registered vehicles.',
    'Real-time alerts, sightings, and system activity.',
    'Vehicle locations, alerts, and nearby sightings.',
  ];

  @override
  Widget build(BuildContext context) {
    final meUid = AdminService.instance.currentAdminUid;
    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AdminSidebar(
            selectedIndex: _tabs.index,
            pendingCount: _pending.length,
            onSelect: (i) => _tabs.animateTo(i),
            onLogout: _logout,
          ),
          Expanded(
            child: Column(
              children: [
                _AdminTopBar(
                  title: _tabTitles[_tabs.index],
                  subtitle: _tabSubtitles[_tabs.index],
                  adminEmail: AdminService.instance.currentAdminEmail,
                ),
                const Divider(height: 1, color: AppColors.vigiLiteBorder),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    // Swiping would fight with dragging the map; tabs change
                    // by tapping a sidebar item.
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      AccountsTab(
                        rows: _rows,
                        loading: _loading,
                        error: _error,
                        meUid: meUid,
                        onRetry: _load,
                        onToggle: _toggleDisabled,
                        onRemove: _removeUser,
                      ),
                      ApprovalsTab(
                        pending: _pending,
                        loading: _pendingLoading,
                        error: _pendingError,
                        onApprove: _approve,
                        onReject: _reject,
                      ),
                      VehiclesTab(users: _rows, usersLoading: _loading),
                      LiveActivityTab(feed: _feed, ownerName: _ownerName),
                      MonitorMapTab(feed: _feed, ownerName: _ownerName),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The dashboard's left navigation rail — replaces the former top `TabBar`
/// with the same 5 sections (plus Log Out) in a persistent dark-teal sidebar,
/// matching the rest of the rebrand. Purely presentational: [onSelect] still
/// drives the same `TabController` the `TabBarView` always used, so which
/// section is "selected" and how its content loads is completely unchanged.
class _AdminSidebar extends StatelessWidget {
  final int selectedIndex;
  final int pendingCount;
  final ValueChanged<int> onSelect;
  final VoidCallback onLogout;
  const _AdminSidebar({
    required this.selectedIndex,
    required this.pendingCount,
    required this.onSelect,
    required this.onLogout,
  });

  static const _items = [
    (icon: Icons.people_alt_outlined, label: 'Accounts'),
    (icon: Icons.how_to_reg_outlined, label: 'Approvals'),
    (icon: Icons.directions_car_outlined, label: 'Vehicles'),
    (icon: Icons.sensors, label: 'Live Activity'),
    (icon: Icons.map_outlined, label: 'Map'),
  ];

  @override
  Widget build(BuildContext context) => Container(
        width: 226,
        color: AppColors.vigiLiteSidebar,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                child: Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Image.asset('assets/images/app_icon.png',
                        width: 32, height: 32, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('VIGILINK',
                            style: GoogleFonts.dmSans(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w800,
                                color: Colors.white)),
                        Text('Admin Dashboard',
                            style: GoogleFonts.dmSans(
                                fontSize: 10.5,
                                color: Colors.white.withValues(alpha: 0.65))),
                      ],
                    ),
                  ),
                ]),
              ),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
              const SizedBox(height: 10),
              for (var i = 0; i < _items.length; i++)
                _SidebarItem(
                  icon: _items[i].icon,
                  label: _items[i].label,
                  badge: i == 1 && pendingCount > 0 ? '$pendingCount' : null,
                  selected: selectedIndex == i,
                  onTap: () => onSelect(i),
                ),
              const Spacer(),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
              _SidebarItem(
                icon: Icons.logout,
                label: 'Log Out',
                selected: false,
                onTap: onLogout,
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      );
}

class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;
  const _SidebarItem({
    required this.icon,
    required this.label,
    this.badge,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Selected sits on a solid cyan fill, which needs dark text/icons for
    // contrast (the same "cyan bg, dark text" rule the primary buttons use)
    // — unselected rows stay light-on-dark, matching the sidebar itself.
    final color = widget.selected
        ? AppColors.vigiLiteText
        : Colors.white.withValues(alpha: 0.72);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppColors.vigiLiteCyan
                : (_hover
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Icon(widget.icon, size: 19, color: color),
            const SizedBox(width: 12),
            Expanded(
                child: Text(widget.label,
                    style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight:
                            widget.selected ? FontWeight.w700 : FontWeight.w600,
                        color: color))),
            if (widget.badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: AppColors.vigiLiteCritical,
                    borderRadius: BorderRadius.circular(99)),
                child: Text(widget.badge!,
                    style: GoogleFonts.dmSans(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The header above each tab's content: that section's title/description
/// (replacing the old single static "Admin Dashboard" app bar title) and the
/// signed-in admin's own email (real auth state, not a placeholder name).
class _AdminTopBar extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? adminEmail;
  const _AdminTopBar({
    required this.title,
    required this.subtitle,
    required this.adminEmail,
  });

  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.vigiLiteSidebar,
        padding: const EdgeInsets.fromLTRB(24, 16, 20, 16),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: GoogleFonts.dmSans(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: GoogleFonts.dmSans(
                        fontSize: 12.5,
                        color: Colors.white.withValues(alpha: 0.7))),
              ],
            ),
          ),
          if (adminEmail != null) ...[
            CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.vigiLiteCyan.withValues(alpha: 0.22),
                child: const Icon(Icons.person_outline,
                    size: 18, color: AppColors.vigiLiteCyan)),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(adminEmail!,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.dmSans(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  Text('Administrator',
                      style: GoogleFonts.dmSans(
                          fontSize: 10.5,
                          color: Colors.white.withValues(alpha: 0.7))),
                ],
              ),
            ),
          ],
        ]),
      );
}
