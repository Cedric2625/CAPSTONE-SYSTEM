import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../utils/app_theme.dart';
import '../services/app_state.dart';
import '../models/models.dart';
import '../widgets/widgets.dart';
import '../widgets/document_photo.dart';
import '../utils/validators.dart';
import '../utils/picker_guard.dart';
import 's9_s10_s11_alerts_map.dart';

// ══════════════════════════════════════
// SCREEN 12: UPDATE VEHICLE STATUS
// ══════════════════════════════════════
class UpdateStatusScreen extends StatefulWidget {
  final TheftAlert alert;
  const UpdateStatusScreen({super.key, required this.alert});
  @override
  State<UpdateStatusScreen> createState() => _UpdateStatusScreenState();
}

class _UpdateStatusScreenState extends State<UpdateStatusScreen> {
  String _selected = 'recovered';
  final _remarks = TextEditingController();
  final _picker = ImagePicker();

  /// Proof the vehicle is genuinely back — required before "Mark as
  /// Recovered" can be confirmed. Same per-photo cap as a theft report's
  /// evidence photos (ReportStolenScreen._maxEvidencePhotoBytes): this
  /// travels inside the same alert document, so it needs the same headroom
  /// discipline under Firestore's 1 MB limit.
  Uint8List? _recoveryPhoto;
  static const int _maxRecoveryPhotoBytes = 170000;
  String? _photoError;

  @override
  void dispose() {
    _remarks.dispose();
    super.dispose();
  }

  Future<void> _pickRecoveryPhoto() async {
    final source =
        await showImageSourceSheet(context, title: 'Add Recovery Photo');
    if (source == null) return;
    if (!mounted) return;
    setState(() => _photoError = null);
    isPickerOpen = true;
    try {
      final img = await _picker.pickImage(
          source: source, maxWidth: 1024, maxHeight: 1024, imageQuality: 60);
      if (img == null) return;
      final bytes = await img.readAsBytes();
      if (!mounted) return;
      if (bytes.length > _maxRecoveryPhotoBytes) {
        setState(() => _photoError =
            'That photo is too large. Please take or choose a smaller one.');
        return;
      }
      setState(() => _recoveryPhoto = bytes);
    } catch (e) {
      setState(() => _photoError =
          'Could not access the camera/gallery. Check app permissions in Settings and try again.');
    } finally {
      isPickerOpen = false;
    }
  }

  Future<void> _confirm() async {
    final state = context.read<AppState>();
    if (_selected == 'recovered') {
      // Proof of recovery is required — a photo of the vehicle and a remark
      // on how/where it was found, same spirit as the photo evidence
      // required to report it stolen in the first place.
      final remarks = _remarks.text.trim();
      if (remarks.isEmpty || _recoveryPhoto == null) {
        setState(() => _photoError = remarks.isEmpty && _recoveryPhoto == null
            ? 'A recovery photo and remarks are both required.'
            : remarks.isEmpty
                ? 'Remarks are required.'
                : 'A recovery photo is required.');
        showResultToast(context,
            message:
                'Please add a photo of the vehicle and remarks on how it was found.',
            success: false);
        return;
      }
      final ok = await showConfirmDialog(
        context,
        title: 'Mark ${widget.alert.plate} as Recovered?',
        message:
            'This will update the vehicle status and notify all nearby nodes of the recovery.',
        confirmLabel: 'Mark Recovered',
        confirmColor: AppColors.green,
        icon: Icons.check_circle_outline,
      );
      if (!ok || !mounted) return;
      showLoadingModal(context, message: 'Updating vehicle status…');
      await state.markRecovered(widget.alert.id,
          remarks: remarks, recoveryPhotoBytes: [_recoveryPhoto!]);
      if (!mounted) return;
      Navigator.of(context).pop(); // the loading modal
      showResultToast(context,
          message: '✅ Vehicle marked as recovered. Nearby nodes notified!',
          success: true);
    } else {
      showResultToast(context,
          message: '📡 Still searching — alert continues broadcasting.',
          success: true);
    }
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/alert-history');
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.alert;
    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
        backgroundColor: AppColors.vigiLiteBg,
        foregroundColor: AppColors.vigiLiteText,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back',
            onPressed: () => Navigator.pop(context)),
        title: const Text('Update Vehicle Status'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Current status card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF7F1D1D), AppColors.vigiLiteCritical]),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CURRENTLY: STOLEN',
                        style: GoogleFonts.dmMono(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.7),
                            letterSpacing: 0.5)),
                    const SizedBox(height: 4),
                    Text(a.plate,
                        style: GoogleFonts.dmMono(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                    Text('${a.model} · ${a.color}',
                        style: GoogleFonts.dmSans(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.8))),
                    const SizedBox(height: 6),
                    Text('Reported: ${_fmtDate(a.timestamp)}',
                        style: GoogleFonts.dmSans(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.65))),
                  ]),
            ),
            const SizedBox(height: 16),

            Text('UPDATE STATUS TO',
                style: GoogleFonts.dmMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.vigiLiteText3,
                    letterSpacing: 0.5)),
            const SizedBox(height: 10),

            // Recovered option
            _StatusOption(
              icon: '✅',
              title: 'Mark as Recovered',
              desc: 'Vehicle has been found and recovered',
              selected: _selected == 'recovered',
              selectedColor: AppColors.vigiLiteSuccess,
              iconBg: AppColors.vigiLiteSuccess.withValues(alpha: 0.18),
              onTap: () => setState(() => _selected = 'recovered'),
            ),
            const SizedBox(height: 10),

            // Still searching
            _StatusOption(
              icon: '🔍',
              title: 'Still Searching',
              desc: 'Continue broadcasting alert to nearby nodes',
              selected: _selected == 'searching',
              selectedColor: AppColors.vigiLiteWarning,
              iconBg: AppColors.vigiLiteWarning.withValues(alpha: 0.18),
              onTap: () => setState(() => _selected = 'searching'),
            ),
            const SizedBox(height: 14),

            if (_selected == 'recovered') ...[
              // Proof of recovery (required) — a photo of the vehicle, same
              // spirit as the photo evidence required to report it stolen.
              Text('RECOVERY PHOTO (REQUIRED)',
                  style: GoogleFonts.dmMono(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteText3,
                      letterSpacing: 0.4)),
              const SizedBox(height: 6),
              Text(
                  'A clear photo of the vehicle now that it\'s back helps confirm this recovery is genuine.',
                  style: GoogleFonts.dmSans(
                      fontSize: 11.5,
                      height: 1.4,
                      color: AppColors.vigiLiteText3)),
              const SizedBox(height: 10),
              SizedBox(
                width: 120,
                child: _RecoveryPhotoTile(
                  photo: _recoveryPhoto,
                  onTap: _pickRecoveryPhoto,
                  onRemove: () => setState(() => _recoveryPhoto = null),
                ),
              ),
              if (_photoError != null) ...[
                const SizedBox(height: 8),
                Text(_photoError!,
                    style: GoogleFonts.dmSans(
                        fontSize: 11.5, color: AppColors.vigiLiteCritical)),
              ],
              const SizedBox(height: 14),
            ],

            Text(
                _selected == 'recovered'
                    ? 'REMARKS (REQUIRED)'
                    : 'REMARKS (OPTIONAL)',
                style: GoogleFonts.dmMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.vigiLiteText3,
                    letterSpacing: 0.4)),
            const SizedBox(height: 6),
            TextField(
              controller: _remarks,
              maxLines: 2,
              style: GoogleFonts.dmSans(
                  fontSize: 14, color: AppColors.vigiLiteText),
              decoration: InputDecoration(
                hintText: 'e.g. Found at Robinsons parking',
                hintStyle: GoogleFonts.dmSans(
                    fontSize: 13, color: AppColors.vigiLiteText3),
                filled: true,
                fillColor: AppColors.vigiLiteInput,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide:
                        const BorderSide(color: AppColors.vigiLiteBorder)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide:
                        const BorderSide(color: AppColors.vigiLiteBorder)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(
                        color: AppColors.vigiLiteCyan, width: 1.5)),
              ),
            ),
            const SizedBox(height: 14),

            // Notify note
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.vigiLiteInfo.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppColors.vigiLiteInfo.withValues(alpha: 0.3))),
              child: Row(
                children: [
                  const Icon(Icons.cell_tower,
                      size: 18, color: AppColors.vigiLiteInfo),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(
                          'Updating will notify all nearby nodes of the status change via the real ad hoc mesh.',
                          style: GoogleFonts.dmSans(
                              fontSize: 12, color: AppColors.vigiLiteInfo))),
                ],
              ),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
                label: 'CONFIRM UPDATE',
                onTap: _confirm,
                color: _selected == 'recovered'
                    ? AppColors.vigiLiteSuccess
                    : AppColors.vigiLiteWarning,
                textColor: Colors.white),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  String _fmtDate(DateTime t) => DateFormat('M/d/yyyy · hh:mm a').format(t);
}

class _RecoveryPhotoTile extends StatelessWidget {
  final Uint8List? photo;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  const _RecoveryPhotoTile(
      {required this.photo, required this.onTap, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final bytes = photo;
    if (bytes != null) {
      return AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(fit: StackFit.expand, children: [
            Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
            Positioned(
              top: 4,
              right: 4,
              child: TapScale(
                onTap: onRemove,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                      color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.close, color: Colors.white, size: 14),
                ),
              ),
            ),
          ]),
        ),
      );
    }
    return TapScale(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.vigiLiteInput,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: AppColors.vigiLiteBorder, style: BorderStyle.solid),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.add_a_photo_outlined,
                color: AppColors.vigiLiteText3, size: 22),
            const SizedBox(height: 4),
            Text('Add Photo',
                style: GoogleFonts.dmSans(
                    fontSize: 11, color: AppColors.vigiLiteText3)),
          ]),
        ),
      ),
    );
  }
}

class _StatusOption extends StatelessWidget {
  final String icon;
  final String title;
  final String desc;
  final bool selected;
  final Color selectedColor;
  final Color iconBg;
  final VoidCallback onTap;
  const _StatusOption(
      {required this.icon,
      required this.title,
      required this.desc,
      required this.selected,
      required this.selectedColor,
      required this.iconBg,
      required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? selectedColor.withValues(alpha: 0.1)
                : AppColors.vigiLiteCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: selected ? selectedColor : AppColors.vigiLiteBorder,
                width: selected ? 2 : 0.8),
          ),
          child: Row(
            children: [
              Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                      color: iconBg, borderRadius: BorderRadius.circular(12)),
                  child: Center(
                      child: Text(icon, style: const TextStyle(fontSize: 20)))),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(title,
                        style: GoogleFonts.dmSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.vigiLiteText)),
                    const SizedBox(height: 2),
                    Text(desc,
                        style: GoogleFonts.dmSans(
                            fontSize: 11, color: AppColors.vigiLiteText3)),
                  ])),
              if (selected)
                Icon(Icons.check_circle, color: selectedColor, size: 22),
            ],
          ),
        ),
      );
}

// ══════════════════════════════════════
// SCREEN 13: PUSH NOTIFICATIONS
// ══════════════════════════════════════
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final notifs = state.notifications;
    final today = notifs
        .where((n) => DateTime.now().difference(n.time).inHours < 24)
        .toList();
    final earlier = notifs
        .where((n) => DateTime.now().difference(n.time).inHours >= 24)
        .toList();

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
        backgroundColor: AppColors.vigiLiteBg,
        foregroundColor: AppColors.vigiLiteText,
        title: const Text('Alert Notifications'),
        actions: [
          TextButton(
            onPressed: () => state.markAllRead(),
            child: Text('Mark all read',
                style: GoogleFonts.dmSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.vigiLiteCyan)),
          ),
        ],
      ),
      body: notifs.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.notifications_none,
                  size: 48, color: AppColors.vigiLiteText3),
              const SizedBox(height: 10),
              Text('No notifications yet.',
                  style: GoogleFonts.dmSans(
                      fontSize: 13, color: AppColors.vigiLiteText3)),
            ]))
          : ListView(
              padding: const EdgeInsets.all(14),
              children: [
                if (today.isNotEmpty) ...[
                  Text('TODAY',
                      style: GoogleFonts.dmMono(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteText3,
                          letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  ...today.map((n) => _NotifCard(n)),
                ],
                if (earlier.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('EARLIER',
                      style: GoogleFonts.dmMono(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteText3,
                          letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  ...earlier.map((n) => _NotifCard(n)),
                ],
                const SizedBox(height: 80),
              ],
            ),
      bottomNavigationBar: const BottomNavBar(current: 3, dark: true),
    );
  }
}

class _NotifCard extends StatelessWidget {
  final NotifItem notif;
  const _NotifCard(this.notif);

  (String, Color, Color) _typeStyle() {
    switch (notif.type) {
      case NotifType.stolen:
        return (
          '🚨',
          AppColors.vigiLiteCritical.withValues(alpha: 0.18),
          AppColors.vigiLiteCritical
        );
      case NotifType.geofence:
        return (
          '📍',
          AppColors.vigiLiteWarning.withValues(alpha: 0.18),
          AppColors.vigiLiteWarning
        );
      case NotifType.relayed:
        return (
          '📡',
          AppColors.vigiLiteInfo.withValues(alpha: 0.18),
          AppColors.vigiLiteInfo
        );
      case NotifType.recovered:
        return (
          '✅',
          AppColors.vigiLiteSuccess.withValues(alpha: 0.18),
          AppColors.vigiLiteSuccess
        );
      case NotifType.sync:
        return (
          '☁',
          AppColors.vigiLiteInfo.withValues(alpha: 0.18),
          AppColors.vigiLiteInfo
        );
      case NotifType.info:
        return ('ℹ️', AppColors.vigiLiteBorder, AppColors.vigiLiteText3);
    }
  }

  Color _borderColor() {
    switch (notif.type) {
      case NotifType.stolen:
        return AppColors.vigiLiteCritical;
      case NotifType.geofence:
        return AppColors.vigiLiteWarning;
      case NotifType.relayed:
        return AppColors.vigiLiteInfo;
      case NotifType.recovered:
        return AppColors.vigiLiteSuccess;
      case NotifType.sync:
        return AppColors.vigiLiteInfo;
      case NotifType.info:
        return AppColors.vigiLiteText3;
    }
  }

  /// [notif.time] is stamped once, the moment the underlying event actually
  /// happened on this device (an alert was relayed in, a sighting arrived,
  /// etc. — see AppState._addNotif) — never recomputed from when this screen
  /// happens to be opened, so this always reflects the real time of the
  /// event, however long ago that was.
  String _timeAgo() {
    final diff = DateTime.now().difference(notif.time);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// The exact date and time, shown alongside the relative text above so the
  /// person can always tell precisely when an alert/event happened, not just
  /// a vague "2h ago" — this used to be the ONLY thing shown once a
  /// notification turned 24h old, and even then with no time of day at all.
  String _exactTime() => DateFormat('MMM d, yyyy · h:mm a').format(notif.time);

  @override
  Widget build(BuildContext context) {
    final (icon, iconBg, _) = _typeStyle();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        // Unread notifications get a subtle tint in the alert's own color
        // (the same light shade as its icon background) so they're visibly
        // distinct at a glance, not just by a slightly thicker left border.
        color: notif.isRead
            ? AppColors.vigiLiteCard
            : iconBg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border(
            left: BorderSide(
                color: notif.isRead ? AppColors.vigiLiteBorder : _borderColor(),
                width: notif.isRead ? 0.8 : 3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                    color: iconBg, borderRadius: BorderRadius.circular(12)),
                child: Center(
                    child: Text(icon, style: const TextStyle(fontSize: 20)))),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(notif.title,
                        style: GoogleFonts.dmSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.vigiLiteText)),
                    const SizedBox(height: 3),
                    Text(notif.body,
                        style: GoogleFonts.dmSans(
                            fontSize: 12,
                            color: AppColors.vigiLiteText3,
                            height: 1.4)),
                    const SizedBox(height: 4),
                    Text('${_timeAgo()} · ${_exactTime()}',
                        style: GoogleFonts.dmMono(
                            fontSize: 10, color: AppColors.vigiLiteText3)),
                  ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════
// SCREEN 14: USER PROFILE
// ══════════════════════════════════════
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final user = state.currentUser;
    final vehicles = state.myVehicles;

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      body: CustomScrollView(
        slivers: [
          // Profile header — flat Lite background, navy name/email text.
          SliverToBoxAdapter(
            child: Container(
              color: AppColors.vigiLiteBg,
              padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 20,
                  left: 20,
                  right: 20,
                  bottom: 32),
              child: Column(children: [
                GestureDetector(
                  onTap: () => _changeProfilePhoto(context, state),
                  child: Stack(children: [
                    Container(
                      width: 72,
                      height: 72,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: AppColors.vigiLiteTeal,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: AppColors.vigiLiteBorder, width: 3),
                      ),
                      child: state.profilePhotoBytes != null
                          ? Image.memory(state.profilePhotoBytes!,
                              fit: BoxFit.cover,
                              width: 72,
                              height: 72,
                              gaplessPlayback: true)
                          : Center(
                              child: Text(user?.initials ?? 'U',
                                  style: GoogleFonts.dmSans(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.vigiLiteText))),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                            color: AppColors.vigiLiteCard,
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: AppColors.vigiLiteBorder)),
                        child: const Icon(Icons.camera_alt,
                            size: 13, color: AppColors.vigiLiteCyan),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                Text(user?.name ?? 'User',
                    style: GoogleFonts.dmSans(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.vigiLiteText)),
                const SizedBox(height: 3),
                Text(user?.email ?? '',
                    style: GoogleFonts.dmSans(
                        fontSize: 13, color: AppColors.vigiLiteText2)),
              ]),
            ),
          ),

          SliverToBoxAdapter(
            child: Transform.translate(
              offset: const Offset(0, -20),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    // Vehicle card
                    AppCard(
                      color: AppColors.vigiLiteCard,
                      borderColor: AppColors.vigiLiteBorder,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('MY VEHICLE',
                              style: GoogleFonts.dmMono(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.vigiLiteText3,
                                  letterSpacing: 0.5)),
                          const SizedBox(height: 10),
                          if (vehicles.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text('No vehicles registered.',
                                  style: GoogleFonts.dmSans(
                                      fontSize: 13,
                                      color: AppColors.vigiLiteText3)),
                            )
                          else
                            ...vehicles.map((v) => Container(
                                  padding: const EdgeInsets.all(10),
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                      color: AppColors.vigiLiteInput,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                          color: AppColors.vigiLiteBorder,
                                          width: 1.2)),
                                  child: Row(
                                    children: [
                                      const Text('🚗',
                                          style: TextStyle(fontSize: 20)),
                                      const SizedBox(width: 10),
                                      Expanded(
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                            Text(v.plate,
                                                style: GoogleFonts.dmMono(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w700,
                                                    color: AppColors
                                                        .vigiLiteText)),
                                            Text(
                                                '${v.model} · ${v.color} · ${v.type}',
                                                style: GoogleFonts.dmSans(
                                                    fontSize: 11,
                                                    color: AppColors
                                                        .vigiLiteText3)),
                                          ])),
                                      v.status == VehicleStatus.active
                                          ? StatusBadge.active()
                                          : StatusBadge.stolen(),
                                    ],
                                  ),
                                )),
                          SizedBox(
                            width: double.infinity,
                            height: 38,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                  side: const BorderSide(
                                      color: AppColors.vigiLiteBorder),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10))),
                              onPressed: () => Navigator.pushNamed(
                                  context, '/register-vehicle'),
                              child: Text('+ Add Another Vehicle',
                                  style: GoogleFonts.dmSans(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.vigiLiteText2)),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Account settings
                    const SizedBox(height: 4),
                    _sectionLabel('ACCOUNT SETTINGS'),
                    const SizedBox(height: 8),
                    _SettingsItem(
                        icon: '✏️',
                        label: 'Edit Profile',
                        onTap: () => user == null
                            ? showResultToast(context,
                                message: 'No profile loaded.', success: false)
                            : _showEditProfileDialog(context, user)),
                    _SettingsItem(
                        icon: '🔔',
                        label: 'Notification Settings',
                        onTap: () =>
                            Navigator.pushNamed(context, '/notifications')),
                    _SettingsItem(
                      icon: '📍',
                      label: 'Location Permission — ${state.gpsStatus.label}',
                      onTap: () async {
                        // Already granted and working — there's no
                        // permission left to request, but tapping used to
                        // silently do nothing despite showing the same
                        // tappable chevron as every row above it. Confirm
                        // instead, so it's clear the row isn't broken.
                        if (state.gpsStatus == GpsStatus.available) {
                          final accuracy = state.currentAccuracy;
                          showResultToast(context,
                              message: accuracy != null
                                  ? 'Location is already available (±${accuracy.round()}m accuracy).'
                                  : 'Location is already available.',
                              success: true);
                          return;
                        }
                        await state.requestLocationPermission();
                        await state.refreshGps();
                      },
                    ),
                    _SettingsItem(
                        icon: '🔒',
                        label: 'Privacy & Data (R.A. 10173)',
                        onTap: () => _showPrivacyDialog(context)),
                    _SettingsItem(
                        icon: '📡',
                        label: 'Ad Hoc Network Settings',
                        onTap: () => _showAdHocDialog(
                            context, user?.deviceId ?? 'DEV-001')),
                    _SettingsItem(
                        icon: '📊',
                        label: 'System Logs',
                        onTap: () => Navigator.pushNamed(context, '/logs')),

                    const SizedBox(height: 14),
                    // Logout
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(
                              color: AppColors.vigiLiteBorder, width: 1.5),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () async {
                          final ok = await showConfirmDialog(
                            context,
                            title: 'Log Out?',
                            message: 'Are you sure you want to log out?',
                            confirmLabel: 'Log Out',
                            confirmColor: AppColors.teal,
                            icon: Icons.logout,
                          );
                          if (!ok) return;
                          await state.logout();
                          if (!context.mounted) return;
                          await showSuccessModal(context,
                              title: 'Logged Out',
                              message:
                                  'You have been successfully logged out.');
                          // Straight to the Login screen, not the Splash
                          // welcome screen — after explicitly logging out,
                          // making the user tap "LOG IN" again on Splash
                          // first is an extra, pointless step.
                          if (context.mounted) {
                            Navigator.pushNamedAndRemoveUntil(
                                context, '/login', (route) => false);
                          }
                        },
                        child: Text('Log Out',
                            style: GoogleFonts.dmSans(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppColors.vigiLiteCyan)),
                      ),
                    ),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const BottomNavBar(current: 3, dark: true),
    );
  }

  Widget _sectionLabel(String text) => Align(
        alignment: Alignment.centerLeft,
        child: Text(text,
            style: GoogleFonts.dmMono(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.vigiLiteText3,
                letterSpacing: 0.5)),
      );
}

/// Take a photo, pick one from the gallery, or remove the current one. The
/// picker shrinks it (400 px, compressed) so it stays a few tens of KB —
/// small enough to save on the account and restore on another phone.
Future<void> _changeProfilePhoto(BuildContext context, AppState state) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Profile Photo',
              style: GoogleFonts.dmSans(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text)),
          const SizedBox(height: 10),
          ListTile(
              leading:
                  const Icon(Icons.camera_alt_outlined, color: AppColors.teal),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(ctx, 'camera')),
          ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppColors.blue),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(ctx, 'gallery')),
          if (state.profilePhotoBytes != null)
            ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: AppColors.gray),
                title: const Text('Remove Photo'),
                onTap: () => Navigator.pop(ctx, 'remove')),
        ]),
      ),
    ),
  );
  if (choice == null) return;
  if (choice == 'remove') {
    await state.removeProfilePhoto();
    if (context.mounted) {
      showResultToast(context,
          message: 'Profile photo removed.', success: true);
    }
    return;
  }
  isPickerOpen = true;
  try {
    final img = await ImagePicker().pickImage(
      source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 400,
      maxHeight: 400,
      imageQuality: 65,
    );
    if (img == null) return;
    final bytes = await img.readAsBytes();
    if (bytes.length > 600000) {
      if (context.mounted) {
        showResultToast(context,
            message: 'That photo is too large. Please choose a smaller one.',
            success: false);
      }
      return;
    }
    await state.setProfilePhoto(bytes);
    if (context.mounted) {
      showResultToast(context,
          message: 'Profile photo updated.', success: true);
    }
  } catch (_) {
    if (context.mounted) {
      showResultToast(context,
          message:
              'Could not access the camera/gallery. Check app permissions and try again.',
          success: false);
    }
  } finally {
    isPickerOpen = false;
  }
}

void _showEditProfileDialog(BuildContext context, UserModel user) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _EditProfileSheet(user: user),
  );
}

class _EditProfileSheet extends StatefulWidget {
  final UserModel user;
  const _EditProfileSheet({required this.user});

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late final _nameCtrl = TextEditingController(text: widget.user.name);
  late final _phoneCtrl = TextEditingController(text: widget.user.phone);
  late final _emailCtrl = TextEditingController(text: widget.user.email);
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  /// True once the number differs from the saved one — which is what makes
  /// the password field appear (a mobile number change must be confirmed).
  bool get _phoneChanged =>
      canonicalPhMobile(_phoneCtrl.text) !=
      canonicalPhMobile(widget.user.phone);

  @override
  void initState() {
    super.initState();
    _phoneCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final changed = _phoneChanged;
    if (changed) {
      final ok = await showConfirmDialog(
        context,
        title: 'Change Mobile Number?',
        message:
            'Vehicle owners you report sightings to will contact you at ${_phoneCtrl.text.trim()}. Only continue if this number is correct and you can be reached on it.',
        confirmLabel: 'Change Number',
        confirmColor: AppColors.blue,
        icon: Icons.phone_outlined,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _saving = true);
    final error = await context.read<AppState>().updateProfile(
        name: _nameCtrl.text,
        phone: _phoneCtrl.text,
        currentPassword: changed ? _passwordCtrl.text : null);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error == null) {
      Navigator.pop(context);
      showResultToast(context,
          message: changed
              ? 'Profile updated. Your mobile number was changed.'
              : 'Profile updated.',
          success: true);
    } else {
      showResultToast(context, message: error, success: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 10, 18, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                    child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                            color: AppColors.border,
                            borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 14),
                Text('Edit Profile',
                    style: GoogleFonts.dmSans(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text)),
                const SizedBox(height: 16),
                AppTextField(
                    label: 'FULL NAME',
                    hint: 'Juan dela Cruz',
                    controller: _nameCtrl,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Name cannot be empty.'
                        : null),
                const SizedBox(height: 14),
                AppTextField(
                    label: 'MOBILE NUMBER',
                    hint: '09171234567',
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    validator: validatePhMobile),
                if (_phoneChanged) ...[
                  const SizedBox(height: 14),
                  AppTextField(
                      label: 'CURRENT PASSWORD',
                      hint: 'Required to change your number',
                      controller: _passwordCtrl,
                      obscure: true,
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Enter your password to change your mobile number.'
                          : null),
                ],
                const SizedBox(height: 14),
                AppTextField(
                    label: 'EMAIL (NOT EDITABLE)',
                    hint: '',
                    controller: _emailCtrl,
                    readOnly: true),
                const SizedBox(height: 20),
                PrimaryButton(
                    label: 'SAVE CHANGES', onTap: _save, loading: _saving),
              ]),
        ),
      ),
    );
  }
}

void _showPrivacyDialog(BuildContext context) {
  showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Privacy & Data'),
            content: Text(
              'VIGILINK collects your GPS location, vehicle information, and theft reports solely for vehicle monitoring and alert dissemination, in compliance with the Philippine Data Privacy Act (R.A. 10173). '
              'Data is stored locally on your device and synchronized to the cloud only when you are online. Location details are shared only with participating nearby nodes as part of the theft-alert relay, and only while an alert is active. '
              'While the real ad hoc mesh is on and the app is open, your name and approximate position (about 11 m) are also shared with other signed-in VIGILINK users so registered devices nearby can be listed; this stops when you log out, turn the mesh off, or close the app.',
              style: GoogleFonts.dmSans(fontSize: 13, height: 1.5),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Got it'))
            ],
          ));
}

void _showAdHocDialog(BuildContext context, String deviceId) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => Consumer<AppState>(
      builder: (ctx, state, _) {
        final realNodes = state.nodes.where((n) => !n.isSimulated).toList();
        return Padding(
          padding: EdgeInsets.fromLTRB(
              18, 10, 18, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                    child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                            color: AppColors.border,
                            borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 14),
                Text('Ad Hoc Network',
                    style: GoogleFonts.dmSans(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text)),
                const SizedBox(height: 4),
                Text('Device ID: $deviceId',
                    style: GoogleFonts.dmMono(
                        fontSize: 11, color: AppColors.text3)),
                const SizedBox(height: 16),

                // Mesh status
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: AppColors.bg,
                      borderRadius: BorderRadius.circular(14)),
                  child: Row(children: [
                    const Icon(Icons.bluetooth,
                        color: AppColors.blue, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('Real BLE / Wi-Fi Direct Mesh',
                              style: GoogleFonts.dmSans(
                                  fontSize: 13, fontWeight: FontWeight.w700)),
                          Text(state.meshStatusLabel,
                              style: GoogleFonts.dmSans(
                                  fontSize: 11.5, color: AppColors.text3)),
                        ])),
                  ]),
                ),
                const SizedBox(height: 10),

                if (!state.meshPermissionsGranted)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: PrimaryButton(
                      label: 'Grant Bluetooth & Location Permission',
                      icon: Icons.bluetooth,
                      color: AppColors.amber,
                      onTap: () async {
                        final granted = await state.requestMeshPermissions();
                        if (ctx.mounted) {
                          showResultToast(ctx,
                              message: granted
                                  ? 'Permissions granted.'
                                  : 'Permission was not granted.',
                              success: granted);
                        }
                      },
                    ),
                  ),

                Text('CONNECTED / NEARBY DEVICES (${realNodes.length})',
                    style: GoogleFonts.dmMono(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text3,
                        letterSpacing: 0.4)),
                const SizedBox(height: 8),
                if (realNodes.isEmpty)
                  Text(
                      'No nearby devices detected yet. Keep the app open on another VIGILINK phone nearby.',
                      style: GoogleFonts.dmSans(
                          fontSize: 12.5, color: AppColors.text3))
                else
                  ...realNodes.map((n) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                  color: n.isOnline
                                      ? AppColors.green
                                      : AppColors.amber,
                                  shape: BoxShape.circle)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(n.name,
                                  style: GoogleFonts.dmSans(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600))),
                          Text(n.isOnline ? 'Connected' : 'Connecting…',
                              style: GoogleFonts.dmSans(
                                  fontSize: 11,
                                  color: n.isOnline
                                      ? AppColors.green
                                      : AppColors.amber)),
                        ]),
                      )),
                const SizedBox(height: 8),
                Text(
                  'This uses raw BLE for discovery and native Wi-Fi Direct for the connection — no Google Play Services involved, so no internet is needed. No manual pairing needed.',
                  style: GoogleFonts.dmSans(
                      fontSize: 11.5, color: AppColors.text3, height: 1.4),
                ),
              ]),
        );
      },
    ),
  );
}

class _SettingsItem extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback onTap;
  const _SettingsItem(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => TapScale(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
              color: AppColors.vigiLiteCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.vigiLiteBorder)),
          child: Row(
            children: [
              SizedBox(
                  width: 32,
                  child: Center(
                      child: Text(icon, style: const TextStyle(fontSize: 20)))),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(label,
                      style: GoogleFonts.dmSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.vigiLiteText))),
              const Icon(Icons.chevron_right,
                  size: 20, color: AppColors.vigiLiteText3),
            ],
          ),
        ),
      );
}

// ══════════════════════════════════════
// SYSTEM LOGS SCREEN (bonus)
// ══════════════════════════════════════
class SystemLogsScreen extends StatelessWidget {
  const SystemLogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final logs = state.logs;

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
        backgroundColor: AppColors.vigiLiteBg,
        foregroundColor: AppColors.vigiLiteText,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back',
            onPressed: () => Navigator.pop(context)),
        title: const Text('System Logs'),
        actions: [
          TextButton(
            onPressed: () async {
              final ok = await showConfirmDialog(
                context,
                title: 'Clear All Logs?',
                message:
                    'This permanently deletes all system logs from this device. This cannot be undone.',
                confirmLabel: 'Clear',
                icon: Icons.delete_outline,
              );
              if (ok) state.clearLogs();
            },
            child: Text('Clear',
                style: GoogleFonts.dmSans(
                    fontSize: 13,
                    color: AppColors.vigiLiteCritical,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: logs.isEmpty
          ? Center(
              child: Text('No logs yet.',
                  style: GoogleFonts.dmSans(
                      fontSize: 13, color: AppColors.vigiLiteText3)))
          : ListView.builder(
              padding: const EdgeInsets.all(14),
              itemCount: logs.length,
              itemBuilder: (_, i) {
                final log = logs[i];
                Color tagColor;
                switch (log.type) {
                  case LogType.ok:
                    tagColor = AppColors.vigiLiteSuccess;
                    break;
                  case LogType.warn:
                    tagColor = AppColors.vigiLiteWarning;
                    break;
                  case LogType.err:
                    tagColor = AppColors.vigiLiteCritical;
                    break;
                  case LogType.relay:
                    tagColor = const Color(0xFFA78BFA);
                    break;
                  default:
                    tagColor = AppColors.vigiLiteInfo;
                }
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showLogDetail(context, log, tagColor),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 8, horizontal: 10),
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                        color: AppColors.vigiLiteCard,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: AppColors.vigiLiteBorder, width: 0.5)),
                    child: Row(
                      children: [
                        Text(
                            DateFormat('MMM d, h:mm:ss a')
                                .format(log.createdAt),
                            style: GoogleFonts.dmMono(
                                fontSize: 10, color: AppColors.vigiLiteText3)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                              color: tagColor.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4)),
                          child: Text('[${log.tag}]',
                              style: GoogleFonts.dmMono(
                                  fontSize: 10,
                                  color: tagColor,
                                  fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(log.message,
                                style: GoogleFonts.dmSans(
                                    fontSize: 12,
                                    color: AppColors.vigiLiteText),
                                overflow: TextOverflow.ellipsis)),
                        const Icon(Icons.chevron_right,
                            size: 16, color: AppColors.vigiLiteText3),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  /// The log list truncates every line with an ellipsis to fit one row —
  /// this is the only way to read a long entry (like a native transport
  /// error naming the exact endpoint/reason) in full, instead of having to
  /// guess at what's cut off.
  void _showLogDetail(BuildContext context, SystemLog log, Color tagColor) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.vigiLiteCard,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  color: tagColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4)),
              child: Text('[${log.tag}]',
                  style: GoogleFonts.dmMono(
                      fontSize: 11,
                      color: tagColor,
                      fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                DateFormat('MMM d, yyyy h:mm:ss a').format(log.createdAt),
                style: GoogleFonts.dmMono(
                    fontSize: 11, color: AppColors.vigiLiteText3),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: SelectableText(log.message,
              style: GoogleFonts.dmSans(
                  fontSize: 13, color: AppColors.vigiLiteText)),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log.message));
              ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Log entry copied.')));
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
