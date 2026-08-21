import 'package:flutter/material.dart';

import 'theme/app_theme.dart';

/// Placeholder for the swing history list (ROADMAP item 6).
///
/// Shown in the Swings tab so the shell is structurally complete. Once
/// item 6 adds the actual swing list, this file gets replaced.
class SwingsScreen extends StatelessWidget {
  const SwingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Swings')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.format_list_bulleted,
                size: 48,
                color: theme.colorScheme.outline,
              ),
              Gap.md,
              Text(
                'Your swing history will appear here.',
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              Gap.sm,
              Text(
                'Record a swing to get started.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
