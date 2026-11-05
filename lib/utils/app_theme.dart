import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // `primary`/`primaryLight`/`primaryDark` stay red — reserved for genuine
  // danger/error meaning (a "STOLEN" badge, error modals, destructive admin
  // actions) now that `teal` below is the brand/primary-action color
  // everywhere else. Never widen `primary`'s use back to generic branding.
  static const primary = Color(0xFFDC2626);
  static const primaryDark = Color(0xFF991B1B);
  static const primaryLight = Color(0xFFFEE2E2);

  // Brand palette — buttons, headers, links, logo-adjacent chrome.
  // Primary teal: main buttons, active nav icons, links, important actions.
  static const teal = Color(0xFF087E8B);
  static const tealDark = Color(0xFF065A63);
  // Pale teal: light backgrounds for cards, sections, secondary chrome.
  static const tealLight = Color(0xFFEAF7F6);
  // Light aqua: selected tabs, icon backgrounds, subtle highlights and
  // decorative accents only — not a substitute for `teal` on buttons or
  // body text.
  static const tealAccent = Color(0xFFA8E5E3);
  // Dark slate: headings, body text, labels, readable icons.
  static const charcoal = Color(0xFF263238);
  static const silver = Color(0xFF64748B);

  static const green = Color(0xFF16A34A);
  static const greenLight = Color(0xFFDCFCE7);
  static const amber = Color(0xFFD97706);
  static const amberLight = Color(0xFFFEF3C7);
  static const orange = Color(0xFFEA580C);
  static const orangeLight = Color(0xFFFFEDD5);
  static const yellow = Color(0xFFCA8A04);
  static const yellowLight = Color(0xFFFEF9C3);
  static const blue = Color(0xFF2563EB);
  static const blueLight = Color(0xFFDBEAFE);
  static const gray = Color(0xFF6B7280);
  static const grayLight = Color(0xFFF3F4F6);
  static const text = Color(0xFF111827);
  static const text2 = Color(0xFF374151);
  static const text3 = Color(0xFF6B7280);
  static const border = Color(0xFFE5E7EB);
  static const bg = Color(0xFFF9FAFB);
  static const white = Color(0xFFFFFFFF);
  static const scaffold = Color(0xFFF1F5F9);

  // ── VIGILINK dark-navy/cyan palette ──
  // Used by screens migrated to the new VIGILINK look (Splash, onboarding,
  // mobile Login as of this pass). Kept separate from the palette above —
  // which the admin dashboard and not-yet-migrated phone screens still use —
  // rather than overwriting those tokens' meaning mid-migration; each
  // further screen switches to these as it's redesigned.
  static const vigiBg = Color(0xFF061522);
  static const vigiBgSecondary = Color(0xFF0B2235);
  static const vigiCard = Color(0xFF102C40);
  static const vigiInput = Color(0xFF0D2638);
  static const vigiCyan = Color(0xFF00D5F2);
  static const vigiTeal = Color(0xFF08A6C8);
  static const vigiText = Color(0xFFF5FAFF);
  static const vigiText2 = Color(0xFFA9BECE);
  static const vigiText3 = Color(0xFF71889B);
  static const vigiBorder = Color(0xFF234357);
  static const vigiCritical = Color(0xFFFF4D5E);
  static const vigiWarning = Color(0xFFFFBF47);
  static const vigiSuccess = Color(0xFF38D996);
  static const vigiInfo = Color(0xFF50A9FF);

  // ── VIGILINK Lite — light navy/cyan palette ──
  // Supersedes the dark-navy tokens above for Home, Map, Alerts, Profile/
  // Settings (and their action sheets/dialogs), the whole admin dashboard
  // interior, and — as of the Login/Register pass — those two screens too.
  // Splash, Onboarding, and License Verification (the standalone re-upload
  // screen, not Register's embedded license step) keep the dark-navy
  // `vigi*` tokens above unchanged — this is a second, separate token set,
  // not a redefinition, so those screens are unaffected.
  static const vigiLiteBg = Color(0xFFF4F8FB);
  static const vigiLiteSidebar = Color(0xFF12304A);
  static const vigiLiteCard = Color(0xFFFFFFFF);
  static const vigiLiteInput = Color(0xFFF4F8FB);
  static const vigiLiteCyan = Color(0xFF08BFD4);
  static const vigiLiteTeal = Color(0xFFDDF7F7);
  static const vigiLiteText = Color(0xFF12304A);
  static const vigiLiteText2 = Color(0xFF58738C);
  static const vigiLiteText3 = Color(0xFF7C93A8);
  static const vigiLiteBorder = Color(0xFFD9E6EF);
  static const vigiLiteCritical = Color(0xFFC62828);
  static const vigiLiteWarning = Color(0xFF946200);
  static const vigiLiteSuccess = Color(0xFF18794E);
  static const vigiLiteInfo = Color(0xFF1769AA);
  // Dark scrim over the Login/Register background photo — deliberately
  // its own near-black-navy value (not reused from the dark `vigi*` set
  // above) so the photo stays moody/legible behind the new light form
  // card, independent of whatever the dark palette's own background is.
  static const vigiLiteScrim = Color(0xFF061B2B);
  // Inline text links (Forgot Password, Register/Log In cross-links) on
  // Lite screens — a darker, more-legible-on-white teal than
  // `vigiLiteCyan`, which stays reserved for solid buttons/icons/active
  // states per the Login/Register spec.
  static const vigiLiteLink = Color(0xFF087FA5);
}

class AppTheme {
  static ThemeData get theme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.teal,
        primary: AppColors.teal,
      ),
      scaffoldBackgroundColor: AppColors.scaffold,
      textTheme: GoogleFonts.dmSansTextTheme(),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.text,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: GoogleFonts.dmSans(
          color: AppColors.text,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: const IconThemeData(color: AppColors.text),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.teal,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle:
              GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w700),
          elevation: 0,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.bg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.teal, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        labelStyle: GoogleFonts.dmSans(color: AppColors.text3, fontSize: 14),
        hintStyle: GoogleFonts.dmSans(color: AppColors.text3, fontSize: 14),
      ),
      cardTheme: CardThemeData(
        color: AppColors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border, width: 0.5),
        ),
        margin: const EdgeInsets.only(bottom: 12),
      ),
      dividerColor: AppColors.border,
    );
  }
}
