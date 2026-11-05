import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../utils/app_theme.dart';
import '../services/app_state.dart';
import '../widgets/terms_and_conditions.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

/// Redesigned to the VIGILINK dark-navy/cyan palette (`AppColors.vigi*`) —
/// the background is now a dark photo, so text/buttons use the vigi tokens
/// instead of the light-background `teal`/`text` tokens the rest of the
/// not-yet-migrated app still uses.
class _SplashScreenState extends State<SplashScreen> {
  bool _autoRouted = false;

  /// Same gate as Login's "Register" link — read first, agree, then the
  /// Create Account form opens. Declining just closes the sheet and leaves
  /// the person on Splash.
  Future<void> _goToRegister() async {
    final agreed = await showTermsAndConditionsModal(context);
    if (agreed && mounted) Navigator.pushNamed(context, '/register');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // Once initialization (DB + session restore) finishes, skip straight to
    // the dashboard for an already-logged-in user. Guarded by `isCurrent`
    // so this only fires while Splash is actually the visible/top route —
    // "GET STARTED" / "LOG IN" push Register/Login ON TOP of Splash rather
    // than replacing it, so Splash stays mounted underneath. Without this
    // guard, a notifyListeners() from Register/Login completing (which also
    // makes isLoggedIn true) would make the inert Splash widget schedule
    // its OWN navigation, racing the screen's own explicit one and tearing
    // out the active route (and any dialog on top of it) mid-flight.
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? false;
    if (!state.isInitializing &&
        state.isLoggedIn &&
        !_autoRouted &&
        isCurrent) {
      _autoRouted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pushReplacementNamed(context, '/home');
      });
    }

    return Scaffold(
      backgroundColor: AppColors.vigiBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/images/splash_background.png', fit: BoxFit.cover),
          // A dark wash keeps the logo/text readable against any part of
          // the photo without hiding it entirely.
          Container(color: AppColors.vigiBg.withValues(alpha: 0.55)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(flex: 2),
                  // Logo
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/images/splash_logo.png',
                      width: 110,
                      height: 110,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'VIGILINK',
                    style: GoogleFonts.dmSans(
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        color: AppColors.vigiText,
                        letterSpacing: -0.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'CONNECT  •  DETECT  •  ALERT',
                    style: GoogleFonts.dmMono(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.vigiCyan,
                        letterSpacing: 1.2),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'A Safer Journey Starts Together',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.dmSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.vigiText2),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Real-Time Vehicle Theft Monitoring & Alert System',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.dmSans(
                        fontSize: 13, color: AppColors.vigiText3, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.vigiCard,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: AppColors.vigiBorder),
                    ),
                    child: Text(
                      'Powered by Ad Hoc Networks',
                      style: GoogleFonts.dmMono(
                          fontSize: 10, color: AppColors.vigiCyan),
                    ),
                  ),
                  const Spacer(flex: 2),
                  // Buttons
                  _SplashButton(
                    label: 'GET STARTED',
                    bg: AppColors.vigiCyan,
                    fg: AppColors.vigiBg,
                    onTap: _goToRegister,
                  ),
                  const SizedBox(height: 12),
                  _SplashButton(
                    label: 'Already have an account?  LOG IN',
                    bg: Colors.transparent,
                    fg: AppColors.vigiText,
                    border: true,
                    borderColor: AppColors.vigiBorder,
                    onTap: () => Navigator.pushNamed(context, '/login'),
                  ),
                  if (state.isInitializing) ...[
                    const SizedBox(height: 14),
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: AppColors.vigiCyan),
                    ),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SplashButton extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  final bool border;
  final Color? borderColor;
  final VoidCallback onTap;
  const _SplashButton(
      {required this.label,
      required this.bg,
      required this.fg,
      this.border = false,
      this.borderColor,
      required this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: fg,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: border
                  ? BorderSide(
                      color: borderColor ?? Colors.white.withValues(alpha: 0.3),
                      width: 1.5)
                  : BorderSide.none,
            ),
          ),
          onPressed: onTap,
          child: Text(label,
              style: GoogleFonts.dmSans(
                  fontSize: 14, fontWeight: FontWeight.w700, color: fg)),
        ),
      );
}
