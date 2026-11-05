import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../utils/app_theme.dart';
import '../utils/geo_defaults.dart';
import '../services/app_state.dart';
import '../services/location_service.dart';
import '../models/models.dart';
import '../widgets/widgets.dart';
import 's16_sightings.dart';
import '../utils/time_format.dart';

// ══════════════════════════════════════
// SCREEN 9: ALERT RECEIVED (NEARBY USER VIEW)
// ══════════════════════════════════════
class AlertReceivedScreen extends StatelessWidget {
  final TheftAlert alert;
  const AlertReceivedScreen({super.key, required this.alert});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // How this alert really reached the phone, and how far away it was
    // reported — this screen used to say "Real Ad Hoc Mesh / Nearby" for
    // every alert, including ones that came over the internet.
    final via = state.receivedVia[alert.id];
    final viaInternet = via == 'Internet';
    final myId = state.currentUser?.id;
    final canReportSighting =
        alert.userId != myId && alert.status == AlertStatus.active;
    final mySightingCount = state
        .sightingsForAlert(alert.id)
        .where((s) => s.reporterId == myId)
        .length;
    final distanceM = (state.currentLat != null &&
            state.currentLng != null &&
            !alert.isDemoLocation)
        ? LocationService.distanceMeters(
            state.currentLat!, state.currentLng!, alert.lat, alert.lng)
        : null;
    final proximityText = distanceM == null
        ? 'Nearby'
        : (distanceM < 1000
            ? '~${distanceM.round()} m away'
            : '~${(distanceM / 1000).toStringAsFixed(1)} km away');
    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
        backgroundColor: AppColors.vigiLiteBg,
        foregroundColor: AppColors.vigiLiteText,
        title: const Text('Alert Received'),
        actions: [
          IconButton(
              icon: const Icon(Icons.notifications_outlined),
              tooltip: 'Notifications',
              onPressed: () => Navigator.pushNamed(context, '/notifications'))
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Alert card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.vigiLiteCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: AppColors.vigiLiteCritical.withValues(alpha: 0.4),
                    width: 2),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                            color: alert.status == AlertStatus.active
                                ? AppColors.vigiLiteCritical
                                    .withValues(alpha: 0.18)
                                : AppColors.vigiLiteSuccess
                                    .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(14)),
                        child: Center(
                            child: Text(
                                alert.status == AlertStatus.active ? '🚨' : '✅',
                                style: const TextStyle(fontSize: 22))),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                            alert.status == AlertStatus.active
                                ? 'Stolen Vehicle Nearby!'
                                : 'Vehicle Recovered',
                            style: GoogleFonts.dmSans(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: alert.status == AlertStatus.active
                                    ? AppColors.vigiLiteCritical
                                    : AppColors.vigiLiteSuccess)),
                      ),
                      if (alert.status == AlertStatus.recovered)
                        StatusBadge.recovered()
                      else if (alert.status == AlertStatus.resolved)
                        StatusBadge.resolved(),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // The vehicle's own identity — plate first and largest,
                  // since that's what anyone nearby actually needs to match
                  // against the real car in front of them. Series and color
                  // used to be crammed into one 12px gray line; each now gets
                  // its own clearly labeled, readable chip.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(alert.plate,
                        style: GoogleFonts.dmMono(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                            color: AppColors.vigiLiteCritical)),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                        child: _VehicleInfoChip(
                            label: 'SERIES', value: alert.model)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _VehicleInfoChip(
                            label: 'COLOR', value: alert.color)),
                  ]),
                  const SizedBox(height: 8),
                  // Recommended by the Highway Patrol Group (HPG) — these two
                  // tell a single car apart from every other one that happens
                  // to share its plate, make, or color.
                  Row(children: [
                    Expanded(
                        child: _VehicleInfoChip(
                            label: 'ENGINE NO.', value: alert.engineNumber)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _VehicleInfoChip(
                            label: 'CHASSIS NO.', value: alert.chassisNumber)),
                  ]),
                  const SizedBox(height: 14),
                  // Meta grid
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 2.2,
                    children: [
                      _MetaItem(label: 'Distance', value: proximityText),
                      _MetaItem(
                          label: 'Received Via',
                          value: viaInternet ? 'Internet' : 'Real Ad Hoc Mesh'),
                      _MetaItem(
                          label: 'Reported',
                          value: timeAgo(alert.timestamp, capitalize: true)),
                      _MetaItem(
                          label: 'Hop Count', value: 'Hop ${alert.hopCount}'),
                    ],
                  ),
                  if (alert.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('REMARKS FROM THE OWNER',
                              style: GoogleFonts.dmMono(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.vigiLiteText3,
                                  letterSpacing: 0.4)),
                          const SizedBox(height: 4),
                          Text(alert.notes.trim(),
                              style: GoogleFonts.dmSans(
                                  fontSize: 13.5,
                                  height: 1.45,
                                  color: AppColors.vigiLiteText)),
                        ],
                      ),
                    ),
                  ],
                  if (alert.hasPhoto) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('PHOTO EVIDENCE',
                          style: GoogleFonts.dmMono(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.vigiLiteText3,
                              letterSpacing: 0.4)),
                    ),
                    const SizedBox(height: 6),
                    PhotoEvidenceRow(
                      photos: alert.photos.map(base64Decode).toList(),
                      height: 180,
                    ),
                  ] else if (!viaInternet &&
                      alert.trigger == AlertTrigger.manualReport) ...[
                    // A manually-submitted report always has 3 photos (FR-12
                    // requires them before it can even be sent) — so if this
                    // mesh-received copy doesn't have any yet, the owner DID
                    // attach them, they just didn't travel over the mesh (too
                    // large for a reliable BLE/Wi-Fi Direct relay payload —
                    // see AppState._alertWireMessage). Say so honestly
                    // instead of looking like nothing was ever attached.
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                          color: AppColors.vigiLiteInfo.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AppColors.vigiLiteInfo
                                  .withValues(alpha: 0.3))),
                      child: Row(
                        children: [
                          const Icon(Icons.photo_outlined,
                              size: 16, color: AppColors.vigiLiteInfo),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(
                                  "The owner attached photos — they're too large to relay over the ad hoc mesh, but will appear here once this device is back online.",
                                  style: GoogleFonts.dmSans(
                                      fontSize: 12,
                                      color: AppColors.vigiLiteInfo))),
                        ],
                      ),
                    ),
                  ],
                  if (alert.status != AlertStatus.active) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color:
                              AppColors.vigiLiteSuccess.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AppColors.vigiLiteSuccess
                                  .withValues(alpha: 0.3))),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('RECOVERY EVIDENCE',
                              style: GoogleFonts.dmMono(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.vigiLiteSuccess,
                                  letterSpacing: 0.4)),
                          if (alert.recoveryRemarks.trim().isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(alert.recoveryRemarks.trim(),
                                style: GoogleFonts.dmSans(
                                    fontSize: 13.5,
                                    height: 1.45,
                                    color: AppColors.vigiLiteText)),
                          ],
                          if (alert.hasRecoveryPhoto) ...[
                            const SizedBox(height: 10),
                            PhotoEvidenceRow(
                              photos: alert.recoveryPhotos
                                  .map(base64Decode)
                                  .toList(),
                              height: 160,
                            ),
                          ] else if (!viaInternet) ...[
                            // A recovery photo is always required (see
                            // TheftAlert.recoveryPhotos) — missing here only
                            // ever means it didn't fit over the mesh, same
                            // reasoning as the original report's photos above.
                            const SizedBox(height: 8),
                            Text(
                                "The owner attached a recovery photo — too large to relay over the ad hoc mesh, but will appear here once this device is back online.",
                                style: GoogleFonts.dmSans(
                                    fontSize: 12,
                                    color: AppColors.vigiLiteSuccess)),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // Stored locally banner
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                        color:
                            AppColors.vigiLiteWarning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: AppColors.vigiLiteWarning
                                .withValues(alpha: 0.3))),
                    child: Row(
                      children: [
                        const Text('💾', style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                'Stolen vehicle info saved to local device storage (SQLite)',
                                style: GoogleFonts.dmSans(
                                    fontSize: 12,
                                    color: AppColors.vigiLiteWarning))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Relay chain
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                        color:
                            AppColors.vigiLiteSuccess.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: AppColors.vigiLiteSuccess
                                .withValues(alpha: 0.3))),
                    child: Row(
                      children: [
                        const Text('📡', style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                viaInternet
                                    ? 'Delivered over the internet. It is also relayed to any nearby device the ad hoc mesh connects to.'
                                    : 'Auto-relaying to ${alert.relayedTo.length} nearby node(s) — store-carry-forward active (real ad hoc mesh)',
                                style: GoogleFonts.dmSans(
                                    fontSize: 12,
                                    color: AppColors.vigiLiteSuccess))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Only someone who ISN'T the owner, and only while the vehicle is
            // still missing — the owner has Update Status instead, and a
            // sighting of an already-recovered vehicle is moot.
            if (canReportSighting) ...[
              PrimaryButton(
                  label: '👁️  REPORT A SIGHTING',
                  onTap: () => Navigator.pushNamed(context, '/report-sighting',
                      arguments: alert),
                  color: AppColors.vigiLiteCyan,
                  textColor: AppColors.vigiLiteText),
              if (mySightingCount > 0) ...[
                const SizedBox(height: 8),
                Center(
                  child: Text(
                      'You have sent $mySightingCount sighting${mySightingCount == 1 ? '' : 's'} for this vehicle.',
                      style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppColors.vigiLiteSuccess,
                          fontWeight: FontWeight.w600)),
                ),
              ],
              const SizedBox(height: 10),
            ],
            OutlineButton2(
                label: '🗺️  VIEW ON MAP',
                onTap: () => Navigator.pushNamed(context, '/prox-map'),
                dark: true),
            const SizedBox(height: 10),
            OutlineButton2(
                label: 'DISMISS',
                onTap: () => Navigator.pushReplacementNamed(context, '/home'),
                dark: true),
          ],
        ),
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  final String label;
  final String value;
  const _MetaItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
            color: AppColors.vigiLiteInput,
            borderRadius: BorderRadius.circular(10)),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label,
                  style: GoogleFonts.dmSans(
                      fontSize: 10,
                      color: AppColors.vigiLiteText3,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(value,
                  style: GoogleFonts.dmMono(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteText)),
            ]),
      );
}

/// A labeled piece of the vehicle's own identity (series, color) — larger
/// and bolder than [_MetaItem] on purpose, since this is what someone
/// nearby actually needs to read clearly to match the alert to a real car.
class _VehicleInfoChip extends StatelessWidget {
  final String label;
  final String value;
  const _VehicleInfoChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: AppColors.vigiLiteInput,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.vigiLiteBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: GoogleFonts.dmMono(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: AppColors.vigiLiteText3,
                  letterSpacing: 0.4)),
          const SizedBox(height: 2),
          Text(value.isEmpty ? '—' : value,
              style: GoogleFonts.dmSans(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.vigiLiteText)),
        ]),
      );
}

// ══════════════════════════════════════
// SCREEN 10: PROXIMITY MAP
// ══════════════════════════════════════
class ProximityMapScreen extends StatefulWidget {
  const ProximityMapScreen({super.key});
  @override
  State<ProximityMapScreen> createState() => _ProximityMapScreenState();
}

class _ProximityMapScreenState extends State<ProximityMapScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _rippleCtrl;
  late Animation<double> _ripple;
  final _mapController = MapController();
  LatLng? _lastCenteredOn;

  @override
  void initState() {
    super.initState();
    _rippleCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat();
    _ripple = Tween<double>(begin: 0.0, end: 1.0).animate(_rippleCtrl);
  }

  @override
  void dispose() {
    _rippleCtrl.dispose();
    super.dispose();
  }

  /// mapX/mapY are 0.0–1.0 relative values originally used to place a pin
  /// on the old fake pixel-grid map. Real BLE/Wi-Fi Direct peers don't
  /// expose an actual distance/bearing (see AdHocNode docs in models.dart),
  /// so a node's exact position was always approximate — this just draws
  /// that same approximate spread on a real map instead of a fake grid.
  LatLng _offsetFromMapXY(LatLng center, double mapX, double mapY) {
    const spreadDegrees =
        0.0012; // roughly ±130m, matching the old "100m radius" visual
    final dx = (mapX - 0.5) * 2 * spreadDegrees;
    final dy = (mapY - 0.5) * 2 * spreadDegrees;
    return LatLng(center.latitude + dy, center.longitude + dx);
  }

  /// Picks the most meaningful map center: the active alert's real location
  /// first (that's what this screen exists to show), then the user's live
  /// GPS, then the same Butuan City fallback used elsewhere in the app.
  LatLng _mapCenter(AppState state, List<TheftAlert> alerts) {
    if (alerts.isNotEmpty) return LatLng(alerts.first.lat, alerts.first.lng);
    if (state.gpsStatus == GpsStatus.available && state.currentLat != null) {
      return LatLng(state.currentLat!, state.currentLng!);
    }
    return const LatLng(kDefaultLat, kDefaultLng);
  }

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
    final nodes = state.nodes;
    final alerts = state.activeAlerts;
    final center = _mapCenter(state, alerts);
    _recenterIfNeeded(center);
    final youPoint =
        (state.gpsStatus == GpsStatus.available && state.currentLat != null)
            ? LatLng(state.currentLat!, state.currentLng!)
            : _offsetFromMapXY(center, 0.4, 0.6);
    // Whether the alert being shown (if any) is the viewer's own vehicle —
    // an alert relayed over the mesh can just as easily be someone else's.
    // Own vehicle: the "You" pin itself turns red/STOLEN, no separate pin.
    // Someone else's: keep both the red STOLEN pin (their vehicle) and the
    // viewer's own blue "You" pin, since those are two different places.
    final myAlert =
        alerts.isNotEmpty && alerts.first.userId == state.currentUser?.id
            ? alerts.first
            : null;
    final otherAlert =
        alerts.isNotEmpty && myAlert == null ? alerts.first : null;
    // What's actually being shown at `center`: the active alert's own
    // recorded location (real GPS at report time, or a labeled fallback —
    // see isDemoLocation) when there is one, otherwise the device's current
    // GPS status. Previously this badge just read the device's CURRENT gps
    // status regardless of which of those `center` actually was, so an
    // alert reported without GPS (isDemoLocation: true) could still say
    // "LAST KNOWN LOCATION" simply because GPS happened to be available now.
    final centerIsReal = alerts.isNotEmpty
        ? !alerts.first.isDemoLocation
        : state.gpsStatus == GpsStatus.available;

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
        backgroundColor: AppColors.vigiLiteBg,
        foregroundColor: AppColors.vigiLiteText,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back',
            onPressed: () => Navigator.pop(context)),
        title: const Text('Proximity Map'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
                child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: AppColors.vigiLiteCritical.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(
                  centerIsReal ? 'LAST KNOWN LOCATION' : 'SIMULATED LOCATION',
                  style: GoogleFonts.dmMono(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteCritical)),
            )),
          ),
        ],
      ),
      body: Column(
        children: [
          // Real OpenStreetMap view — shows the stolen vehicle's actual
          // last-known location, the user's live GPS position, and nearby
          // nodes, instead of a mock pixel-grid map.
          Container(
            height: 280,
            clipBehavior: Clip.antiAlias,
            decoration: const BoxDecoration(),
            child: Stack(
              children: [
                FlutterMap(
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
                    // ~100m proximity indicator around the stolen vehicle —
                    // only meaningful once there's an actual alert to show.
                    if (alerts.isNotEmpty)
                      CircleLayer(circles: [
                        CircleMarker(
                          point: center,
                          radius: 100,
                          useRadiusInMeter: true,
                          color: AppColors.vigiLiteCritical
                              .withValues(alpha: 0.05),
                          borderColor:
                              AppColors.vigiLiteCritical.withValues(alpha: 0.3),
                          borderStrokeWidth: 1.5,
                        ),
                      ]),
                    MarkerLayer(markers: [
                      // Someone else's stolen vehicle — its own red ripple
                      // pin, separate from the viewer's own position below.
                      // (When the alert being shown is the viewer's own
                      // vehicle, this is skipped — see the "You" pin.)
                      if (otherAlert != null)
                        Marker(
                          point: center,
                          width: 140,
                          height: 70,
                          alignment: Alignment.center,
                          child: AnimatedBuilder(
                            animation: _ripple,
                            builder: (_, __) => Stack(
                              alignment: Alignment.topCenter,
                              children: [
                                Positioned(
                                  top: 17 - 40 * _ripple.value,
                                  child: Container(
                                    width: 34 + 80 * _ripple.value,
                                    height: 34 + 80 * _ripple.value,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: AppColors.vigiLiteCritical
                                              .withValues(
                                                  alpha: 1 - _ripple.value),
                                          width: 2),
                                    ),
                                  ),
                                ),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                          color: AppColors.vigiLiteCritical,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: Colors.white, width: 2.5)),
                                      child: const Center(
                                          child: Text('🚗',
                                              style: TextStyle(fontSize: 16))),
                                    ),
                                    const SizedBox(height: 2),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius:
                                              BorderRadius.circular(5),
                                          boxShadow: [
                                            BoxShadow(
                                                color: Colors.black
                                                    .withValues(alpha: 0.15),
                                                blurRadius: 4)
                                          ]),
                                      child: Text(
                                          'STOLEN · ${otherAlert.plate}',
                                          style: GoogleFonts.dmMono(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w800,
                                              color:
                                                  AppColors.vigiLiteCritical)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      // The viewer's own position — one dot, not two: blue
                      // "You" normally, or the same red ripple+STOLEN pin
                      // above (merged, not duplicated) once it's their own
                      // vehicle that was reported stolen, so nearby viewers
                      // reading the map see a single red dot for "stolen"
                      // either way.
                      Marker(
                        point: youPoint,
                        width: 140,
                        height: 70,
                        alignment: Alignment.center,
                        child: myAlert != null
                            ? AnimatedBuilder(
                                animation: _ripple,
                                builder: (_, __) => Stack(
                                  alignment: Alignment.topCenter,
                                  children: [
                                    Positioned(
                                      top: 17 - 40 * _ripple.value,
                                      child: Container(
                                        width: 34 + 80 * _ripple.value,
                                        height: 34 + 80 * _ripple.value,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: AppColors.vigiLiteCritical
                                                  .withValues(
                                                      alpha: 1 - _ripple.value),
                                              width: 2),
                                        ),
                                      ),
                                    ),
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 34,
                                          height: 34,
                                          decoration: BoxDecoration(
                                              color: AppColors.vigiLiteCritical,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                  color: Colors.white,
                                                  width: 2.5)),
                                          child: const Center(
                                              child: Text('🚗',
                                                  style:
                                                      TextStyle(fontSize: 16))),
                                        ),
                                        const SizedBox(height: 2),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                              boxShadow: [
                                                BoxShadow(
                                                    color: Colors.black
                                                        .withValues(
                                                            alpha: 0.15),
                                                    blurRadius: 4)
                                              ]),
                                          child: Text(
                                              'STOLEN · ${myAlert.plate}',
                                              style: GoogleFonts.dmMono(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                  color: AppColors
                                                      .vigiLiteCritical)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                          color: AppColors.vigiLiteInfo,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: Colors.white, width: 2)),
                                      child: const Center(
                                          child: Text('📱',
                                              style: TextStyle(fontSize: 14)))),
                                  const SizedBox(height: 2),
                                  const _MapTag('You', Colors.white),
                                ],
                              ),
                      ),
                      // Nodes from state
                      ...nodes.where((n) => !n.viaInternet).take(3).map((n) {
                        Color bg;
                        switch (n.relayStatus) {
                          case RelayStatus.received:
                            bg = AppColors.orange;
                            break;
                          case RelayStatus.relaying:
                            bg = AppColors.yellow;
                            break;
                          case RelayStatus.pending:
                            bg = AppColors.blue;
                        }
                        return Marker(
                          point: _offsetFromMapXY(center, n.mapX, n.mapY),
                          width: 70,
                          height: 55,
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                    color: bg,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 2)),
                                child: const Center(
                                    child: Text('📱',
                                        style: TextStyle(fontSize: 14)))),
                            const SizedBox(height: 2),
                            _MapTag(
                                '${n.name.split(' ')[0]} ${n.name.split(' ').length > 1 ? n.name.split(' ')[1] : ''}',
                                Colors.white),
                          ]),
                        );
                      }),
                    ]),
                    const RichAttributionWidget(attributions: [
                      TextSourceAttribution('OpenStreetMap contributors'),
                    ]),
                  ],
                ),
                // Broadcast radius label
                const Positioned(
                  top: 10,
                  right: 10,
                  child: _MapChip('Broadcast Radius'),
                ),
              ],
            ),
          ),

          // Legend
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppColors.vigiLiteCard,
            child: const Row(
              children: [
                _LegendDot(AppColors.vigiLiteCritical, 'Stolen'),
                SizedBox(width: 14),
                _LegendDot(AppColors.vigiLiteInfo, 'You'),
                SizedBox(width: 14),
                _LegendDot(AppColors.orange, 'Relay'),
                SizedBox(width: 14),
                _LegendDot(AppColors.yellow, 'Relaying'),
              ],
            ),
          ),

          // Bottom list
          Expanded(
            child: Container(
              color: AppColors.vigiLiteBg,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionLabel('ACTIVE ALERTS IN AREA', dark: true),
                    if (alerts.isEmpty)
                      const AppCard(
                          color: AppColors.vigiLiteCard,
                          borderColor: AppColors.vigiLiteBorder,
                          child: Center(
                              child: Text('No active alerts in your area.',
                                  style: TextStyle(
                                      color: AppColors.vigiLiteText3))))
                    else
                      ...alerts.map((a) => GestureDetector(
                          onTap: () => openAlertDetails(context, a),
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppColors.vigiLiteCard,
                              borderRadius: BorderRadius.circular(14),
                              border: const Border(
                                  left: BorderSide(
                                      color: AppColors.vigiLiteCritical,
                                      width: 3)),
                            ),
                            child: Row(
                              children: [
                                const Text('🚗',
                                    style: TextStyle(fontSize: 24)),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text('⚠ ${a.plate} — Nearby',
                                          style: GoogleFonts.dmSans(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color:
                                                  AppColors.vigiLiteCritical)),
                                      Text(
                                          '${a.model} · ${a.color} · Butuan City',
                                          style: GoogleFonts.dmSans(
                                              fontSize: 11,
                                              color: AppColors.vigiLiteText3)),
                                      Text(
                                          '${a.triggerLabel} · ${_fmtTime(a.timestamp)}',
                                          style: GoogleFonts.dmMono(
                                              fontSize: 10,
                                              color: AppColors.vigiLiteText3)),
                                      const SizedBox(height: 4),
                                      // What tapping does — nothing on the card
                                      // used to suggest it was tappable at all.
                                      Text(
                                          a.userId == state.currentUser?.id
                                              ? 'Tap to view sightings'
                                              : 'Tap to report a sighting',
                                          style: GoogleFonts.dmSans(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.vigiLiteInfo)),
                                    ])),
                                const Icon(Icons.chevron_right,
                                    size: 20, color: AppColors.vigiLiteInfo),
                              ],
                            ),
                          ))),
                    const SizedBox(height: 4),
                    const SectionLabel('NEARBY NODES (REAL AD HOC MESH)',
                        dark: true),
                    ...nodes
                        .where((n) => n.isOnline)
                        .map((n) => ProximityNodeRow(node: n)),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const BottomNavBar(current: 1, dark: true),
    );
  }

  String _fmtTime(DateTime t) => DateFormat('hh:mm a').format(t);
}

class _MapTag extends StatelessWidget {
  final String text;
  final Color bg;
  const _MapTag(this.text, this.bg);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(5),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12), blurRadius: 3)
            ]),
        child: Text(text,
            style: GoogleFonts.dmMono(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Colors.black87)),
      );
}

class _MapChip extends StatelessWidget {
  final String text;
  const _MapChip(this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            style: GoogleFonts.dmMono(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: AppColors.text)),
      );
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot(this.color, this.label);

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label,
              style: GoogleFonts.dmSans(
                  fontSize: 12, color: AppColors.vigiLiteText2)),
        ],
      );
}

// ══════════════════════════════════════
// SCREEN 11: ALERT HISTORY
// ══════════════════════════════════════
class AlertHistoryScreen extends StatefulWidget {
  const AlertHistoryScreen({super.key});
  @override
  State<AlertHistoryScreen> createState() => _AlertHistoryScreenState();
}

class _AlertHistoryScreenState extends State<AlertHistoryScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // Every alert this device knows about — including ones relayed in from
    // other users over the ad hoc mesh, not just alerts this account
    // reported itself. It used to be state.myAlerts, so a received "STOLEN
    // vehicle nearby" alert would never show up in the very screen named
    // Alert History, even though it was already stored and notified on.
    final all = state.allAlerts;
    final tabs = ['All', 'Active', 'Recovered', 'Resolved'];
    List<TheftAlert> filtered;
    switch (_tab) {
      case 1:
        filtered = all.where((a) => a.status == AlertStatus.active).toList();
        break;
      case 2:
        filtered = all.where((a) => a.status == AlertStatus.recovered).toList();
        break;
      case 3:
        filtered = all.where((a) => a.status == AlertStatus.resolved).toList();
        break;
      default:
        filtered = all;
    }

    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      appBar: AppBar(
          backgroundColor: AppColors.vigiLiteBg,
          foregroundColor: AppColors.vigiLiteText,
          title: const Text('Alert History')),
      body: Column(
        children: [
          // Tabs
          Container(
            color: AppColors.vigiLiteCard,
            child: Row(
              children: List.generate(
                  tabs.length,
                  (i) => Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _tab = i),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                                border: Border(
                                    bottom: BorderSide(
                                        color: _tab == i
                                            ? AppColors.vigiLiteCyan
                                            : Colors.transparent,
                                        width: 2.5))),
                            child: Text(tabs[i],
                                textAlign: TextAlign.center,
                                style: GoogleFonts.dmSans(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: _tab == i
                                        ? AppColors.vigiLiteCyan
                                        : AppColors.vigiLiteText3)),
                          ),
                        ),
                      )),
            ),
          ),
          // Stats bar
          Container(
            color: AppColors.vigiLiteBg,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                _AhStat(
                    '${all.where((a) => a.status == AlertStatus.active).length}',
                    'Active',
                    AppColors.vigiLiteCritical),
                const SizedBox(width: 10),
                _AhStat(
                    '${all.where((a) => a.status == AlertStatus.recovered).length}',
                    'Recovered',
                    AppColors.vigiLiteSuccess),
                const SizedBox(width: 10),
                _AhStat('${all.length}', 'Total', AppColors.vigiLiteInfo),
              ],
            ),
          ),
          // List
          Expanded(
            child: Container(
              color: AppColors.vigiLiteBg,
              child: filtered.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_circle_outline,
                          size: 48, color: AppColors.vigiLiteSuccess),
                      const SizedBox(height: 10),
                      Text('No alerts in this category.',
                          style: GoogleFonts.dmSans(
                              fontSize: 13, color: AppColors.vigiLiteText3)),
                    ]))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final a = filtered[i];
                        final mine = a.userId == state.currentUser?.id;
                        final sightingCount = state
                            .sightingsForAlert(a.id)
                            .where((s) => s.ownerId == a.userId)
                            .length;
                        return AlertLogItem(
                          alert: a,
                          // Tapping opens the owner's sightings, or — for
                          // someone else's alert — the screen where a nearby
                          // user can report having seen the vehicle. These
                          // cards used to do nothing when tapped.
                          onTap: () => openAlertDetails(context, a),
                          hint: mine
                              ? 'Tap to view sightings ($sightingCount)'
                              : (a.status == AlertStatus.active
                                  ? 'Tap to report a sighting'
                                  : null),
                          // Only the reporter can update their own alert's
                          // status — now that relayed-in alerts from other
                          // users are shown here too, this stops anyone
                          // nearby from "recovering" a vehicle that isn't
                          // theirs.
                          onUpdateStatus:
                              (a.status == AlertStatus.active && mine)
                                  ? () => Navigator.pushNamed(
                                      context, '/update-status',
                                      arguments: a)
                                  : null,
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const BottomNavBar(current: 2, dark: true),
    );
  }
}

class _AhStat extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  const _AhStat(this.value, this.label, this.color);

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: AppColors.vigiLiteCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.vigiLiteBorder)),
          child: Column(children: [
            Text(value,
                style: GoogleFonts.dmMono(
                    fontSize: 22, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: GoogleFonts.dmSans(
                    fontSize: 10, color: AppColors.vigiLiteText3)),
          ]),
        ),
      );
}

// ─── SHARED BOTTOM NAV ───
// Every screen except Home reaches its tabs by replacing the current route
// (it isn't hosting the other tabs itself the way Home's IndexedStack does),
// so that's the one behavior shared here. The actual bar — destinations,
// icons, colors — lives once in AppBottomNav (widgets.dart) and is reused
// by this AND by Home, instead of being hand-copied in both places.
class BottomNavBar extends StatelessWidget {
  final int current;
  // Defaults to false (unchanged everywhere else) — screens migrated to
  // the VIGILINK dark palette pass `dark: true`.
  final bool dark;
  const BottomNavBar({super.key, required this.current, this.dark = false});

  static const _routes = ['/home', '/prox-map', '/alert-history', '/profile'];

  @override
  Widget build(BuildContext context) => AppBottomNav(
        currentIndex: current,
        dark: dark,
        // `pushNamed`, not `pushReplacementNamed` — every tab switch becomes
        // its own back-stack entry (Home used to be the only screen that did
        // this), so the system/hardware back button always retraces the
        // actual sequence of tabs visited (Map → Alerts → Map's back goes to
        // Alerts, not straight to Home) instead of jumping straight back to
        // Home because the tab in between had silently replaced it out of
        // the stack. Re-tapping the tab already showing is a no-op, so
        // mashing the same icon doesn't pile up duplicate stack entries.
        onTap: (i) {
          if (i == current) return;
          Navigator.pushNamed(context, _routes[i]);
        },
      );
}
