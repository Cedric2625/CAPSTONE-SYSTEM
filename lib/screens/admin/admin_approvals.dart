import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../models/models.dart';
import '../../services/admin_service.dart';
import '../../utils/app_theme.dart';
import 'admin_widgets.dart';

// ══════════════════════════════════════
// APPROVALS TAB — new registrations waiting on an admin. Each card shows the
// account, its vehicle and all four documents, and the admin confirms each
// document is genuine before Approve unlocks. Reject asks for a reason, which
// the person sees on their next attempt to log in.
// ══════════════════════════════════════

/// Everything a pending card shows, loaded once when the card first appears.
class _PendingDocs {
  final VehicleModel? vehicle;
  final Uint8List? front;
  final Uint8List? back;
  final Uint8List? or;
  final Uint8List? cr;
  const _PendingDocs({
    required this.vehicle,
    required this.front,
    required this.back,
    required this.or,
    required this.cr,
  });

  /// Approval needs every document present, not just the ones that happened
  /// to load.
  bool get complete =>
      vehicle != null &&
      front != null &&
      back != null &&
      or != null &&
      cr != null;
}

class ApprovalsTab extends StatelessWidget {
  final List<PendingRegistration> pending;
  final bool loading;
  final String? error;
  final Future<void> Function(PendingRegistration p) onApprove;
  final Future<void> Function(PendingRegistration p, String reason) onReject;

  const ApprovalsTab({
    super.key,
    required this.pending,
    required this.loading,
    required this.error,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_outlined,
                size: 40, color: AppColors.vigiLiteText3),
            const SizedBox(height: 10),
            Text(error!,
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                    fontSize: 13, color: AppColors.vigiLiteText3)),
          ]),
        ),
      );
    }
    if (loading && pending.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.vigiLiteCyan));
    }
    if (pending.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.task_alt_outlined,
                size: 40, color: AppColors.vigiLiteText3),
            const SizedBox(height: 10),
            Text('No registrations are waiting for review.',
                style: GoogleFonts.dmSans(
                    fontSize: 13, color: AppColors.vigiLiteText3)),
          ]),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Text(
          '${pending.length} registration${pending.length == 1 ? '' : 's'} waiting for review',
          style: GoogleFonts.dmSans(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.vigiLiteText),
        ),
        const SizedBox(height: 4),
        Text(
          'Before approving, confirm each document is a genuine, unedited photo '
          '— not AI-generated, a screenshot, or altered.',
          style: GoogleFonts.dmSans(
              fontSize: 12.5, color: AppColors.vigiLiteText3),
        ),
        const SizedBox(height: 16),
        for (final p in pending)
          _PendingCard(
            key: ValueKey(p.user.id),
            registration: p,
            onApprove: () => onApprove(p),
            onReject: (reason) => onReject(p, reason),
          ),
      ],
    );
  }
}

class _PendingCard extends StatefulWidget {
  final PendingRegistration registration;
  final Future<void> Function() onApprove;
  final Future<void> Function(String reason) onReject;
  const _PendingCard({
    super.key,
    required this.registration,
    required this.onApprove,
    required this.onReject,
  });

  @override
  State<_PendingCard> createState() => _PendingCardState();
}

class _PendingCardState extends State<_PendingCard> {
  static const _loadFailedText =
      "Could not load this registration's documents. Check your connection and refresh the page.";
  static const _checks = [
    ('front', "Driver's license — front is genuine and unedited"),
    ('back', "Driver's license — back is genuine and unedited"),
    ('or', 'Official Receipt (OR) is genuine and unedited'),
    ('cr', 'Certificate of Registration (CR) is genuine and unedited'),
  ];

  late final Future<_PendingDocs> _docs = _load();
  final Set<String> _checked = {};
  bool _busy = false;

  UserModel get _user => widget.registration.user;

  Future<_PendingDocs> _load() async {
    final svc = AdminService.instance;
    final vehicles = await svc.fetchVehicles(_user.id);
    final vehicle = vehicles.isEmpty ? null : vehicles.first;
    final license = await svc.fetchLicense(_user.id);
    final vehicleDocs = vehicle == null
        ? (or: null, cr: null)
        : await svc.fetchVehicleDocuments(_user.id, vehicle.id);
    return _PendingDocs(
      vehicle: vehicle,
      front: license.front,
      back: license.back,
      or: vehicleDocs.or,
      cr: vehicleDocs.cr,
    );
  }

  Future<void> _askReject() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Reject ${_user.name}\'s registration?',
            style: GoogleFonts.dmSans(fontWeight: FontWeight.w800)),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            style: GoogleFonts.dmSans(fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Reason (shown to the applicant)',
              hintText:
                  'e.g. The OR photo appears edited — the amount is inconsistent.',
              hintStyle:
                  GoogleFonts.dmSans(fontSize: 13, color: AppColors.text3),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () {
              final text = controller.text.trim();
              if (text.length < 5) return;
              Navigator.pop(ctx, text);
            },
            child: const Text('Reject Registration'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null) return;
    await _run(() => widget.onReject(reason));
  }

  /// Runs one decision and always clears the busy state afterwards, so a
  /// failed save leaves the card usable instead of stuck.
  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final submitted = widget.registration.submittedAt;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.vigiLiteCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.vigiLiteBorder),
      ),
      child: FutureBuilder<_PendingDocs>(
        future: _docs,
        builder: (context, snap) {
          final docs = snap.data;
          final loading = snap.connectionState != ConnectionState.done;
          final failed = snap.hasError;
          final ready = docs != null && docs.complete;
          final allChecked = _checks.every((c) => _checked.contains(c.$1));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor:
                      AppColors.vigiLiteCyan.withValues(alpha: 0.18),
                  child: Text(_user.initials,
                      style: GoogleFonts.dmSans(
                          fontWeight: FontWeight.w800,
                          color: AppColors.vigiLiteCyan)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_user.name,
                            style: GoogleFonts.dmSans(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: AppColors.vigiLiteText)),
                        Text('${_user.email} · ${_user.phone}',
                            style: GoogleFonts.dmSans(
                                fontSize: 12, color: AppColors.vigiLiteText3)),
                      ]),
                ),
                _Pill(
                  text: submitted == null
                      ? 'PENDING REVIEW'
                      : 'SUBMITTED ${DateFormat('d MMM yyyy, h:mm a').format(submitted)}',
                  color: AppColors.vigiLiteWarning,
                ),
              ]),
              const SizedBox(height: 16),

              // Account + vehicle
              LayoutBuilder(builder: (context, c) {
                final account = _Section(
                  title: 'ACCOUNT',
                  child: AdminInfoCard([
                    AdminInfo('Full name', _user.name, selectable: true),
                    AdminInfo('Email', _user.email, selectable: true),
                    AdminInfo('Mobile', _user.phone, selectable: true),
                  ]),
                );
                final vehicle = _Section(
                  title: 'VEHICLE',
                  child: loading
                      ? const _Loading()
                      : failed
                          ? const _Missing(_loadFailedText)
                          : docs?.vehicle == null
                              ? const _Missing('No vehicle was submitted.')
                              : AdminInfoCard([
                                  AdminInfo('Plate', docs!.vehicle!.plate,
                                      selectable: true),
                                  AdminInfo('Model', docs.vehicle!.model),
                                  AdminInfo('Color', docs.vehicle!.color),
                                  AdminInfo(
                                      'Year model',
                                      docs.vehicle!.yearModel.isEmpty
                                          ? '—'
                                          : docs.vehicle!.yearModel),
                                  AdminInfo('Body type', docs.vehicle!.type),
                                  AdminInfo(
                                      'Engine number',
                                      docs.vehicle!.engineNumber.isEmpty
                                          ? '—'
                                          : docs.vehicle!.engineNumber,
                                      selectable: docs
                                          .vehicle!.engineNumber.isNotEmpty),
                                  AdminInfo(
                                      'Chassis number',
                                      docs.vehicle!.chassisNumber.isEmpty
                                          ? '—'
                                          : docs.vehicle!.chassisNumber,
                                      selectable: docs
                                          .vehicle!.chassisNumber.isNotEmpty),
                                ]),
                );
                return c.maxWidth >= 720
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Expanded(child: account),
                            const SizedBox(width: 14),
                            Expanded(child: vehicle),
                          ])
                    : Column(children: [account, vehicle]);
              }),

              // Documents
              _Section(
                title: 'DOCUMENTS',
                child: loading
                    ? const _Loading()
                    : failed || docs == null
                        ? const _Missing(_loadFailedText)
                        : Wrap(spacing: 12, runSpacing: 12, children: [
                            for (final d in [
                              ('LICENSE FRONT', docs.front),
                              ('LICENSE BACK', docs.back),
                              ('OR', docs.or),
                              ('CR', docs.cr),
                            ])
                              SizedBox(
                                width: 200,
                                child: AdminPhotoTile(
                                    label: d.$1, bytes: d.$2, height: 150),
                              ),
                          ]),
              ),

              // Verification checklist
              _Section(
                title: 'VERIFICATION',
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.vigiLiteInput,
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: AppColors.vigiLiteBorder, width: 0.8),
                  ),
                  child: Column(children: [
                    for (final c in _checks)
                      CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: AppColors.vigiLiteSuccess,
                        value: _checked.contains(c.$1),
                        onChanged: (!ready || _busy)
                            ? null
                            : (v) => setState(() => v == true
                                ? _checked.add(c.$1)
                                : _checked.remove(c.$1)),
                        title: Text(c.$2,
                            style: GoogleFonts.dmSans(
                                fontSize: 13, color: AppColors.vigiLiteText)),
                      ),
                    if (!loading && !ready)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text(
                          'A document is missing, so this registration can only be rejected.',
                          style: GoogleFonts.dmSans(
                              fontSize: 12, color: AppColors.vigiLiteCritical),
                        ),
                      ),
                  ]),
                ),
              ),

              // Actions
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.vigiLiteCritical,
                      side: const BorderSide(color: AppColors.vigiLiteCritical),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  onPressed: _busy || loading ? null : _askReject,
                  icon: const Icon(Icons.close, size: 18),
                  label: Text('Reject',
                      style: GoogleFonts.dmSans(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.vigiLiteSuccess,
                      disabledBackgroundColor: AppColors.vigiLiteBorder,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  onPressed: (!ready || !allChecked || _busy)
                      ? null
                      : () => _run(widget.onApprove),
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(
                      allChecked || !ready
                          ? 'Approve'
                          : 'Verify all documents first',
                      style: GoogleFonts.dmSans(fontWeight: FontWeight.w700)),
                ),
              ]),
            ],
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: GoogleFonts.dmMono(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.vigiLiteText3,
                  letterSpacing: 0.5)),
          const SizedBox(height: 8),
          child,
        ]),
      );
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(text,
            style: GoogleFonts.dmMono(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
      );
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(
            minHeight: 2,
            color: AppColors.vigiLiteCyan,
            backgroundColor: AppColors.vigiLiteBorder),
      );
}

class _Missing extends StatelessWidget {
  final String text;
  const _Missing(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style:
          GoogleFonts.dmSans(fontSize: 13, color: AppColors.vigiLiteCritical));
}
