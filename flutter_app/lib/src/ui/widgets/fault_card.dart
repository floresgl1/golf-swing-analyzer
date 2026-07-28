import 'package:flutter/material.dart';

import '../../models/swing_analysis.dart';

/// A single fault measurement: a status chip, the measured detail, and (when
/// flagged) the drills that target it nested beneath it.
///
/// Presentation is deliberately tentative — the thresholds behind [flagged] are
/// unvalidated, so a flagged fault reads as "possible", not as a finding.
class FaultCard extends StatelessWidget {
  const FaultCard({
    super.key,
    required this.verdict,
    required this.drills,
    this.isFocus = false,
  });

  final FaultVerdict verdict;

  /// Drill tiles to show under a flagged fault (empty when nothing was flagged).
  final List<Widget> drills;

  /// Whether this is the fault the golfer chose to work on this swing.
  final bool isFocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final flagged = verdict.flagged;
    // Amber, not error red: this is something to look at, not a diagnosis.
    final statusColor = flagged ? Colors.amber.shade800 : Colors.green.shade600;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: isFocus
          ? RoundedRectangleBorder(
              side: BorderSide(color: scheme.primary, width: 1.5),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isFocus) ...[
              Row(
                children: [
                  Icon(Icons.center_focus_strong,
                      size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Your focus this swing',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Icon(
                  flagged ? Icons.info_outline : Icons.check_circle,
                  color: statusColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    verdict.tentativeLabel,
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
                    flagged ? 'POSSIBLE' : 'NOT SEEN',
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
              Text('Drills that target this',
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
