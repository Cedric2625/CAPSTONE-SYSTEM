import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../utils/app_theme.dart';
import '../models/models.dart';

// ─── TAP SCALE WRAPPER (button press feedback used across the app) ───
class TapScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool haptic;
  const TapScale(
      {super.key,
      required this.child,
      required this.onTap,
      this.haptic = true});

  @override
  State<TapScale> createState() => _TapScaleState();
}

class _TapScaleState extends State<TapScale> {
  double _scale = 1.0;

  void _setPressed(bool pressed) {
    if (widget.onTap == null) return;
    setState(() => _scale = pressed ? 0.96 : 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic) HapticFeedback.lightImpact();
              widget.onTap!();
            },
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// ─── CONFIRM DIALOG (used before destructive / high-stakes actions) ───
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  Color confirmColor = AppColors.primary,
  IconData icon = Icons.warning_amber_rounded,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      // Capped so this doesn't stretch edge-to-edge on a wide browser
      // window (the admin dashboard is the one place this is shown on a
      // screen wider than a phone) — on a phone the screen itself is
      // already narrower than this, so nothing changes there.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                    color: confirmColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle),
                child: Icon(icon, color: confirmColor, size: 26),
              ),
              const SizedBox(height: 14),
              Text(title,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text)),
              const SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(
                      fontSize: 13, color: AppColors.text3, height: 1.5)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                            color: AppColors.border, width: 1.5),
                        minimumSize: const Size(0, 46),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(cancelLabel,
                          style: GoogleFonts.dmSans(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.text2)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: confirmColor,
                        elevation: 0,
                        minimumSize: const Size(0, 46),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        Navigator.pop(ctx, true);
                      },
                      child: Text(confirmLabel,
                          style: GoogleFonts.dmSans(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return result ?? false;
}

/// Shows a small top-of-screen style success/failure toast using a SnackBar,
/// so every important action gives clear feedback (prompt §23).
void showResultToast(BuildContext context,
    {required String message, required bool success}) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: success ? AppColors.green : AppColors.primary,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    content: Row(
      children: [
        Icon(success ? Icons.check_circle_outline : Icons.error_outline,
            color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Text(message,
                style: GoogleFonts.dmSans(
                    fontSize: 13,
                    color: Colors.white,
                    fontWeight: FontWeight.w600))),
      ],
    ),
  ));
}

/// A blocking "please wait" dialog for an action that takes a moment (like
/// signing in or sending a sighting over the network) — it can't be
/// dismissed by tapping outside or pressing back, so the person can't leave
/// mid-operation or tap Submit twice. Not awaited by callers: start it, do
/// the work, then close it with `Navigator.of(context).pop()`.
Future<void> showLoadingModal(BuildContext context,
    {String message = 'Please wait…'}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 44),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 30),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(22)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 76,
                height: 76,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const SizedBox(
                      width: 76,
                      height: 76,
                      child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: AppColors.teal,
                          backgroundColor: AppColors.tealAccent),
                    ),
                    ClipOval(
                      child: Image.asset('assets/images/app_icon.png',
                          width: 54, height: 54, fit: BoxFit.cover),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('VIGILINK',
                  style: GoogleFonts.dmSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppColors.charcoal)),
              const SizedBox(height: 6),
              Text(message,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.text2)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Shows a celebratory modal for a major completed action (account created,
/// vehicle registered, geofence saved, …) — reserved for milestones worth
/// interrupting the user for; routine confirmations should stay as
/// [showResultToast]. Previously duplicated privately in the auth screens;
/// centralized here so every screen gets the same look for free.
Future<void> showSuccessModal(BuildContext context,
    {required String title,
    String? message,
    IconData icon = Icons.check_circle}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(20)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                  color: AppColors.greenLight, shape: BoxShape.circle),
              child: Icon(icon, color: AppColors.green, size: 30),
            ).animate().scale(
                duration: 320.ms,
                curve: Curves.elasticOut,
                begin: const Offset(0.4, 0.4)),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text)),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style:
                      GoogleFonts.dmSans(fontSize: 13, color: AppColors.text3)),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.teal,
                  elevation: 0,
                  minimumSize: const Size(0, 46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: Text('Continue',
                    style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(duration: 200.ms)
        .scale(begin: const Offset(0.94, 0.94), curve: Curves.easeOutCubic),
  );
}

// ─── SECTION LABEL ───
class SectionLabel extends StatelessWidget {
  final String text;
  // Defaults to false (unchanged everywhere else). Every call site that
  // passes `dark: true` is on a VIGILINK Lite screen (Home, Map, Alerts,
  // Profile/Settings, admin dashboard) — the flag now renders the Lite
  // muted-navy label color rather than the old dark-navy one.
  final bool dark;
  const SectionLabel(this.text, {super.key, this.dark = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: GoogleFonts.dmMono(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: dark ? AppColors.vigiLiteText2 : AppColors.text3,
              letterSpacing: 0.5,
            )),
      );
}

// ─── APP CARD ───
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final Color? color;
  // Defaults to AppColors.border (unchanged everywhere this isn't passed) —
  // VIGILINK-dark screens pass AppColors.vigiBorder alongside a vigiCard
  // `color` so the card's outline matches its own dark fill.
  final Color? borderColor;
  const AppCard(
      {super.key,
      required this.child,
      this.padding,
      this.color,
      this.borderColor});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color ?? AppColors.white,
          borderRadius: BorderRadius.circular(16),
          border:
              Border.all(color: borderColor ?? AppColors.border, width: 0.8),
        ),
        child: child,
      );
}

// ─── BADGE ───
class StatusBadge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  final bool withDot;
  const StatusBadge(
      {super.key,
      required this.label,
      required this.bg,
      required this.fg,
      this.withDot = false});

  factory StatusBadge.active() => const StatusBadge(
      label: 'NOT STOLEN',
      bg: AppColors.greenLight,
      fg: Color(0xFF166534),
      withDot: true);
  factory StatusBadge.stolen() => const StatusBadge(
      label: 'STOLEN',
      bg: AppColors.primaryLight,
      fg: AppColors.primaryDark,
      withDot: true);
  factory StatusBadge.recovered() => const StatusBadge(
      label: 'RECOVERED', bg: AppColors.greenLight, fg: Color(0xFF166534));
  factory StatusBadge.resolved() => const StatusBadge(
      label: 'RESOLVED', bg: AppColors.grayLight, fg: AppColors.gray);
  factory StatusBadge.online() => const StatusBadge(
      label: 'LIVE',
      bg: AppColors.greenLight,
      fg: Color(0xFF166534),
      withDot: true);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (withDot) ...[
              Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
              const SizedBox(width: 4),
            ],
            Text(label,
                style: GoogleFonts.dmMono(
                    fontSize: 10, fontWeight: FontWeight.w700, color: fg)),
          ],
        ),
      );
}

// ─── FORM FIELD WIDGET ───
class AppTextField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final bool readOnly;
  final Widget? suffix;
  final bool uppercase;
  // Defaults to false, which every existing call site relies on implicitly
  // (looks exactly as it did before this was added) — only screens migrated
  // to the VIGILINK dark palette pass `dark: true` for a dark input fill,
  // light text, and a cyan focus outline instead of the app's usual light
  // field + teal focus outline.
  final bool dark;
  // VIGILINK Lite screens (Home, Map, Alerts, Profile/Settings, and their
  // action forms) pass `lite: true` instead — a white/pale-blue field with
  // navy text and a cyan focus outline. Takes precedence over `dark`; the
  // two are never both true from any call site.
  final bool lite;
  const AppTextField({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
    this.obscure = false,
    this.keyboardType,
    this.validator,
    this.readOnly = false,
    this.suffix,
    this.uppercase = false,
    this.dark = false,
    this.lite = false,
  });

  @override
  Widget build(BuildContext context) {
    final labelColor = lite
        ? AppColors.vigiLiteText2
        : (dark ? AppColors.vigiText3 : AppColors.text3);
    final valueColor = lite
        ? (readOnly ? AppColors.vigiLiteText3 : AppColors.vigiLiteText)
        : (dark
            ? (readOnly ? AppColors.vigiText3 : AppColors.vigiText)
            : (readOnly ? AppColors.text3 : AppColors.text));
    final fillColor = lite
        ? AppColors.vigiLiteInput
        : (dark
            ? AppColors.vigiInput
            : (readOnly ? const Color(0xFFF3F4F6) : AppColors.bg));
    final borderColor = lite ? AppColors.vigiLiteBorder : AppColors.vigiBorder;
    final focusColor = lite ? AppColors.vigiLiteCyan : AppColors.vigiCyan;
    final hasOutline = lite || dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: GoogleFonts.dmMono(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: labelColor,
                letterSpacing: 0.4)),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          validator: validator,
          readOnly: readOnly,
          textCapitalization: uppercase
              ? TextCapitalization.characters
              : TextCapitalization.none,
          style: GoogleFonts.dmSans(fontSize: 14, color: valueColor),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: (lite || dark)
                ? GoogleFonts.dmSans(
                    fontSize: 14,
                    color: lite ? AppColors.vigiLiteText3 : AppColors.vigiText3)
                : null,
            suffixIcon: suffix,
            filled: true,
            fillColor: fillColor,
            border: hasOutline
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: borderColor))
                : null,
            enabledBorder: hasOutline
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: borderColor))
                : null,
            focusedBorder: hasOutline
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: focusColor, width: 1.5))
                : null,
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }
}

// ─── APP BOTTOM NAVIGATION BAR ───
// One shared bottom nav, used by every screen that has one — the exact same
// set of 4 destinations (icons, labels, colors) used to be hand-coded twice
// (once here, once again directly inside HomeScreen); this is the one
// definition both now use. Callers keep full control of what selecting a
// tab actually does (see [onTap]) — only the look is shared.
class AppBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  // Defaults to false (unchanged everywhere else). Every call site that
  // passes `dark: true` is on a VIGILINK Lite screen — white bar, muted
  // navy-gray unselected icons/labels, cyan selected state on a pale-cyan
  // rounded indicator.
  final bool dark;
  const AppBottomNav(
      {super.key,
      required this.currentIndex,
      required this.onTap,
      this.dark = false});

  @override
  Widget build(BuildContext context) {
    final accent = dark ? AppColors.vigiLiteCyan : AppColors.teal;
    final unselected = dark ? AppColors.vigiLiteText3 : null;
    Widget dest(IconData outline, IconData filled, String label) =>
        NavigationDestination(
            icon: Icon(outline, color: unselected),
            selectedIcon: Icon(filled, color: accent),
            label: label);
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: onTap,
      backgroundColor: dark ? AppColors.vigiLiteCard : Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: dark ? AppColors.vigiLiteTeal : AppColors.tealLight,
      labelTextStyle: dark
          ? WidgetStateProperty.resolveWith((states) => GoogleFonts.dmSans(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: states.contains(WidgetState.selected)
                  ? accent
                  : AppColors.vigiLiteText3))
          : null,
      destinations: [
        dest(Icons.home_outlined, Icons.home, 'Home'),
        dest(Icons.map_outlined, Icons.map, 'Map'),
        dest(Icons.warning_amber_outlined, Icons.warning_amber, 'Alerts'),
        dest(Icons.person_outline, Icons.person, 'Profile'),
      ],
    );
  }
}

// ─── SEARCHABLE SELECT FIELD (type-ahead dropdown, still free-text) ───
// Used by RegisterVehicleScreen for Model/Color: filters [options] live as
// the user types, for a faster pick from a long list. Like AppTextField, it
// never blocks arbitrary text — an option missing from the list can just be
// typed directly, so a value not in [options] (e.g. "Other", or anything
// else) is never treated as invalid.
class SearchableSelectField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> options;
  final String? Function(String?)? validator;
  // Defaults to false (unchanged everywhere else) — VIGILINK-dark screens
  // pass `dark: true` for a dark fill, light text, and a cyan accent.
  final bool dark;
  // VIGILINK Lite screens pass `lite: true` instead — a white/pale-blue
  // fill, navy text, and a cyan accent. Takes precedence over `dark`.
  // [VehicleFormSection] is embedded (dark) inside Register but also used
  // standalone (lite) from Home/Profile, so both flags are threaded through
  // from there rather than one being hardcoded.
  final bool lite;
  const SearchableSelectField({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
    required this.focusNode,
    required this.options,
    this.validator,
    this.dark = false,
    this.lite = false,
  });

  @override
  Widget build(BuildContext context) {
    final labelColor = lite
        ? AppColors.vigiLiteText2
        : (dark ? AppColors.vigiText3 : AppColors.text3);
    final valueColor = lite
        ? AppColors.vigiLiteText
        : (dark ? AppColors.vigiText : AppColors.text);
    final hintColor = lite ? AppColors.vigiLiteText3 : AppColors.vigiText3;
    final fillColor = lite
        ? AppColors.vigiLiteInput
        : (dark ? AppColors.vigiInput : AppColors.bg);
    final iconColor = lite
        ? AppColors.vigiLiteText3
        : (dark ? AppColors.vigiText3 : AppColors.text3);
    final borderColor = lite ? AppColors.vigiLiteBorder : AppColors.vigiBorder;
    final focusColor = lite ? AppColors.vigiLiteCyan : AppColors.vigiCyan;
    final hasOutline = lite || dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: GoogleFonts.dmMono(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: labelColor,
                letterSpacing: 0.4)),
        const SizedBox(height: 6),
        RawAutocomplete<String>(
          textEditingController: controller,
          focusNode: focusNode,
          optionsBuilder: (value) {
            if (value.text.isEmpty) return options;
            final q = value.text.toLowerCase();
            return options.where((o) => o.toLowerCase().contains(q));
          },
          onSelected: (selection) {
            // "Other" isn't a real value — clear the field so the user types
            // the actual model/color fresh instead of saving the word "Other".
            if (selection == 'Other') controller.clear();
          },
          fieldViewBuilder:
              (context, fieldController, fieldFocusNode, onFieldSubmitted) =>
                  TextFormField(
            controller: fieldController,
            focusNode: fieldFocusNode,
            validator: validator,
            style: GoogleFonts.dmSans(fontSize: 14, color: valueColor),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: (lite || dark)
                  ? GoogleFonts.dmSans(fontSize: 14, color: hintColor)
                  : null,
              filled: true,
              fillColor: fillColor,
              suffixIcon: Icon(Icons.search, size: 18, color: iconColor),
              border: hasOutline
                  ? OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor))
                  : null,
              enabledBorder: hasOutline
                  ? OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor))
                  : null,
              focusedBorder: hasOutline
                  ? OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: focusColor, width: 1.5))
                  : null,
            ),
          ),
          optionsViewBuilder: (context, onSelected, resultOptions) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxHeight: 240, minWidth: 260),
                child: resultOptions.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text('No match — you can still type your own.',
                            style: GoogleFonts.dmSans(
                                fontSize: 12.5, color: AppColors.text3)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        shrinkWrap: true,
                        itemCount: resultOptions.length,
                        itemBuilder: (context, index) {
                          final option = resultOptions.elementAt(index);
                          return ListTile(
                            dense: true,
                            title: Text(option,
                                style: GoogleFonts.dmSans(
                                    fontSize: 13.5, color: AppColors.text)),
                            onTap: () => onSelected(option),
                          );
                        },
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }
}

// ─── PRIMARY BUTTON ───
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  // Defaults to white, which every existing call site relies on implicitly
  // (plain `PrimaryButton(...)` with no textColor keeps looking exactly as
  // it did before this was added) — only the VIGILINK cyan buttons pass a
  // dark textColor for contrast on a light cyan background.
  final Color textColor;
  final IconData? icon;
  final bool loading;
  const PrimaryButton(
      {super.key,
      required this.label,
      required this.onTap,
      this.color,
      this.textColor = Colors.white,
      this.icon,
      this.loading = false});

  @override
  Widget build(BuildContext context) => TapScale(
        onTap: loading ? null : onTap,
        child: Container(
          width: double.infinity,
          height: 52,
          decoration: BoxDecoration(
            color: (loading
                ? (color ?? AppColors.teal).withValues(alpha: 0.7)
                : (color ?? AppColors.teal)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: loading
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: textColor))
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 20, color: textColor),
                        const SizedBox(width: 8)
                      ],
                      Text(label,
                          style: GoogleFonts.dmSans(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: textColor)),
                    ],
                  ),
          ),
        ),
      );
}

// ─── OUTLINE BUTTON ───
class OutlineButton2 extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  // Defaults to false (unchanged everywhere else). Every call site that
  // passes `dark: true` is on a VIGILINK Lite screen — navy outline/text
  // on the white Lite background.
  final bool dark;
  const OutlineButton2(
      {super.key, required this.label, required this.onTap, this.dark = false});

  @override
  Widget build(BuildContext context) => TapScale(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: dark ? AppColors.vigiLiteBorder : AppColors.border,
                width: 1.5),
          ),
          child: Center(
            child: Text(label,
                style: GoogleFonts.dmSans(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: dark ? AppColors.vigiLiteText2 : AppColors.text2)),
          ),
        ),
      );
}

// ─── VEHICLE CARD ───
class VehicleCard extends StatelessWidget {
  final VehicleModel vehicle;
  final VoidCallback? onTap;
  final VoidCallback? onGeofence;
  final VoidCallback? onDeactivateGeofence;
  final VoidCallback? onRemove;
  final VoidCallback? onRecover;
  // Defaults to false (unchanged everywhere else). Every call site that
  // passes `dark: true` is on a VIGILINK Lite screen — white card fill and
  // navy text instead of the plain-light defaults.
  final bool dark;
  const VehicleCard(
      {super.key,
      required this.vehicle,
      this.onTap,
      this.onGeofence,
      this.onDeactivateGeofence,
      this.onRemove,
      this.onRecover,
      this.dark = false});

  @override
  Widget build(BuildContext context) {
    final icon = vehicle.type == 'SUV'
        ? '🚙'
        : vehicle.type == 'Hatchback'
            ? '🚘'
            : '🚗';
    final critical = dark ? AppColors.vigiLiteCritical : AppColors.primary;
    final borderColor = dark ? AppColors.vigiLiteBorder : AppColors.border;
    final mutedText = dark ? AppColors.vigiLiteText2 : AppColors.text3;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: dark ? AppColors.vigiLiteCard : AppColors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: vehicle.status == VehicleStatus.stolen
                  ? critical.withValues(alpha: 0.4)
                  : borderColor,
              width: vehicle.status == VehicleStatus.stolen ? 1.5 : 0.8),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                        color:
                            dark ? AppColors.vigiLiteTeal : AppColors.grayLight,
                        borderRadius: BorderRadius.circular(12)),
                    child: Center(
                        child:
                            Text(icon, style: const TextStyle(fontSize: 22))),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(vehicle.plate,
                            style: GoogleFonts.dmMono(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                                color: dark
                                    ? AppColors.vigiLiteText
                                    : AppColors.text)),
                        const SizedBox(height: 2),
                        Text(
                            '${vehicle.model} · ${vehicle.color} · ${vehicle.type}',
                            style: GoogleFonts.dmSans(
                                fontSize: 12, color: mutedText)),
                        const SizedBox(height: 5),
                        _statusBadge(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: dark ? AppColors.vigiLiteBg : AppColors.bg,
                borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16)),
                border: Border(top: BorderSide(color: borderColor, width: 0.8)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                        vehicle.geofenceActive
                            ? 'Geofence: ${vehicle.geofenceRadius.toInt()}m (Active)'
                            : 'Geofence: Not configured',
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.dmSans(
                            fontSize: 12,
                            color: vehicle.geofenceActive
                                ? (dark
                                    ? AppColors.vigiLiteSuccess
                                    : AppColors.green)
                                : mutedText,
                            fontWeight: vehicle.geofenceActive
                                ? FontWeight.w600
                                : FontWeight.w400)),
                  ),
                  const SizedBox(width: 8),
                  // Wrap (not a fixed Row of buttons) so a vehicle with an
                  // active geofence — which shows one more button than the
                  // default two — gracefully drops to a second line on a
                  // narrow screen instead of overflowing.
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (vehicle.status == VehicleStatus.stolen &&
                          onRecover != null)
                        _actionBtn(
                            '✅ Recovered',
                            dark ? AppColors.vigiLiteSuccess : AppColors.green,
                            onRecover!),
                      if (vehicle.geofenceActive &&
                          onDeactivateGeofence != null)
                        _actionBtn(
                            'Turn Off',
                            dark ? AppColors.vigiLiteWarning : AppColors.amber,
                            onDeactivateGeofence!),
                      if (onGeofence != null)
                        _actionBtn(
                            'Geofence',
                            dark ? AppColors.vigiLiteInfo : AppColors.blue,
                            onGeofence!),
                      if (onRemove != null)
                        _actionBtn('Remove', critical, onRemove!),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge() {
    switch (vehicle.status) {
      case VehicleStatus.active:
        return StatusBadge.active();
      case VehicleStatus.stolen:
        return StatusBadge.stolen();
      case VehicleStatus.recovered:
        return StatusBadge.recovered();
    }
  }

  Widget _actionBtn(String label, Color color, VoidCallback onTap) => TapScale(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.3))),
          child: Text(label,
              style: GoogleFonts.dmSans(
                  fontSize: 11, fontWeight: FontWeight.w700, color: color)),
        ),
      );
}

// ─── ALERT LOG ITEM ───
class AlertLogItem extends StatelessWidget {
  final TheftAlert alert;
  final VoidCallback? onUpdateStatus;

  /// Opens the alert's detail screen (report a sighting / view sightings).
  /// Alert cards used to be plain, untappable containers, so a nearby user
  /// who saw a stolen-vehicle alert had no way to act on it.
  final VoidCallback? onTap;

  /// Short line shown at the bottom of the card saying what tapping it does
  /// (e.g. "Tap to report a sighting") — without it nothing on the card
  /// suggests it is tappable.
  final String? hint;
  const AlertLogItem(
      {super.key,
      required this.alert,
      this.onUpdateStatus,
      this.onTap,
      this.hint});

  @override
  Widget build(BuildContext context) {
    Color headBg, iconBg;
    IconData icon;
    switch (alert.status) {
      case AlertStatus.active:
        headBg = AppColors.vigiLiteCritical.withValues(alpha: 0.10);
        iconBg = AppColors.vigiLiteCritical.withValues(alpha: 0.16);
        icon = Icons.warning_amber_rounded;
        break;
      case AlertStatus.recovered:
        headBg = AppColors.vigiLiteSuccess.withValues(alpha: 0.10);
        iconBg = AppColors.vigiLiteSuccess.withValues(alpha: 0.16);
        icon = Icons.check_circle_outline;
        break;
      case AlertStatus.resolved:
        headBg = AppColors.vigiLiteBg;
        iconBg = AppColors.vigiLiteBg;
        icon = Icons.article_outlined;
    }
    return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
              color: AppColors.vigiLiteCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.vigiLiteBorder, width: 0.8)),
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                    color: headBg,
                    borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(14),
                        topRight: Radius.circular(14))),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                          color: iconBg,
                          borderRadius: BorderRadius.circular(10)),
                      child: Icon(icon,
                          color: alert.status == AlertStatus.active
                              ? AppColors.vigiLiteCritical
                              : alert.status == AlertStatus.recovered
                                  ? AppColors.vigiLiteSuccess
                                  : AppColors.vigiLiteText3,
                          size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(alert.plate,
                              style: GoogleFonts.dmMono(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                  color: AppColors.vigiLiteText)),
                          Text('${alert.model} · ${alert.color}',
                              style: GoogleFonts.dmSans(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.vigiLiteText2)),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _statusBadge(alert.status),
                        const SizedBox(height: 3),
                        Text(_formatTime(alert.timestamp),
                            style: GoogleFonts.dmMono(
                                fontSize: 10, color: AppColors.vigiLiteText3)),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: 14, runSpacing: 4, children: [
                      _metaChip('⚡ ${alert.triggerLabel}'),
                      _metaChip('🔗 Hop ${alert.hopCount}'),
                      _metaChip('📡 ${alert.relayedTo.length} nodes'),
                      if (alert.hasPhoto) _metaChip('📷 Photo attached'),
                      if (alert.notes.isNotEmpty)
                        _metaChip('📝 ${alert.notes}'),
                      if (alert.status != AlertStatus.active &&
                          alert.hasRecoveryPhoto)
                        _metaChip('✅ Recovery proof attached'),
                    ]),
                    if (alert.status == AlertStatus.active &&
                        onUpdateStatus != null) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        height: 38,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.vigiLiteSuccess,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              elevation: 0),
                          onPressed: onUpdateStatus,
                          child: Text('Update Status →',
                              style: GoogleFonts.dmSans(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                        ),
                      ),
                    ],
                    if (hint != null) ...[
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                          child: Text(hint!,
                              style: GoogleFonts.dmSans(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.vigiLiteInfo)),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 18, color: AppColors.vigiLiteInfo),
                      ]),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ));
  }

  Widget _statusBadge(AlertStatus s) {
    switch (s) {
      case AlertStatus.active:
        return StatusBadge.stolen();
      case AlertStatus.recovered:
        return StatusBadge.recovered();
      case AlertStatus.resolved:
        return StatusBadge.resolved();
    }
  }

  Widget _metaChip(String text) => Text(text,
      style: GoogleFonts.dmSans(fontSize: 12, color: AppColors.vigiLiteText2));

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

// ─── NODE RELAY ROW ───
class NodeRelayRow extends StatelessWidget {
  final AdHocNode node;
  const NodeRelayRow({super.key, required this.node});

  @override
  Widget build(BuildContext context) {
    Color iconBg;
    String statusText;
    Color statusColor;
    switch (node.relayStatus) {
      case RelayStatus.received:
        iconBg = AppColors.orangeLight;
        statusText = '✓ Received';
        statusColor = AppColors.orange;
        break;
      case RelayStatus.relaying:
        iconBg = AppColors.yellowLight;
        statusText = '⟳ Relaying';
        statusColor = AppColors.yellow;
        break;
      case RelayStatus.pending:
        iconBg = AppColors.grayLight;
        statusText = 'Pending';
        statusColor = AppColors.gray;
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
          border: Border(
              bottom: BorderSide(color: AppColors.vigiLiteBorder, width: 0.6))),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
            child:
                const Center(child: Text('📱', style: TextStyle(fontSize: 16))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(node.name,
                    style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.vigiLiteText)),
                Text(
                    '${node.distance < 0 ? "Nearby" : "${node.distance.toInt()}m away"} · ${node.connectionLabel}',
                    style: GoogleFonts.dmMono(
                        fontSize: 10, color: AppColors.vigiLiteText3)),
              ],
            ),
          ),
          Text(statusText,
              style: GoogleFonts.dmSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: statusColor)),
        ],
      ),
    );
  }
}

// ─── PROXIMITY NODE ROW ───
class ProximityNodeRow extends StatelessWidget {
  final AdHocNode node;
  const ProximityNodeRow({super.key, required this.node});

  @override
  Widget build(BuildContext context) {
    // Real nodes (distance == -1, unknown — raw BLE/Wi-Fi Direct doesn't
    // expose range) get a meaningful bar based on connection state instead
    // of feeding a negative number into the same formula simulated nodes use.
    final pct = node.distance < 0
        ? (node.isOnline ? 1.0 : 0.3)
        : (node.distance / 100).clamp(0.1, 1.0);
    Color barColor;
    switch (node.relayStatus) {
      case RelayStatus.received:
        barColor = AppColors.orange;
        break;
      case RelayStatus.relaying:
        barColor = AppColors.yellow;
        break;
      case RelayStatus.pending:
        barColor = AppColors.vigiLiteInfo;
    }
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: AppColors.vigiLiteCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.vigiLiteBorder, width: 0.8)),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
                color: node.isOnline
                    ? AppColors.vigiLiteSuccess.withValues(alpha: 0.14)
                    : AppColors.vigiLiteBg,
                shape: BoxShape.circle,
                border: Border.all(
                    color: node.isOnline
                        ? AppColors.vigiLiteSuccess.withValues(alpha: 0.4)
                        : AppColors.vigiLiteBorder)),
            child:
                const Center(child: Text('📱', style: TextStyle(fontSize: 18))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(node.name,
                    style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.vigiLiteText)),
                Text(
                    '${node.distance < 0 ? "Nearby" : "${node.distance.toInt()}m"} · ${node.connectionLabel} · ${node.isOnline ? "Connected" : "Offline"}',
                    style: GoogleFonts.dmMono(
                        fontSize: 10, color: AppColors.vigiLiteText3)),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: AppColors.vigiLiteBorder,
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    minHeight: 5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _badge(node.relayStatus),
        ],
      ),
    );
  }

  Widget _badge(RelayStatus s) {
    switch (s) {
      case RelayStatus.received:
        // Not StatusBadge.active() — that factory's label is hardcoded to
        // "NOT STOLEN", meant for a vehicle's status, not a relay node's.
        return const StatusBadge(
            label: '✓ Received',
            bg: AppColors.orangeLight,
            fg: AppColors.orange,
            withDot: true);
      case RelayStatus.relaying:
        return const StatusBadge(
            label: '⟳', bg: AppColors.yellowLight, fg: AppColors.yellow);
      case RelayStatus.pending:
        return const StatusBadge(
            label: 'Pending', bg: AppColors.grayLight, fg: AppColors.gray);
    }
  }
}

/// A single-button error/warning modal. Built on [showConfirmDialog] with one
/// "OK" so every error looks the same across the app.
/// A genuinely single-button modal — its own dialog, not [showConfirmDialog]
/// with both labels set to "OK". That used to render two side-by-side
/// buttons that both said "OK", which read as a bug (because it was one):
/// [showConfirmDialog] always draws a Cancel/Confirm pair, and passing the
/// same label for both doesn't collapse them into one. This mirrors
/// [showSuccessModal]'s single full-width button instead.
Future<void> showErrorModal(BuildContext context,
    {required String title,
    required String message,
    IconData icon = Icons.error_outline,
    Color color = AppColors.primary}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(20)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 30),
            ).animate().scale(
                duration: 320.ms,
                curve: Curves.elasticOut,
                begin: const Offset(0.4, 0.4)),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                    fontSize: 13, color: AppColors.text3, height: 1.5)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: color,
                  elevation: 0,
                  minimumSize: const Size(0, 46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: Text('OK',
                    style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(duration: 200.ms)
        .scale(begin: const Offset(0.94, 0.94), curve: Curves.easeOutCubic),
  );
}

/// Full-screen, pinch-to-zoom view of a photo — shared by every screen that
/// shows a decoded evidence photo (a sighting's, and a theft report's),
/// rather than each screen keeping its own copy of the same dialog.
void showPhotoViewer(BuildContext context, Uint8List bytes) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(12),
      child: Stack(children: [
        InteractiveViewer(
          child:
              Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'Close',
              onPressed: () => Navigator.pop(ctx)),
        ),
      ]),
    ),
  );
}

/// A row of a theft report's evidence photos (1 to 3), each tappable to view
/// full-size via [showPhotoViewer]. Shown wherever a report's photos appear —
/// the owner's own report, a received alert, and the admin's alert detail —
/// one definition, so those three can't drift apart or show the photos
/// differently from each other.
class PhotoEvidenceRow extends StatelessWidget {
  final List<Uint8List> photos;
  final double height;
  const PhotoEvidenceRow({super.key, required this.photos, this.height = 90});

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) return const SizedBox.shrink();
    return Row(children: [
      for (var i = 0; i < photos.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: GestureDetector(
            onTap: () => showPhotoViewer(context, photos[i]),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(photos[i],
                  height: height,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  gaplessPlayback: true),
            ),
          ),
        ),
      ],
    ]);
  }
}
