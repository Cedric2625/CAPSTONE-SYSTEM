import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../utils/app_theme.dart';
import '../../services/admin_service.dart';
import '../../models/models.dart';
// `showPhotoViewer` is hidden here — this file uses admin_widgets.dart's own
// copy, kept separate on purpose (the admin web portal stays independent of
// the phone app's widget file; see that file's own doc comment).
import '../../widgets/widgets.dart' hide showPhotoViewer;
import 'admin_widgets.dart';

// ══════════════════════════════════════
// ADMIN — VEHICLES TAB
// ══════════════════════════════════════
// Every registered vehicle with its registration details (plate, make/model,
// color, type, device, geofence), who owns it, whether its status is stolen,
// and whether its OR / CR photos are on file — a table on a wide window, cards
// on a narrow one. Tapping a row opens the full registration record with the
// OR and CR photos. Web-only and independent of AppState, like the rest of
// the admin portal.

enum _VehicleFilter { all, stolen, active, documentsMissing }

Widget _docsBadge(bool? onFile) => onFile == null
    ? const StatusBadge(
        label: 'OR/CR ?', bg: AppColors.grayLight, fg: AppColors.gray)
    : onFile
        ? const StatusBadge(
            label: 'OR/CR ✓', bg: AppColors.greenLight, fg: adminGreenText)
        : const StatusBadge(
            label: 'NO OR/CR', bg: AppColors.amberLight, fg: adminAmberText);

Widget _vehicleStatusBadge(VehicleStatus s) => switch (s) {
      VehicleStatus.stolen => StatusBadge.stolen(),
      VehicleStatus.recovered => StatusBadge.recovered(),
      VehicleStatus.active => StatusBadge.active(),
    };

String _geofenceLabel(VehicleModel v) =>
    v.geofenceActive ? 'On · ${v.geofenceRadius.round()} m' : 'Off';

/// One row of the Vehicles tab: either a real registered vehicle, or an
/// account that hasn't registered one yet ([vehicleRow] null — rendered as
/// "Not Yet Registered"). [number] is that account's OWN registration
/// number from the Accounts tab (see [registrationNumbers]) — the same
/// account can appear more than once here (one row per vehicle it owns),
/// each showing that same number, so a reader can tell at a glance which
/// vehicles belong to which numbered account without cross-referencing.
class _VehicleEntry {
  final int number;
  final UserModel owner;
  final bool ownerDisabled;
  final AdminVehicleRow? vehicleRow;
  const _VehicleEntry({
    required this.number,
    required this.owner,
    required this.ownerDisabled,
    this.vehicleRow,
  });
}

class VehiclesTab extends StatefulWidget {
  /// The accounts the dashboard already loaded — vehicles are read per owner.
  final List<AdminUserRow> users;
  final bool usersLoading;
  const VehiclesTab(
      {super.key, required this.users, required this.usersLoading});

  @override
  State<VehiclesTab> createState() => _VehiclesTabState();
}

class _VehiclesTabState extends State<VehiclesTab> {
  List<AdminVehicleRow>? _rows;
  String? _error;
  String _query = '';
  _VehicleFilter _filter = _VehicleFilter.all;

  @override
  void initState() {
    super.initState();
    if (!widget.usersLoading) _load();
  }

  // The dashboard's Refresh button reloads the accounts; a new list here means
  // the vehicles should be re-read too.
  @override
  void didUpdateWidget(VehiclesTab old) {
    super.didUpdateWidget(old);
    if (!identical(old.users, widget.users) && !widget.usersLoading) _load();
  }

  Future<void> _load() async {
    setState(() {
      _rows = null;
      _error = null;
    });
    try {
      final rows = await AdminService.instance.fetchAllVehicles(widget.users);
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error =
          'Could not load the registered vehicles. Check your internet connection and the Firestore rules, then try again.');
    }
  }

  /// One entry per account, in the SAME registration order/numbering as the
  /// Accounts tab — an account with no vehicle gets exactly one entry (a
  /// placeholder, rendered as "Not Yet Registered"); an account with one or
  /// more gets one entry per vehicle, each carrying that account's number.
  List<_VehicleEntry> get _entries {
    final rows = _rows;
    if (rows == null) return const [];
    final numbers = registrationNumbers(widget.users);
    final byOwner = <String, List<AdminVehicleRow>>{};
    for (final r in rows) {
      byOwner.putIfAbsent(r.owner.id, () => []).add(r);
    }
    final sortedUsers = List<AdminUserRow>.from(widget.users)
      ..sort(byRegistrationOrder);
    final entries = <_VehicleEntry>[];
    for (final u in sortedUsers) {
      final number = numbers[u.user.id] ?? 0;
      final owned = byOwner[u.user.id];
      if (owned == null || owned.isEmpty) {
        entries.add(_VehicleEntry(
            number: number, owner: u.user, ownerDisabled: u.disabled));
      } else {
        for (final r in owned) {
          entries.add(_VehicleEntry(
              number: number,
              owner: u.user,
              ownerDisabled: u.disabled,
              vehicleRow: r));
        }
      }
    }
    return entries;
  }

  List<_VehicleEntry> get _filtered {
    final q = _query.trim().toLowerCase();
    return _entries.where((e) {
      final r = e.vehicleRow;
      final matchesQuery = q.isEmpty ||
          e.owner.name.toLowerCase().contains(q) ||
          e.owner.email.toLowerCase().contains(q) ||
          (r != null &&
              (r.vehicle.plate.toLowerCase().contains(q) ||
                  r.vehicle.model.toLowerCase().contains(q) ||
                  r.vehicle.color.toLowerCase().contains(q) ||
                  r.vehicle.deviceId.toLowerCase().contains(q)));
      // A "Not Yet Registered" placeholder has no vehicle status/documents
      // to match, so it only ever shows under "All" — never under a filter
      // that's specifically about a vehicle's own state.
      final matchesFilter = switch (_filter) {
        _VehicleFilter.all => true,
        _VehicleFilter.stolen => r?.vehicle.status == VehicleStatus.stolen,
        _VehicleFilter.active => r?.vehicle.status == VehicleStatus.active,
        _VehicleFilter.documentsMissing => r?.documentsOnFile == false,
      };
      return matchesQuery && matchesFilter;
    }).toList();
  }

  /// Total/Not Stolen/Stolen have an exact matching filter chip and double
  /// as that chip — tapping one applies the filter, and it fills solidly
  /// while that filter is the one currently applied. Recovered, OR/CR On
  /// File and Geofence On have no exact matching filter (OR/CR On File is
  /// the inverse of the "OR/CR missing" filter, not the same thing) and
  /// stay plain, informational tiles.
  List<AdminStatChip> _chips(List<AdminVehicleRow> rows) {
    int count(bool Function(AdminVehicleRow) test) => rows.where(test).length;
    final stolen = count((r) => r.vehicle.status == VehicleStatus.stolen);
    final withDocs = count((r) => r.documentsOnFile == true);
    return [
      AdminStatChip(
          label: 'TOTAL VEHICLES',
          value: '${rows.length}',
          color: AppColors.vigiLiteInfo,
          selected: _filter == _VehicleFilter.all,
          onTap: () => setState(() => _filter = _VehicleFilter.all)),
      AdminStatChip(
          label: 'NOT STOLEN',
          value: '${count((r) => r.vehicle.status == VehicleStatus.active)}',
          color: AppColors.vigiLiteSuccess,
          selected: _filter == _VehicleFilter.active,
          onTap: () => setState(() => _filter = _VehicleFilter.active)),
      AdminStatChip(
          label: 'STOLEN',
          value: '$stolen',
          color: stolen > 0
              ? AppColors.vigiLiteCritical
              : AppColors.vigiLiteSuccess,
          selected: _filter == _VehicleFilter.stolen,
          onTap: () => setState(() => _filter = _VehicleFilter.stolen)),
      AdminStatChip(
          label: 'RECOVERED',
          value: '${count((r) => r.vehicle.status == VehicleStatus.recovered)}',
          color: AppColors.vigiLiteInfo),
      AdminStatChip(
          label: 'OR/CR ON FILE',
          value: '$withDocs / ${rows.length}',
          color: withDocs == rows.length
              ? AppColors.vigiLiteSuccess
              : AppColors.vigiLiteWarning),
      AdminStatChip(
          label: 'GEOFENCE ON',
          value: '${count((r) => r.vehicle.geofenceActive)}',
          color: AppColors.vigiLiteInfo),
    ];
  }

  void _openEntry(_VehicleEntry entry) {
    final row = entry.vehicleRow;
    if (row == null) return; // nothing to show for "Not Yet Registered"
    _open(row);
  }

  void _open(AdminVehicleRow row) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.vigiLiteCard,
      constraints: const BoxConstraints(maxWidth: 760),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.92,
        child: _VehicleDetailSheet(row: row),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = adminLoadingOrError(
        loading: widget.usersLoading || (_rows == null && _error == null),
        error: _error,
        onRetry: _load);
    if (asyncState != null) return asyncState;

    final all = _rows!;
    final rows = _filtered;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 900;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child:
                  AdminSummaryGrid(chips: _chips(all), width: c.maxWidth - 32),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: AdminToolbar<_VehicleFilter>(
                hint: 'Search plate, model, color, owner or device ID',
                noun: 'vehicle',
                filter: _filter,
                filters: const {
                  _VehicleFilter.all: 'All',
                  _VehicleFilter.stolen: 'Stolen',
                  _VehicleFilter.active: 'Not stolen',
                  _VehicleFilter.documentsMissing: 'OR/CR missing',
                },
                onQuery: (v) => setState(() => _query = v),
                onFilter: (f) => setState(() => _filter = f),
                shown: rows.length,
                total: all.length,
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                          widget.users.isEmpty
                              ? 'No registered accounts yet.'
                              : 'No matching vehicles.',
                          style: GoogleFonts.dmSans(
                              fontSize: 13, color: AppColors.vigiLiteText3)))
                  : (wide
                      ? ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                          children: [
                            AdminTableFrame(
                              header: const _TableHeader(),
                              rows: [
                                for (final entry in rows)
                                  AdminHoverRow(
                                    onTap: entry.vehicleRow == null
                                        ? null
                                        : () => _openEntry(entry),
                                    child: _VehicleRowContent(entry: entry),
                                  ),
                              ],
                            ),
                          ],
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                          itemCount: rows.length,
                          itemBuilder: (_, i) => _VehicleCard(
                              entry: rows[i],
                              onTap: rows[i].vehicleRow == null
                                  ? null
                                  : () => _openEntry(rows[i])),
                        )),
            ),
          ]);
        }),
      ),
    );
  }
}

// Column flex values shared by the header and every wide row so they align.
const _colNumber = 30.0;
const _colPlate = 2;
const _colVehicle = 2;
const _colOwner = 2;
const _colDevice = 1;
const _colStatus = 4;
const _colGeofence = 1;
const _colDocs = 3;
// Fixed, not flex — a short, roughly-constant-width date string doesn't need
// to compete with the other columns for proportional space (see the same
// choice on the Accounts tab).
const _colDate = 84.0;

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    Widget h(String t, int flex) => Expanded(
        flex: flex,
        child: Text(t,
            style: GoogleFonts.dmMono(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: AppColors.vigiLiteText3,
                letterSpacing: 0.5)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      child: Row(children: [
        const SizedBox(
            width: _colNumber,
            child: Text('#',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.vigiLiteText3))),
        const AdminColumnDivider(),
        h('PLATE NUMBER', _colPlate),
        const AdminColumnDivider(),
        h('VEHICLE', _colVehicle),
        const AdminColumnDivider(),
        h('REGISTERED OWNER', _colOwner),
        const AdminColumnDivider(),
        h('DEVICE ID', _colDevice),
        const AdminColumnDivider(),
        h('STATUS', _colStatus),
        const AdminColumnDivider(),
        h('GEOFENCE', _colGeofence),
        const AdminColumnDivider(),
        h('OR / CR', _colDocs),
        const AdminColumnDivider(),
        const SizedBox(
            width: _colDate,
            child: Text('DATE REGISTERED',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.vigiLiteText3,
                    letterSpacing: 0.5))),
        const SizedBox(width: 24),
      ]),
    );
  }
}

Widget _twoLine(String top, String bottom) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(top,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.dmSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.vigiLiteText)),
          Text(bottom,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.dmSans(
                  fontSize: 11.5, color: AppColors.vigiLiteText3)),
        ]);

/// The wide/desktop table row's content — no card decoration of its own;
/// [AdminHoverRow]/[AdminTableFrame] (see the caller) supply the hover
/// highlight, zebra background and row divider. When [_VehicleEntry.vehicleRow]
/// is null (the account hasn't registered a vehicle yet), every
/// vehicle-specific column shows "—" except the VEHICLE column itself, which
/// reads "Not Yet Registered".
class _VehicleRowContent extends StatelessWidget {
  final _VehicleEntry entry;
  const _VehicleRowContent({required this.entry});

  @override
  Widget build(BuildContext context) {
    final row = entry.vehicleRow;
    final v = row?.vehicle;
    Widget cell(int flex, Widget child) => Expanded(
        flex: flex,
        child: Padding(padding: const EdgeInsets.only(right: 8), child: child));
    Widget dash() => Text('—',
        style:
            GoogleFonts.dmSans(fontSize: 13, color: AppColors.vigiLiteText3));

    return Row(children: [
      AdminRowNumber(number: entry.number),
      const AdminColumnDivider(),
      cell(
          _colPlate,
          v == null
              ? dash()
              : Text(v.plate,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.dmMono(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteText))),
      const AdminColumnDivider(),
      cell(
          _colVehicle,
          v == null
              ? Text('Not Yet Registered',
                  style: GoogleFonts.dmSans(
                      fontSize: 12.5,
                      fontStyle: FontStyle.italic,
                      color: AppColors.vigiLiteText3))
              : Row(children: [
                  VehicleTypeIcon(type: v.type, size: 32),
                  const SizedBox(width: 8),
                  Expanded(child: _twoLine(v.model, '${v.color} · ${v.type}')),
                ])),
      const AdminColumnDivider(),
      cell(_colOwner, _twoLine(entry.owner.name, entry.owner.email)),
      const AdminColumnDivider(),
      cell(
          _colDevice,
          v == null
              ? dash()
              : Text(v.deviceId,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.dmMono(
                      fontSize: 12, color: AppColors.vigiLiteText2))),
      const AdminColumnDivider(),
      cell(
          _colStatus,
          v == null
              ? dash()
              : Align(
                  alignment: Alignment.centerLeft,
                  child: _vehicleStatusBadge(v.status))),
      const AdminColumnDivider(),
      cell(
          _colGeofence,
          v == null
              ? dash()
              : Text(_geofenceLabel(v),
                  style: GoogleFonts.dmSans(
                      fontSize: 12.5, color: AppColors.vigiLiteText2))),
      const AdminColumnDivider(),
      cell(
          _colDocs,
          v == null
              ? dash()
              : Align(
                  alignment: Alignment.centerLeft,
                  child: _docsBadge(row!.documentsOnFile))),
      const AdminColumnDivider(),
      SizedBox(
          width: _colDate,
          child: v == null
              ? dash()
              : Text(adminDateLabel(v.createdAt),
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.dmSans(
                      fontSize: 12, color: AppColors.vigiLiteText2))),
      SizedBox(
          width: 24,
          child: v == null
              ? null
              : const Icon(Icons.chevron_right,
                  color: AppColors.vigiLiteText3, size: 20)),
    ]);
  }
}

/// The narrow/mobile card — same "Not Yet Registered" placeholder handling
/// as [_VehicleRowContent], with the account's registration number added.
class _VehicleCard extends StatelessWidget {
  final _VehicleEntry entry;
  final VoidCallback? onTap;
  const _VehicleCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final row = entry.vehicleRow;
    final v = row?.vehicle;

    final body = v == null
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AdminRowNumber(number: entry.number),
              const SizedBox(width: 4),
              Expanded(
                  child: Text('Not Yet Registered',
                      style: GoogleFonts.dmSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          fontStyle: FontStyle.italic,
                          color: AppColors.vigiLiteText3))),
            ]),
            const SizedBox(height: 4),
            Text('Owner: ${entry.owner.name}',
                style: GoogleFonts.dmSans(
                    fontSize: 12, color: AppColors.vigiLiteText3)),
          ])
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AdminRowNumber(number: entry.number),
              const SizedBox(width: 4),
              VehicleTypeIcon(type: v.type, size: 30),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(v.plate,
                      style: GoogleFonts.dmMono(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.vigiLiteText))),
              _vehicleStatusBadge(v.status),
            ]),
            const SizedBox(height: 4),
            Text('${v.model} · ${v.color} · ${v.type}',
                style: GoogleFonts.dmSans(
                    fontSize: 12.5, color: AppColors.vigiLiteText)),
            Text('Owner: ${entry.owner.name}',
                style: GoogleFonts.dmSans(
                    fontSize: 12, color: AppColors.vigiLiteText3)),
            Text('Registered: ${adminDateLabel(v.createdAt)}',
                style: GoogleFonts.dmMono(
                    fontSize: 11, color: AppColors.vigiLiteText3)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              _docsBadge(row!.documentsOnFile),
              StatusBadge(
                  label: 'GEOFENCE ${v.geofenceActive ? 'ON' : 'OFF'}',
                  bg: AppColors.grayLight,
                  fg: AppColors.gray),
            ]),
          ]);

    return TapScale(
      onTap: onTap ?? () {},
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: AppColors.vigiLiteCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: v?.status == VehicleStatus.stolen
                  ? AppColors.vigiLiteCritical.withValues(alpha: 0.35)
                  : AppColors.vigiLiteBorder,
              width: 0.8),
        ),
        child: body,
      ),
    );
  }
}

// ══════════════════════════════════════
// FULL REGISTRATION RECORD
// ══════════════════════════════════════
class _VehicleDetailSheet extends StatefulWidget {
  final AdminVehicleRow row;
  const _VehicleDetailSheet({required this.row});
  @override
  State<_VehicleDetailSheet> createState() => _VehicleDetailSheetState();
}

class _VehicleDetailSheetState extends State<_VehicleDetailSheet> {
  ({Uint8List? or, Uint8List? cr})? _docs;
  String? _docsError;

  @override
  void initState() {
    super.initState();
    _loadDocs();
  }

  Future<void> _loadDocs() async {
    try {
      final d = await AdminService.instance
          .fetchVehicleDocuments(widget.row.owner.id, widget.row.vehicle.id);
      if (!mounted) return;
      setState(() => _docs = d);
    } catch (_) {
      if (!mounted) return;
      setState(() => _docsError =
          "Could not load this vehicle's OR/CR photos. Check the Firestore rules and your connection.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.row.vehicle;
    final o = widget.row.owner;
    final located = !(v.lat == 0 && v.lng == 0);
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
          VehicleTypeIcon(type: v.type, size: 44),
          const SizedBox(width: 12),
          Expanded(
              child: Text(v.plate,
                  style: GoogleFonts.dmMono(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: AppColors.vigiLiteText))),
          _vehicleStatusBadge(v.status),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 4, children: [
          _docsBadge(widget.row.documentsOnFile),
        ]),
        const SizedBox(height: 18),
        const SectionLabel('VEHICLE INFORMATION', dark: true),
        AdminInfoCard([
          AdminInfo('Plate number', v.plate),
          AdminInfo('Series', v.model),
          AdminInfo('Color', v.color),
          AdminInfo('Vehicle type', v.type),
          AdminInfo('Year model', v.yearModel.isEmpty ? '—' : v.yearModel),
          // Recommended by the Highway Patrol Group (HPG) — these two tell a
          // single car apart from every other one sharing its plate, make,
          // or color.
          AdminInfo(
              'Engine number', v.engineNumber.isEmpty ? '—' : v.engineNumber,
              selectable: v.engineNumber.isNotEmpty),
          AdminInfo(
              'Chassis number', v.chassisNumber.isEmpty ? '—' : v.chassisNumber,
              selectable: v.chassisNumber.isNotEmpty),
          AdminInfo('Status', v.statusLabel),
          AdminInfo('Device ID', v.deviceId),
          AdminInfo('Date registered', adminDateLabel(v.createdAt)),
          AdminInfo('Geofence', _geofenceLabel(v)),
          AdminInfo(
              'Last location',
              located
                  ? '${v.lat.toStringAsFixed(5)}, ${v.lng.toStringAsFixed(5)}'
                  : 'No location'),
          AdminInfo(
              'Last update',
              v.lastLocationUpdate == null
                  ? '—'
                  : DateFormat('d MMM yyyy, h:mm a')
                      .format(v.lastLocationUpdate!)),
          AdminInfo('Vehicle ID', v.id, selectable: true),
        ]),
        const SizedBox(height: 16),
        const SectionLabel('REGISTERED OWNER', dark: true),
        AdminInfoCard([
          AdminInfo('Full name', o.name),
          AdminInfo('Email address', o.email),
          AdminInfo('Mobile number', o.phone.isEmpty ? '—' : o.phone,
              selectable: o.phone.isNotEmpty),
          AdminInfo('Account status',
              widget.row.ownerDisabled ? 'Suspended' : 'Active'),
          AdminInfo('Account ID', o.id, selectable: true),
        ]),
        const SizedBox(height: 16),
        const SectionLabel('OR / CR DOCUMENTS', dark: true),
        _docsSection(),
      ],
    );
  }

  Widget _docsSection() {
    if (_docsError != null) {
      return Text(_docsError!,
          style: GoogleFonts.dmSans(
              fontSize: 12.5, color: AppColors.vigiLiteCritical));
    }
    final d = _docs;
    if (d == null) {
      return const Padding(
          padding: EdgeInsets.all(14),
          child: Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.vigiLiteCyan))));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: AdminPhotoTile(
                label: 'OFFICIAL RECEIPT (OR)', bytes: d.or, height: 190)),
        const SizedBox(width: 12),
        Expanded(
            child: AdminPhotoTile(
                label: 'CERTIFICATE OF REGISTRATION (CR)',
                bytes: d.cr,
                height: 190)),
      ]),
      const SizedBox(height: 6),
      Text(
          d.or == null && d.cr == null
              ? 'This vehicle was registered before OR/CR photos were required.'
              : 'Tap a photo to enlarge it.',
          style:
              GoogleFonts.dmSans(fontSize: 11, color: AppColors.vigiLiteText3)),
    ]);
  }
}
