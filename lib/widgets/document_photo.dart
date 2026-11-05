import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import '../utils/app_theme.dart';
import '../utils/picker_guard.dart';

// ══════════════════════════════════════
// DOCUMENT PHOTOS — shared by the driver's license (registration) and the
// vehicle's OR/CR (vehicle registration): one way to take/choose a photo, and
// one card that shows it.
// ══════════════════════════════════════

/// Each photo travels inside a Firestore document (1 MB limit, and Cloud
/// Storage needs a paid plan), so it is shrunk on capture and capped here.
const int kMaxDocumentPhotoBytes = 450000;

/// A photo taken/chosen for a document, or the reason there isn't one. Both
/// null means the person simply closed the camera/gallery.
class DocumentPhotoResult {
  final Uint8List? bytes;
  final String? error;
  const DocumentPhotoResult({this.bytes, this.error});
}

/// The "Take Photo / Choose from Gallery" bottom sheet used wherever a photo
/// can come from either. Null when dismissed.
Future<ImageSource?> showImageSourceSheet(BuildContext context,
    {required String title, String? subtitle}) {
  return showModalBottomSheet<ImageSource>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title,
              style: GoogleFonts.dmSans(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle,
                textAlign: TextAlign.center,
                style:
                    GoogleFonts.dmSans(fontSize: 12, color: AppColors.text3)),
          ],
          const SizedBox(height: 14),
          ListTile(
            leading:
                const Icon(Icons.camera_alt_outlined, color: AppColors.teal),
            title: const Text('Take Photo'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading:
                const Icon(Icons.photo_library_outlined, color: AppColors.blue),
            title: const Text('Choose from Gallery'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    ),
  );
}

Future<DocumentPhotoResult> captureDocumentPhoto(ImageSource source) async {
  isPickerOpen = true;
  try {
    final img = await ImagePicker().pickImage(
        source: source,
        preferredCameraDevice: CameraDevice.rear,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 60);
    if (img == null) return const DocumentPhotoResult();
    final bytes = await img.readAsBytes();
    if (bytes.length > kMaxDocumentPhotoBytes) {
      return const DocumentPhotoResult(
          error:
              'That photo is too large. Please retake it a little farther from the document.');
    }
    return DocumentPhotoResult(bytes: bytes);
  } catch (_) {
    return const DocumentPhotoResult(
        error:
            'Could not open the camera or gallery. Allow access in Settings and try again.');
  } finally {
    isPickerOpen = false;
  }
}

/// One document photo: a card-shaped preview (or a placeholder saying what
/// must be readable) and a take/retake button.
class DocumentPhotoCard extends StatelessWidget {
  final String title;
  final bool active;
  final bool enabled;
  final String? lockedNote;
  final Uint8List? photo;
  final String hint;
  final String buttonLabel;
  final VoidCallback onCapture;

  /// True once a submit attempt found this specific photo still missing —
  /// highlights the card red with an inline "Photo required" note, the same
  /// way a `TextFormField` highlights itself red on validation failure,
  /// instead of leaving the only indication in a popup the person has
  /// already dismissed. Cleared automatically the moment [photo] is set
  /// (see the `missing` check below), so it never lingers after the person
  /// fixes it.
  final bool showError;

  /// Defaults to false, which every existing call site relies on implicitly
  /// (unchanged look) — only screens migrated to the VIGILINK dark palette
  /// pass `dark: true` for a dark card fill and light text/placeholder.
  final bool dark;

  /// VIGILINK Lite screens (Register Vehicle's OR/CR photos) pass
  /// `lite: true` instead — a white card with navy text and a cyan accent.
  /// Takes precedence over `dark`; the two are never both true from any
  /// call site.
  final bool lite;
  const DocumentPhotoCard({
    super.key,
    required this.title,
    required this.active,
    required this.enabled,
    this.lockedNote,
    required this.photo,
    required this.hint,
    required this.buttonLabel,
    required this.onCapture,
    this.showError = false,
    this.dark = false,
    this.lite = false,
  });

  @override
  Widget build(BuildContext context) {
    final missing = showError && photo == null;
    final activeColor = lite
        ? AppColors.vigiLiteCyan
        : (dark ? AppColors.vigiCyan : AppColors.teal);
    final borderColor = lite
        ? AppColors.vigiLiteBorder
        : (dark ? AppColors.vigiBorder : AppColors.border);
    final labelColor = lite
        ? AppColors.vigiLiteText2
        : (dark ? AppColors.vigiText3 : AppColors.text3);
    final criticalColor = lite
        ? AppColors.vigiLiteCritical
        : (dark ? AppColors.vigiCritical : AppColors.primary);
    final successColor = lite
        ? AppColors.vigiLiteSuccess
        : (dark ? AppColors.vigiSuccess : AppColors.green);
    final cardColor = lite
        ? AppColors.vigiLiteCard
        : (dark ? AppColors.vigiCard : AppColors.white);
    final placeholderColor = lite
        ? AppColors.vigiLiteBg
        : (dark ? AppColors.vigiInput : AppColors.bg);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color:
                missing ? criticalColor : (active ? activeColor : borderColor),
            width: missing || active ? 1.4 : 0.8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(title,
                  style: GoogleFonts.dmMono(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: labelColor,
                      letterSpacing: 0.5))),
          if (photo != null)
            Icon(Icons.check_circle, size: 18, color: successColor),
        ]),
        const SizedBox(height: 10),
        // ID-1 card proportions (85.6 × 54 mm).
        AspectRatio(
          aspectRatio: 1.586,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: photo != null
                ? Image.memory(photo!, fit: BoxFit.cover, gaplessPlayback: true)
                : Container(
                    color: placeholderColor,
                    padding: const EdgeInsets.all(14),
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.badge_outlined, size: 34, color: labelColor),
                        const SizedBox(height: 8),
                        Text(hint,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.dmSans(
                                fontSize: 12, height: 1.4, color: labelColor)),
                      ]),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: enabled ? onCapture : null,
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: Text(!enabled && lockedNote != null && photo == null
                ? lockedNote!
                : buttonLabel),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 46),
                foregroundColor: lite
                    ? AppColors.vigiLiteCyan
                    : (dark ? AppColors.vigiCyan : AppColors.blue),
                side: BorderSide(color: borderColor)),
          ),
        ),
        if (missing) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.error_outline, size: 14, color: criticalColor),
            const SizedBox(width: 4),
            Text('Photo required',
                style: GoogleFonts.dmSans(
                    fontSize: 11.5,
                    color: criticalColor,
                    fontWeight: FontWeight.w600)),
          ]),
        ],
      ]),
    );
  }
}
