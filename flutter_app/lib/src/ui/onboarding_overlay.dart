import 'package:flutter/material.dart';

import 'theme/app_theme.dart';

/// A two-page onboarding overlay shown on first launch.
///
/// Page 1: what the app does (one sentence).
/// Page 2: how to frame the shot (side-on, full body).
///
/// Shown as a full-screen modal route so it sits above the camera tab. Calls
/// [onDismissed] when the golfer taps "Get started", which the caller uses to
/// persist the flag.
class OnboardingOverlay extends StatefulWidget {
  const OnboardingOverlay({super.key, required this.onDismissed});

  final VoidCallback onDismissed;

  @override
  State<OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends State<OnboardingOverlay> {
  final _controller = PageController();
  int _currentPage = 0;

  static const _pageCount = 2;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentPage < _pageCount - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onDismissed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sc = SwingColors.of(context);
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _OnboardingPage(
                    icon: Icons.sports_golf,
                    iconColor: sc.focus,
                    title: 'Fore Swing',
                    body: 'Record your swing and get instant feedback on '
                        'four common faults — no account, no upload, '
                        'everything stays on your phone.',
                  ),
                  _OnboardingPage(
                    icon: Icons.videocam_outlined,
                    iconColor: sc.focus,
                    title: 'How to film',
                    body: 'Set your phone at hip height, about 3 metres away, '
                        'facing your lead side.\n\n'
                        'Keep your full body in frame from address through '
                        'finish — the analyzer needs to see your hips, '
                        'shoulders, and feet throughout the swing.',
                  ),
                ],
              ),
            ),
            // Page indicator dots
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pageCount, (i) {
                  final active = i == _currentPage;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: active
                          ? sc.focus
                          : theme.colorScheme.outline.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),
            // Action button
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _next,
                  child: Text(
                    _currentPage < _pageCount - 1 ? 'Next' : 'Get started',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single onboarding page: centered icon, title, and body text.
class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: iconColor),
          Gap.lg,
          Text(
            title,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          Gap.md,
          Text(
            body,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
