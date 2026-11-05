import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_theme.dart';
import '../widgets/widgets.dart';

// ══════════════════════════════════════
// ONBOARDING — a new, 3-page first-launch carousel introducing VIGILINK
// (not part of the original manuscript's numbered screens, hence no `sN_`
// prefix). Shown once, before Splash, then never again — `main.dart` checks
// [onboardingSeenKey] before `runApp` and picks the initial route from it.
// Pure UI/navigation: no account, auth, or data logic lives here.
// ══════════════════════════════════════

const onboardingSeenKey = 'vigilink_seen_onboarding';

class _OnboardingPage {
  final String image;
  final String headingWhite;
  final String headingCyan;
  final String subtitle;
  const _OnboardingPage({
    required this.image,
    required this.headingWhite,
    required this.headingCyan,
    required this.subtitle,
  });
}

const _pages = [
  _OnboardingPage(
    image: 'assets/images/onboarding_bg_1.png',
    headingWhite: 'MONITOR',
    headingCyan: 'ALL YOUR RIDES',
    subtitle: 'Currently supporting cars — more vehicle types coming soon.',
  ),
  _OnboardingPage(
    image: 'assets/images/onboarding_bg_2.png',
    headingWhite: 'REAL-TIME ALERTS',
    headingCyan: 'AND SHARED AWARENESS',
    subtitle: 'Stay informed. Help others. Be part of a safer community.',
  ),
  _OnboardingPage(
    image: 'assets/images/onboarding_bg_3.png',
    headingWhite: 'A STRONGER COMMUNITY',
    headingCyan: 'ON THE ROAD',
    subtitle: 'Connected devices. Faster alerts. Greater awareness.',
  ),
];

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(onboardingSeenKey, true);
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/');
  }

  void _next() {
    if (_index == _pages.length - 1) {
      _finish();
      return;
    }
    _controller.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final last = _index == _pages.length - 1;
    return Scaffold(
      backgroundColor: AppColors.vigiBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: _pages.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _OnboardingPageView(page: _pages[i]),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: last ? 0 : 1,
                  child: TextButton(
                    onPressed: last ? null : _finish,
                    child: Text('Skip',
                        style: GoogleFonts.dmSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.vigiText2)),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 36,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _pages.length; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: i == _index ? 22 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                              color: i == _index
                                  ? AppColors.vigiCyan
                                  : AppColors.vigiText3,
                              borderRadius: BorderRadius.circular(99)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  PrimaryButton(
                    label: last ? 'Get Started' : 'Next',
                    color: AppColors.vigiCyan,
                    textColor: AppColors.vigiBg,
                    icon: Icons.arrow_forward,
                    onTap: _next,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingPageView extends StatelessWidget {
  final _OnboardingPage page;
  const _OnboardingPageView({required this.page});

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(page.image, fit: BoxFit.cover),
          // A dark gradient (not a flat overlay) so the photo reads clearly
          // up top and the heading/subtitle stay readable lower down,
          // wherever they land on the image.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xCC061522)],
                stops: [0.45, 1.0],
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 128,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(page.headingWhite,
                    style: GoogleFonts.dmSans(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: AppColors.vigiText,
                        height: 1.15)),
                Text(page.headingCyan,
                    style: GoogleFonts.dmSans(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: AppColors.vigiCyan,
                        height: 1.15)),
                const SizedBox(height: 10),
                Text(page.subtitle,
                    style: GoogleFonts.dmSans(
                        fontSize: 14, color: AppColors.vigiText2, height: 1.4)),
              ],
            ),
          ),
        ],
      );
}
