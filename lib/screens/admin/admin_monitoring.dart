import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../utils/app_theme.dart';
import '../../utils/geo_defaults.dart';
import '../../services/admin_service.dart';
import '../../models/models.dart';
// `showPhotoViewer` is hidden here — this file uses admin_widgets.dart's own
// copy, kept separate on purpose (the admin web portal stays independent of
// the phone app's widget file; see that file's own doc comment).
import '../../widgets/widgets.dart' hide showPhotoViewer;
import 'admin_widgets.dart';
import '../../utils/time_format.dart';

// ══════════════════════════════════════
// ADMIN MONITORING (FR-11) — the "Live Activity" and "Map" tabs of the web
// Admin Dashboard: real-time alert activity, stolen-vehicle reports, a
// proximity map, and per-incident location history, so an admin can track
// and analyze theft incidents. Web-only like the rest of the admin portal —
// it reads Firestore through AdminService/AdminMonitorFeed and never touches
// AppState, so nothing Android-only is pulled into the web build.
// ══════════════════════════════════════

const _butuanCity = LatLng(kDefaultLat, kDefaultLng);

String _stamp(DateTime t) => DateFormat('d MMM yyyy, h:mm a').format(t);

/// "20:47:03.210" — millisecond precision for the delivery-delay log, where
/// a sub-second difference between sent/received times actually matters.
String _hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';

/// The app never fabricates GPS, so (0, 0) means "no position", not a real
/// spot in the Gulf of Guinea.
bool _located(double lat, double lng) => !(lat == 0 && lng == 0);

Widget _statusBadge(AlertStatus s) => switch (s) {
      AlertStatus.active => StatusBadge.stolen(),
      AlertStatus.recovered => StatusBadge.recovered(),
      AlertStatus.resolved => StatusBadge.resolved(),
    };

Uint8List? _decodePhoto(String b64) {
  try {
    return base64Decode(b64);
  } catch (_) {
    return null;
  }
}

/// Shown above a tab when one of the live feeds couldn't load — usually the
/// Firestore rules not being published yet.
class _FeedErrorBanner extends StatelessWidget {
  final Map<String, String> errors;
  const _FeedErrorBanner({required this.errors});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: AppColors.vigiLiteWarning.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.warning_amber_rounded,
              size: 18, color: AppColors.vigiLiteWarning),
          const SizedBox(width: 8),
          Expanded(
              child: Text(errors.values.join('\n'),
                  style: GoogleFonts.dmSans(
                      fontSize: 12, color: AppColors.vigiLiteWarning))),
        ]),
      );
}

// ══════════════════════════════════════
// LIVE ACTIVITY TAB
// ══════════════════════════════════════
enum _Filter { all, stolen, closed, sightings, deliveries }

class _Event {
  final DateTime time;
  final TheftAlert? alert;
  final SightingReport? sighting;
  final AlertDelivery? delivery;
  _Event.alert(TheftAlert a)
      : time = a.timestamp,
        alert = a,
        sighting = null,
        delivery = null;
  _Event.sighting(SightingReport s)
      : time = s.sentAt,
        alert = null,
        sighting = s,
        delivery = null;
  _Event.delivery(AlertDelivery d)
      : time = d.receivedAt,
        alert = null,
        sighting = null,
        delivery = d;
}

class LiveActivityTab extends StatefulWidget {
  final AdminMonitorFeed feed;
  final String Function(String uid) ownerName;
  const LiveActivityTab(
      {super.key, required this.feed, required this.ownerName});
  @override
  State<LiveActivityTab> createState() => _LiveActivityTabState();
}

class _LiveActivityTabState extends State<LiveActivityTab> {
  _Filter _filter = _Filter.all;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keeps "3 min ago" and "online now" honest between Firestore updates.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _openAlert(String alertId) {
    final match = widget.feed.alerts.where((a) => a.id == alertId);
    if (match.isEmpty) return;
    showAlertDetailSheet(context,
        feed: widget.feed, alert: match.first, ownerName: widget.ownerName);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.feed,
      builder: (context, _) {
        final f = widget.feed;
        final stolen =
            f.alerts.where((a) => a.status == AlertStatus.active).length;
        final closed = f.alerts.length - stolen;
        final online = f.devices.where((d) => d.onlineNow).length;

        final sightingCounts = <String, int>{};
        for (final s in f.sightings) {
          sightingCounts[s.alertId] = (sightingCounts[s.alertId] ?? 0) + 1;
        }
        // Real end-to-end delay average, across every recorded delivery —
        // see AppState._logAlertDelivery for how each one is measured.
        final avgDelayMs = f.deliveries.isEmpty
            ? null
            : f.deliveries.fold<int>(0, (total, d) => total + d.delayMs) /
                f.deliveries.length;
        final events = <_Event>[
          if (_filter != _Filter.sightings && _filter != _Filter.deliveries)
            for (final a in f.alerts)
              if (_filter == _Filter.all ||
                  (_filter == _Filter.stolen &&
                      a.status == AlertStatus.active) ||
                  (_filter == _Filter.closed && a.status != AlertStatus.active))
                _Event.alert(a),
          if (_filter == _Filter.all || _filter == _Filter.sightings)
            for (final s in f.sightings) _Event.sighting(s),
          if (_filter == _Filter.deliveries)
            for (final d in f.deliveries) _Event.delivery(d),
        ]..sort((a, b) => b.time.compareTo(a.time));

        return Column(children: [
          if (f.errors.isNotEmpty) _FeedErrorBanner(errors: f.errors),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(children: [
              Expanded(
                  child: AdminStatChip(
                      label: 'ACTIVE ALERTS',
                      value: '$stolen',
                      color: AppColors.vigiLiteCritical)),
              const SizedBox(width: 8),
              Expanded(
                  child: AdminStatChip(
                      label: 'RECOVERED / RESOLVED',
                      value: '$closed',
                      color: AppColors.vigiLiteSuccess)),
              const SizedBox(width: 8),
              Expanded(
                  child: AdminStatChip(
                      label: 'SIGHTINGS',
                      value: '${f.sightings.length}',
                      color: AppColors.vigiLiteWarning)),
              const SizedBox(width: 8),
              Expanded(
                  child: AdminStatChip(
                      label: 'DEVICES ONLINE',
                      value: '$online',
                      color: AppColors.vigiLiteInfo)),
              const SizedBox(width: 8),
              Expanded(
                  child: AdminStatChip(
                      label: 'AVG DELIVERY DELAY',
                      value: avgDelayMs == null
                          ? '—'
                          : '${(avgDelayMs / 1000).toStringAsFixed(2)}s',
                      color: AppColors.vigiLiteInfo,
                      selected: _filter == _Filter.deliveries,
                      onTap: () =>
                          setState(() => _filter = _Filter.deliveries))),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final e in const {
                      _Filter.all: 'All activity',
                      _Filter.stolen: 'Stolen',
                      _Filter.closed: 'Recovered / resolved',
                      _Filter.sightings: 'Sightings',
                      _Filter.deliveries: 'Delivery log',
                    }.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(e.value),
                          selected: _filter == e.key,
                          onSelected: (_) => setState(() => _filter = e.key),
                          backgroundColor: AppColors.vigiLiteInput,
                          selectedColor: AppColors.vigiLiteCyan,
                          side: BorderSide(
                              color: _filter == e.key
                                  ? AppColors.vigiLiteCyan
                                  : AppColors.vigiLiteBorder),
                          labelStyle: GoogleFonts.dmSans(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: _filter == e.key
                                  ? AppColors.vigiLiteText
                                  : AppColors.vigiLiteText2),
                        ),
                      ),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.circle,
                  size: 9, color: AppColors.vigiLiteSuccess),
              const SizedBox(width: 4),
              Text(
                  f.lastUpdate == null
                      ? 'LIVE'
                      : 'LIVE · ${DateFormat('h:mm:ss a').format(f.lastUpdate!)}',
                  style: GoogleFonts.dmMono(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteSuccess)),
            ]),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: !f.alertsReady
                ? const Center(
                    child: CircularProgressIndicator(
                        color: AppColors.vigiLiteCyan))
                : events.isEmpty
                    ? Center(
                        child: Text('No activity to show yet.',
                            style: GoogleFonts.dmSans(
                                fontSize: 13, color: AppColors.vigiLiteText3)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: events.length,
                        itemBuilder: (_, i) {
                          final e = events[i];
                          final a = e.alert;
                          final d = e.delivery;
                          if (a != null) {
                            return _AlertEventTile(
                                alert: a,
                                owner: widget.ownerName(a.userId),
                                sightingCount: sightingCounts[a.id] ?? 0,
                                onTap: () => _openAlert(a.id));
                          }
                          if (d != null) {
                            return _DeliveryEventTile(
                                delivery: d,
                                onTap: () => _openAlert(d.alertId));
                          }
                          return _SightingEventTile(
                              sighting: e.sighting!,
                              plate: _plateFor(e.sighting!.alertId),
                              onTap: () => _openAlert(e.sighting!.alertId));
                        },
                      ),
          ),
        ]);
      },
    );
  }

  String _plateFor(String alertId) {
    for (final a in widget.feed.alerts) {
      if (a.id == alertId) return a.plate;
    }
    return 'a vehicle';
  }
}

class _AlertEventTile extends StatelessWidget {
  final TheftAlert alert;
  final String owner;
  final int sightingCount;
  final VoidCallback onTap;
  const _AlertEventTile(
      {required this.alert,
      required this.owner,
      required this.sightingCount,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final a = alert;
    final active = a.status == AlertStatus.active;
    return TapScale(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.vigiLiteCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: active
                  ? AppColors.vigiLiteCritical.withValues(alpha: 0.35)
                  : AppColors.vigiLiteBorder,
              width: 0.8),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: (active
                        ? AppColors.vigiLiteCritical
                        : AppColors.vigiLiteSuccess)
                    .withValues(alpha: 0.18),
                shape: BoxShape.circle),
            child: Icon(Icons.directions_car,
                size: 20,
                color: active
                    ? AppColors.vigiLiteCritical
                    : AppColors.vigiLiteSuccess),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(a.plate,
                        style: GoogleFonts.dmMono(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.vigiLiteText)),
                    _statusBadge(a.status),
                  ]),
              const SizedBox(height: 3),
              Text('${a.model} · ${a.color} · owner: $owner',
                  style: GoogleFonts.dmSans(
                      fontSize: 12, color: AppColors.vigiLiteText3)),
              const SizedBox(height: 3),
              Text(
                  '${a.triggerLabel} · ${timeAgo(a.timestamp)} (${_stamp(a.timestamp)})',
                  style: GoogleFonts.dmSans(
                      fontSize: 11.5, color: AppColors.vigiLiteText3)),
              const SizedBox(height: 6),
              Wrap(spacing: 12, runSpacing: 2, children: [
                _meta(Icons.alt_route, '${a.hopCount} hop(s)'),
                _meta(Icons.share_outlined, 'relayed to ${a.relayedTo.length}'),
                _meta(
                    Icons.visibility_outlined,
                    sightingCount == 0
                        ? 'no sightings'
                        : '$sightingCount sighting(s)'),
                // Same "📷 photo" at-a-glance signal _SightingEventTile
                // already shows — previously only the alert's OWN detail
                // sheet (opened by tapping this tile) showed whether a
                // photo was attached.
                if (a.hasPhoto) _meta(Icons.photo_outlined, 'photo'),
              ]),
            ]),
          ),
          const Icon(Icons.chevron_right, color: AppColors.vigiLiteText3),
        ]),
      ),
    );
  }

  Widget _meta(IconData icon, String text) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: AppColors.vigiLiteText3),
        const SizedBox(width: 4),
        Text(text,
            style: GoogleFonts.dmSans(
                fontSize: 11, color: AppColors.vigiLiteText3)),
      ]);
}

class _SightingEventTile extends StatelessWidget {
  final SightingReport sighting;
  final String plate;
  final VoidCallback onTap;
  const _SightingEventTile(
      {required this.sighting, required this.plate, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = sighting;
    return TapScale(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.vigiLiteWarning.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.vigiLiteWarning.withValues(alpha: 0.35)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: AppColors.vigiLiteWarning.withValues(alpha: 0.18),
                shape: BoxShape.circle),
            child: const Icon(Icons.visibility,
                size: 20, color: AppColors.vigiLiteWarning),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s.reporterName} reported a sighting of $plate',
                  style: GoogleFonts.dmSans(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteText)),
              const SizedBox(height: 3),
              Text(s.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.dmSans(
                      fontSize: 12.5,
                      height: 1.4,
                      color: AppColors.vigiLiteText2)),
              const SizedBox(height: 4),
              Text(
                  '${timeAgo(s.sentAt)} · seen ${_stamp(s.seenAt)}'
                  '${s.hasPhoto ? ' · 📷 photo' : ''}'
                  '${s.hasLocation ? ' · 📍 location' : ''}',
                  style: GoogleFonts.dmSans(
                      fontSize: 11, color: AppColors.vigiLiteText3)),
            ]),
          ),
          const Icon(Icons.chevron_right, color: AppColors.vigiLiteText3),
        ]),
      ),
    );
  }
}

/// One row of the "Delivery log" filter — the real end-to-end delay
/// measurement for a single device's receipt of an alert (see
/// AppState._logAlertDelivery). Matches the log line format requested:
/// "ALERT {plate} · sent HH:mm:ss.SSS · received HH:mm:ss.SSS · delay Ns ·
/// via {mesh|internet} · hop N".
class _DeliveryEventTile extends StatelessWidget {
  final AlertDelivery delivery;
  final VoidCallback onTap;
  const _DeliveryEventTile({required this.delivery, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = delivery;
    final delaySec = (d.delayMs / 1000).toStringAsFixed(2);
    return TapScale(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.vigiLiteCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.vigiLiteBorder, width: 0.8),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: AppColors.vigiLiteInfo.withValues(alpha: 0.18),
                shape: BoxShape.circle),
            child: const Icon(Icons.timer_outlined,
                size: 20, color: AppColors.vigiLiteInfo),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d.plate} · delay ${delaySec}s',
                  style: GoogleFonts.dmMono(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteText)),
              const SizedBox(height: 3),
              Text('via ${d.via} · hop ${d.hopCount}',
                  style: GoogleFonts.dmSans(
                      fontSize: 12, color: AppColors.vigiLiteText3)),
              const SizedBox(height: 3),
              Text('sent ${_hms(d.sentAt)} · received ${_hms(d.receivedAt)}',
                  style: GoogleFonts.dmMono(
                      fontSize: 11, color: AppColors.vigiLiteText3)),
            ]),
          ),
          const Icon(Icons.chevron_right, color: AppColors.vigiLiteText3),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════
// INCIDENT DETAIL — opened from a Live Activity tile or a map marker
// ══════════════════════════════════════
Future<void> showAlertDetailSheet(BuildContext context,
    {required AdminMonitorFeed feed,
    required TheftAlert alert,
    required String Function(String uid) ownerName}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.vigiLiteCard,
    constraints: const BoxConstraints(maxWidth: 780),
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.92,
      child: _AlertDetailSheet(feed: feed, alert: alert, ownerName: ownerName),
    ),
  );
}

class _AlertDetailSheet extends StatefulWidget {
  final AdminMonitorFeed feed;
  final TheftAlert alert;
  final String Function(String uid) ownerName;
  const _AlertDetailSheet(
      {required this.feed, required this.alert, required this.ownerName});
  @override
  State<_AlertDetailSheet> createState() => _AlertDetailSheetState();
}

class _AlertDetailSheetState extends State<_AlertDetailSheet> {
  static const _historyShown = 30;
  List<LocationRecord>? _history;
  String? _historyError;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final h = await AdminService.instance
          .fetchLocationHistory(widget.alert.vehicleId);
      if (!mounted) return;
      setState(() => _history = h);
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() => _historyError = e.code == 'permission-denied'
          ? "Firestore's rules don't let the admin list location history yet — publish the latest rules from Progress.md."
          : 'Could not load location history (${e.code}).');
    } catch (_) {
      if (!mounted) return;
      setState(() => _historyError =
          'Could not load location history. Check your connection.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.feed,
      builder: (context, _) {
        // Re-read the alert each time so a status change made on the owner's
        // phone shows up here live, without closing the sheet.
        final a = widget.feed.alerts.firstWhere((x) => x.id == widget.alert.id,
            orElse: () => widget.alert);
        final sightings =
            widget.feed.sightings.where((s) => s.alertId == a.id).toList();
        final trail = [
          for (final r in (_history ?? const <LocationRecord>[]).reversed)
            LatLng(r.lat, r.lng)
        ];
        final points = <LatLng>[
          if (_located(a.lat, a.lng)) LatLng(a.lat, a.lng),
          for (final s in sightings)
            if (s.hasLocation) LatLng(s.lat!, s.lng!),
          ...trail,
        ];

        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          children: [
            Center(
                child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: AppColors.vigiLiteBorder,
                        borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: Text(a.plate,
                      style: GoogleFonts.dmMono(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: AppColors.vigiLiteText))),
              _statusBadge(a.status),
            ]),
            const SizedBox(height: 12),
            _info('Vehicle', '${a.model} · ${a.color}'),
            // Recommended by the Highway Patrol Group (HPG) — these two tell
            // a single car apart from every other one sharing its plate,
            // make, or color. Blank for an alert reported before these
            // fields existed, so they're only shown when there's a value.
            if (a.engineNumber.isNotEmpty) _info('Engine No.', a.engineNumber),
            if (a.chassisNumber.isNotEmpty)
              _info('Chassis No.', a.chassisNumber),
            _info('Owner', widget.ownerName(a.userId)),
            _info('Trigger', a.triggerLabel),
            _info(
                'Reported', '${_stamp(a.timestamp)} (${timeAgo(a.timestamp)})'),
            _info(
                'Last known',
                _located(a.lat, a.lng)
                    ? '${a.lat.toStringAsFixed(5)}, ${a.lng.toStringAsFixed(5)}'
                    : 'No location'),
            _info('Relay',
                '${a.hopCount} hop(s) · relayed to ${a.relayedTo.length} device(s)'),
            if (a.notes.trim().isNotEmpty) _info('Notes', a.notes.trim()),
            if (a.hasPhoto) ...[
              const SizedBox(height: 10),
              PhotoEvidenceRow(
                photos:
                    a.photos.map(_decodePhoto).whereType<Uint8List>().toList(),
                height: 200,
              ),
            ],
            // Proof the owner attached when they marked this recovered —
            // only ever present once status has moved past active.
            if (a.status != AlertStatus.active &&
                (a.recoveryRemarks.trim().isNotEmpty ||
                    a.hasRecoveryPhoto)) ...[
              const SizedBox(height: 14),
              const SectionLabel('RECOVERY EVIDENCE', dark: true),
              if (a.recoveryRemarks.trim().isNotEmpty)
                _info('Remarks', a.recoveryRemarks.trim()),
              if (a.hasRecoveryPhoto) ...[
                const SizedBox(height: 10),
                PhotoEvidenceRow(
                  photos: a.recoveryPhotos
                      .map(_decodePhoto)
                      .whereType<Uint8List>()
                      .toList(),
                  height: 200,
                ),
              ],
            ],
            const SizedBox(height: 8),
            if (points.isNotEmpty) ...[
              Container(
                height: 260,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.vigiLiteBorder)),
                child: FlutterMap(
                  key: ValueKey(points.length),
                  options: MapOptions(
                    initialCenter: points.first,
                    initialZoom: 15,
                    initialCameraFit: points.length > 1
                        ? CameraFit.coordinates(
                            coordinates: points,
                            padding: const EdgeInsets.all(40),
                            maxZoom: 17)
                        : null,
                    interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'ph.edu.carsu.vehicleguard',
                    ),
                    if (trail.length > 1)
                      PolylineLayer(polylines: [
                        Polyline(
                            points: trail,
                            strokeWidth: 3,
                            color:
                                AppColors.vigiLiteCyan.withValues(alpha: 0.7)),
                      ]),
                    MarkerLayer(markers: [
                      if (_located(a.lat, a.lng))
                        Marker(
                            point: LatLng(a.lat, a.lng),
                            width: 44,
                            height: 44,
                            child: const Text('🚗',
                                style: TextStyle(fontSize: 28))),
                      for (final s in sightings)
                        if (s.hasLocation)
                          Marker(
                              point: LatLng(s.lat!, s.lng!),
                              width: 44,
                              height: 44,
                              child: const Text('📍',
                                  style: TextStyle(fontSize: 28))),
                    ]),
                    const RichAttributionWidget(attributions: [
                      TextSourceAttribution('OpenStreetMap contributors'),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                  '🚗 reported stolen here   📍 where it was seen   ━ recorded movement',
                  style: GoogleFonts.dmSans(
                      fontSize: 11, color: AppColors.vigiLiteText3)),
            ],
            const SizedBox(height: 18),
            SectionLabel('SIGHTINGS (${sightings.length})', dark: true),
            if (sightings.isEmpty)
              Text('Nobody has reported seeing this vehicle yet.',
                  style: GoogleFonts.dmSans(
                      fontSize: 12.5, color: AppColors.vigiLiteText3))
            else
              ...sightings.map((s) => _AdminSightingCard(sighting: s)),
            const SizedBox(height: 14),
            const SectionLabel('LOCATION HISTORY', dark: true),
            _historySection(),
          ],
        );
      },
    );
  }

  Widget _historySection() {
    if (_historyError != null) {
      return Text(_historyError!,
          style: GoogleFonts.dmSans(
              fontSize: 12.5, color: AppColors.vigiLiteCritical));
    }
    final h = _history;
    if (h == null) {
      return const Padding(
          padding: EdgeInsets.all(12),
          child: Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.vigiLiteCyan))));
    }
    if (h.isEmpty) {
      return Text(
          'No recorded positions for this vehicle. Positions are logged while its geofence is on and synced when the phone is online.',
          style: GoogleFonts.dmSans(
              fontSize: 12.5, color: AppColors.vigiLiteText3));
    }
    final shown = h.take(_historyShown).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
          '${h.length} record(s)${h.length > _historyShown ? ' — latest $_historyShown shown' : ''}',
          style: GoogleFonts.dmSans(
              fontSize: 11.5, color: AppColors.vigiLiteText3)),
      const SizedBox(height: 6),
      for (final r in shown)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            SizedBox(
                width: 170,
                child: Text(DateFormat('d MMM, h:mm:ss a').format(r.time),
                    style: GoogleFonts.dmMono(
                        fontSize: 11, color: AppColors.vigiLiteText3))),
            Text('${r.lat.toStringAsFixed(5)}, ${r.lng.toStringAsFixed(5)}',
                style: GoogleFonts.dmMono(
                    fontSize: 11, color: AppColors.vigiLiteText2)),
          ]),
        ),
    ]);
  }

  Widget _info(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 92,
              child: Text(label,
                  style: GoogleFonts.dmMono(
                      fontSize: 11,
                      color: AppColors.vigiLiteText3,
                      fontWeight: FontWeight.w700))),
          Expanded(
              child: Text(value,
                  style: GoogleFonts.dmSans(
                      fontSize: 12.5, color: AppColors.vigiLiteText))),
        ]),
      );
}

class _AdminSightingCard extends StatelessWidget {
  final SightingReport sighting;
  const _AdminSightingCard({required this.sighting});

  @override
  Widget build(BuildContext context) {
    final s = sighting;
    final photo = s.hasPhoto ? _decodePhoto(s.photoB64!) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.vigiLiteCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.vigiLiteBorder, width: 0.8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(s.reporterName,
                  style: GoogleFonts.dmSans(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteText))),
          Text(timeAgo(s.sentAt),
              style: GoogleFonts.dmSans(
                  fontSize: 11, color: AppColors.vigiLiteText3)),
        ]),
        Text('Seen ${_stamp(s.seenAt)}',
            style: GoogleFonts.dmMono(
                fontSize: 10.5, color: AppColors.vigiLiteText3)),
        const SizedBox(height: 8),
        Text(s.message,
            style: GoogleFonts.dmSans(
                fontSize: 13, height: 1.45, color: AppColors.vigiLiteText2)),
        if (photo != null) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => showPhotoViewer(context, photo),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(photo,
                  width: double.infinity,
                  height: 200,
                  fit: BoxFit.cover,
                  gaplessPlayback: true),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Row(children: [
          Icon(s.hasLocation ? Icons.place : Icons.location_off_outlined,
              size: 15,
              color: s.hasLocation
                  ? AppColors.vigiLiteCyan
                  : AppColors.vigiLiteText3),
          const SizedBox(width: 6),
          Text(
              s.hasLocation
                  ? '${s.lat!.toStringAsFixed(5)}, ${s.lng!.toStringAsFixed(5)}'
                  : 'No location shared',
              style: GoogleFonts.dmMono(
                  fontSize: 11, color: AppColors.vigiLiteText3)),
        ]),
      ]),
    );
  }
}

// ══════════════════════════════════════
// MAP TAB — every located alert, sighting and online phone at once
// ══════════════════════════════════════
class MonitorMapTab extends StatefulWidget {
  final AdminMonitorFeed feed;
  final String Function(String uid) ownerName;
  const MonitorMapTab({super.key, required this.feed, required this.ownerName});
  @override
  State<MonitorMapTab> createState() => _MonitorMapTabState();
}

class _MonitorMapTabState extends State<MonitorMapTab> {
  final _map = MapController();
  bool _showAlerts = true;
  bool _showSightings = true;
  bool _showDevices = true;
  bool _fitted = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Devices drop off the map when their last position goes stale.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _map.dispose();
    super.dispose();
  }

  void _fit(List<LatLng> pts) {
    if (pts.isEmpty) return;
    _map.fitCamera(CameraFit.coordinates(
        coordinates: pts, padding: const EdgeInsets.all(80), maxZoom: 16));
  }

  void _openAlert(String alertId) {
    final match = widget.feed.alerts.where((a) => a.id == alertId);
    if (match.isEmpty) return;
    showAlertDetailSheet(context,
        feed: widget.feed, alert: match.first, ownerName: widget.ownerName);
  }

  Widget _pin(IconData icon, Color color, double size, VoidCallback? onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 4)
              ]),
          child: Icon(icon, color: Colors.white, size: size * 0.55),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.feed,
      builder: (context, _) {
        final f = widget.feed;
        final alerts = f.alerts.where((a) => _located(a.lat, a.lng)).toList();
        final sightings = f.sightings.where((s) => s.hasLocation).toList();
        final devices = f.devices.where((d) => d.onlineNow).toList();
        final active = alerts.where((a) => a.status == AlertStatus.active);

        final allPoints = [
          for (final a in alerts) LatLng(a.lat, a.lng),
          for (final s in sightings) LatLng(s.lat!, s.lng!),
        ];
        if (!_fitted && allPoints.isNotEmpty) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fit(allPoints);
          });
        }

        return Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter:
                  allPoints.isNotEmpty ? allPoints.first : _butuanCity,
              initialZoom: 13,
              interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'ph.edu.carsu.vehicleguard',
              ),
              // The 100 m proximity range the manuscript uses for alerts
              // (FR-07) around every vehicle that is still missing.
              if (_showAlerts)
                CircleLayer(circles: [
                  for (final a in active)
                    CircleMarker(
                        point: LatLng(a.lat, a.lng),
                        radius: 100,
                        useRadiusInMeter: true,
                        color:
                            AppColors.vigiLiteCritical.withValues(alpha: 0.10),
                        borderColor:
                            AppColors.vigiLiteCritical.withValues(alpha: 0.5),
                        borderStrokeWidth: 1),
                ]),
              MarkerLayer(markers: [
                if (_showDevices)
                  for (final d in devices)
                    Marker(
                        point: LatLng(d.lat, d.lng),
                        width: 26,
                        height: 26,
                        child: Tooltip(
                            message:
                                '${d.name} · ${d.deviceId}\nseen ${timeAgo(d.updatedAt)}',
                            child: _pin(Icons.smartphone,
                                AppColors.vigiLiteInfo, 26, null))),
                if (_showSightings)
                  for (final s in sightings)
                    Marker(
                        point: LatLng(s.lat!, s.lng!),
                        width: 34,
                        height: 34,
                        child: Tooltip(
                            message:
                                'Sighting by ${s.reporterName}\n${_stamp(s.seenAt)}',
                            child: _pin(
                                Icons.visibility,
                                AppColors.vigiLiteWarning,
                                34,
                                () => _openAlert(s.alertId)))),
                if (_showAlerts)
                  for (final a in alerts)
                    Marker(
                        point: LatLng(a.lat, a.lng),
                        width: 42,
                        height: 42,
                        child: Tooltip(
                            message:
                                '${a.plate} · ${a.statusLabel}\n${timeAgo(a.timestamp)}',
                            child: _pin(
                                Icons.directions_car,
                                a.status == AlertStatus.active
                                    ? AppColors.vigiLiteCritical
                                    : AppColors.vigiLiteSuccess,
                                42,
                                () => _openAlert(a.id)))),
              ]),
              const RichAttributionWidget(attributions: [
                TextSourceAttribution('OpenStreetMap contributors'),
              ]),
            ],
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (f.errors.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: AppColors.amberLight,
                      borderRadius: BorderRadius.circular(10)),
                  child: Text(f.errors.values.join('\n'),
                      style: GoogleFonts.dmSans(
                          fontSize: 12, color: adminAmberText)),
                ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.vigiLiteBorder)),
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  FilterChip(
                    avatar: const Icon(Icons.directions_car,
                        size: 16, color: AppColors.vigiLiteCritical),
                    label: Text('Alerts (${alerts.length}) · Broadcast Radius'),
                    selected: _showAlerts,
                    onSelected: (v) => setState(() => _showAlerts = v),
                  ),
                  FilterChip(
                    avatar: const Icon(Icons.visibility,
                        size: 16, color: AppColors.vigiLiteWarning),
                    label: Text('Sightings (${sightings.length})'),
                    selected: _showSightings,
                    onSelected: (v) => setState(() => _showSightings = v),
                  ),
                  FilterChip(
                    avatar: const Icon(Icons.smartphone,
                        size: 16, color: AppColors.vigiLiteInfo),
                    label: Text('Devices online (${devices.length})'),
                    selected: _showDevices,
                    onSelected: (v) => setState(() => _showDevices = v),
                  ),
                ]),
              ),
            ]),
          ),
          Positioned(
            right: 12,
            bottom: 28,
            child: FloatingActionButton.small(
              heroTag: 'fit-map',
              backgroundColor: Colors.white,
              tooltip: 'Fit all alerts and sightings',
              onPressed: () => _fit(allPoints),
              child: const Icon(Icons.center_focus_strong,
                  color: AppColors.vigiLiteCyan),
            ),
          ),
          if (!f.alertsReady)
            const Center(
                child: CircularProgressIndicator(color: AppColors.vigiLiteCyan))
          else if (allPoints.isEmpty)
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(12)),
                child: Text('No located alerts or sightings yet.',
                    style: GoogleFonts.dmSans(
                        fontSize: 13, color: AppColors.vigiLiteText3)),
              ),
            ),
        ]);
      },
    );
  }
}
