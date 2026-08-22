import 'package:flutter/material.dart';

import '../../analysis/swing_history.dart';
import '../theme/app_theme.dart';

/// "Last swing vs this swing" card for the report screen.
///
/// Renders the previous session's measured value next to the current one, one
/// row per fault plus a tempo row. Deliberately non-judgmental: no trend, no
/// threshold-crossing badges, no improved/fixed/new language. [SwingComparison]
/// still computes trends and crossings, but this view does not read them —
/// calling a change progress would claim more than the unvalidated thresholds
/// can support. See the note on `SwingComparison.between`.
class SwingComparisonView extends StatelessWidget {
  const SwingComparisonView({super.key, required this.comparison});

  final SwingComparison comparison;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previousDate = comparison.previousSession.timestamp;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Last time → this time',
                style: theme.textTheme.titleMedium),
            Gap.xs,
            Text(
              'Previous swing: ${_friendlyDate(previousDate)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final fault in comparison.faults) _FaultRow(fault: fault),
            if (comparison.tempo != null) _TempoRow(tempo: comparison.tempo!),
          ],
        ),
      ),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _friendlyDate(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour < 12 ? 'am' : 'pm';
    return '${_months[d.month - 1]} ${d.day}, $h:$m $ampm';
  }
}

class _FaultRow extends StatelessWidget {
  const _FaultRow({required this.fault});

  final FaultComparison fault;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        '${fault.label}: ${fault.valuesText}',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

class _TempoRow extends StatelessWidget {
  const _TempoRow({required this.tempo});

  final TempoComparison tempo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        'Tempo ratio: ${tempo.valuesText}',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}
