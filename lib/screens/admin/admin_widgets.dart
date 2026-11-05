import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../utils/app_theme.dart';
import '../../services/admin_service.dart';
// `showPhotoViewer` is hidden — this file defines its OWN copy below, kept
// separate on purpose (see that function's doc comment).
import '../../widgets/widgets.dart' hide showPhotoViewer;

// ══════════════════════════════════════
// SHARED ADMIN-PORTAL PIECES — used by the Accounts, Vehicles and Live
// Activity tabs so they look and behave the same. Web-only, like the rest of
// the admin portal (nothing here touches AppState or any Android plugin).
// ══════════════════════════════════════

const adminGreenText = Color(0xFF166534);
const adminAmberText = Color(0xFF92400E);

/// Oldest-first: an account with no known `createdAt` (registered before
/// that field existed) sorts BEFORE every dated one — it was, in real-world
/// terms, actually registered earlier than anything the app can put an
/// exact date on, so it belongs nearer the front, not the back. Getting
/// this backwards was a real bug: a single freshly-registered (and
/// therefore dated) account was sorting as #1 — "oldest" — ahead of five
/// older, undated accounts, the opposite of what a "new user is numbered
/// last" ask means. Grouped together and ordered by name among themselves,
/// since there's no way to know their real relative order. Shared by the
/// Accounts and Vehicles tabs so an account's row number means the same
/// thing — and stays the same number — on both.
int byRegistrationOrder(AdminUserRow a, AdminUserRow b) {
  final ca = a.user.createdAt;
  final cb = b.user.createdAt;
  if (ca != null && cb != null) return ca.compareTo(cb);
  if (ca == null && cb == null) {
    return a.user.name.toLowerCase().compareTo(b.user.name.toLowerCase());
  }
  return ca == null ? -1 : 1;
}

/// Every account's position in registration order (oldest = 1), keyed by
/// account ID — computed from the FULL, unfiltered list so a number stays
/// the same account's number even while a search/filter hides other rows,
/// and only shifts when the actual roster changes (a new registration, or a
/// deletion).
Map<String, int> registrationNumbers(List<AdminUserRow> all) {
  final sorted = List<AdminUserRow>.from(all)..sort(byRegistrationOrder);
  return {for (var i = 0; i < sorted.length; i++) sorted[i].user.id: i + 1};
}

/// "—" for an unknown date (an account/vehicle that predates the
/// `createdAt` field), otherwise a short absolute date — this is a
/// record-keeping column, so a relative "3 days ago" would go stale the
/// moment someone reopens the dashboard.
String adminDateLabel(DateTime? d) =>
    d == null ? '—' : DateFormat('d MMM yyyy').format(d);

/// A small fixed-width "row number" badge — the account/vehicle's position
/// in registration order (oldest = 1), recomputed live from whatever's
/// currently loaded, so it naturally shifts down when an earlier account is
/// deleted rather than being a permanent stored ID.
class AdminRowNumber extends StatelessWidget {
  final int number;
  const AdminRowNumber({super.key, required this.number});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 30,
        child: Text('$number',
            style: GoogleFonts.dmMono(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.vigiLiteText3)),
      );
}

/// Wraps a table's header and its data rows in one bordered, rounded card
/// with a tinted header and a hairline divider between rows — the
/// wide/desktop table view, as opposed to the stacked cards used on a
/// narrow window. Turns what used to be a stack of separately-floating
/// cards into an actual gridded table.
class AdminTableFrame extends StatelessWidget {
  final Widget header;
  final List<Widget> rows;
  const AdminTableFrame({super.key, required this.header, required this.rows});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.vigiLiteCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.vigiLiteBorder, width: 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          Container(
              color: AppColors.vigiLiteBg,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: header),
          for (var i = 0; i < rows.length; i++)
            Container(
              decoration: BoxDecoration(
                  color: i.isOdd
                      ? AppColors.vigiLiteInput.withValues(alpha: 0.4)
                      : AppColors.vigiLiteCard,
                  border: const Border(
                      top: BorderSide(
                          color: AppColors.vigiLiteBorder, width: 0.6))),
              child: rows[i],
            ),
        ]),
      );
}

/// One row inside [AdminTableFrame]: highlights under the mouse (this is a
/// WEB admin dashboard) and forwards taps, without fighting the row's own
/// background color set by [AdminTableFrame]'s zebra striping.
class AdminHoverRow extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  const AdminHoverRow({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.fromLTRB(14, 12, 10, 12),
  });

  @override
  State<AdminHoverRow> createState() => _AdminHoverRowState();
}

class _AdminHoverRowState extends State<AdminHoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor:
            widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            color: _hover
                ? AppColors.vigiLiteCyan.withValues(alpha: 0.12)
                : Colors.transparent,
            padding: widget.padding,
            child: widget.child,
          ),
        ),
      );
}

/// A subtle vertical divider between two table columns, for the "column
/// lines" a gridded table needs — used inside a wide row's [Row] between
/// cells, not around every cell, so it never doubles up with a neighbor's.
class AdminColumnDivider extends StatelessWidget {
  const AdminColumnDivider({super.key});
  @override
  Widget build(BuildContext context) => Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: AppColors.vigiLiteBorder.withValues(alpha: 0.7));
}

/// The loading spinner or the "couldn't load — Retry" card shared by every
/// admin tab's list. Returns null when neither applies, meaning the caller
/// should render its actual content instead.
Widget? adminLoadingOrError(
    {required bool loading,
    required String? error,
    required VoidCallback onRetry}) {
  if (loading) {
    return const Center(
        child: CircularProgressIndicator(color: AppColors.vigiLiteCyan));
  }
  if (error != null) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_outlined,
              size: 40, color: AppColors.vigiLiteText3),
          const SizedBox(height: 10),
          Text(error,
              textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(
                  fontSize: 13, color: AppColors.vigiLiteText3)),
          const SizedBox(height: 14),
          OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.vigiLiteCyan,
                  side: const BorderSide(color: AppColors.vigiLiteBorder)),
              child: const Text('Retry')),
        ]),
      ),
    );
  }
  return null;
}

/// A number with a label, colour-tinted. When [onTap] is given (this stat
/// has a matching filter chip — e.g. the "ACTIVE" tile and the "Active"
/// filter), [selected] fills it solidly instead of just a light tint, so
/// which filter is currently applied is obvious at a glance from the
/// summary row itself, not just from the small chip below it. Tapping the
/// tile also applies that filter, the same as tapping its chip.
class AdminStatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  const AdminStatChip({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: selected ? color : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: selected ? color : color.withValues(alpha: 0.2),
            width: selected ? 1.5 : 1),
        boxShadow: selected
            ? [
                BoxShadow(
                    color: color.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 3))
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: GoogleFonts.dmSans(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : color)),
          Text(label,
              style: GoogleFonts.dmMono(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? Colors.white.withValues(alpha: 0.9)
                      : AppColors.vigiLiteText3,
                  letterSpacing: 0.4)),
        ],
      ),
    );
    if (onTap == null) return tile;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: TapScale(onTap: onTap, child: tile),
    );
  }
}

/// Counters that reflow to 6 / 3 / 2 columns by available width.
class AdminSummaryGrid extends StatelessWidget {
  final List<AdminStatChip> chips;
  final double width;
  const AdminSummaryGrid({super.key, required this.chips, required this.width});

  @override
  Widget build(BuildContext context) {
    final cols = width >= 800 ? 6 : (width >= 480 ? 3 : 2);
    const gap = 8.0;
    final itemWidth = (width - gap * (cols - 1)) / cols;
    return Wrap(spacing: gap, runSpacing: gap, children: [
      for (final c in chips) SizedBox(width: itemWidth, child: c),
    ]);
  }
}

/// Search box + filter chips + "Showing N of M" line.
class AdminToolbar<T> extends StatelessWidget {
  final String hint;
  final String noun; // "account", "vehicle"
  final T filter;
  final Map<T, String> filters;
  final ValueChanged<String> onQuery;
  final ValueChanged<T> onFilter;
  final int shown;
  final int total;
  const AdminToolbar({
    super.key,
    required this.hint,
    required this.noun,
    required this.filter,
    required this.filters,
    required this.onQuery,
    required this.onFilter,
    required this.shown,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final search = TextField(
      onChanged: onQuery,
      style: GoogleFonts.dmSans(fontSize: 14, color: AppColors.vigiLiteText),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle:
            GoogleFonts.dmSans(fontSize: 13, color: AppColors.vigiLiteText3),
        prefixIcon:
            const Icon(Icons.search, size: 20, color: AppColors.vigiLiteText3),
        isDense: true,
        filled: true,
        fillColor: AppColors.vigiLiteInput,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.vigiLiteBorder)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.vigiLiteBorder)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                const BorderSide(color: AppColors.vigiLiteCyan, width: 1.5)),
      ),
    );
    final chips = Wrap(spacing: 6, runSpacing: 4, children: [
      for (final e in filters.entries)
        ChoiceChip(
          label: Text(e.value),
          selected: filter == e.key,
          onSelected: (_) => onFilter(e.key),
          backgroundColor: AppColors.vigiLiteInput,
          selectedColor: AppColors.vigiLiteCyan,
          side: BorderSide(
              color: filter == e.key
                  ? AppColors.vigiLiteCyan
                  : AppColors.vigiLiteBorder),
          labelStyle: GoogleFonts.dmSans(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: filter == e.key
                  ? AppColors.vigiLiteText
                  : AppColors.vigiLiteText2),
        ),
    ]);
    return LayoutBuilder(
      builder: (context, c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (c.maxWidth >= 700)
            Row(children: [
              Expanded(child: search),
              const SizedBox(width: 12),
              chips,
            ])
          else ...[
            search,
            const SizedBox(height: 8),
            chips,
          ],
          const SizedBox(height: 6),
          Text('Showing $shown of $total $noun(s)',
              style: GoogleFonts.dmSans(
                  fontSize: 11.5, color: AppColors.vigiLiteText3)),
        ],
      ),
    );
  }
}

/// One label/value line of a detail card.
class AdminInfo {
  final String label;
  final String value;
  final bool selectable;
  const AdminInfo(this.label, this.value, {this.selectable = false});
}

/// A bordered card of label/value lines separated by hairlines.
class AdminInfoCard extends StatelessWidget {
  final List<AdminInfo> rows;
  const AdminInfoCard(this.rows, {super.key});

  @override
  Widget build(BuildContext context) {
    final valueStyle =
        GoogleFonts.dmSans(fontSize: 13, color: AppColors.vigiLiteText);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
          color: AppColors.vigiLiteCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.vigiLiteBorder, width: 0.8)),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
                border: i == rows.length - 1
                    ? null
                    : const Border(
                        bottom: BorderSide(
                            color: AppColors.vigiLiteBorder, width: 0.6))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                  width: 120,
                  child: Text(rows[i].label,
                      style: GoogleFonts.dmMono(
                          fontSize: 11,
                          color: AppColors.vigiLiteText3,
                          fontWeight: FontWeight.w700))),
              Expanded(
                  child: rows[i].selectable
                      ? SelectableText(rows[i].value, style: valueStyle)
                      : Text(rows[i].value, style: valueStyle)),
            ]),
          ),
      ]),
    );
  }
}

/// A labelled photo (or "Not submitted") that opens full-size on click — for
/// the driver's license sides and a vehicle's OR / CR.
class AdminPhotoTile extends StatelessWidget {
  final String label;
  final Uint8List? bytes;
  final double height;
  const AdminPhotoTile(
      {super.key, required this.label, required this.bytes, this.height = 150});

  @override
  Widget build(BuildContext context) => Column(children: [
        Text(label,
            style: GoogleFonts.dmMono(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: AppColors.vigiLiteText3)),
        const SizedBox(height: 6),
        bytes == null
            ? Container(
                height: height,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AppColors.vigiLiteInput,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.vigiLiteBorder)),
                child: Text('Not submitted',
                    style: GoogleFonts.dmSans(
                        fontSize: 12, color: AppColors.vigiLiteText3)))
            : GestureDetector(
                onTap: () => showPhotoViewer(context, bytes!),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(bytes!,
                      height: height,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      gaplessPlayback: true),
                ),
              ),
      ]);
}

/// The closest Material icon for a vehicle's free-text `type` field (e.g.
/// "Sedan", "SUV", "Hatchback", "Wagon") — Material has no distinct icon per
/// body style, so only the few types with a genuinely different silhouette
/// (motorcycle, van, truck, bus) get their own icon; every car-shaped type
/// falls back to the same generic car icon rather than guessing.
IconData vehicleTypeIcon(String type) {
  final t = type.toLowerCase();
  if (t.contains('motor') || t.contains('scooter') || t.contains('tricycle')) {
    return Icons.two_wheeler;
  }
  if (t.contains('van')) return Icons.airport_shuttle;
  if (t.contains('truck') || t.contains('pickup')) return Icons.local_shipping;
  if (t.contains('bus')) return Icons.directions_bus;
  return Icons.directions_car;
}

/// A vehicle's type as a small, neutral icon in a rounded tile — a simple,
/// consistent stand-in for a vehicle photo (none is captured anywhere in
/// this app), used by both the Vehicles tab and an account's vehicle list
/// wherever a row needs a quick visual anchor.
class VehicleTypeIcon extends StatelessWidget {
  final String type;
  final double size;
  const VehicleTypeIcon({super.key, required this.type, this.size = 36});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: AppColors.vigiLiteCyan.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(size * 0.3)),
        child: Icon(vehicleTypeIcon(type),
            size: size * 0.52, color: AppColors.vigiLiteCyan),
      );
}

/// Full-screen, zoomable view of a photo.
void showPhotoViewer(BuildContext context, Uint8List bytes) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(16),
      child: Stack(children: [
        InteractiveViewer(child: Center(child: Image.memory(bytes))),
        Positioned(
          top: 4,
          right: 4,
          child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(ctx)),
        ),
      ]),
    ),
  );
}
