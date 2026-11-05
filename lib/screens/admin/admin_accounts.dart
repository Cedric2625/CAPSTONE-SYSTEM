import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../utils/app_theme.dart';
import '../../services/admin_service.dart';
import '../../models/models.dart';
// `showPhotoViewer` is hidden here — this file uses admin_widgets.dart's own
// copy, kept separate on purpose (the admin web portal stays independent of
// the phone app's widget file; see that file's own doc comment).
import '../../widgets/widgets.dart' hide showPhotoViewer;
import 'admin_widgets.dart';

// ══════════════════════════════════════
// ADMIN — ACCOUNTS TAB
// ══════════════════════════════════════
// Every registered user with their information at a glance: name, email,
// mobile number, device, vehicles, driver's license and account status — as a
// table on a wide (desktop) window and as cards on a narrow one. Tapping a row
// opens the full profile. Suspend / delete stay one click away on each row.
// Like the rest of the admin portal this is web-only and independent of
// AppState.

enum _AccountFilter { all, active, suspended, licensePending }

Widget _licenseBadge(bool? onFile) => onFile == null
    ? const StatusBadge(
        label: 'LICENSE ?', bg: AppColors.grayLight, fg: AppColors.gray)
    : onFile
        ? const StatusBadge(
            label: 'LICENSE ✓', bg: AppColors.greenLight, fg: adminGreenText)
        : const StatusBadge(
            label: 'NO LICENSE', bg: AppColors.amberLight, fg: adminAmberText);

Widget _accountStatusBadge(bool disabled) => disabled
    ? const StatusBadge(
        label: 'SUSPENDED',
        bg: AppColors.primaryLight,
        fg: AppColors.primaryDark,
        withDot: true)
    : const StatusBadge(
        label: 'ACTIVE',
        bg: AppColors.greenLight,
        fg: adminGreenText,
        withDot: true);

class AccountsTab extends StatefulWidget {
  final List<AdminUserRow> rows;
  final bool loading;
  final String? error;
  final String? meUid;
  final VoidCallback onRetry;
  final Future<void> Function(AdminUserRow row) onToggle;
  final Future<void> Function(AdminUserRow row) onRemove;
  const AccountsTab({
    super.key,
    required this.rows,
    required this.loading,
    required this.error,
    required this.meUid,
    required this.onRetry,
    required this.onToggle,
    required this.onRemove,
  });

  @override
  State<AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<AccountsTab> {
  String _query = '';
  _AccountFilter _filter = _AccountFilter.all;

  // Sorted oldest-first so the row ON SCREEN is always in the same order as
  // its "#" number — the Firestore query itself orders by name (see
  // AdminService.fetchAllUsers), which is a different order than
  // registration, and previously left the number and the row's actual
  // position disagreeing (e.g. row 1 showing further down the list than
  // row 8).
  List<AdminUserRow> get _filtered {
    final q = _query.trim().toLowerCase();
    final sorted = List<AdminUserRow>.from(widget.rows)
      ..sort(byRegistrationOrder);
    return sorted.where((r) {
      final u = r.user;
      final matchesQuery = q.isEmpty ||
          u.name.toLowerCase().contains(q) ||
          u.email.toLowerCase().contains(q) ||
          u.phone.toLowerCase().contains(q) ||
          u.deviceId.toLowerCase().contains(q);
      final matchesFilter = switch (_filter) {
        _AccountFilter.all => true,
        _AccountFilter.active => !r.disabled,
        _AccountFilter.suspended => r.disabled,
        _AccountFilter.licensePending => r.licenseOnFile == false,
      };
      return matchesQuery && matchesFilter;
    }).toList();
  }

  Future<void> _open(AdminUserRow row) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.vigiLiteCard,
      constraints: const BoxConstraints(maxWidth: 760),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.92,
        child:
            _AccountDetailSheet(row: row, isSelf: row.user.id == widget.meUid),
      ),
    );
    if (action == 'toggle') {
      await widget.onToggle(row);
    } else if (action == 'remove') {
      await widget.onRemove(row);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = adminLoadingOrError(
        loading: widget.loading, error: widget.error, onRetry: widget.onRetry);
    if (asyncState != null) return asyncState;

    final rows = _filtered;
    final numbers = registrationNumbers(widget.rows);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 860;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: AdminSummaryGrid(
                  chips: _summaryChips(widget.rows,
                      filter: _filter,
                      onFilter: (f) => setState(() => _filter = f)),
                  width: c.maxWidth - 32),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: AdminToolbar<_AccountFilter>(
                hint: 'Search name, email, mobile number or device ID',
                noun: 'account',
                filter: _filter,
                filters: const {
                  _AccountFilter.all: 'All',
                  _AccountFilter.active: 'Active',
                  _AccountFilter.suspended: 'Suspended',
                  _AccountFilter.licensePending: 'License pending',
                },
                onQuery: (v) => setState(() => _query = v),
                onFilter: (f) => setState(() => _filter = f),
                shown: rows.length,
                total: widget.rows.length,
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                          widget.rows.isEmpty
                              ? 'No registered accounts yet.'
                              : 'No matching accounts.',
                          style: GoogleFonts.dmSans(
                              fontSize: 13, color: AppColors.vigiLiteText3)))
                  : RefreshIndicator(
                      color: AppColors.vigiLiteCyan,
                      onRefresh: () async => widget.onRetry(),
                      child: wide
                          ? ListView(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                              children: [
                                AdminTableFrame(
                                  header: const _TableHeader(),
                                  rows: [
                                    for (final row in rows)
                                      AdminHoverRow(
                                        onTap: () => _open(row),
                                        child: _AccountRowContent(
                                          row: row,
                                          number: numbers[row.user.id] ?? 0,
                                          isSelf: row.user.id == widget.meUid,
                                          onToggle: () => widget.onToggle(row),
                                          onRemove: () => widget.onRemove(row),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                              itemCount: rows.length,
                              itemBuilder: (_, i) {
                                final row = rows[i];
                                return _AccountCard(
                                  row: row,
                                  number: numbers[row.user.id] ?? 0,
                                  isSelf: row.user.id == widget.meUid,
                                  onTap: () => _open(row),
                                  onToggle: () => widget.onToggle(row),
                                  onRemove: () => widget.onRemove(row),
                                );
                              },
                            ),
                    ),
            ),
          ]);
        }),
      ),
    );
  }
}

/// [filter]/[onFilter] let the four tiles with a matching filter chip
/// (Total, Active, Suspended, License Pending) double as that chip —
/// tapping one applies the filter, and it fills solidly while that filter
/// is the one currently applied, so which filter is active is obvious from
/// the summary row itself, not just the small chip underneath it. Vehicles
/// and Admins have no matching filter and stay plain, informational tiles.
List<AdminStatChip> _summaryChips(List<AdminUserRow> rows,
    {required _AccountFilter filter,
    required ValueChanged<_AccountFilter> onFilter}) {
  final total = rows.length;
  final suspended = rows.where((r) => r.disabled).length;
  final admins = rows.where((r) => r.user.role == 'admin').length;
  final pending = rows.where((r) => r.licenseOnFile == false).length;
  final vehicles = rows.fold<int>(0, (sum, r) => sum + (r.vehicleCount ?? 0));
  return [
    AdminStatChip(
        label: 'TOTAL ACCOUNTS',
        value: '$total',
        color: AppColors.vigiLiteInfo,
        selected: filter == _AccountFilter.all,
        onTap: () => onFilter(_AccountFilter.all)),
    AdminStatChip(
        label: 'ACTIVE',
        value: '${total - suspended}',
        color: AppColors.vigiLiteSuccess,
        selected: filter == _AccountFilter.active,
        onTap: () => onFilter(_AccountFilter.active)),
    AdminStatChip(
        label: 'SUSPENDED',
        value: '$suspended',
        color: AppColors.vigiLiteWarning,
        selected: filter == _AccountFilter.suspended,
        onTap: () => onFilter(_AccountFilter.suspended)),
    AdminStatChip(
        label: 'LICENSE PENDING',
        value: '$pending',
        color: pending > 0
            ? AppColors.vigiLiteCritical
            : AppColors.vigiLiteSuccess,
        selected: filter == _AccountFilter.licensePending,
        onTap: () => onFilter(_AccountFilter.licensePending)),
    AdminStatChip(
        label: 'VEHICLES', value: '$vehicles', color: AppColors.vigiLiteInfo),
    // Firestore rules only restrict WHO can be admin, not how many are — so
    // this turns red if it's ever more than the one intended account.
    AdminStatChip(
        label: 'ADMINS',
        value: '$admins',
        color:
            admins > 1 ? AppColors.vigiLiteCritical : AppColors.vigiLiteInfo),
  ];
}

// Column widths shared by the header and every wide row so they line up.
const _colNumber = 30.0;
const _colAccount = 4;
const _colMobile = 2;
const _colDevice = 2;
const _colVehicles = 1;
const _colLicense = 4;
const _colStatus = 3;
// Fixed, not flex — a short, roughly-constant-width date string doesn't need
// to compete with the other columns for proportional space.
const _colDate = 84.0;
const _actionsWidth = 108.0;

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    Widget h(String t, int flex, {TextAlign align = TextAlign.left}) =>
        Expanded(
            flex: flex,
            child: Text(t,
                textAlign: align,
                style: GoogleFonts.dmMono(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.vigiLiteText3,
                    letterSpacing: 0.5)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
      child: Row(children: [
        const SizedBox(
            width: _colNumber,
            child: Text('#',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.vigiLiteText3))),
        const AdminColumnDivider(),
        h('ACCOUNT', _colAccount),
        const AdminColumnDivider(),
        h('MOBILE NUMBER', _colMobile),
        const AdminColumnDivider(),
        h('DEVICE ID', _colDevice),
        const AdminColumnDivider(),
        h('VEHICLES', _colVehicles, align: TextAlign.center),
        const AdminColumnDivider(),
        h('DRIVER\'S LICENSE', _colLicense),
        const AdminColumnDivider(),
        h('STATUS', _colStatus),
        const AdminColumnDivider(),
        const SizedBox(
            width: _colDate,
            child: Text('DATE CREATED',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.vigiLiteText3,
                    letterSpacing: 0.5))),
        const SizedBox(width: _actionsWidth - 8),
      ]),
    );
  }
}

/// The wide/desktop table row's content — no card decoration of its own;
/// [AdminHoverRow]/[AdminTableFrame] (see the caller) supply the hover
/// highlight, zebra background and row divider.
class _AccountRowContent extends StatelessWidget {
  final AdminUserRow row;
  final int number;
  final bool isSelf;
  final VoidCallback onToggle;
  final VoidCallback onRemove;
  const _AccountRowContent({
    required this.row,
    required this.number,
    required this.isSelf,
    required this.onToggle,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final u = row.user;
    final identity = _AccountIdentity(row: row, isSelf: isSelf);
    final actions = isSelf
        ? const SizedBox(width: _actionsWidth)
        : SizedBox(
            width: _actionsWidth,
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              _RowIconButton(
                icon: row.disabled ? Icons.restart_alt : Icons.block,
                color: row.disabled
                    ? AppColors.vigiLiteSuccess
                    : AppColors.vigiLiteWarning,
                tooltip: row.disabled ? 'Restore account' : 'Suspend account',
                onTap: onToggle,
              ),
              const SizedBox(width: 6),
              _RowIconButton(
                icon: Icons.delete_outline,
                color: AppColors.vigiLiteCritical,
                tooltip: 'Delete permanently',
                onTap: onRemove,
              ),
            ]),
          );

    Widget cell(int flex, Widget child) => Expanded(
        flex: flex,
        child: Padding(padding: const EdgeInsets.only(right: 8), child: child));

    return Row(children: [
      AdminRowNumber(number: number),
      const AdminColumnDivider(),
      cell(_colAccount, identity),
      const AdminColumnDivider(),
      cell(
          _colMobile,
          Text(u.phone.isEmpty ? '—' : u.phone,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.dmMono(
                  fontSize: 12, color: AppColors.vigiLiteText2))),
      const AdminColumnDivider(),
      cell(
          _colDevice,
          Text(u.deviceId,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.dmMono(
                  fontSize: 12, color: AppColors.vigiLiteText2))),
      const AdminColumnDivider(),
      cell(
          _colVehicles,
          Center(
              child: Text(row.vehicleCount?.toString() ?? '—',
                  style: GoogleFonts.dmSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteText)))),
      const AdminColumnDivider(),
      cell(
          _colLicense,
          Align(
              alignment: Alignment.centerLeft,
              child: _licenseBadge(row.licenseOnFile))),
      const AdminColumnDivider(),
      cell(
          _colStatus,
          Align(
              alignment: Alignment.centerLeft,
              child: _accountStatusBadge(row.disabled))),
      const AdminColumnDivider(),
      SizedBox(
          width: _colDate,
          child: Text(adminDateLabel(u.createdAt),
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.dmSans(
                  fontSize: 12, color: AppColors.vigiLiteText2))),
      actions,
    ]);
  }
}

/// The narrow/mobile card — unchanged look from before, with the
/// registration number and date added.
class _AccountCard extends StatelessWidget {
  final AdminUserRow row;
  final int number;
  final bool isSelf;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onRemove;
  const _AccountCard({
    required this.row,
    required this.number,
    required this.isSelf,
    required this.onTap,
    required this.onToggle,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final u = row.user;
    final identity = _AccountIdentity(row: row, isSelf: isSelf);
    final actions = isSelf
        ? const SizedBox(width: _actionsWidth)
        : SizedBox(
            width: _actionsWidth,
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              _RowIconButton(
                icon: row.disabled ? Icons.restart_alt : Icons.block,
                color: row.disabled
                    ? AppColors.vigiLiteSuccess
                    : AppColors.vigiLiteWarning,
                tooltip: row.disabled ? 'Restore account' : 'Suspend account',
                onTap: onToggle,
              ),
              const SizedBox(width: 6),
              _RowIconButton(
                icon: Icons.delete_outline,
                color: AppColors.vigiLiteCritical,
                tooltip: 'Delete permanently',
                onTap: onRemove,
              ),
            ]),
          );

    final body =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        AdminRowNumber(number: number),
        const SizedBox(width: 4),
        Expanded(child: identity),
        actions,
      ]),
      const SizedBox(height: 8),
      Text(
          '${u.phone.isEmpty ? 'No mobile number' : u.phone}  ·  ${u.deviceId}  ·  ${row.vehicleCount ?? '—'} vehicle(s)',
          style:
              GoogleFonts.dmMono(fontSize: 11, color: AppColors.vigiLiteText3)),
      Text('Registered: ${adminDateLabel(u.createdAt)}',
          style:
              GoogleFonts.dmMono(fontSize: 11, color: AppColors.vigiLiteText3)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 4, children: [
        _accountStatusBadge(row.disabled),
        _licenseBadge(row.licenseOnFile),
      ]),
    ]);

    return TapScale(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: AppColors.vigiLiteCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: row.disabled
                  ? AppColors.vigiLiteCritical.withValues(alpha: 0.25)
                  : AppColors.vigiLiteBorder,
              width: 0.8),
        ),
        child: body,
      ),
    );
  }
}

/// The avatar + name/email block shared by both the wide table row and the
/// narrow card.
class _AccountIdentity extends StatelessWidget {
  final AdminUserRow row;
  final bool isSelf;
  const _AccountIdentity({required this.row, required this.isSelf});

  @override
  Widget build(BuildContext context) {
    final u = row.user;
    return Row(children: [
      Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
            color: row.disabled
                ? AppColors.vigiLiteBorder
                : AppColors.vigiLiteCyan.withValues(alpha: 0.18),
            shape: BoxShape.circle),
        child: Center(
            child: Text(u.initials,
                style: GoogleFonts.dmSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: row.disabled
                        ? AppColors.vigiLiteText3
                        : AppColors.vigiLiteCyan))),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Wrap, not Row — a fixed-width "(you)"/"ADMIN" tag combined with a
          // long name has no room to shrink; wrapping onto a second line when
          // truly squeezed is what actually stays responsive instead of
          // overflowing the row at a narrower column width.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 2,
            children: [
              Text(u.name,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.dmSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.vigiLiteText)),
              if (isSelf)
                Text('(you)',
                    style: GoogleFonts.dmSans(
                        fontSize: 11, color: AppColors.vigiLiteText3)),
              if (u.role == 'admin')
                const StatusBadge(
                    label: 'ADMIN',
                    bg: AppColors.blueLight,
                    fg: AppColors.blue),
            ],
          ),
          const SizedBox(height: 2),
          Text(u.email,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.dmSans(
                  fontSize: 12, color: AppColors.vigiLiteText3)),
        ]),
      ),
    ]);
  }
}

/// A small tappable icon chip for a row's quick actions, with press feedback,
/// that doesn't also trigger the row's own tap.
class _RowIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _RowIconButton(
      {required this.icon,
      required this.color,
      required this.tooltip,
      required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: TapScale(
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      );
}

// ══════════════════════════════════════
// FULL PROFILE
// ══════════════════════════════════════
class _AccountDetailSheet extends StatefulWidget {
  final AdminUserRow row;
  final bool isSelf;
  const _AccountDetailSheet({required this.row, required this.isSelf});
  @override
  State<_AccountDetailSheet> createState() => _AccountDetailSheetState();
}

class _AccountDetailSheetState extends State<_AccountDetailSheet> {
  List<VehicleModel>? _vehicles;
  String? _vehiclesError;
  ({Uint8List? front, Uint8List? back})? _license;
  String? _licenseError;

  @override
  void initState() {
    super.initState();
    _loadVehicles();
    _loadLicense();
  }

  Future<void> _loadVehicles() async {
    try {
      final v = await AdminService.instance.fetchVehicles(widget.row.user.id);
      if (!mounted) return;
      setState(() => _vehicles = v);
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _vehiclesError = "Could not load this account's vehicles.");
    }
  }

  Future<void> _loadLicense() async {
    try {
      final l = await AdminService.instance.fetchLicense(widget.row.user.id);
      if (!mounted) return;
      setState(() => _license = l);
    } catch (_) {
      if (!mounted) return;
      setState(() => _licenseError =
          "Could not load this account's driver's license. Check the Firestore rules and your connection.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.row.user;
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
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
                color: AppColors.vigiLiteCyan.withValues(alpha: 0.18),
                shape: BoxShape.circle),
            child: Center(
                child: Text(u.initials,
                    style: GoogleFonts.dmSans(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.vigiLiteCyan))),
          ),
          const SizedBox(width: 14),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(u.name,
                  style: GoogleFonts.dmSans(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.vigiLiteText)),
              Text(u.email,
                  style: GoogleFonts.dmSans(
                      fontSize: 12.5, color: AppColors.vigiLiteText3)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                _accountStatusBadge(widget.row.disabled),
                _licenseBadge(widget.row.licenseOnFile),
                if (u.role == 'admin')
                  const StatusBadge(
                      label: 'ADMIN',
                      bg: AppColors.blueLight,
                      fg: AppColors.blue),
              ]),
            ]),
          ),
        ]),
        const SizedBox(height: 18),
        const SectionLabel('ACCOUNT INFORMATION', dark: true),
        AdminInfoCard([
          AdminInfo('Full name', u.name),
          AdminInfo('Email address', u.email),
          AdminInfo('Mobile number', u.phone.isEmpty ? '—' : u.phone,
              selectable: u.phone.isNotEmpty),
          AdminInfo('Device ID', u.deviceId),
          AdminInfo(
              'Role', u.role == 'admin' ? 'Administrator' : 'Vehicle owner'),
          AdminInfo('Account status',
              widget.row.disabled ? 'Suspended (cannot log in)' : 'Active'),
          AdminInfo('Date created', adminDateLabel(u.createdAt)),
          AdminInfo('Account ID', u.id, selectable: true),
        ]),
        const SizedBox(height: 16),
        SectionLabel(
            'REGISTERED VEHICLES${_vehicles == null ? '' : ' (${_vehicles!.length})'}',
            dark: true),
        _vehiclesSection(),
        const SizedBox(height: 16),
        const SectionLabel("DRIVER'S LICENSE", dark: true),
        _licenseSection(),
        const SizedBox(height: 22),
        if (widget.isSelf)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.vigiLiteWarning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              const Icon(Icons.info_outline,
                  size: 16, color: AppColors.vigiLiteWarning),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      'This is the admin account itself — suspend and delete are disabled here to prevent locking yourself out.',
                      style: GoogleFonts.dmSans(
                          fontSize: 11.5, color: AppColors.vigiLiteWarning))),
            ]),
          )
        else
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, 'toggle'),
                icon: Icon(
                    widget.row.disabled ? Icons.restart_alt : Icons.block,
                    size: 18),
                label: Text(widget.row.disabled
                    ? 'Restore Account'
                    : 'Suspend Account'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    foregroundColor: widget.row.disabled
                        ? AppColors.vigiLiteSuccess
                        : AppColors.vigiLiteWarning,
                    side: BorderSide(
                        color: widget.row.disabled
                            ? AppColors.vigiLiteSuccess
                            : AppColors.vigiLiteWarning)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(context, 'remove'),
                icon: const Icon(Icons.delete_forever_outlined,
                    size: 18, color: Colors.white),
                label: Text('Delete Permanently',
                    style: GoogleFonts.dmSans(
                        fontWeight: FontWeight.w700, color: Colors.white)),
                style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    backgroundColor: AppColors.vigiLiteCritical,
                    foregroundColor: Colors.white,
                    elevation: 0),
              ),
            ),
          ]),
      ],
    );
  }

  Widget _vehiclesSection() {
    if (_vehiclesError != null) {
      return Text(_vehiclesError!,
          style: GoogleFonts.dmSans(
              fontSize: 12.5, color: AppColors.vigiLiteCritical));
    }
    final v = _vehicles;
    if (v == null) return _loader();
    if (v.isEmpty) {
      return Text('No vehicles registered.',
          style: GoogleFonts.dmSans(
              fontSize: 12.5, color: AppColors.vigiLiteText3));
    }
    return Column(children: [
      for (final x in v)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: AppColors.vigiLiteCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.vigiLiteBorder, width: 0.8)),
          child: Row(children: [
            VehicleTypeIcon(type: x.type, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(x.plate,
                        style: GoogleFonts.dmMono(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.vigiLiteText)),
                    Text('${x.model} · ${x.color} · ${x.type}',
                        style: GoogleFonts.dmSans(
                            fontSize: 12, color: AppColors.vigiLiteText3)),
                    Text(
                        x.geofenceActive
                            ? 'Geofence on · ${x.geofenceRadius.round()} m'
                            : 'Geofence off',
                        style: GoogleFonts.dmSans(
                            fontSize: 11.5, color: AppColors.vigiLiteText3)),
                  ]),
            ),
            x.status == VehicleStatus.stolen
                ? StatusBadge.stolen()
                : (x.status == VehicleStatus.recovered
                    ? StatusBadge.recovered()
                    : StatusBadge.active()),
          ]),
        ),
    ]);
  }

  Widget _licenseSection() {
    if (_licenseError != null) {
      return Text(_licenseError!,
          style: GoogleFonts.dmSans(
              fontSize: 12.5, color: AppColors.vigiLiteCritical));
    }
    final l = _license;
    if (l == null) return _loader();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: AdminPhotoTile(label: 'FRONT', bytes: l.front)),
        const SizedBox(width: 12),
        Expanded(child: AdminPhotoTile(label: 'BACK', bytes: l.back)),
      ]),
      const SizedBox(height: 6),
      Text('Tap a photo to enlarge it.',
          style:
              GoogleFonts.dmSans(fontSize: 11, color: AppColors.vigiLiteText3)),
    ]);
  }

  Widget _loader() => const Padding(
      padding: EdgeInsets.all(14),
      child: Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.vigiLiteCyan))));
}
