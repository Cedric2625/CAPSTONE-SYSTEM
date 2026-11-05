import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../utils/app_theme.dart';
import '../utils/geo_defaults.dart';
import '../services/app_state.dart';
import '../models/models.dart';
import '../widgets/widgets.dart';
import '../utils/time_format.dart';
import '../utils/picker_guard.dart';

// ══════════════════════════════════════
// SIGHTING REPORTS — a nearby user tells a stolen vehicle's owner they've
// seen it (message + photo proof + where + when), and the owner reviews them.
// ══════════════════════════════════════
// Before this existed, an alert that reached a nearby phone was a dead end:
// the alert cards weren't tappable and the only screen they led to (Alert
// Received) offered nothing but "View on map" and "Dismiss". Everyone who
// received an alert could see it and none could help.

/// Opens the right screen for an alert card: the owner sees the sightings
/// people have sent about their vehicle; anyone else sees the alert and can
/// report a sighting. Shared by the Alert History list and the Proximity Map
/// so both behave identically.
void openAlertDetails(BuildContext context, TheftAlert alert) {
  final myId = context.read<AppState>().currentUser?.id;
  Navigator.pushNamed(
      context, alert.userId == myId ? '/alert-sightings' : '/alert-received',
      arguments: alert);
}

String _seenLabel(DateTime t) {
  final now = DateTime.now();
  final time = DateFormat('hh:mm a').format(t);
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today, $time';
  if (diff == 1) return 'Yesterday, $time';
  return '${DateFormat('MMM d').format(t)}, $time';
}

// ══════════════════════════════════════
// REPORT A SIGHTING (nearby user)
// ══════════════════════════════════════
class ReportSightingScreen extends StatefulWidget {
  final TheftAlert alert;
  const ReportSightingScreen({super.key, required this.alert});
  @override
  State<ReportSightingScreen> createState() => _ReportSightingScreenState();
}

class _ReportSightingScreenState extends State<ReportSightingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _message = TextEditingController();
  final _picker = ImagePicker();
  Uint8List? _photo;
  String? _photoError;
  bool _attachLocation = true;
  bool _sending = false;

  /// Null means "right now" — resolved at the moment of sending, not when the
  /// screen opened, so a form left open for a while doesn't send a stale time.
  DateTime? _customSeenAt;

  DateTime get _seenAt => _customSeenAt ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    // A fresh GPS fix, so the location attached below is current.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => context.read<AppState>().refreshGps());
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto(ImageSource source) async {
    setState(() => _photoError = null);
    isPickerOpen = true;
    try {
      // Shrunk and compressed on the spot: the picture travels inside a
      // database document to the owner, so it has to stay small.
      final img = await _picker.pickImage(
          source: source, maxWidth: 1024, maxHeight: 1024, imageQuality: 60);
      if (img == null) return;
      final bytes = await img.readAsBytes();
      if (!mounted) return;
      if (bytes.length > 500000) {
        setState(() => _photoError =
            'That photo is too large. Please take or choose a smaller one.');
        return;
      }
      setState(() => _photo = bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _photoError =
          'Could not access the camera/gallery. Check app permissions in Settings and try again.');
    } finally {
      isPickerOpen = false;
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_seenAt));
    if (picked == null) return;
    final now = DateTime.now();
    var t = DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
    // A time later than "now" today can only mean it was yesterday.
    if (t.isAfter(now)) t = t.subtract(const Duration(days: 1));
    setState(() => _customSeenAt = t);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final state = context.read<AppState>();
    final hasFix =
        state.gpsStatus == GpsStatus.available && state.currentLat != null;
    final useLocation = _attachLocation && hasFix;

    setState(() => _sending = true);
    showLoadingModal(context, message: 'Sending your sighting…');
    final result = await state.submitSighting(
      alert: widget.alert,
      message: _message.text,
      seenAt: _seenAt,
      lat: useLocation ? state.currentLat : null,
      lng: useLocation ? state.currentLng : null,
      photoBytes: _photo,
    );
    if (!mounted) return;
    Navigator.of(context).pop(); // close the loading modal
    setState(() => _sending = false);

    if (!result.ok) {
      await showErrorModal(
        context,
        title: 'Could Not Send Sighting',
        message: result.error!,
      );
      return;
    }
    final mesh = result.sharedOverMesh
        ? ' It was also shared with nearby devices over the ad hoc mesh.'
        : '';
    if (result.blockedByRules) {
      // Not a connection problem, so "we'll deliver it when you're online"
      // would be a false promise — the server is refusing sightings outright.
      await showErrorModal(
        context,
        title: 'Saved, But Not Delivered',
        message:
            'Your sighting is saved on this phone, but the server refused it — the sightings rule has not been published in Firebase yet, so the owner can\'t receive it over the internet until it is.$mesh',
        color: AppColors.amber,
        icon: Icons.warning_amber_rounded,
      );
      if (!mounted) return;
      Navigator.pop(context);
      return;
    }
    await showSuccessModal(
      context,
      title: result.delivered ? 'Sighting Sent' : 'Sighting Saved',
      message: result.delivered
          ? 'Your report about ${widget.alert.plate} was delivered to the vehicle\'s owner.$mesh'
          : 'Saved on this phone. It will be delivered to the owner as soon as you\'re back online.$mesh',
      icon: Icons.check_circle,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(text,
            style: GoogleFonts.dmMono(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.vigiLiteText3,
                letterSpacing: 0.5)),
      );

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final a = widget.alert;
    final hasFix =
        state.gpsStatus == GpsStatus.available && state.currentLat != null;
    final seenIsNow = _customSeenAt == null;

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
        backgroundColor: AppColors.vigiLiteBg,
        foregroundColor: AppColors.vigiLiteText,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back',
            onPressed: _sending ? null : () => Navigator.pop(context)),
        title: const Text('Report a Sighting'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The vehicle being reported on.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.vigiLiteCard,
                  borderRadius: BorderRadius.circular(14),
                  border: const Border(
                      left: BorderSide(
                          color: AppColors.vigiLiteCritical, width: 3)),
                ),
                child: Row(children: [
                  const Text('🚨', style: TextStyle(fontSize: 26)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.plate,
                              style: GoogleFonts.dmMono(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.vigiLiteText)),
                          Text('${a.model} · ${a.color}',
                              style: GoogleFonts.dmSans(
                                  fontSize: 12,
                                  color: AppColors.vigiLiteText3)),
                          Text('Reported stolen ${timeAgo(a.timestamp)}',
                              style: GoogleFonts.dmSans(
                                  fontSize: 11,
                                  color: AppColors.vigiLiteCritical)),
                        ]),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: AppColors.vigiLiteInfo.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  const Icon(Icons.info_outline,
                      size: 16, color: AppColors.vigiLiteInfo),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'Your report goes straight to the vehicle\'s owner — with your name, your message, the photo, where you are, and when you saw it. Only report a vehicle you actually saw.',
                        style: GoogleFonts.dmSans(
                            fontSize: 11.5, color: AppColors.vigiLiteInfo)),
                  ),
                ]),
              ),
              const SizedBox(height: 16),

              _sectionLabel('WHAT DID YOU SEE?'),
              TextFormField(
                controller: _message,
                minLines: 4,
                maxLines: 6,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                style: GoogleFonts.dmSans(
                    fontSize: 14, color: AppColors.vigiLiteText),
                decoration: InputDecoration(
                  hintText:
                      'e.g. Parked beside the market on Montilla St., heading toward the highway. Plate matches.',
                  hintStyle: GoogleFonts.dmSans(
                      fontSize: 14, color: AppColors.vigiLiteText3),
                  filled: true,
                  fillColor: AppColors.vigiLiteInput,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AppColors.vigiLiteBorder)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: AppColors.vigiLiteBorder)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                          color: AppColors.vigiLiteCyan, width: 1.5)),
                  counterStyle: GoogleFonts.dmSans(
                      fontSize: 11, color: AppColors.vigiLiteText3),
                ),
                validator: (v) => (v == null || v.trim().length < 5)
                    ? 'Please describe what you saw (at least a few words).'
                    : null,
              ),
              const SizedBox(height: 8),

              _sectionLabel('PHOTO PROOF (OPTIONAL)'),
              if (_photo != null)
                Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(_photo!,
                        width: double.infinity, height: 200, fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: TapScale(
                      onTap:
                          _sending ? null : () => setState(() => _photo = null),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                            color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.close,
                            size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                ])
              else
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _sending
                          ? null
                          : () => _pickPhoto(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined, size: 18),
                      label: const Text('Take Photo'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          foregroundColor: AppColors.vigiLiteCyan,
                          side: const BorderSide(
                              color: AppColors.vigiLiteBorder)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _sending
                          ? null
                          : () => _pickPhoto(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('Gallery'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          foregroundColor: AppColors.vigiLiteInfo,
                          side: const BorderSide(
                              color: AppColors.vigiLiteBorder)),
                    ),
                  ),
                ]),
              if (_photoError != null) ...[
                const SizedBox(height: 6),
                Text(_photoError!,
                    style: GoogleFonts.dmSans(
                        fontSize: 12, color: AppColors.vigiLiteCritical)),
              ],
              const SizedBox(height: 16),

              _sectionLabel('WHERE YOU SAW IT'),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: AppColors.vigiLiteCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.vigiLiteBorder)),
                child: Row(children: [
                  Icon(hasFix ? Icons.gps_fixed : Icons.location_off_outlined,
                      size: 20,
                      color: hasFix
                          ? AppColors.vigiLiteInfo
                          : AppColors.vigiLiteWarning),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              hasFix
                                  ? 'Attach my current location'
                                  : state.gpsStatus.label,
                              style: GoogleFonts.dmSans(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.vigiLiteText)),
                          Text(
                              hasFix
                                  ? '${state.currentLat!.toStringAsFixed(5)}, ${state.currentLng!.toStringAsFixed(5)}'
                                  : 'No GPS fix — the report will be sent without coordinates. Turn on Location Services to include them.',
                              style: GoogleFonts.dmMono(
                                  fontSize: 10.5,
                                  color: AppColors.vigiLiteText3)),
                        ]),
                  ),
                  if (hasFix)
                    Switch(
                        value: _attachLocation,
                        onChanged: _sending
                            ? null
                            : (v) => setState(() => _attachLocation = v),
                        activeThumbColor: AppColors.vigiLiteCyan)
                  else
                    IconButton(
                        icon: const Icon(Icons.refresh,
                            size: 20, color: AppColors.vigiLiteText3),
                        tooltip: 'Try again',
                        onPressed: state.refreshGps),
                ]),
              ),
              const SizedBox(height: 16),

              _sectionLabel('WHEN YOU SAW IT'),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                    color: AppColors.vigiLiteCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.vigiLiteBorder)),
                child: Row(children: [
                  const Icon(Icons.schedule,
                      size: 20, color: AppColors.vigiLiteText3),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(seenIsNow ? 'Just now' : _seenLabel(_seenAt),
                        style: GoogleFonts.dmSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.vigiLiteText)),
                  ),
                  if (!seenIsNow)
                    TextButton(
                        onPressed: _sending
                            ? null
                            : () => setState(() => _customSeenAt = null),
                        child: const Text('Now')),
                  TextButton(
                      onPressed: _sending ? null : _pickTime,
                      child: const Text('Change')),
                ]),
              ),
              const SizedBox(height: 16),

              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: AppColors.vigiLiteInfo.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10)),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline,
                          size: 16, color: AppColors.vigiLiteInfo),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            (state.currentUser?.phone.isNotEmpty ?? false)
                                ? "Your name and registered phone number are shared with the vehicle's owner so they can contact you about this sighting."
                                : "Your name is shared with the vehicle's owner. You have no phone number on your profile, so they won't be able to call or text you. Add one in Edit Profile if you want to be reachable.",
                            style: GoogleFonts.dmSans(
                                fontSize: 11.5,
                                height: 1.4,
                                color: AppColors.vigiLiteText2)),
                      ),
                    ]),
              ),
              const SizedBox(height: 22),

              PrimaryButton(
                  label: 'SEND SIGHTING',
                  icon: Icons.send_rounded,
                  onTap: _submit,
                  loading: _sending,
                  color: AppColors.vigiLiteCyan,
                  textColor: AppColors.vigiLiteText),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════
// SIGHTINGS OF MY STOLEN VEHICLE (owner)
// ══════════════════════════════════════
class AlertSightingsScreen extends StatefulWidget {
  final TheftAlert alert;
  const AlertSightingsScreen({super.key, required this.alert});
  @override
  State<AlertSightingsScreen> createState() => _AlertSightingsScreenState();
}

class _AlertSightingsScreenState extends State<AlertSightingsScreen> {
  final _mapController = MapController();

  void _showOnMap(SightingReport s) {
    if (!s.hasLocation) return;
    _mapController.move(LatLng(s.lat!, s.lng!), 17);
  }

  void _showPhoto(SightingReport s) =>
      showPhotoViewer(context, base64Decode(s.photoB64!));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final a = widget.alert;
    final sightings = state.sightingsForAlert(a.id);
    final located = sightings.where((s) => s.hasLocation).toList();

    // Where the vehicle was reported stolen — only when that position is real
    // (an alert filed with no GPS fix carries a placeholder, never plotted).
    final alertPoint = a.isDemoLocation ? null : LatLng(a.lat, a.lng);
    final center = located.isNotEmpty
        ? LatLng(located.first.lat!, located.first.lng!)
        : (alertPoint ?? const LatLng(kDefaultLat, kDefaultLng));

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
        backgroundColor: AppColors.vigiLiteBg,
        foregroundColor: AppColors.vigiLiteText,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back',
            onPressed: () => Navigator.pop(context)),
        title: const Text('Sightings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.vigiLiteCard,
              borderRadius: BorderRadius.circular(14),
              border: const Border(
                  left:
                      BorderSide(color: AppColors.vigiLiteCritical, width: 3)),
            ),
            child: Row(children: [
              const Text('🚗', style: TextStyle(fontSize: 26)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.plate,
                          style: GoogleFonts.dmMono(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.vigiLiteText)),
                      Text('${a.model} · ${a.color}',
                          style: GoogleFonts.dmSans(
                              fontSize: 12, color: AppColors.vigiLiteText3)),
                      Text('Reported ${timeAgo(a.timestamp)}',
                          style: GoogleFonts.dmSans(
                              fontSize: 11, color: AppColors.vigiLiteText3)),
                    ]),
              ),
              a.status == AlertStatus.active
                  ? StatusBadge.stolen()
                  : (a.status == AlertStatus.recovered
                      ? StatusBadge.recovered()
                      : StatusBadge.resolved()),
            ]),
          ),
          // The owner's own report — their remarks and the evidence photo
          // they attached when filing it (FR-12). Previously this screen
          // only ever showed OTHER people's sightings; the owner's own
          // submission was nowhere on it, even though it's their report.
          if (a.notes.trim().isNotEmpty || a.hasPhoto) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.vigiLiteCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.vigiLiteBorder, width: 0.8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('YOUR REPORT',
                      style: GoogleFonts.dmMono(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteText3,
                          letterSpacing: 0.4)),
                  if (a.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(a.notes.trim(),
                        style: GoogleFonts.dmSans(
                            fontSize: 13.5,
                            height: 1.45,
                            color: AppColors.vigiLiteText)),
                  ],
                  if (a.hasPhoto) ...[
                    const SizedBox(height: 10),
                    PhotoEvidenceRow(
                      photos: a.photos.map(base64Decode).toList(),
                      height: 180,
                    ),
                  ],
                ],
              ),
            ),
          ],
          // Proof the owner attached when they marked this recovered — only
          // ever present once status has moved past active.
          if (a.status != AlertStatus.active &&
              (a.recoveryRemarks.trim().isNotEmpty || a.hasRecoveryPhoto)) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.vigiLiteSuccess.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: AppColors.vigiLiteSuccess.withValues(alpha: 0.3),
                    width: 0.8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('RECOVERY EVIDENCE',
                      style: GoogleFonts.dmMono(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteSuccess,
                          letterSpacing: 0.4)),
                  if (a.recoveryRemarks.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(a.recoveryRemarks.trim(),
                        style: GoogleFonts.dmSans(
                            fontSize: 13.5,
                            height: 1.45,
                            color: AppColors.vigiLiteText)),
                  ],
                  if (a.hasRecoveryPhoto) ...[
                    const SizedBox(height: 10),
                    PhotoEvidenceRow(
                      photos: a.recoveryPhotos.map(base64Decode).toList(),
                      height: 180,
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (located.isNotEmpty || alertPoint != null) ...[
            Container(
              height: 230,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.vigiLiteBorder)),
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: 15,
                  interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'ph.edu.carsu.vehicleguard',
                  ),
                  MarkerLayer(markers: [
                    if (alertPoint != null)
                      Marker(
                          point: alertPoint,
                          width: 44,
                          height: 44,
                          child:
                              const Text('🚗', style: TextStyle(fontSize: 28))),
                    for (final s in located)
                      Marker(
                          point: LatLng(s.lat!, s.lng!),
                          width: 44,
                          height: 44,
                          child:
                              const Text('📍', style: TextStyle(fontSize: 28))),
                  ]),
                  const RichAttributionWidget(attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ]),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text('🚗 where it was reported stolen   📍 where it was seen',
                style: GoogleFonts.dmSans(
                    fontSize: 11, color: AppColors.vigiLiteText3)),
            const SizedBox(height: 14),
          ],
          SectionLabel('SIGHTINGS (${sightings.length})', dark: true),
          if (sightings.isEmpty)
            AppCard(
              color: AppColors.vigiLiteCard,
              borderColor: AppColors.vigiLiteBorder,
              child: Column(children: [
                const Icon(Icons.visibility_outlined,
                    size: 34, color: AppColors.vigiLiteText3),
                const SizedBox(height: 8),
                Text('No sightings yet',
                    style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.vigiLiteText)),
                const SizedBox(height: 4),
                Text(
                    'When someone nearby reports seeing this vehicle, it shows up here with their message, photo, location and the time they saw it — and you get a notification.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.dmSans(
                        fontSize: 12,
                        color: AppColors.vigiLiteText3,
                        height: 1.4)),
              ]),
            )
          else
            ...sightings.map((s) => _SightingCard(
                  sighting: s,
                  onShowOnMap: s.hasLocation ? () => _showOnMap(s) : null,
                  onOpenPhoto: s.hasPhoto ? () => _showPhoto(s) : null,
                  onOpenContact: () => showReporterContactModal(context, s),
                )),
        ],
      ),
    );
  }
}

class _SightingCard extends StatelessWidget {
  final SightingReport sighting;
  final VoidCallback? onShowOnMap;
  final VoidCallback? onOpenPhoto;
  final VoidCallback onOpenContact;
  const _SightingCard(
      {required this.sighting,
      required this.onOpenContact,
      this.onShowOnMap,
      this.onOpenPhoto});

  @override
  Widget build(BuildContext context) {
    final s = sighting;
    final initial =
        s.reporterName.isNotEmpty ? s.reporterName[0].toUpperCase() : '?';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.vigiLiteCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.vigiLiteBorder, width: 0.8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Tapping the reporter opens their contact details.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpenContact,
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: AppColors.vigiLiteInfo.withValues(alpha: 0.18),
                  shape: BoxShape.circle),
              child: Center(
                  child: Text(initial,
                      style: GoogleFonts.dmSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteInfo))),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.reporterName,
                        style: GoogleFonts.dmSans(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.vigiLiteText)),
                    Text('Seen ${_seenLabel(s.seenAt)}',
                        style: GoogleFonts.dmMono(
                            fontSize: 10.5, color: AppColors.vigiLiteText3)),
                  ]),
            ),
            Text(timeAgo(s.sentAt),
                style: GoogleFonts.dmSans(
                    fontSize: 11, color: AppColors.vigiLiteText3)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                size: 18, color: AppColors.vigiLiteText3),
          ]),
        ),
        const SizedBox(height: 10),
        Text(s.message,
            style: GoogleFonts.dmSans(
                fontSize: 13.5, height: 1.45, color: AppColors.vigiLiteText)),
        if (s.hasPhoto) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onOpenPhoto,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(base64Decode(s.photoB64!),
                  width: double.infinity,
                  height: 170,
                  fit: BoxFit.cover,
                  gaplessPlayback: true),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Icon(s.hasLocation ? Icons.place : Icons.location_off_outlined,
              size: 16,
              color: s.hasLocation
                  ? AppColors.vigiLiteCyan
                  : AppColors.vigiLiteText3),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                s.hasLocation
                    ? '${s.lat!.toStringAsFixed(5)}, ${s.lng!.toStringAsFixed(5)}'
                    : 'No location shared',
                style: GoogleFonts.dmMono(
                    fontSize: 11, color: AppColors.vigiLiteText3)),
          ),
          TextButton.icon(
              onPressed: onOpenContact,
              style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: AppColors.vigiLiteCyan),
              icon: const Icon(Icons.phone_outlined, size: 16),
              label: const Text('Contact')),
          if (onShowOnMap != null)
            TextButton(
                onPressed: onShowOnMap,
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: AppColors.vigiLiteCyan),
                child: const Text('Show on map')),
        ]),
      ]),
    );
  }
}

/// The reporter's contact details, for the vehicle's owner to follow up on a
/// sighting. Shows the phone number they registered with (with a copy
/// button), or says plainly that they haven't got one.
Future<void> showReporterContactModal(BuildContext context, SightingReport s) {
  final initial =
      s.reporterName.isNotEmpty ? s.reporterName[0].toUpperCase() : '?';
  var copied = false;
  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setModal) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(20)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                  color: AppColors.blueLight, shape: BoxShape.circle),
              child: Center(
                  child: Text(initial,
                      style: GoogleFonts.dmSans(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: AppColors.blue))),
            ),
            const SizedBox(height: 12),
            Text(s.reporterName,
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            Text('Reported a sighting · seen ${_seenLabel(s.seenAt)}',
                textAlign: TextAlign.center,
                style:
                    GoogleFonts.dmSans(fontSize: 12, color: AppColors.text3)),
            const SizedBox(height: 16),
            if (s.hasContact)
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  const Icon(Icons.phone_outlined,
                      size: 20, color: AppColors.blue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('MOBILE NUMBER',
                              style: GoogleFonts.dmMono(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.text3)),
                          SelectableText(s.reporterPhone,
                              style: GoogleFonts.dmSans(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                        ]),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: s.reporterPhone));
                      setModal(() => copied = true);
                    },
                    icon: Icon(copied ? Icons.check : Icons.copy, size: 16),
                    label: Text(copied ? 'Copied' : 'Copy'),
                  ),
                ]),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: AppColors.amberLight,
                    borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  const Icon(Icons.phone_disabled_outlined,
                      size: 18, color: AppColors.amber),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        "This person hasn't added a phone number to their profile. Their message and location are all they shared.",
                        style: GoogleFonts.dmSans(
                            fontSize: 12,
                            height: 1.4,
                            color: const Color(0xFF92400E))),
                  ),
                ]),
              ),
            const SizedBox(height: 12),
            Text(
                'Only you can see this. Please use it only to follow up on this sighting.',
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                    fontSize: 11, height: 1.4, color: AppColors.text3)),
            const SizedBox(height: 16),
            PrimaryButton(label: 'CLOSE', onTap: () => Navigator.pop(ctx)),
          ]),
        ),
      ),
    ),
  );
}
