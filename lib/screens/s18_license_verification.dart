import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/app_theme.dart';
import '../services/app_state.dart';
import '../widgets/widgets.dart';
import '../widgets/document_photo.dart';

// ══════════════════════════════════════
// DRIVER'S LICENSE VERIFICATION
// ══════════════════════════════════════
// Every account must show a valid Philippine driver's license — a photo of the
// FRONT, then of the BACK, taken with the camera or chosen from the gallery.
// The capture UI ([LicenseCaptureSection]) is part of the REGISTRATION FORM
// itself, as one of its required fields. [LicenseVerificationScreen] wraps
// the same section for the one other case: an account that has no license on
// file (registered before this requirement, or abandoned registration
// halfway) is asked for it at login. The back can't be taken until the front
// is. Every rejection or acceptance shows as a modal, not inline text, so it
// can't be missed mid-form.
//
// The photos are stored as private documents under the account
// (`users/{uid}/license/front|back`) that only the owner and an admin can
// read — see the rules in Progress.md.

/// The front/back camera capture, used inside the registration form and on the
/// login-time verification screen. The parent owns the photos; this only
/// takes them and reports back.
class LicenseCaptureSection extends StatefulWidget {
  final Uint8List? front;
  final Uint8List? back;
  final ValueChanged<Uint8List> onFront;
  final ValueChanged<Uint8List> onBack;
  final bool enabled;

  /// True once a submit attempt found the license still missing — highlights
  /// whichever side (front/back) is still empty red, inline, instead of only
  /// saying so in a popup. See [DocumentPhotoCard.showError].
  final bool showMissingErrors;

  /// Defaults to false (unchanged look everywhere it's already used) —
  /// `true` on screens migrated to the VIGILINK dark palette.
  final bool dark;

  /// `true` on the Register form's license step, now migrated to VIGILINK
  /// Lite — a white card/input style instead of the dark one. Takes
  /// precedence over [dark]; [LicenseVerificationScreen] (the standalone
  /// re-upload screen reached at login) keeps passing `dark: true` and is
  /// unaffected.
  final bool lite;
  const LicenseCaptureSection({
    super.key,
    required this.front,
    required this.back,
    required this.onFront,
    required this.onBack,
    this.enabled = true,
    this.showMissingErrors = false,
    this.dark = false,
    this.lite = false,
  });

  @override
  State<LicenseCaptureSection> createState() => _LicenseCaptureSectionState();
}

class _LicenseCaptureSectionState extends State<LicenseCaptureSection> {
  Future<void> _capture({required bool front}) async {
    final source = await showImageSourceSheet(context,
        title: front ? 'Front of License' : 'Back of License',
        subtitle: 'Take a photo, or choose one already on your phone.');
    if (source == null) return;
    final r = await captureDocumentPhoto(source);
    if (!mounted) return;
    if (r.error != null) {
      await showErrorModal(context,
          title: 'Could Not Add Photo', message: r.error!);
      return;
    }
    if (r.bytes == null) return; // dismissed
    front ? widget.onFront(r.bytes!) : widget.onBack(r.bytes!);
    if (!mounted) return;
    await showSuccessModal(context,
        title: front ? 'Front Captured' : 'Back Captured',
        message: front
            ? 'The front of your license was added. Now add a photo of the back.'
            : 'Both sides of your license were added.');
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.front == null ? 1 : (widget.back == null ? 2 : 3);
    final lite = widget.lite;
    final dark = widget.dark;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _StepBar(step: step, dark: dark, lite: lite),
      const SizedBox(height: 12),
      DocumentPhotoCard(
        title: 'FRONT OF LICENSE',
        active: step == 1,
        enabled: widget.enabled,
        photo: widget.front,
        hint:
            'Your photo, full name, license number, expiration date and DL codes must be readable.',
        buttonLabel:
            widget.front == null ? 'TAKE PHOTO OF FRONT' : 'RETAKE FRONT',
        onCapture: () => _capture(front: true),
        showError: widget.showMissingErrors,
        dark: dark,
        lite: lite,
      ),
      const SizedBox(height: 12),
      DocumentPhotoCard(
        title: 'BACK OF LICENSE',
        active: step == 2,
        enabled: widget.enabled && widget.front != null,
        lockedNote: 'Take the front first.',
        photo: widget.back,
        hint:
            'The DL codes table, conditions and serial number must be readable.',
        buttonLabel: widget.back == null ? 'TAKE PHOTO OF BACK' : 'RETAKE BACK',
        onCapture: () => _capture(front: false),
        showError: widget.showMissingErrors,
        dark: dark,
        lite: lite,
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: lite
                ? AppColors.vigiLiteTeal
                : (dark ? AppColors.vigiCard : AppColors.blueLight),
            borderRadius: BorderRadius.circular(10),
            border: lite
                ? Border.all(color: AppColors.vigiLiteBorder)
                : (dark ? Border.all(color: AppColors.vigiBorder) : null)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline,
              size: 16,
              color: lite
                  ? AppColors.vigiLiteInfo
                  : (dark ? AppColors.vigiInfo : AppColors.blue)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                'Tips: lay the card flat in good light, keep all four corners in view and avoid glare. Your license photos are private — only you and the system administrator can view them, and they are used only to verify your eligibility to drive (R.A. 10173).',
                style: GoogleFonts.dmSans(
                    fontSize: 11.5,
                    height: 1.4,
                    color: lite
                        ? AppColors.vigiLiteText2
                        : (dark ? AppColors.vigiText2 : AppColors.text2))),
          ),
        ]),
      ),
    ]);
  }
}

/// Pops `true` once both photos were uploaded, `false`/null if abandoned.
/// Used at LOGIN for accounts with no license on file.
class LicenseVerificationScreen extends StatefulWidget {
  const LicenseVerificationScreen({super.key});
  @override
  State<LicenseVerificationScreen> createState() =>
      _LicenseVerificationScreenState();
}

class _LicenseVerificationScreenState extends State<LicenseVerificationScreen> {
  Uint8List? _front;
  Uint8List? _back;
  bool _submitting = false;

  Future<void> _submit() async {
    final front = _front, back = _back;
    if (front == null || back == null) return;
    setState(() => _submitting = true);
    showLoadingModal(context, message: 'Submitting your license…');
    final error =
        await context.read<AppState>().submitLicense(front: front, back: back);
    if (!mounted) return;
    Navigator.of(context).pop(); // the loading modal
    setState(() => _submitting = false);
    if (error != null) {
      await showErrorModal(
        context,
        title: 'Could Not Submit',
        message: error,
      );
      return;
    }
    await showSuccessModal(
      context,
      title: 'License Submitted',
      message:
          "Your driver's license photos were received. Thank you for verifying.",
    );
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _confirmLeave() async {
    final leave = await showConfirmDialog(
      context,
      title: 'Leave Verification?',
      message:
          "A driver's license photo is required to use VIGILINK. You can finish it the next time you log in.",
      confirmLabel: 'Leave',
      cancelLabel: 'Stay',
      confirmColor: AppColors.teal,
      icon: Icons.badge_outlined,
    );
    if (leave && mounted) Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _front != null && _back != null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_submitting) _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: AppColors.vigiBg,
        appBar: AppBar(
          backgroundColor: AppColors.vigiBg,
          foregroundColor: AppColors.vigiText,
          automaticallyImplyLeading: false,
          title: const Text("Driver's License"),
          actions: [
            IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: _submitting ? null : _confirmLeave),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text('Verify that you can drive',
                style: GoogleFonts.dmSans(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppColors.vigiText)),
            const SizedBox(height: 6),
            Text(
                "Take a clear photo of the front and then the back of your Philippine driver's license. VIGILINK is for licensed drivers, so this step is required.",
                style: GoogleFonts.dmSans(
                    fontSize: 13, height: 1.45, color: AppColors.vigiText2)),
            const SizedBox(height: 14),
            LicenseCaptureSection(
              front: _front,
              back: _back,
              enabled: !_submitting,
              onFront: (b) => setState(() => _front = b),
              onBack: (b) => setState(() => _back = b),
              dark: true,
            ),
            const SizedBox(height: 18),
            Opacity(
              opacity: ready ? 1 : 0.45,
              child: PrimaryButton(
                  label: 'SUBMIT FOR VERIFICATION',
                  icon: Icons.verified_user_outlined,
                  onTap: ready && !_submitting ? _submit : null,
                  loading: _submitting,
                  color: AppColors.vigiCyan,
                  textColor: AppColors.vigiBg),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _StepBar extends StatelessWidget {
  final int step; // 1 = front, 2 = back, 3 = ready to submit
  final bool dark;
  final bool lite;
  const _StepBar({required this.step, this.dark = false, this.lite = false});

  @override
  Widget build(BuildContext context) {
    final activeColor = lite
        ? AppColors.vigiLiteCyan
        : (dark ? AppColors.vigiCyan : AppColors.teal);
    final inactiveColor = lite
        ? AppColors.vigiLiteBorder
        : (dark ? AppColors.vigiBorder : AppColors.border);
    final inactiveTextColor = lite
        ? AppColors.vigiLiteText3
        : (dark ? AppColors.vigiText3 : AppColors.text3);
    Widget dot(int n, String label) {
      final done = step > n;
      final current = step == n;
      final color = done || current ? activeColor : inactiveColor;
      return Expanded(
        child: Column(children: [
          Container(
            height: 6,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(height: 4),
          Text(done ? '✓ $label' : label,
              style: GoogleFonts.dmMono(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: done || current ? activeColor : inactiveTextColor)),
        ]),
      );
    }

    return Row(children: [
      dot(1, '1 FRONT'),
      const SizedBox(width: 8),
      dot(2, '2 BACK'),
    ]);
  }
}
