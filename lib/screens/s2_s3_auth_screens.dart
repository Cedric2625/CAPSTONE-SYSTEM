import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/app_theme.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../widgets/widgets.dart';
import '../widgets/terms_and_conditions.dart';
import 's18_license_verification.dart';
import 's4_s5_vehicle_home.dart';
import '../utils/validators.dart';

// ─── PASSWORD STRENGTH (Register screen only) ───
// Scores a password on length + character variety so the user gets
// real-time weak/medium/strong feedback before the account is created.
enum _PwStrength { empty, weak, medium, strong }

class _PwStrengthResult {
  final _PwStrength level;
  final String label;
  final Color color;
  final double score; // 0.0–1.0, drives the strength meter bar
  const _PwStrengthResult(this.level, this.label, this.color, this.score);
}

_PwStrengthResult _evaluatePasswordStrength(String password) {
  if (password.isEmpty) {
    return const _PwStrengthResult(
        _PwStrength.empty, '', AppColors.vigiLiteBorder, 0);
  }
  int score = 0;
  if (password.length >= 8) score++;
  if (password.length >= 12) score++;
  if (RegExp(r'[A-Z]').hasMatch(password)) score++;
  if (RegExp(r'[a-z]').hasMatch(password)) score++;
  if (RegExp(r'[0-9]').hasMatch(password)) score++;
  if (RegExp(r'''[!@#$%^&*(),.?":{}|<>_\-\[\]/\\+=~`;]''').hasMatch(password)) {
    score++;
  }

  if (password.length < 8 || score <= 2) {
    return const _PwStrengthResult(
        _PwStrength.weak, 'Weak', AppColors.vigiLiteCritical, 0.33);
  } else if (score <= 4) {
    return const _PwStrengthResult(
        _PwStrength.medium, 'Medium', AppColors.vigiLiteWarning, 0.66);
  }
  return const _PwStrengthResult(
      _PwStrength.strong, 'Strong', AppColors.vigiLiteSuccess, 1.0);
}

// Success modal for register/login now lives in widgets.dart as the shared
// showSuccessModal(), used across the app instead of a copy private to
// this file.

// ══════════════════════════════════════
// SCREEN 2: REGISTER ACCOUNT
// ══════════════════════════════════════
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _vehicleKey = GlobalKey<VehicleFormSectionState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _loading = false;
  bool _obscurePass = true;
  bool _obscurePass2 = true;
  // Required, like every field above: the front and back of a valid driver's
  // license, taken with the camera.
  Uint8List? _licenseFront;
  Uint8List? _licenseBack;
  // True once a submit attempt found the license still missing — highlights
  // the missing side(s) inline, in addition to the popup. See
  // LicenseCaptureSection.showMissingErrors.
  bool _showLicenseErrors = false;
  _PwStrengthResult _strength = _evaluatePasswordStrength('');

  // Set after a submit attempt comes back "this name/email is already
  // registered" — holds the exact value that was rejected, so the Full
  // Name/Email field's own validator can show it as inline red text right
  // under that field (standard Form behavior: once validate() has run once,
  // each field re-validates live as it's edited). Naturally stops showing
  // the moment the person changes the text, since it then no longer matches
  // what was actually rejected.
  String? _nameTaken;
  String? _emailTaken;

  @override
  void initState() {
    super.initState();
    _pass.addListener(_onPasswordChanged);
    _pass2.addListener(_onConfirmPasswordChanged);
  }

  void _onPasswordChanged() {
    setState(() => _strength = _evaluatePasswordStrength(_pass.text));
  }

  // Just triggers a rebuild — the CONFIRM PASSWORD match indicator below
  // reads both controllers' current text live in build().
  void _onConfirmPasswordChanged() => setState(() {});

  @override
  void dispose() {
    _pass.removeListener(_onPasswordChanged);
    _pass2.removeListener(_onConfirmPasswordChanged);
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _pass.dispose();
    _pass2.dispose();
    super.dispose();
  }

  /// Validates the account, license and vehicle together, then submits them
  /// for admin approval. Nothing is signed in as a usable account until the
  /// admins approve it — the person waits on the Awaiting Approval screen.
  Future<void> _submit() async {
    final formOk = _formKey.currentState!.validate();
    final hasLicense = _licenseFront != null && _licenseBack != null;
    if (!hasLicense) {
      setState(() => _showLicenseErrors = true);
      await showErrorModal(
        context,
        title: "Driver's License Required",
        message:
            "Please take photos of both the front and the back of your driver's license.",
        icon: Icons.badge_outlined,
        color: AppColors.teal,
      );
    }
    if (!mounted) return;
    final vehicle = await _vehicleKey.currentState!.collectDraft();
    if (!mounted) return;
    if (!formOk || !hasLicense || vehicle == null) return;

    setState(() => _loading = true);
    showLoadingModal(context, message: 'Creating your account…');
    final result = await context.read<AppState>().submitRegistration(
          name: _name.text,
          email: _email.text,
          phone: _phone.text,
          password: _pass.text,
          licenseFront: _licenseFront!,
          licenseBack: _licenseBack!,
          vehicle: vehicle,
        );
    if (!mounted) return;
    Navigator.of(context).pop(); // the loading modal
    setState(() => _loading = false);
    if (!result.ok) {
      String title = 'Registration Not Submitted';
      IconData icon = Icons.error_outline;
      switch (result.field) {
        case RegistrationIssueField.name:
          title = 'Full Name Already Registered';
          icon = Icons.person_off_outlined;
          setState(() => _nameTaken = _name.text.trim());
          break;
        case RegistrationIssueField.email:
          title = 'Email Already Registered';
          icon = Icons.email_outlined;
          setState(() => _emailTaken = _email.text.trim());
          break;
        case null:
          break;
      }
      // Re-run validation so the just-set _nameTaken/_emailTaken shows up as
      // red text under the actual field right away, not only in the modal.
      if (result.field != null) _formKey.currentState!.validate();
      await showErrorModal(
        context,
        title: title,
        message: result.error!,
        icon: icon,
      );
      return;
    }
    await _showSubmittedModal();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/awaiting-approval');
  }

  /// Confirms the submission. Deliberately says what happens next, since the
  /// account can't be used until an admin has reviewed it.
  Future<void> _showSubmittedModal() => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Dialog(
          backgroundColor: AppColors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                    color: AppColors.amberLight, shape: BoxShape.circle),
                child: const Icon(Icons.hourglass_top_rounded,
                    size: 30, color: AppColors.amber),
              ),
              const SizedBox(height: 18),
              Text('Registration Submitted',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.text)),
              const SizedBox(height: 10),
              Text(
                'Your documents and vehicle registration are being processed. '
                'Please wait for an admin to review and approve your account — '
                'you will be notified as soon as a decision is made.',
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                    fontSize: 13.5, height: 1.5, color: AppColors.text2),
              ),
              const SizedBox(height: 22),
              PrimaryButton(
                  label: 'OK, I UNDERSTAND', onTap: () => Navigator.pop(ctx)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back',
            onPressed: () => Navigator.pop(context)),
        title: const Text('Create Account'),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/images/login_background.png', fit: BoxFit.cover),
          Container(color: AppColors.vigiLiteScrim.withValues(alpha: 0.62)),
          SafeArea(
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Logo + wordmark + tagline sit directly on the
                        // photo, above the light form card — same treatment
                        // as Login.
                        ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Image.asset('assets/images/app_icon.png',
                              width: 56, height: 56, fit: BoxFit.cover),
                        ),
                        const SizedBox(height: 8),
                        Text('VIGILINK',
                            style: GoogleFonts.dmSans(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                letterSpacing: -0.5)),
                        const SizedBox(height: 2),
                        Text('CONNECT  •  DETECT  •  ALERT',
                            style: GoogleFonts.dmMono(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.vigiLiteCyan,
                                letterSpacing: 1.1)),
                        const SizedBox(height: 18),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                          decoration: BoxDecoration(
                            color: AppColors.vigiLiteCard,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.vigiLiteBorder),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.18),
                                  blurRadius: 24,
                                  offset: const Offset(0, 10))
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppTextField(
                                  label: 'FULL NAME',
                                  hint: 'e.g. Juan dela Cruz',
                                  controller: _name,
                                  lite: true,
                                  validator: (v) {
                                    final trimmed = (v ?? '').trim();
                                    if (trimmed.isEmpty) {
                                      return 'Name is required';
                                    }
                                    if (_nameTaken != null &&
                                        trimmed == _nameTaken) {
                                      return 'This name is already registered.';
                                    }
                                    return null;
                                  }),
                              AppTextField(
                                  label: 'EMAIL ADDRESS',
                                  hint: 'tanjiro@gmail.com',
                                  controller: _email,
                                  keyboardType: TextInputType.emailAddress,
                                  lite: true,
                                  validator: (v) {
                                    final emailError = validateEmail(v);
                                    if (emailError != null) return emailError;
                                    if (!hasAllowedRegistrationEmailDomain(
                                        v!)) {
                                      return 'Only @gmail.com or @carsu.edu.ph email addresses can register.';
                                    }
                                    final trimmed = v.trim();
                                    if (_emailTaken != null &&
                                        trimmed == _emailTaken) {
                                      return 'This email is already registered.';
                                    }
                                    return null;
                                  }),
                              AppTextField(
                                  label: 'MOBILE NUMBER',
                                  hint: '09171234567',
                                  controller: _phone,
                                  keyboardType: TextInputType.phone,
                                  lite: true,
                                  validator: validatePhMobile),
                              AppTextField(
                                label: 'PASSWORD',
                                hint: 'Minimum 8 characters',
                                controller: _pass,
                                obscure: _obscurePass,
                                lite: true,
                                suffix: GestureDetector(
                                  onTap: () => setState(
                                      () => _obscurePass = !_obscurePass),
                                  child: Icon(
                                      _obscurePass
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      size: 20,
                                      color: AppColors.vigiLiteText3),
                                ),
                                validator: (v) {
                                  if (v == null || v.length < 8) {
                                    return 'Password must be at least 8 characters';
                                  }
                                  if (_evaluatePasswordStrength(v).level ==
                                      _PwStrength.weak) {
                                    return 'Password is too weak. Add uppercase letters, numbers, or symbols.';
                                  }
                                  return null;
                                },
                              ),
                              if (_pass.text.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Row(children: [
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(99),
                                        child: LinearProgressIndicator(
                                          value: _strength.score,
                                          minHeight: 5,
                                          backgroundColor:
                                              AppColors.vigiLiteBorder,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  _strength.color),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(_strength.label,
                                        style: GoogleFonts.dmMono(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: _strength.color)),
                                  ]),
                                ),
                              AppTextField(
                                label: 'CONFIRM PASSWORD',
                                hint: 'Re-enter password',
                                controller: _pass2,
                                obscure: _obscurePass2,
                                lite: true,
                                suffix: GestureDetector(
                                  onTap: () => setState(
                                      () => _obscurePass2 = !_obscurePass2),
                                  child: Icon(
                                      _obscurePass2
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      size: 20,
                                      color: AppColors.vigiLiteText3),
                                ),
                                validator: (v) => (v != _pass.text)
                                    ? 'Passwords do not match'
                                    : null,
                              ),
                              if (_pass2.text.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Row(children: [
                                    Icon(
                                      _pass2.text == _pass.text
                                          ? Icons.check_circle
                                          : Icons.error_outline,
                                      size: 14,
                                      color: _pass2.text == _pass.text
                                          ? AppColors.vigiLiteSuccess
                                          : AppColors.vigiLiteCritical,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      _pass2.text == _pass.text
                                          ? 'Password Match'
                                          : 'Passwords do not match',
                                      style: GoogleFonts.dmSans(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: _pass2.text == _pass.text
                                              ? AppColors.vigiLiteSuccess
                                              : AppColors.vigiLiteCritical),
                                    ),
                                  ]),
                                ),
                              const SizedBox(height: 6),
                              Text("DRIVER'S LICENSE (REQUIRED)",
                                  style: GoogleFonts.dmMono(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.vigiLiteText3,
                                      letterSpacing: 0.5)),
                              const SizedBox(height: 4),
                              Text(
                                  "Take a photo of the front, then the back, of your valid Philippine driver's license.",
                                  style: GoogleFonts.dmSans(
                                      fontSize: 12,
                                      height: 1.4,
                                      color: AppColors.vigiLiteText3)),
                              const SizedBox(height: 10),
                              LicenseCaptureSection(
                                front: _licenseFront,
                                back: _licenseBack,
                                enabled: !_loading,
                                onFront: (b) =>
                                    setState(() => _licenseFront = b),
                                onBack: (b) => setState(() => _licenseBack = b),
                                showMissingErrors: _showLicenseErrors,
                                lite: true,
                              ),
                              const SizedBox(height: 24),
                              const Divider(
                                  height: 1, color: AppColors.vigiLiteBorder),
                              const SizedBox(height: 20),
                              Text('VEHICLE (REQUIRED)',
                                  style: GoogleFonts.dmMono(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.vigiLiteText3,
                                      letterSpacing: 0.5)),
                              const SizedBox(height: 4),
                              Text(
                                  'The vehicle this account will monitor. Its OR and CR photos are reviewed together with your documents.',
                                  style: GoogleFonts.dmSans(
                                      fontSize: 12,
                                      height: 1.4,
                                      color: AppColors.vigiLiteText3)),
                              const SizedBox(height: 12),
                              VehicleFormSection(
                                  key: _vehicleKey, embedded: true, lite: true),
                              const SizedBox(height: 16),
                              PrimaryButton(
                                  label: 'REGISTER',
                                  onTap: _submit,
                                  loading: _loading,
                                  color: AppColors.vigiLiteCyan,
                                  textColor: Colors.white),
                              const SizedBox(height: 16),
                              Center(
                                child: GestureDetector(
                                  onTap: () => Navigator.pushReplacementNamed(
                                      context, '/login'),
                                  child: Text.rich(
                                    TextSpan(children: [
                                      TextSpan(
                                          text: 'Already registered? ',
                                          style: GoogleFonts.dmSans(
                                              color: AppColors.vigiLiteText2,
                                              fontSize: 13)),
                                      TextSpan(
                                          text: 'Log In',
                                          style: GoogleFonts.dmSans(
                                              color: AppColors.vigiLiteLink,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13)),
                                    ]),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The admin's stated reason, quoted in the rejection notice, with the same
/// next step either way.
String _rejectionMessage(String? reason) {
  final why = (reason ?? '').trim();
  return why.isEmpty
      ? 'An admin could not approve this registration. Please register again with valid documents.'
      : 'An admin could not approve this registration.\n\nReason: $why\n\nPlease register again with valid documents.';
}

// ══════════════════════════════════════
// AWAITING APPROVAL — shown right after a registration is submitted. Stays
// live on the admin's decision: an approval signs the person in, a rejection
// explains why and starts registration over.
// ══════════════════════════════════════
class AwaitingApprovalScreen extends StatefulWidget {
  const AwaitingApprovalScreen({super.key});
  @override
  State<AwaitingApprovalScreen> createState() => _AwaitingApprovalScreenState();
}

class _AwaitingApprovalScreenState extends State<AwaitingApprovalScreen> {
  StreamSubscription<({String? status, String? reason})>? _sub;
  bool _deciding = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final stream = context.read<AppState>().watchOwnApproval();
      if (stream == null) {
        Navigator.pushReplacementNamed(context, '/login');
        return;
      }
      _sub = stream.listen((d) => _onDecision(d.status, d.reason));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _onDecision(String? status, String? reason) async {
    if (_deciding || !mounted) return;
    if (status == 'approved') {
      _deciding = true;
      _sub?.cancel();
      final state = context.read<AppState>();
      final signedIn = await state.completeApprovedSignIn();
      if (!mounted) return;
      if (!signedIn) {
        // Approved, but the email still has to be verified before the app
        // opens — that's handled by the normal Login screen.
        await state.leaveAwaitingApproval();
        if (!mounted) return;
        await showSuccessModal(context,
            title: 'Account Approved',
            message:
                'Your account has been approved. Verify your email address, then log in to start using VIGILINK.',
            icon: Icons.verified_outlined);
        if (!mounted) return;
        Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
        return;
      }
      await showSuccessModal(context,
          title: 'Account Approved',
          message:
              'Welcome to VIGILINK! Your account and vehicle are now active.',
          icon: Icons.verified_outlined);
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, '/home', (r) => false);
    } else if (status == 'rejected') {
      _deciding = true;
      _sub?.cancel();
      await showErrorModal(context,
          title: 'Registration Not Approved',
          message: _rejectionMessage(reason),
          icon: Icons.gpp_bad_outlined);
      if (!mounted) return;
      final freed =
          await context.read<AppState>().discardRejectedRegistration();
      if (!mounted) return;
      if (freed) {
        Navigator.pushNamedAndRemoveUntil(context, '/register', (r) => false);
        return;
      }
      // Firebase wouldn't delete the old sign-in from this long-open session.
      // Logging in again is a fresh sign-in, and the Login screen clears it.
      showResultToast(context,
          message:
              'Please log in once more to finish clearing this rejected registration, then register again.',
          success: false);
      Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = context.read<AppState>().pendingRegistrationEmail ?? '';
    return PopScope(
      // Back would return into a form that's already been submitted.
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.white,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: const BoxDecoration(
                        color: AppColors.amberLight, shape: BoxShape.circle),
                    child: const Icon(Icons.hourglass_top_rounded,
                        size: 40, color: AppColors.amber),
                  ),
                  const SizedBox(height: 22),
                  Text('Awaiting Admin Approval',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.dmSans(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text)),
                  const SizedBox(height: 10),
                  Text(
                    'Your registration has been submitted. An admin is checking '
                    'your driver\'s license and your vehicle\'s OR/CR documents. '
                    'This screen updates by itself the moment a decision is made.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.dmSans(
                        fontSize: 13.5, height: 1.5, color: AppColors.text2),
                  ),
                  const SizedBox(height: 26),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        color: AppColors.bg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.border)),
                    child: const Column(children: [
                      _ProgressStep(label: 'Account created', done: true),
                      _ProgressStep(
                          label: "Driver's license submitted", done: true),
                      _ProgressStep(
                          label: 'Vehicle and OR/CR submitted', done: true),
                      _ProgressStep(
                          label: 'Admin review', done: false, current: true),
                      _ProgressStep(
                          label: 'Access granted', done: false, last: true),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: AppColors.blueLight,
                        borderRadius: BorderRadius.circular(12)),
                    child: Text(
                      email.isEmpty
                          ? 'Also verify your email address — check your inbox for the verification link.'
                          : 'Also verify your email address ($email) — check your inbox for the verification link.',
                      style: GoogleFonts.dmSans(
                          fontSize: 12.5, height: 1.45, color: AppColors.blue),
                    ),
                  ),
                  const SizedBox(height: 26),
                  OutlineButton2(
                    label: 'BACK TO LOG IN',
                    onTap: () async {
                      await context.read<AppState>().leaveAwaitingApproval();
                      if (!context.mounted) return;
                      Navigator.pushNamedAndRemoveUntil(
                          context, '/login', (r) => false);
                    },
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One line of the Awaiting screen's progress checklist.
class _ProgressStep extends StatelessWidget {
  final String label;
  final bool done;
  final bool current;
  final bool last;
  const _ProgressStep(
      {required this.label,
      required this.done,
      this.current = false,
      this.last = false});

  @override
  Widget build(BuildContext context) {
    final color =
        done ? AppColors.green : (current ? AppColors.amber : AppColors.text3);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Row(children: [
        Icon(
            done
                ? Icons.check_circle
                : (current
                    ? Icons.hourglass_top_rounded
                    : Icons.radio_button_unchecked),
            size: 20,
            color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              style: GoogleFonts.dmSans(
                  fontSize: 13.5,
                  fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                  color: current ? AppColors.text : AppColors.text2)),
        ),
      ]),
    );
  }
}

// ─── EMAIL VERIFICATION (FR-01 — confirms the registrant controls the
// email address before registration is considered complete). Replaces the
// old SMS-OTP flow: Firebase email verification is free on the no-cost
// Spark plan, whereas real SMS delivery requires the paid Blaze plan — this
// keeps the same "verify before you're in" guarantee without any billing
// requirement, and works for any stranger downloading the app, not just
// pre-registered test numbers. ───
class _EmailVerificationScreen extends StatefulWidget {
  final String email;
  const _EmailVerificationScreen({required this.email});
  @override
  State<_EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<_EmailVerificationScreen> {
  bool _checking = false;
  bool _resending = false;
  String? _error;
  String? _info;

  // 60-second window to confirm verification, mirroring the old OTP
  // screen's countdown — if it passes without the user tapping "I've
  // Verified — Continue", they're required to tap "Resend Email" to get a
  // fresh 60-second window instead of continuing to poll indefinitely. This
  // only gates the MANUAL button below.
  static const int _windowSeconds = 60;
  Timer? _countdownTimer;
  int _secondsLeft = _windowSeconds;
  bool _expired = false;

  // Automatic detection: polls quietly in the background so tapping the
  // link in the email is enough — no need to switch back and tap "I've
  // Verified" by hand. This is a local check (rereading this device's own
  // sign-in state), never a new email send, so it isn't subject to the
  // email-sending limits above and keeps running even after the visible
  // countdown "expires"; only the countdown UI and the manual button are
  // gated by [_expired], not this.
  static const Duration _autoCheckInterval = Duration(seconds: 4);
  Timer? _autoCheckTimer;

  @override
  void initState() {
    super.initState();
    _startCountdown();
    _autoCheckTimer = Timer.periodic(_autoCheckInterval, (_) => _silentCheck());
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _autoCheckTimer?.cancel();
    super.dispose();
  }

  /// Same check as the manual button, run quietly in the background: no
  /// spinner, no "not verified yet" message on every miss — that's the
  /// expected, normal state while waiting, not something worth interrupting
  /// over. Only acts when it actually finds the email verified.
  Future<void> _silentCheck() async {
    if (_checking) return; // don't race a manual check already in flight
    final verified = await context.read<AppState>().checkEmailVerified();
    if (!mounted || !verified) return;
    _countdownTimer?.cancel();
    _autoCheckTimer?.cancel();
    Navigator.pop(context, true);
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() {
      _secondsLeft = _windowSeconds;
      _expired = false;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() {
          _secondsLeft = 0;
          _expired = true;
        });
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  Future<void> _checkVerified() async {
    if (_expired) return;
    setState(() {
      _checking = true;
      _error = null;
      _info = null;
    });
    final verified = await context.read<AppState>().checkEmailVerified();
    if (!mounted) return;
    setState(() => _checking = false);
    if (verified) {
      _countdownTimer?.cancel();
      Navigator.pop(context, true);
    } else {
      setState(() => _error =
          'Not verified yet. Open the link we emailed you, then tap Continue again.');
    }
  }

  Future<void> _resend() async {
    setState(() {
      _resending = true;
      _error = null;
      _info = null;
    });
    final err = await context.read<AppState>().resendVerificationEmail();
    if (!mounted) return;
    setState(() {
      _resending = false;
      if (err == null) {
        _info = 'Verification email resent to ${widget.email}.';
      } else {
        _error = err;
      }
    });
    if (err == null) _startCountdown();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // No accidental back-out mid-verification — leaving requires the
      // explicit back arrow below, same intent as the old OTP screen.
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.white,
        appBar: AppBar(
          backgroundColor: AppColors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            tooltip: 'Back',
            onPressed: () => Navigator.pop(context, false),
          ),
          title: const Text('Verify Your Email'),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.mark_email_read_outlined,
                  size: 48, color: AppColors.teal),
              const SizedBox(height: 16),
              Text('Check your email',
                  style: GoogleFonts.dmSans(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text)),
              const SizedBox(height: 6),
              Text(
                'We sent a verification link to ${widget.email} for verification and security reasons. Open it — this screen will move on by itself once it detects the link was clicked, or tap Continue yourself if you\'d rather not wait.',
                style: GoogleFonts.dmSans(fontSize: 13, color: AppColors.text3),
              ),
              const SizedBox(height: 16),
              Text(
                _expired
                    ? 'Verification window expired'
                    : 'Verify within 0:${_secondsLeft.toString().padLeft(2, '0')}',
                style: GoogleFonts.dmMono(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _expired
                      ? AppColors.primary
                      : (_secondsLeft <= 10
                          ? AppColors.amber
                          : AppColors.text3),
                ),
              ),
              const SizedBox(height: 8),
              Row(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: AppColors.text3)),
                const SizedBox(width: 8),
                Text('Checking automatically…',
                    style: GoogleFonts.dmSans(
                        fontSize: 11.5, color: AppColors.text3)),
              ]),
              const SizedBox(height: 16),
              if (_error != null) ...[
                Text(_error!,
                    style: GoogleFonts.dmSans(
                        fontSize: 12.5, color: AppColors.primary)),
                const SizedBox(height: 12),
              ],
              if (_info != null) ...[
                Text(_info!,
                    style: GoogleFonts.dmSans(
                        fontSize: 12.5, color: AppColors.green)),
                const SizedBox(height: 12),
              ],
              if (!_expired)
                PrimaryButton(
                    label: "I'VE VERIFIED — CONTINUE",
                    onTap: _checkVerified,
                    loading: _checking),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: _resending ? null : _resend,
                  child: Text(
                    'Resend Email',
                    style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _expired ? AppColors.primary : AppColors.blue),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: AppColors.blueLight,
                    borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  const Icon(Icons.info_outline,
                      size: 16, color: AppColors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Email verification confirms this address belongs to you, protecting your account and every theft alert it sends. Check your spam/junk folder if it doesn\'t arrive within a minute.',
                      style: GoogleFonts.dmSans(
                          fontSize: 11.5, color: AppColors.blue),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════
// SCREEN 3: LOGIN
// ══════════════════════════════════════
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;
  bool _googleLoading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  /// The one gate every path into registration goes through: the Terms &
  /// Conditions / Privacy Policy must be read and agreed to before the
  /// Create Account form (and, after that, vehicle registration) ever
  /// opens. Declining just closes the sheet — already on Login, there's
  /// nowhere else to send them.
  Future<void> _goToRegister() async {
    final agreed = await showTermsAndConditionsModal(context);
    if (agreed && mounted) {
      Navigator.pushReplacementNamed(context, '/register');
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    showLoadingModal(context, message: 'Signing you in securely…');
    final state = context.read<AppState>();
    final ok = await state.login(_email.text, _pass.text);
    if (!mounted) return;
    Navigator.of(context).pop(); // the loading modal
    setState(() => _loading = false);

    if (ok) {
      await _completeLogin(state);
      return;
    }
    if (state.registrationDecision != null) {
      await _showRegistrationDecision(state);
      return;
    }
    if (state.pendingLicense) {
      await _finishLicenseThenSignIn(state);
      return;
    }

    final pendingEmail = state.pendingEmailVerification;
    if (pendingEmail != null) {
      // Credentials were correct, but this account never finished email
      // verification (registration was abandoned before clicking the link,
      // or it expired) — send them through it now instead of just failing.
      final verified = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
            builder: (_) => _EmailVerificationScreen(email: pendingEmail)),
      );
      if (!mounted) return;
      if (verified != true) {
        showResultToast(context,
            message:
                'Email verification is still required to finish setting up this account.',
            success: false);
        return;
      }
      // Email is verified now — retry with the same credentials, which will
      // pass the check that blocked it a moment ago.
      setState(() => _loading = true);
      showLoadingModal(context, message: 'Signing you in securely…');
      final retryOk = await state.login(_email.text, _pass.text);
      if (!mounted) return;
      Navigator.of(context).pop(); // the loading modal
      setState(() => _loading = false);
      if (retryOk) {
        await _completeLogin(state);
      } else if (state.pendingLicense) {
        await _finishLicenseThenSignIn(state);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(state.lastAuthError ??
                  'Something went wrong. Please try logging in again.'),
              backgroundColor: AppColors.primary),
        );
      }
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(state.lastAuthError ?? 'Invalid email or password.'),
          backgroundColor: AppColors.primary),
    );
  }

  /// The credentials were right but this account has no driver's license
  /// photos on file yet — collect them, then finish signing in.
  Future<void> _finishLicenseThenSignIn(AppState state) async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LicenseVerificationScreen()),
    );
    if (!mounted) return;
    if (done != true) {
      await state.cancelPendingSignIn();
      if (!mounted) return;
      showResultToast(context,
          message: "Driver's license verification is required to use VIGILINK.",
          success: false);
      return;
    }
    await state.completePendingSignIn();
    if (!mounted) return;
    await _completeLogin(state);
  }

  Future<void> _completeLogin(AppState state) async {
    final name = state.currentUser?.name ?? 'User';
    await showSuccessModal(context, title: 'You are Logged in as $name');
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/home');
  }

  /// A sign-in that stopped because the account is awaiting an admin's review
  /// or was rejected. Pending only needs the notice. Rejected also explains
  /// why, then frees the account so the person can register again.
  Future<void> _showRegistrationDecision(AppState state) async {
    if (state.registrationDecision == RegistrationDecision.pending) {
      await showErrorModal(
        context,
        title: 'Awaiting Admin Approval',
        message:
            'Your account is still being reviewed by an admin. You can log in as soon as it has been approved.',
        icon: Icons.hourglass_top_rounded,
      );
      return;
    }
    await showErrorModal(
      context,
      title: 'Registration Not Approved',
      message: _rejectionMessage(state.rejectionReason),
      icon: Icons.gpp_bad_outlined,
    );
    final freed = await state.discardRejectedRegistration();
    if (!mounted) return;
    if (!freed) {
      showResultToast(context,
          message:
              'Could not clear this rejected registration. Check your connection and log in again.',
          success: false);
      return;
    }
    Navigator.pushReplacementNamed(context, '/register');
  }

  Future<void> _submitGoogle() async {
    setState(() => _googleLoading = true);
    showLoadingModal(context, message: 'Connecting to Google…');
    final state = context.read<AppState>();
    final ok = await state.signInWithGoogle();
    if (!mounted) return;
    Navigator.of(context).pop(); // the loading modal
    setState(() => _googleLoading = false);
    if (ok) {
      await _completeLogin(state);
    } else if (state.registrationDecision != null) {
      await _showRegistrationDecision(state);
    } else if (state.pendingLicense) {
      await _finishLicenseThenSignIn(state);
    } else if (state.googleRejectedEmail != null) {
      // This Google account was never registered through the Register form
      // (AppState already signed it back out) — say so clearly instead of
      // logging the person in.
      final goRegister = await showConfirmDialog(
        context,
        title: 'Google Account Not Registered',
        message:
            '${state.googleRejectedEmail} is not registered with VIGILINK yet. Please create an account with this email first using Register, then you can sign in with Google.',
        confirmLabel: 'Register',
        cancelLabel: 'Close',
        confirmColor: AppColors.teal,
        icon: Icons.person_off_outlined,
      );
      if (goRegister && mounted) {
        await _goToRegister();
      }
    } else if ((state.lastAuthError ?? '').isNotEmpty) {
      // An empty lastAuthError means the user just closed the Google
      // account picker — not a real failure worth surfacing.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(state.lastAuthError!),
            backgroundColor: AppColors.primary),
      );
    }
  }

  Future<void> _showForgotPassword() async {
    final emailCtrl = TextEditingController(text: _email.text.trim());
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Reset Password'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email address'),
            validator: validateEmail,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (!(formKey.currentState?.validate() ?? false)) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('Send Link'),
          ),
        ],
      ),
    );
    if (ok != true) {
      emailCtrl.dispose();
      return;
    }
    final targetEmail = emailCtrl.text.trim();
    emailCtrl.dispose();
    if (!mounted) return;
    final error =
        await context.read<AppState>().sendPasswordResetEmail(targetEmail);
    if (!mounted) return;
    showResultToast(
      context,
      message: error ?? 'Password reset link sent to $targetEmail.',
      success: error == null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.vigiLiteBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/images/login_background.png', fit: BoxFit.cover),
          Container(color: AppColors.vigiLiteScrim.withValues(alpha: 0.62)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    size: 18, color: Colors.white),
                tooltip: 'Back',
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
          SafeArea(
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      children: [
                        // Logo + wordmark + tagline sit directly on the
                        // photo, above the light form card — not inside it.
                        ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Image.asset('assets/images/app_icon.png',
                              width: 60, height: 60, fit: BoxFit.cover),
                        ),
                        const SizedBox(height: 10),
                        Text('VIGILINK',
                            style: GoogleFonts.dmSans(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                letterSpacing: -0.5)),
                        const SizedBox(height: 2),
                        Text('CONNECT  •  DETECT  •  ALERT',
                            style: GoogleFonts.dmMono(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: AppColors.vigiLiteCyan,
                                letterSpacing: 1.1)),
                        const SizedBox(height: 22),
                        Container(
                          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                          decoration: BoxDecoration(
                            color: AppColors.vigiLiteCard,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.vigiLiteBorder),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.18),
                                  blurRadius: 24,
                                  offset: const Offset(0, 10))
                            ],
                          ),
                          child: Column(
                            children: [
                              Text('Welcome back',
                                  style: GoogleFonts.dmSans(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.vigiLiteText)),
                              const SizedBox(height: 4),
                              Text('Sign in to continue monitoring',
                                  style: GoogleFonts.dmSans(
                                      fontSize: 13,
                                      color: AppColors.vigiLiteText2)),
                              const SizedBox(height: 24),
                              AppTextField(
                                  label: 'EMAIL ADDRESS',
                                  hint: 'naruto@gmail.com',
                                  controller: _email,
                                  keyboardType: TextInputType.emailAddress,
                                  validator: validateEmail,
                                  lite: true),
                              AppTextField(
                                  label: 'PASSWORD',
                                  hint: '••••••••',
                                  controller: _pass,
                                  obscure: _obscure,
                                  suffix: GestureDetector(
                                      onTap: () =>
                                          setState(() => _obscure = !_obscure),
                                      child: Icon(
                                          _obscure
                                              ? Icons.visibility_off_outlined
                                              : Icons.visibility_outlined,
                                          size: 20,
                                          color: AppColors.vigiLiteText3)),
                                  validator: (v) => (v == null || v.isEmpty)
                                      ? 'Password is required'
                                      : null,
                                  lite: true),
                              Align(
                                alignment: Alignment.centerRight,
                                child: GestureDetector(
                                  onTap: _showForgotPassword,
                                  child: Text('Forgot password?',
                                      style: GoogleFonts.dmSans(
                                          color: AppColors.vigiLiteLink,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13)),
                                ),
                              ),
                              const SizedBox(height: 16),
                              PrimaryButton(
                                  label: 'LOG IN',
                                  onTap: _submit,
                                  loading: _loading,
                                  color: AppColors.vigiLiteCyan,
                                  textColor: Colors.white),
                              const SizedBox(height: 16),
                              Row(children: [
                                const Expanded(
                                    child: Divider(
                                        color: AppColors.vigiLiteBorder)),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10),
                                  child: Text('OR',
                                      style: GoogleFonts.dmSans(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.vigiLiteText3)),
                                ),
                                const Expanded(
                                    child: Divider(
                                        color: AppColors.vigiLiteBorder)),
                              ]),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                height: 52,
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(
                                        color: AppColors.vigiLiteBorder,
                                        width: 1.5),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(14)),
                                  ),
                                  onPressed:
                                      _googleLoading ? null : _submitGoogle,
                                  child: _googleLoading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2.2,
                                              color: AppColors.vigiLiteCyan))
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text('G',
                                                style: GoogleFonts.dmSans(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.w900,
                                                    color: const Color(
                                                        0xFF4285F4))),
                                            const SizedBox(width: 10),
                                            Text('Continue with Google',
                                                style: GoogleFonts.dmSans(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w700,
                                                    color: AppColors
                                                        .vigiLiteText)),
                                          ],
                                        ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              GestureDetector(
                                onTap: _goToRegister,
                                child: Text.rich(
                                  TextSpan(children: [
                                    TextSpan(
                                        text: 'No account yet? ',
                                        style: GoogleFonts.dmSans(
                                            color: AppColors.vigiLiteText2,
                                            fontSize: 13)),
                                    TextSpan(
                                        text: 'Register',
                                        style: GoogleFonts.dmSans(
                                            color: AppColors.vigiLiteLink,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13)),
                                  ]),
                                ),
                              ),
                              const SizedBox(height: 10),
                              GestureDetector(
                                onTap: () => showTermsAndConditionsModal(
                                    context,
                                    requireAgreement: false),
                                child: Text('Terms and Conditions',
                                    style: GoogleFonts.dmSans(
                                        color: AppColors.vigiLiteText3,
                                        fontSize: 12,
                                        decoration: TextDecoration.underline,
                                        decorationColor:
                                            AppColors.vigiLiteText3)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
