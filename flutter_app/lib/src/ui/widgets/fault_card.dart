import 'package:flutter/material.dart';

import '../../models/swing_analysis.dart';

/// A single fault verdict: a colored status chip, the measured detail, and (when
/// flagged) the recommended drills nested beneath it.
class FaultCard extends StatelessWidget {
  const FaultCard({super.key, required this.verdict, required this.drills});

  final FaultVerdict verdict;

  /// Drill tiles to show under a flagged fault (empty when OK).
  final List<Widget> drills;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final flagged = verdict.flagged;
    final statusColor = flagged ? scheme.error : Colors.green.shade600;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  flagged ? Icons.warning_amber_rounded : Icons.check_circle,
                  color: statusColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    verdict.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    flagged ? 'FLAGGED' : 'OK',
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(verdict.detail,
                style: Theme.of(context).textTheme.bodyMedium),
            if (drills.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Drills to fix this',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              ...drills,
            ],
          ],
        ),
      ),
    );
  }
}
