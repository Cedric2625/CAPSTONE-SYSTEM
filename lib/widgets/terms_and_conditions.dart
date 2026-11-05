import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../utils/app_theme.dart';

// ══════════════════════════════════════
// TERMS & CONDITIONS / PRIVACY POLICY
// ══════════════════════════════════════
// Shown two ways:
//  1. GATED, before registration ever starts (Login's "Register" links) —
//     must be read and agreed to before the Create Account form opens; a
//     decline simply closes the sheet and leaves the person on Login.
//  2. READ-ONLY, from the "Terms and Conditions" link on Login itself — any
//     visitor, registered or not, can review it any time; just a Close
//     button, no gate.
// Both are the exact same content and layout — one shared sheet, one
// boolean flag, no duplication.

class _TermsSection {
  final IconData icon;
  final String title;
  final String body;
  const _TermsSection(
      {required this.icon, required this.title, required this.body});
}

const List<_TermsSection> _termsSections = [
  _TermsSection(
    icon: Icons.fact_check_outlined,
    title: '1. Acceptance of This Agreement',
    body:
        'This End-User License Agreement and Privacy Policy ("Agreement") is a binding legal agreement between you and the developers of VIGILINK, a real-time vehicle theft monitoring and alert system developed as an academic capstone project of Caraga State University. By creating an account or tapping "I Agree" below, you confirm that you have read, understood, and agree to be bound by this Agreement; that you are at least 18 years old or possess the legal capacity to consent under Philippine law; and that all information and documents you submit — including your name, contact details, driver\'s license, and vehicle documents — are true, accurate, and belong to you. If you do not agree with any part of this Agreement, do not register for or use VIGILINK.',
  ),
  _TermsSection(
    icon: Icons.article_outlined,
    title: '2. License Grant',
    body:
        'Subject to your compliance with this Agreement, the developers grant you a limited, non-exclusive, non-transferable, and revocable license to install and use VIGILINK on a device you own or control, solely for its intended purpose — registering and monitoring your own vehicle(s) and participating in the community-based ad hoc alert network. This license does not sell or transfer any ownership of the app to you. All rights not expressly granted in this Agreement are reserved by the developers.',
  ),
  _TermsSection(
    icon: Icons.block,
    title: '3. License Restrictions',
    body:
        'You agree that you will not: (a) copy, modify, reverse-engineer, decompile, or disassemble any part of VIGILINK; (b) sell, rent, lease, sublicense, or distribute the app or access to it; (c) remove, obscure, or alter any proprietary notices; (d) use automated means such as bots or scrapers to access the app or its backend services; (e) attempt to bypass, disable, or interfere with the app\'s security, identity verification, or administrator-approval process; or (f) use the app for any unlawful purpose, including submitting fraudulent documents, false theft reports, or impersonating another person or vehicle owner.',
  ),
  _TermsSection(
    icon: Icons.shield_outlined,
    title: '4. Intellectual Property Rights',
    body:
        'VIGILINK — including its source code, design, interface, logo, and documentation — is the intellectual property of its developers and is protected by Philippine copyright and intellectual property law. Nothing in this Agreement transfers any intellectual property rights to you. Any feedback, suggestions, or bug reports you voluntarily submit may be used by the developers to improve the system without restriction, attribution, or compensation.',
  ),
  _TermsSection(
    icon: Icons.description_outlined,
    title: '5. Information We Collect',
    body:
        '• Account details: full name, email address, mobile number, and a device identifier.\n'
        '• Driver\'s license: a photo of the front and back of your valid Philippine driver\'s license.\n'
        '• Vehicle details: plate number, series, color, body type, year model, and a photo of its Official Receipt (OR) and Certificate of Registration (CR).\n'
        '• Location: your device\'s GPS position while monitoring is active, used to detect geofence violations and to plot alerts on the map.\n'
        '• Reports: any photos, notes, or details you submit when reporting a vehicle stolen or reporting a sighting of one.',
  ),
  _TermsSection(
    icon: Icons.verified_user_outlined,
    title: '6. Why We Collect It',
    body:
        'Your driver\'s license confirms you are a licensed driver — it is never used for any other purpose. Your vehicle\'s OR/CR confirms the vehicle is real, that you are its registered owner, and distinguishes it from every other vehicle in the system; an administrator reviews these documents before your account is approved. Your location is used only to detect when a vehicle leaves its configured safe zone and to display theft alerts on the map. Your contact details let a vehicle owner reach someone who reports a sighting of their stolen vehicle.',
  ),
  _TermsSection(
    icon: Icons.lock_outline,
    title: '7. Who Can Access Your Information',
    body:
        'Your driver\'s license photos, your vehicle\'s OR/CR photos, and your personal account details are private records. They are accessed or viewed ONLY by:\n\n'
        '• You, the account owner; and\n'
        '• The system administrator, solely to review submitted documents, decide on new registrations, and manage accounts.\n\n'
        'No other registered user, and no unauthorized third party, can ever view another person\'s driver\'s license, OR/CR, or personal information. This is separate from a theft alert itself — a plate number, vehicle description, and location are shown to nearby users so they can help, but never your identity documents. If you report a sighting of a stolen vehicle, your name and mobile number are shared only with that vehicle\'s registered owner, so they can reach you — with no one else.',
  ),
  _TermsSection(
    icon: Icons.cloud_outlined,
    title: '8. How Your Data Is Stored, Retained, and Protected',
    body:
        'Your information is stored using Firebase (Google Cloud infrastructure) and, for offline access, a local database on your own device. Data sent between your device and our servers is encrypted in transit. Reasonable technical and organizational measures are used to protect your data from unauthorized access, alteration, or disclosure. Your data is retained for as long as your account remains active, or as needed to comply with legal obligations; you may request its correction or deletion as described in Section 9.',
  ),
  _TermsSection(
    icon: Icons.gavel_outlined,
    title: '9. Your Rights Under the Data Privacy Act of 2012 (R.A. 10173)',
    body:
        'As a data subject under the Data Privacy Act of 2012 (R.A. 10173) and its Implementing Rules and Regulations, you have the right to: be informed that your personal data will be, are being, or were processed; access your personal data upon reasonable request; dispute and request correction of inaccurate data; object to or withdraw consent for certain processing; request erasure or blocking of your data, subject to legal retention requirements; be indemnified for damages arising from unlawful processing; obtain a copy of your data in electronic form; and lodge a complaint with the National Privacy Commission. To exercise any of these rights, contact the system administrator through the app.',
  ),
  _TermsSection(
    icon: Icons.checklist_outlined,
    title: '10. Your Responsibilities and Account Registration',
    body:
        'You agree to provide truthful, accurate, and current information; to register only vehicles you own or are legally authorized to register; to keep only one account per identity; to keep your password and device secure and confidential; and to never submit a false theft report or a fraudulent document. New registrations, including your driver\'s license and vehicle documents, are subject to review and approval by an administrator before your account becomes active. Misuse of the system — including submitting fraudulent documents or false reports, or attempting to bypass the approval process — may result in your registration being rejected, or your account being suspended or permanently removed.',
  ),
  _TermsSection(
    icon: Icons.hub_outlined,
    title: '11. The Ad Hoc Network',
    body:
        'A theft alert may be relayed through nearby participating devices over Bluetooth or Wi-Fi Direct ("ad hoc networking"), so it can still reach people nearby even without an internet connection. What gets relayed is limited strictly to the alert itself — plate number, description, location, and timestamp. Your private documents and personal account details are never sent over this network.',
  ),
  _TermsSection(
    icon: Icons.warning_amber_outlined,
    title: '12. Disclaimer of Warranties and System Limitations',
    body:
        'VIGILINK is provided "AS IS" and "AS AVAILABLE," without warranties of any kind, whether express or implied, including but not limited to merchantability, fitness for a particular purpose, and non-infringement. The developers do not guarantee uninterrupted, error-free, or secure access, or that an alert will always be delivered, relayed, or received in time. GPS accuracy and ad hoc network range depend on your device, its settings, and your surroundings, and are outside the developers\' control. VIGILINK is a monitoring and community-alert tool — it does NOT replace filing an official report with the Philippine National Police or other appropriate law enforcement authorities. As an academic capstone project, the system is provided on a best-effort, non-commercial basis.',
  ),
  _TermsSection(
    icon: Icons.gpp_maybe_outlined,
    title: '13. Limitation of Liability',
    body:
        'To the maximum extent permitted by law, the developers, their academic institution, and any contributors shall not be liable for any indirect, incidental, special, consequential, or punitive damages — including loss of the vehicle, loss of data, or a delayed, undelivered, or missed alert — arising from or related to your use of, or inability to use, VIGILINK, even if advised of the possibility of such damages.',
  ),
  _TermsSection(
    icon: Icons.gpp_bad_outlined,
    title: '14. Indemnification',
    body:
        'You agree to indemnify and hold harmless the developers from and against any claims, damages, losses, or liabilities — including reasonable legal fees — arising from your breach of this Agreement, your misuse of the system, or any false, inaccurate, or fraudulent information, document, or report you submit.',
  ),
  _TermsSection(
    icon: Icons.person_off_outlined,
    title: '15. Suspension and Termination',
    body:
        'This Agreement remains in effect for as long as you use VIGILINK. The developers or an administrator may suspend or permanently terminate your account, with or without prior notice, if you violate this Agreement, submit fraudulent documents or reports, or misuse the ad hoc network or the admin-approval process. You may stop using the app and request deletion of your account and data at any time by contacting the administrator.',
  ),
  _TermsSection(
    icon: Icons.link,
    title: '16. Governing Law, Severability, and Entire Agreement',
    body:
        'This Agreement is governed by the laws of the Republic of the Philippines, including the Data Privacy Act of 2012 (R.A. 10173) and its Implementing Rules and Regulations. Any dispute arising from this Agreement shall first be resolved amicably between the parties; failing that, it shall be submitted to the proper courts of Butuan City, Agusan del Norte, Philippines. If any provision of this Agreement is held invalid or unenforceable, the remaining provisions remain in full force and effect, and together with any policy referenced here, constitute the entire agreement between you and VIGILINK regarding its use.',
  ),
  _TermsSection(
    icon: Icons.update_outlined,
    title: '17. Changes to This Agreement',
    body:
        'This Agreement and Privacy Policy may be updated as the system continues to be developed. Continuing to use VIGILINK after an update means you accept the revised terms.',
  ),
  _TermsSection(
    icon: Icons.handshake_outlined,
    title: '18. Contact Us and Your Consent',
    body:
        'For questions about this Agreement, or to exercise your rights under the Data Privacy Act of 2012 (R.A. 10173), contact the system administrator through the app. By tapping "I Agree" below, you acknowledge that you have read and understood this End-User License Agreement and Privacy Policy, and you voluntarily consent to the collection, use, storage, and limited sharing of your information as described above — including submitting your driver\'s license and vehicle OR/CR for verification and admin-approval purposes.',
  ),
];

/// Shows the Terms & Conditions / Privacy Policy as a near full-screen
/// sheet. When [requireAgreement] is true (the registration gate), the
/// sheet must be scrolled to the end before "I Agree" enables, and returns
/// `true` only if the person actually taps it — `false`/null on Decline or
/// a swipe-to-dismiss. When false (the standalone Login link, read-only for
/// anyone including already-registered users), there's just a single Close
/// button and the return value is never used by the caller.
Future<bool> showTermsAndConditionsModal(BuildContext context,
    {bool requireAgreement = true}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (ctx) => _TermsSheet(requireAgreement: requireAgreement),
  );
  return result ?? false;
}

class _TermsSheet extends StatefulWidget {
  final bool requireAgreement;
  const _TermsSheet({required this.requireAgreement});

  @override
  State<_TermsSheet> createState() => _TermsSheetState();
}

class _TermsSheetState extends State<_TermsSheet> {
  final _scroll = ScrollController();
  bool _reachedEnd = false;

  @override
  void initState() {
    super.initState();
    if (!widget.requireAgreement) _reachedEnd = true;
    _scroll.addListener(_onScroll);
    // A short policy could already fit without scrolling on a tall screen —
    // don't leave "I Agree" permanently disabled in that case.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _scroll.position.maxScrollExtent <= 0) {
        _onScroll();
      }
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_reachedEnd) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 24) {
      setState(() => _reachedEnd = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canAgree = _reachedEnd || !widget.requireAgreement;
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(children: [
            const SizedBox(height: 10),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.asset('assets/images/app_icon.png',
                      width: 46, height: 46, fit: BoxFit.cover),
                ).animate().scale(
                    duration: 320.ms,
                    curve: Curves.elasticOut,
                    begin: const Offset(0.5, 0.5)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Terms & Conditions',
                            style: GoogleFonts.dmSans(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: AppColors.text)),
                        Text('Privacy Policy & Data Use',
                            style: GoogleFonts.dmSans(
                                fontSize: 12.5, color: AppColors.text3)),
                      ]),
                ),
              ]),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
                itemCount: _termsSections.length,
                itemBuilder: (_, i) {
                  final s = _termsSections[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          margin: const EdgeInsets.only(top: 2),
                          decoration: BoxDecoration(
                              color: AppColors.blueLight,
                              borderRadius: BorderRadius.circular(10)),
                          child: Icon(s.icon, size: 17, color: AppColors.blue),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.title,
                                  style: GoogleFonts.dmSans(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.text)),
                              const SizedBox(height: 4),
                              Text(s.body,
                                  style: GoogleFonts.dmSans(
                                      fontSize: 13,
                                      height: 1.5,
                                      color: AppColors.text2)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                      .animate(delay: (i * 40).ms)
                      .fadeIn(duration: 320.ms)
                      .slideY(begin: 0.08, end: 0, curve: Curves.easeOutCubic);
                },
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  24, 14, 24, 14 + MediaQuery.of(context).padding.bottom),
              child: widget.requireAgreement
                  ? Column(children: [
                      if (!canAgree)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.keyboard_double_arrow_down,
                                    size: 15, color: AppColors.text3),
                                const SizedBox(width: 6),
                                Text('Scroll to read the full policy',
                                    style: GoogleFonts.dmSans(
                                        fontSize: 11.5,
                                        color: AppColors.text3)),
                              ]),
                        ),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context, false),
                            style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 50),
                                foregroundColor: AppColors.text3,
                                side:
                                    const BorderSide(color: AppColors.border)),
                            child: const Text('Decline'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: canAgree
                                ? () => Navigator.pop(context, true)
                                : null,
                            icon: const Icon(Icons.check_circle_outline,
                                size: 18),
                            label: Text('I Agree',
                                style: GoogleFonts.dmSans(
                                    fontWeight: FontWeight.w700)),
                            style: ElevatedButton.styleFrom(
                                minimumSize: const Size(0, 50),
                                backgroundColor: AppColors.teal,
                                disabledBackgroundColor: AppColors.grayLight,
                                elevation: 0),
                          ),
                        ),
                      ]),
                    ])
                  : SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                            minimumSize: const Size(0, 50),
                            backgroundColor: AppColors.teal,
                            elevation: 0),
                        child: Text('Close',
                            style: GoogleFonts.dmSans(
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}
