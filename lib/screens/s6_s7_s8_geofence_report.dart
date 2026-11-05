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
import '../utils/emergency_hotlines.dart';
import '../utils/picker_guard.dart';
import '../services/app_state.dart';
import '../models/models.dart';
import '../widgets/widgets.dart';
import '../widgets/document_photo.dart';

// ══════════════════════════════════════
// SCREEN 6: SET GEOFENCE
// ══════════════════════════════════════
class GeofenceScreen extends StatefulWidget {
  final VehicleModel vehicle;
  const GeofenceScreen({super.key, required this.vehicle});
  @override
  State<GeofenceScreen> createState() => _GeofenceScreenState();
}

class _GeofenceScreenState extends State<GeofenceScreen> {
  late double _radius;
  bool _useCurrent = true;
  bool _saving = false;
  bool _deactivating = false;
  final _coordsCtrl = TextEditingController();
  final _mapController = MapController();
  LatLng? _lastCenteredOn;

  @override
  void initState() {
    super.initState();
    _radius = widget.vehicle.geofenceRadius;
    if (widget.vehicle.geofenceCenterLat != null) {
      _coordsCtrl.text =
          '${widget.vehicle.geofenceCenterLat!.toStringAsFixed(5)}° N, ${widget.vehicle.geofenceCenterLng!.toStringAsFixed(5)}° E';
      _useCurrent = false;
    }
    // Live-updates the map preview as a valid manual coordinate is typed —
    // without this, the map only reflected the manual entry after some
    // unrelated rebuild (a GPS tick, toggling the switch), not as you typed.
    _coordsCtrl.addListener(_onManualCoordsChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => context.read<AppState>().refreshGps());
  }

  void _onManualCoordsChanged() {
    if (!_useCurrent) setState(() {});
  }

  @override
  void dispose() {
    _coordsCtrl.removeListener(_onManualCoordsChanged);
    _coordsCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    double? lat, lng;
    if (_useCurrent) {
      if (state.gpsStatus != GpsStatus.available) {
        showResultToast(context,
            message:
                'Location unavailable. Turn on Location Services and try again.',
            success: false);
        return;
      }
      lat = state.currentLat;
      lng = state.currentLng;
    } else {
      final parsed = _parseManualCoords(_coordsCtrl.text);
      if (parsed == null) {
        showResultToast(context,
            message: 'Enter valid coordinates, e.g. 8.9484, 125.5436',
            success: false);
        return;
      }
      lat = parsed.$1;
      lng = parsed.$2;
    }
    setState(() => _saving = true);
    await state.setVehicleGeofence(widget.vehicle.id, _radius,
        active: true, centerLat: lat, centerLng: lng);
    if (!mounted) return;
    setState(() => _saving = false);
    await showSuccessModal(
      context,
      title: 'Geofence Armed',
      message:
          'Safe zone set to ${_radius.toInt()}m for ${widget.vehicle.plate}. Monitoring is now active.',
      icon: Icons.shield_outlined,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  /// Turns monitoring off for this vehicle without deleting it or its
  /// saved radius/center — see AppState.deactivateGeofence. Previously the
  /// only way to stop an active geofence was Remove Vehicle on the Home
  /// screen, which deleted the whole registration just to stop watching a
  /// car the owner was about to drive again.
  Future<void> _deactivate() async {
    final state = context.read<AppState>();
    final ok = await showConfirmDialog(
      context,
      title: 'Turn Off Geofence?',
      message:
          'Monitoring stops for ${widget.vehicle.plate} until you turn it back on. The ${_radius.toInt()}m safe zone stays saved, so reactivating later won\'t need to be set up again.',
      confirmLabel: 'Turn Off',
      confirmColor: AppColors.amber,
      icon: Icons.shield_moon_outlined,
    );
    if (!ok || !mounted) return;
    // Second, final confirmation — guards against an accidental tap on the
    // first dialog's confirm button before monitoring actually stops.
    final reallySure = await showConfirmDialog(
      context,
      title: 'Are You Sure?',
      message:
          'Geofence monitoring for ${widget.vehicle.plate} will stop right away.',
      confirmLabel: 'Yes, Turn Off',
      cancelLabel: 'No, Keep It On',
      confirmColor: AppColors.amber,
      icon: Icons.shield_moon_outlined,
    );
    if (!reallySure) return;
    setState(() => _deactivating = true);
    await state.deactivateGeofence(widget.vehicle.id);
    if (!mounted) return;
    setState(() => _deactivating = false);
    showResultToast(context,
        message: 'Geofence turned off for ${widget.vehicle.plate}.',
        success: true);
    Navigator.pop(context);
  }

  (double, double)? _parseManualCoords(String text) {
    final cleaned = text
        .replaceAll('°', '')
        .replaceAll('N', '')
        .replaceAll('E', '')
        .replaceAll(' ', '');
    final parts = cleaned.split(',');
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0]);
    final lng = double.tryParse(parts[1]);
    if (lat == null || lng == null) return null;
    return (lat, lng);
  }

  /// Picks the map's center point. When the user has switched off "Use
  /// Current GPS Location", whatever they've typed takes priority — the map
  /// used to always show the GPS position here regardless of that toggle,
  /// so the preview and the coordinates actually being saved could disagree.
  /// Falls back to live GPS, then a previously-saved geofence center, then
  /// Butuan City as the same fallback used elsewhere in the app.
  LatLng _mapCenter(AppState state) {
    if (!_useCurrent) {
      final manual = _parseManualCoords(_coordsCtrl.text);
      if (manual != null) return LatLng(manual.$1, manual.$2);
    }
    if (state.gpsStatus == GpsStatus.available && state.currentLat != null) {
      return LatLng(state.currentLat!, state.currentLng!);
    }
    if (widget.vehicle.geofenceCenterLat != null) {
      return LatLng(
          widget.vehicle.geofenceCenterLat!, widget.vehicle.geofenceCenterLng!);
    }
    return const LatLng(kDefaultLat, kDefaultLng);
  }

  /// Keeps the map camera following the center point as GPS updates arrive,
  /// without fighting the user if they've panned/zoomed manually.
  void _recenterIfNeeded(LatLng center) {
    if (_lastCenteredOn == center) return;
    _lastCenteredOn = center;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _mapController.move(center, _mapController.camera.zoom);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final hasFix =
        state.gpsStatus == GpsStatus.available && state.currentLat != null;
    final center = _mapCenter(state);
    _recenterIfNeeded(center);

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
        backgroundColor: AppColors.vigiLiteBg,
        foregroundColor: AppColors.vigiLiteText,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back',
            onPressed: () => Navigator.pop(context)),
        title: const Text('Set Geofence'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Set a safe zone around your vehicle\'s usual location.',
                style: GoogleFonts.dmSans(
                    fontSize: 13, color: AppColors.vigiLiteText2, height: 1.4)),
            const SizedBox(height: 10),
            // Which vehicle this geofence belongs to — previously this
            // screen never named the vehicle at all, so with more than one
            // registered there was no way to tell them apart at a glance.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                  color: AppColors.vigiLiteCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.vigiLiteBorder)),
              child: Row(children: [
                const Icon(Icons.directions_car_filled,
                    size: 22, color: AppColors.vigiLiteText3),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.vehicle.plate,
                          style: GoogleFonts.dmMono(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: AppColors.vigiLiteText)),
                      Text('${widget.vehicle.model} · ${widget.vehicle.color}',
                          style: GoogleFonts.dmSans(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.vigiLiteText2)),
                    ],
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            // Real OpenStreetMap view — shows the geofence center and the
            // safe-zone radius as an actual map overlay instead of a mock.
            // The map tiles themselves stay the standard OpenStreetMap
            // style (same provider/coordinates/markers as before); only the
            // frame around it follows the new dark palette.
            Container(
              height: 200,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.vigiLiteBorder)),
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: center,
                      initialZoom: 16,
                      interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'ph.edu.carsu.vehicleguard',
                      ),
                      CircleLayer(circles: [
                        CircleMarker(
                          point: center,
                          radius: _radius,
                          useRadiusInMeter: true,
                          color: AppColors.vigiLiteCyan.withValues(alpha: 0.1),
                          borderColor:
                              AppColors.vigiLiteCyan.withValues(alpha: 0.7),
                          borderStrokeWidth: 2,
                        ),
                      ]),
                      MarkerLayer(markers: [
                        Marker(
                          point: center,
                          width: 40,
                          height: 40,
                          child:
                              const Text('📍', style: TextStyle(fontSize: 28)),
                        ),
                      ]),
                      const RichAttributionWidget(attributions: [
                        TextSourceAttribution('OpenStreetMap contributors'),
                      ]),
                    ],
                  ),
                  Positioned(
                    bottom: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6)),
                      child: Text(
                        hasFix
                            ? '${state.currentLat!.toStringAsFixed(4)}, ${state.currentLng!.toStringAsFixed(4)}'
                            : state.gpsStatus.label,
                        style: GoogleFonts.dmMono(
                            fontSize: 10, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Radius slider
            Text('SAFE ZONE RADIUS',
                style: GoogleFonts.dmMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.vigiLiteText3,
                    letterSpacing: 0.4)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _radius,
                    min: 50,
                    max: 500,
                    divisions: 90,
                    activeColor: AppColors.vigiLiteCyan,
                    inactiveColor: AppColors.vigiLiteBorder,
                    onChanged: (v) => setState(() => _radius = v),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: AppColors.vigiLiteCyan.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text('${_radius.toInt()}m',
                      style: GoogleFonts.dmMono(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteCyan)),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Use current location toggle
            Text('CENTER LOCATION',
                style: GoogleFonts.dmMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.vigiLiteText3,
                    letterSpacing: 0.4)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                  color: AppColors.vigiLiteCard,
                  border: Border.all(color: AppColors.vigiLiteBorder),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  Text('Use Current GPS Location',
                      style: GoogleFonts.dmSans(
                          fontSize: 14, color: AppColors.vigiLiteText)),
                  const Spacer(),
                  Switch(
                      value: _useCurrent,
                      onChanged: (v) => setState(() => _useCurrent = v),
                      activeThumbColor: AppColors.vigiLiteCyan),
                ],
              ),
            ),
            const SizedBox(height: 14),
            AppTextField(
                label: 'MANUAL CENTER (LAT, LNG)',
                hint: '8.9484, 125.5436',
                controller: _coordsCtrl,
                readOnly: _useCurrent,
                lite: true),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: AppColors.vigiLiteInfo.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                const Icon(Icons.info_outline,
                    size: 16, color: AppColors.vigiLiteInfo),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        'Boundary is set manually. Violation detection is automatic — but only while this phone stays with the vehicle (e.g. left inside it), since VIGILINK uses this phone\'s own GPS to track it. Detection also needs this app open in the foreground.',
                        style: GoogleFonts.dmSans(
                            fontSize: 11.5,
                            color: AppColors.vigiLiteInfo,
                            fontWeight: FontWeight.w600))),
              ]),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
                label: 'SAVE GEOFENCE',
                onTap: _save,
                loading: _saving,
                color: AppColors.vigiLiteCyan,
                textColor: AppColors.vigiLiteText),
            if (widget.vehicle.geofenceActive) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _deactivating ? null : _deactivate,
                icon: _deactivating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.shield_moon_outlined, size: 18),
                label: const Text('TURN OFF GEOFENCE'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52),
                  foregroundColor: AppColors.vigiLiteWarning,
                  side: const BorderSide(color: AppColors.vigiLiteWarning),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════
// SCREEN 7: REPORT STOLEN
// ══════════════════════════════════════
class ReportStolenScreen extends StatefulWidget {
  final VehicleModel vehicle;
  const ReportStolenScreen({super.key, required this.vehicle});
  @override
  State<ReportStolenScreen> createState() => _ReportStolenScreenState();
}

class _ReportStolenScreenState extends State<ReportStolenScreen> {
  final _notes = TextEditingController();
  final _picker = ImagePicker();

  /// Exactly 3 required now, for clearer proof than a single photo —
  /// fixed-length so each tile keeps its own slot regardless of which one(s)
  /// are filled. Decoded bytes, not just an XFile/path — a file path only
  /// resolves on THIS phone's own filesystem, which is exactly why these
  /// evidence photos never used to reach anyone who received the alert
  /// (nearby devices, or the owner's own Alert History on another device).
  /// Same shape and size discipline as ReportSightingScreen's photo, which
  /// already works correctly across devices.
  final List<Uint8List?> _photos = List<Uint8List?>.filled(3, null);
  bool _submitting = false;
  String? _photoError;

  /// All 3 travel inside ONE Firestore document together with the rest of
  /// the alert (1 MB limit) — this cap is tighter than a single-photo cap
  /// would need to be, specifically so 3 of these combined (as base64, which
  /// is ~4/3 the raw size) still leave comfortable headroom under that limit.
  static const int _maxEvidencePhotoBytes = 170000;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto(ImageSource source, int index) async {
    setState(() => _photoError = null);
    isPickerOpen = true;
    try {
      final img = await _picker.pickImage(
          source: source, maxWidth: 1024, maxHeight: 1024, imageQuality: 60);
      if (img == null) return;
      final bytes = await img.readAsBytes();
      if (!mounted) return;
      if (bytes.length > _maxEvidencePhotoBytes) {
        setState(() => _photoError =
            'That photo is too large. Please take or choose a smaller one.');
        return;
      }
      setState(() => _photos[index] = bytes);
    } catch (e) {
      // Camera permission denied or unavailable — don't crash, show a clear message (prompt §9 & §23).
      setState(() => _photoError =
          'Could not access the camera/gallery. Check app permissions in Settings and try again.');
    } finally {
      isPickerOpen = false;
    }
  }

  Future<void> _showPhotoSheet(int index) async {
    final source = await showImageSourceSheet(context,
        title: 'Add Photo Evidence ${index + 1}');
    if (source != null) _pickPhoto(source, index);
  }

  Future<void> _confirm() async {
    if (_photos.any((p) => p == null)) {
      // FR-12: photo evidence (vehicle or parking location) is required
      // before a theft report can be submitted, to reduce false reports —
      // ALL 3 photos now, for clearer proof than a single one.
      setState(() => _photoError =
          'All 3 photos are required before you can submit a theft report.');
      showResultToast(context,
          message:
              'Please attach all 3 required photos of the vehicle or parking location first.',
          success: false);
      return;
    }
    final state = context.read<AppState>();
    if (state.gpsStatus != GpsStatus.available) {
      await state.refreshGps();
    }
    if (!mounted) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Report ${widget.vehicle.plate} as Stolen?',
      message:
          'This will mark your vehicle as STOLEN and broadcast the alert to participating nearby nodes. Submitting a false report is not appropriate and may affect your account standing.',
      confirmLabel: 'Report as Stolen',
      icon: Icons.warning_amber_rounded,
    );
    if (!ok) return;
    if (!mounted) return;

    setState(() => _submitting = true);
    showLoadingModal(context, message: 'Submitting theft report…');
    final TheftAlert alert;
    try {
      alert = await state.reportStolen(
        widget.vehicle.id,
        _notes.text,
        photoBytes: _photos.whereType<Uint8List>().toList(),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // the loading modal
      setState(() => _submitting = false);
      await showErrorModal(context,
          title: 'Could Not Report Stolen',
          message: e is StateError
              ? e.message
              : 'Something went wrong. Check your connection and try again.');
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // the loading modal
    setState(() => _submitting = false);
    // Show the right local authorities before moving on — based on where
    // THIS report says the vehicle was, not the phone's live GPS (they can
    // differ when the owner has no fix and the vehicle's last known spot is
    // used instead; see AppState.reportStolen).
    await showNearestAuthoritiesModal(context,
        lat: alert.lat, lng: alert.lng, isDemoLocation: alert.isDemoLocation);
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/broadcasting', arguments: alert);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.vehicle;
    final state = context.watch<AppState>();
    final hasFix =
        state.gpsStatus == GpsStatus.available && state.currentLat != null;
    final lat = hasFix ? state.currentLat!.toStringAsFixed(5) : '—';
    final lng = hasFix ? state.currentLng!.toStringAsFixed(5) : '—';

    return PopScope(
      // Blocks the Android hardware back button while a report is actively
      // being submitted, so the user can't navigate away mid-submission and
      // end up confused about whether the alert actually went out
      // (manuscript §22/§31 — Android back button handling).
      canPop: !_submitting,
      child: Scaffold(
        backgroundColor: AppColors.vigiLiteBg,
        appBar: AppBar(
          backgroundColor: AppColors.vigiLiteBg,
          foregroundColor: AppColors.vigiLiteText,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back',
            onPressed: _submitting
                ? () => showResultToast(context,
                    message:
                        'Please wait — your report is still being submitted.',
                    success: false)
                : () => Navigator.pop(context),
          ),
          title: Text('Report Vehicle as Stolen',
              style: GoogleFonts.dmSans(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.vigiLiteCritical)),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // Vehicle banner
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.vigiLiteTeal,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.vigiLiteBorder),
                ),
                child: Row(
                  children: [
                    const Text('🚗', style: TextStyle(fontSize: 28)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(v.plate,
                                style: GoogleFonts.dmMono(
                                    fontSize: 23,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.vigiLiteText,
                                    letterSpacing: 1.2)),
                            Text('${v.model} · ${v.color} · ${v.type}',
                                style: GoogleFonts.dmSans(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.vigiLiteText2)),
                          ]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // GPS location — real, honest status
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: AppColors.vigiLiteCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.vigiLiteBorder)),
                child: Row(
                  children: [
                    Icon(hasFix ? Icons.gps_fixed : Icons.gps_not_fixed,
                        color: hasFix
                            ? AppColors.vigiLiteInfo
                            : AppColors.vigiLiteWarning,
                        size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(
                              hasFix
                                  ? 'Smartphone GPS Location'
                                  : state.gpsStatus.label,
                              style: GoogleFonts.dmSans(
                                  fontSize: 12,
                                  color: AppColors.vigiLiteText2,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(
                              hasFix
                                  ? '$lat° N, $lng° E'
                                  : 'Tap refresh to acquire a GPS fix',
                              style: GoogleFonts.dmMono(
                                  fontSize: 11,
                                  color: hasFix
                                      ? AppColors.vigiLiteInfo
                                      : AppColors.vigiLiteText3,
                                  fontWeight: FontWeight.w600)),
                        ])),
                    IconButton(
                        icon: const Icon(Icons.refresh,
                            size: 20, color: AppColors.vigiLiteText3),
                        tooltip: 'Refresh GPS location',
                        onPressed: () => state.refreshGps()),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Photo evidence (FR-12)
              AppCard(
                color: AppColors.vigiLiteCard,
                borderColor: AppColors.vigiLiteBorder,
                padding: const EdgeInsets.all(14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text('PHOTO EVIDENCE',
                            style: GoogleFonts.dmMono(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.vigiLiteText3,
                                letterSpacing: 0.4)),
                        const SizedBox(width: 6),
                        Text('(3 required)',
                            style: GoogleFonts.dmSans(
                                fontSize: 11,
                                color: AppColors.vigiLiteCyan,
                                fontWeight: FontWeight.w600)),
                      ]),
                      const SizedBox(height: 4),
                      Text(
                          'Take 3 clear photos — different angles of the vehicle or its parking spot help confirm this report is genuine.',
                          style: GoogleFonts.dmSans(
                              fontSize: 11.5,
                              height: 1.4,
                              color: AppColors.vigiLiteText3)),
                      const SizedBox(height: 10),
                      Row(children: [
                        for (var i = 0; i < _photos.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(
                            child: _EvidencePhotoTile(
                              index: i,
                              photo: _photos[i],
                              onTap: () => _showPhotoSheet(i),
                              onRemove: () => setState(() => _photos[i] = null),
                            ),
                          ),
                        ],
                      ]),
                      if (_photoError != null) ...[
                        const SizedBox(height: 8),
                        Text(_photoError!,
                            style: GoogleFonts.dmSans(
                                fontSize: 11.5,
                                color: AppColors.vigiLiteCritical)),
                      ],
                    ]),
              ),
              const SizedBox(height: 12),

              // Notes
              AppCard(
                color: AppColors.vigiLiteCard,
                borderColor: AppColors.vigiLiteBorder,
                padding: const EdgeInsets.all(14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('REMARKS (OPTIONAL)',
                          style: GoogleFonts.dmMono(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.vigiLiteText3,
                              letterSpacing: 0.4)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _notes,
                        maxLines: 2,
                        style: GoogleFonts.dmSans(
                            fontSize: 14, color: AppColors.vigiLiteText),
                        decoration: InputDecoration(
                          hintText:
                              'e.g. Last seen near Robinsons Mall, heading north',
                          hintStyle: GoogleFonts.dmSans(
                              fontSize: 13, color: AppColors.vigiLiteText3),
                          filled: true,
                          fillColor: AppColors.vigiLiteInput,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                  color: AppColors.vigiLiteBorder)),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                  color: AppColors.vigiLiteBorder)),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                  color: AppColors.vigiLiteCyan, width: 1.5)),
                        ),
                      ),
                    ]),
              ),

              // Warning
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: AppColors.vigiLiteCritical.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color:
                            AppColors.vigiLiteCritical.withValues(alpha: 0.4))),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('⚠️', style: TextStyle(fontSize: 18)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(
                            'This action will mark your vehicle as STOLEN and broadcast the alert to nearby VIGILINK devices over the real ad hoc mesh (Bluetooth/Wi-Fi). Submitting a false report is not appropriate.',
                            style: GoogleFonts.dmSans(
                                fontSize: 12,
                                color: AppColors.vigiLiteCritical,
                                height: 1.5))),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                  label: '🚨  REPORT AS STOLEN',
                  onTap: _confirm,
                  loading: _submitting,
                  color: AppColors.vigiLiteCritical),
              const SizedBox(height: 10),
              OutlineButton2(
                  label: 'CANCEL',
                  onTap: () => Navigator.pop(context),
                  dark: true),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the 3 required evidence-photo slots: a captured thumbnail with a
/// remove button, or an empty "add photo" tile naming its own slot number.
class _EvidencePhotoTile extends StatelessWidget {
  final int index;
  final Uint8List? photo;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  const _EvidencePhotoTile({
    required this.index,
    required this.photo,
    required this.onTap,
    required this.onRemove,
  });

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
            Text('Photo ${index + 1}',
                style: GoogleFonts.dmSans(
                    fontSize: 11, color: AppColors.vigiLiteText3)),
          ]),
        ),
      ),
    );
  }
}

/// Shows the emergency authorities closest to where a just-submitted theft
/// report says the vehicle was — the same "view contact, copy the number"
/// pattern as [showReporterContactModal] in s16_sightings.dart, but for a
/// list of agencies instead of one person. [isDemoLocation] mirrors
/// [TheftAlert.isDemoLocation]: true when the report used the vehicle's last
/// known spot because the phone had no live GPS fix at the time.
Future<void> showNearestAuthoritiesModal(
  BuildContext context, {
  required double lat,
  required double lng,
  required bool isDemoLocation,
}) {
  final area = nearestHotlineArea(lat, lng);
  return showDialog<void>(
    context: context,
    builder: (ctx) =>
        _AuthoritiesDialog(area: area, isDemoLocation: isDemoLocation),
  );
}

class _AuthoritiesDialog extends StatefulWidget {
  final HotlineArea area;
  final bool isDemoLocation;
  const _AuthoritiesDialog({required this.area, required this.isDemoLocation});

  @override
  State<_AuthoritiesDialog> createState() => _AuthoritiesDialogState();
}

class _AuthoritiesDialogState extends State<_AuthoritiesDialog> {
  final Set<String> _copied = {};
  bool _showBarangay = false;

  /// Copies the DIALABLE number — the network tag some entries carry, like
  /// "(Smart)", is shown for context but stripped before it reaches the
  /// clipboard, so pasting it into the phone dialer actually works.
  Future<void> _copy(String rawNumber) async {
    final clean = rawNumber.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();
    await Clipboard.setData(ClipboardData(text: clean));
    if (!mounted) return;
    setState(() => _copied.add(rawNumber));
  }

  @override
  Widget build(BuildContext context) {
    final main = widget.area.entries.where((e) => !e.isBarangay).toList();
    final barangay = widget.area.entries.where((e) => e.isBarangay).toList();
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: 440,
            maxHeight: MediaQuery.of(context).size.height * 0.84),
        child: Container(
          decoration: BoxDecoration(
              color: AppColors.white, borderRadius: BorderRadius.circular(20)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
              child: Column(children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: const BoxDecoration(
                      color: AppColors.tealLight, shape: BoxShape.circle),
                  child: const Icon(Icons.shield_outlined,
                      color: AppColors.teal, size: 26),
                ),
                const SizedBox(height: 12),
                Text('Nearby Authorities to Contact',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.dmSans(
                        fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                  widget.isDemoLocation
                      ? "Closest listed authorities to this vehicle's last known location:"
                      : 'Closest listed authorities to where you reported this:',
                  textAlign: TextAlign.center,
                  style:
                      GoogleFonts.dmSans(fontSize: 12, color: AppColors.text3),
                ),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: AppColors.blueLight,
                      borderRadius: BorderRadius.circular(99)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.place, size: 14, color: AppColors.blue),
                    const SizedBox(width: 6),
                    Text(widget.area.name,
                        style: GoogleFonts.dmSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.blue)),
                  ]),
                ),
              ]),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                children: [
                  for (final e in main)
                    _HotlineRow(entry: e, copied: _copied, onCopy: _copy),
                  if (barangay.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    TapScale(
                      onTap: () =>
                          setState(() => _showBarangay = !_showBarangay),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 10, horizontal: 12),
                        decoration: BoxDecoration(
                            color: AppColors.bg,
                            borderRadius: BorderRadius.circular(10)),
                        child: Row(children: [
                          const Icon(Icons.info_outline,
                              size: 16, color: AppColors.text3),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                                'Barangay DRRMO contacts (${barangay.length})',
                                style: GoogleFonts.dmSans(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.text2)),
                          ),
                          Icon(
                              _showBarangay
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 18,
                              color: AppColors.text3),
                        ]),
                      ),
                    ),
                    if (_showBarangay) ...[
                      const SizedBox(height: 8),
                      for (final e in barangay)
                        _HotlineRow(entry: e, copied: _copied, onCopy: _copy),
                    ],
                  ],
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
              child: Column(children: [
                Text(
                  'These numbers are for your convenience during an emergency. VIGILINK does not replace an official report to the Philippine National Police.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(
                      fontSize: 11, height: 1.4, color: AppColors.text3),
                ),
                const SizedBox(height: 14),
                PrimaryButton(
                    label: 'CLOSE', onTap: () => Navigator.pop(context)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// One agency's card: its name, and each of its numbers with its own copy
/// button and "Copied" feedback, so several numbers under one agency can
/// each be copied independently.
class _HotlineRow extends StatelessWidget {
  final HotlineEntry entry;
  final Set<String> copied;
  final Future<void> Function(String number) onCopy;
  const _HotlineRow(
      {required this.entry, required this.copied, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
          color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 4),
            child: Text(entry.agency,
                style: GoogleFonts.dmSans(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text)),
          ),
          for (final n in entry.numbers)
            Row(children: [
              const Icon(Icons.phone_outlined, size: 15, color: AppColors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(n,
                    style: GoogleFonts.dmMono(
                        fontSize: 13.5, fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: () => onCopy(n),
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                icon: Icon(copied.contains(n) ? Icons.check : Icons.copy,
                    size: 15),
                label: Text(copied.contains(n) ? 'Copied' : 'Copy',
                    style: GoogleFonts.dmSans(fontSize: 11.5)),
              ),
            ]),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════
// SCREEN 8: ALERT BROADCASTING
// ══════════════════════════════════════
class AlertBroadcastingScreen extends StatefulWidget {
  final TheftAlert alert;
  const AlertBroadcastingScreen({super.key, required this.alert});
  @override
  State<AlertBroadcastingScreen> createState() =>
      _AlertBroadcastingScreenState();
}

class _AlertBroadcastingScreenState extends State<AlertBroadcastingScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat();
    _pulse = Tween<double>(begin: 0.8, end: 1.4)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // Only devices the alert is actually relayed to (Bluetooth / simulated) —
    // devices listed by shared GPS get it through the internet feed instead.
    final nodes =
        state.nodes.where((n) => n.isOnline && !n.viaInternet).toList();
    final alert = widget.alert;
    final t = alert.timestamp;
    final timeStr = DateFormat('hh:mm a').format(t);

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
        backgroundColor: AppColors.vigiLiteBg,
        foregroundColor: AppColors.vigiLiteText,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back to Home',
            onPressed: () => Navigator.pushReplacementNamed(context, '/home')),
        title: const Text('Alert Broadcasting'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
                child: Text('Hop ${alert.hopCount}',
                    style: GoogleFonts.dmMono(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.vigiLiteCyan))),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Stolen alert card with pulse
            Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, __) => Container(
                    width: double.infinity,
                    height: 130,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: AppColors.vigiLiteCritical
                          .withValues(alpha: 0.05 * (1.4 - _pulse.value)),
                    ),
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [Color(0xFF7F1D1D), Color(0xFFDC2626)]),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(99)),
                        child: Text('🚨  STOLEN',
                            style: GoogleFonts.dmMono(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                      const SizedBox(height: 8),
                      Text(alert.plate,
                          style: GoogleFonts.dmMono(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                      Text('${alert.model} · ${alert.color}',
                          style: GoogleFonts.dmSans(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.8))),
                      const SizedBox(height: 6),
                      Text(
                          '📍 ${alert.lat.toStringAsFixed(4)}° N, ${alert.lng.toStringAsFixed(4)}° E  ·  $timeStr${alert.isDemoLocation ? '  ·  DEMO / SIMULATED LOCATION' : ''}',
                          style: GoogleFonts.dmMono(
                              fontSize: 10,
                              color: Colors.white.withValues(alpha: 0.6))),
                      Text(
                          '⚡ Trigger: ${alert.triggerLabel}  ·  ID: ${alert.id}',
                          style: GoogleFonts.dmMono(
                              fontSize: 10,
                              color: Colors.white.withValues(alpha: 0.6))),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Nodes card
            AppCard(
              color: AppColors.vigiLiteCard,
              borderColor: AppColors.vigiLiteBorder,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('📡 Broadcasting via Real Ad Hoc Mesh',
                      style: GoogleFonts.dmSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteText)),
                  const SizedBox(height: 4),
                  Text(
                      'BLE / Wi-Fi Direct (Real) · Hop Count: ${alert.hopCount}',
                      style: GoogleFonts.dmMono(
                          fontSize: 11, color: AppColors.vigiLiteText3)),
                  const SizedBox(height: 4),
                  Text(
                      nodes.isEmpty
                          ? 'No participating devices are currently nearby. The alert remains stored and will relay when a node becomes available.'
                          : '${alert.relayedTo.length} of ${nodes.length} nearby node(s) have received this alert.',
                      style: GoogleFonts.dmSans(
                          fontSize: 11, color: AppColors.vigiLiteText3)),
                  const SizedBox(height: 10),
                  ...nodes.map((n) => NodeRelayRow(node: n)),
                ],
              ),
            ),

            // Multi-hop info
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.vigiLiteInfo.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(
                children: [
                  const Icon(Icons.link,
                      size: 18, color: AppColors.vigiLiteInfo),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(
                          'Multi-hop store-carry-forward active. Alerts propagate even without internet.',
                          style: GoogleFonts.dmSans(
                              fontSize: 12, color: AppColors.vigiLiteInfo))),
                ],
              ),
            ),
            const SizedBox(height: 14),
            OutlineButton2(
                label: 'View Alert History →',
                onTap: () => Navigator.pushNamed(context, '/alert-history'),
                dark: true),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
