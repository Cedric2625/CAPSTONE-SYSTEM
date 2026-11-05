/// Input checks shared by every screen that takes a mobile number — the
/// registration form and Edit Profile — so the two can never disagree about
/// what a valid number is. Pure Dart on purpose: the web admin build
/// imports this too.
final _phMobile = RegExp(r'^(\+63|0)9\d{9}$');

/// Form validator for a Philippine mobile number. A number is required.
String? validatePhMobile(String? v) {
  if (v == null || v.trim().isEmpty) return 'Mobile number is required.';
  if (!_phMobile.hasMatch(_stripSeparators(v))) {
    return 'Please enter a valid Philippine mobile number (e.g., 09171234567).';
  }
  return null;
}

/// One form for comparing two entries of the same number: "+63 917 123 4567"
/// and "0917-123-4567" are the same number, not a change.
String canonicalPhMobile(String v) {
  final d = _stripSeparators(v);
  return d.startsWith('+63') ? '0${d.substring(3)}' : d;
}

String _stripSeparators(String v) => v.replaceAll(RegExp(r'[\s\-]'), '');

// Basic "something@something.tld" check — good enough client-side gating;
// Firebase Auth is the real authority on whether an email is valid/usable.
final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

bool isValidEmail(String v) => _email.hasMatch(v);

/// Form validator for an email address.
String? validateEmail(String? v) =>
    (v == null || !isValidEmail(v)) ? 'Enter a valid email' : null;

/// Email domains allowed to self-register a new VIGILINK account — a
/// personal Gmail address or a CARSU-issued one. Deliberately only gates
/// NEW registrations (see RegisterScreen's email validator and
/// AppState.submitRegistration): Login, Forgot Password, and the Admin
/// Login's email field all keep accepting whatever domain an
/// already-registered account's email actually has.
const registrationEmailDomains = ['gmail.com', 'carsu.edu.ph'];

bool hasAllowedRegistrationEmailDomain(String v) {
  final at = v.trim().toLowerCase().lastIndexOf('@');
  if (at == -1) return false;
  return registrationEmailDomains
      .contains(v.trim().toLowerCase().substring(at + 1));
}

/// Canonical form of a plate used to tell whether two plates are the SAME
/// real-world vehicle regardless of formatting — "ABC-123", "ABC 123" and
/// "ABC123" must all collide to one key. Shared by [AppState] (cross-account
/// and same-account plate uniqueness) and the vehicle registration screen
/// (comparing a plate read off the OR against the one read off the CR), so
/// the two can never define "the same plate" differently.
String normalizedPlate(String plate) =>
    plate.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Canonical form of a full name used only to check whether it's already
/// registered — case and extra whitespace shouldn't let "Juan Dela Cruz" and
/// "juan   dela cruz" both go through as if they were different people.
/// Never used for storage or display — the name as actually typed keeps its
/// original casing/spacing everywhere else. Used by
/// [AppState.submitRegistration], the only place a new account is created.
String normalizedFullName(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
