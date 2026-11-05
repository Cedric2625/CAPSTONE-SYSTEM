import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Wraps Firebase Authentication (email/password) — the REAL backend
/// identity provider named in the manuscript's software requirements
/// (Table 3.3.2.1: "Backend / Database: Firebase (Firestore, Auth)").
///
/// Local SQLite (see DatabaseService) deliberately does NOT verify
/// passwords anymore — it only caches the signed-in user's profile
/// (name/phone/deviceId) so screens like Profile still work offline,
/// exactly matching the manuscript's stated scope for local storage
/// ("offline alert and vehicle data storage"). Credential verification
/// always happens against Firebase's servers, so a stolen or extracted
/// local database contains no password material to crack offline.
///
/// Bonus: Firebase Auth already rate-limits repeated failed sign-ins
/// server-side (`too-many-requests`) — real brute-force protection that a
/// local-only auth check could never provide.
class FirebaseAuthService {
  FirebaseAuthService._();
  static final FirebaseAuthService instance = FirebaseAuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  /// The currently signed-in Firebase user, or null. Available
  /// synchronously and offline once a user has signed in on this device
  /// before — Firebase Auth persists this locally, so session restore on
  /// app relaunch doesn't require connectivity.
  User? get currentFirebaseUser => _auth.currentUser;

  /// Re-confirms the signed-in person's identity with their password — the
  /// standard step before a sensitive change (Firebase calls it
  /// re-authentication). Returns null when the password is right, or a
  /// user-facing error message.
  Future<String?> reauthenticate(String password) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      return 'Please sign in again to continue.';
    }
    try {
      await user.reauthenticateWithCredential(
          EmailAuthProvider.credential(email: email, password: password));
      return null;
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case 'invalid-credential':
        case 'wrong-password':
          return 'Incorrect password.';
        case 'too-many-requests':
          return 'Too many attempts. Please wait a moment and try again.';
        default:
          return _friendlyMessage(e);
      }
    } catch (_) {
      return 'Could not reach the server. Check your internet connection and try again.';
    }
  }

  Future<AuthOutcome> register(
      {required String email,
      required String password,
      required String displayName}) async {
    final User user;
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
          email: email.trim(), password: password);
      user = cred.user!;
    } on FirebaseAuthException catch (e) {
      return AuthOutcome.failure(_friendlyMessage(e), code: e.code);
    } catch (_) {
      return AuthOutcome.failure(
          'Could not reach the server. Check your internet connection and try again.');
    }

    // From here the Firebase ACCOUNT already exists — a failure in either
    // of these two follow-up calls must never be reported back as "you
    // failed to register", or the person's account would be silently
    // stranded (created, but the app tells them otherwise, and every retry
    // just fails again as `email-already-in-use`), with no path to
    // actually verify it. This is exactly the bug behind "filled up
    // registration, no verification email arrived": Firebase's free-tier
    // email-sending has a rate limit (easy to hit during heavy testing),
    // and a single `sendEmailVerification()` hiccup used to fail this
    // whole method even though the account was fine. Bundling all three
    // calls into one try/catch was the mistake; each step now fails
    // independently, and the caller still gets a success outcome as long
    // as the account itself exists — the Email Verification screen's own
    // "Resend Email" button (see resendEmailVerification) is exactly the
    // recovery path for a first send that didn't go through.
    try {
      await user.updateDisplayName(displayName);
    } catch (_) {
      // Cosmetic only (shows as the account's display name) — never worth
      // blocking a successful registration over.
    }
    String? verificationEmailError;
    try {
      // FR-01 / "for verification and security reasons": confirms the
      // registrant actually controls this email address before the account
      // is considered complete — the free, no-billing-required replacement
      // for SMS OTP (see manuscript alignment note in AppState.submitRegistration()).
      await user.sendEmailVerification();
    } on FirebaseAuthException catch (e) {
      // Captured, not swallowed — see the note above for why a failure here
      // must never fail the whole method (the account still exists). But
      // silently pretending this succeeded was its own bug: the Email
      // Verification screen would show "Check your email" regardless, with
      // no way to tell the person the automatic send likely never went out
      // (most often Firebase's free-tier email-sending rate limit, easy to
      // hit during testing) — they'd just wait on an email that was never
      // coming, with no hint to tap Resend right away. Passed back so the
      // screen can show it immediately instead.
      verificationEmailError = e.code == 'too-many-requests'
          ? "Firebase's free plan limits how many verification emails can be sent per hour. This is a temporary limit, not a problem with your account — wait a few minutes, then tap Resend Email below."
          : _friendlyMessage(e);
    } catch (_) {
      verificationEmailError =
          'Could not send the verification email. Check your internet connection, then tap Resend Email below.';
    }
    return AuthOutcome.success(user,
        verificationEmailError: verificationEmailError);
  }

  /// Re-sends the verification email to the currently signed-in user (for a
  /// "Resend Email" action, mirroring the old OTP screen's "Resend Code").
  Future<String?> resendEmailVerification() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return 'Session expired. Please register again.';
      await user.sendEmailVerification();
      return null;
    } on FirebaseAuthException catch (e) {
      return e.code == 'too-many-requests'
          ? "Firebase's free plan limits how many verification emails can be sent per hour. This is a temporary limit, not a problem with your account — please wait a few minutes and try again."
          : _friendlyMessage(e);
    } catch (_) {
      return 'Could not send the verification email. Check your internet connection and try again.';
    }
  }

  /// Reloads the current user from Firebase's servers and reports whether
  /// their email is now verified — call this after the user says they've
  /// clicked the link in their inbox.
  Future<bool> checkEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      await user.reload();
    } catch (_) {
      // Offline or unreachable — report the last-known local state rather
      // than failing outright.
    }
    return _auth.currentUser?.emailVerified ?? false;
  }

  /// True only for an account created through the app's Register form —
  /// i.e. it has the email/password provider. Google can be linked to such an
  /// account (same email), but an account that ONLY has Google was never
  /// registered through the app.
  ///
  /// This matters because Firebase's Google sign-in silently creates a brand
  /// new account for any Google email it hasn't seen: without this check,
  /// tapping "Continue with Google" with an unregistered Gmail signed the
  /// person straight in, bypassing registration entirely.
  bool isRegisteredAccount(User user) =>
      user.providerData.any((p) => p.providerId == 'password');

  /// Deletes [user]'s own sign-in account (best effort) and signs out fully,
  /// including Google's cached session. Used to undo a Google sign-in for an
  /// unregistered account, and to free the email of a rejected registration
  /// so it can be registered again.
  /// Returns false when the account could NOT be deleted — Firebase only lets
  /// an account delete itself shortly after signing in, so a long-open session
  /// can be refused. The caller then asks the person to log in again.
  Future<bool> discardAccount(User user) async {
    var deleted = false;
    try {
      await user.delete();
      deleted = true;
    } catch (_) {}
    await signOut();
    return deleted;
  }

  /// Signs in with a Google account. Note Firebase auto-creates an account
  /// for an unseen Google email at this step — the CALLER must reject that
  /// case with [isRegisteredAccount] (see AppState.signInWithGoogle), since
  /// Google is meant for logging into accounts registered through the app,
  /// not for registering. A Google-authenticated email is already verified
  /// by Google itself, so no separate email-verification step is needed.
  Future<AuthOutcome> signInWithGoogle() async {
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        // User cancelled the account picker — not an error.
        return AuthOutcome.failure('');
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final cred = await _auth.signInWithCredential(credential);
      return AuthOutcome.success(cred.user!);
    } on FirebaseAuthException catch (e) {
      return AuthOutcome.failure(_friendlyMessage(e));
    } catch (_) {
      return AuthOutcome.failure(
          'Could not sign in with Google. Check your internet connection and try again.');
    }
  }

  Future<AuthOutcome> login(
      {required String email, required String password}) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
          email: email.trim(), password: password);
      return AuthOutcome.success(cred.user!);
    } on FirebaseAuthException catch (e) {
      return AuthOutcome.failure(_friendlyMessage(e));
    } catch (_) {
      return AuthOutcome.failure(
          'Could not reach the server. Check your internet connection and try again.');
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
    // Also clears Google's own cached session — without this, tapping
    // "Sign in with Google" again after logout would silently reuse the
    // previous account instead of showing the account picker.
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Not signed in via Google, or Google Play Services unavailable —
      // either way, logout must still succeed.
    }
  }

  /// Sends a Firebase password-reset email. Returns null on success, or a
  /// user-facing error message on failure (malformed email, no network, …).
  Future<String?> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendlyMessage(e);
    } catch (_) {
      return 'Could not reach the server. Check your internet connection and try again.';
    }
  }

  String _friendlyMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':
        return 'This email address is already registered. Please log in instead, or use a different email address.';
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'weak-password':
        return 'Password is too weak. Use at least 8 characters with a mix of letters, numbers, or symbols.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Invalid email or password.';
      case 'user-disabled':
        return 'This account has been disabled. Contact support.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'network-request-failed':
        return 'No internet connection. Registration and login require connectivity.';
      case 'credential-already-in-use':
      case 'account-exists-with-different-credential':
        return 'This Google account\'s email is already registered. Please log in with your email and password instead, or use a different Google account.';
      case 'provider-already-linked':
        return 'This account is already linked to that sign-in method.';
      case 'configuration-not-found':
        return 'Authentication isn\'t fully set up for this project yet. In the Firebase Console, go to Authentication → Sign-in method and enable Email/Password (and Google, for sign-in), then try again.';
      case 'sign_in_canceled':
      case 'popup_closed_by_user':
        return '';
      default:
        return e.message ?? 'Authentication failed.';
    }
  }
}

class AuthOutcome {
  final bool ok;
  final User? user;
  final String? error;

  /// The raw `FirebaseAuthException.code` behind [error], when there was
  /// one (null for a non-Firebase failure, e.g. no network at all). Lets a
  /// caller like [AppState.submitRegistration] tell "this email is already
  /// registered" apart from every other reason `register()` can fail,
  /// without re-parsing the human-readable [error] string.
  final String? code;

  /// Set only by [FirebaseAuthService.register] when the account was created
  /// successfully but sending the FIRST verification email failed — the
  /// caller shows this right away on the Verify Your Email screen instead of
  /// silently leaving the person waiting on an email that was never sent.
  final String? verificationEmailError;
  AuthOutcome._(this.ok, this.user, this.error,
      [this.verificationEmailError, this.code]);
  factory AuthOutcome.success(User user, {String? verificationEmailError}) =>
      AuthOutcome._(true, user, null, verificationEmailError);
  factory AuthOutcome.failure(String error, {String? code}) =>
      AuthOutcome._(false, null, error, null, code);
}
