import 'package:flutter/material.dart';

import '../../analysis/swing_history.dart';

/// "Progress vs previous swing" card for the report screen.
///
/// Renders one row per fault (previous -> current value with an
/// improved/worsened/unchanged verdict and FIXED/NEW threshold-crossing
/// badges), a tempo row, and -- when a fault appeared that was not in the
/// previous swing -- a callout pointing the golfer at the drills recommended
/// for it in the fault section above.
class SwingComparisonView extends StatelessWidget {
  const SwingComparisonView({super.key, required this.comparison});

  final SwingComparison comparison;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previousDate = comparison.previousSession.timestamp;
    final focus = comparison.focusFault;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Progress vs previous swing',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Compared with the session from '
              '${previousDate.year}-${_two(previousDate.month)}-${_two(previousDate.day)} '
              '${_two(previousDate.hour)}:${_two(previousDate.minute)}'
              '${focus != null ? '. You were working on: ${faultLabels[focus] ?? focus}.' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final fault in comparison.faults)
              _FaultRow(fault: fault, isFocus: fault.faultId == focus),
            if (comparison.tempo != null) _TempoRow(tempo: comparison.tempo!),
            if (comparison.fixedFaults.isNotEmpty)
              _Callout(
                color: Colors.green,
                icon: Icons.check_circle_outline,
                text: 'Nice work — you cleared: '
                    '${comparison.fixedFaults.map((f) => faultLabels[f]!.toLowerCase()).join(', ')}. '
                    'Keep the drills in rotation so it stays fixed.',
              ),
            if (comparison.newFaults.isNotEmpty)
              _Callout(
                color: Colors.red,
                icon: Icons.warning_amber_outlined,
                text: 'NEW fault this session: '
                    '${comparison.newFaults.map((f) => faultLabels[f]!).join(', ')} — '
                    'not present in your previous swing. Start on the drills '
                    'recommended for it above.',
              ),
            if (focus != null) _focusVerdict(theme, focus),
          ],
        ),
      ),
    );
  }

  Widget _focusVerdict(ThemeData theme, String focus) {
    FaultComparison? fault;
    for (final f in comparison.faults) {
      if (f.faultId == focus) fault = f;
    }
    if (fault == null) return const SizedBox.shrink();
    final improved = fault.trend == Trend.improved;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        improved
            ? 'Your focus fault (${fault.label.toLowerCase()}) improved — '
                'the practice is paying off!'
            : 'Your focus fault (${fault.label.toLowerCase()}) has not '
                'improved yet — stick with the drills and re-test.',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: improved ? Colors.green.shade700 : Colors.orange.shade800,
        ),
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _FaultRow extends StatelessWidget {
  const _FaultRow({required this.fault, required this.isFocus});

  final FaultComparison fault;
  final bool isFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, word) = switch (fault.trend) {
      Trend.improved => (Icons.arrow_downward, Colors.green, 'improved!'),
      Trend.worsened => (Icons.arrow_upward, Colors.red, 'worsened'),
      Trend.unchanged => (Icons.remove, Colors.grey, 'unchanged'),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${fault.label}${isFocus ? ' (your focus)' : ''}: '
              '${fault.valuesText} — $word',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (fault.crossing == Crossing.faultFixed)
            const _Badge(text: 'FIXED', color: Colors.green),
          if (fault.crossing == Crossing.faultNew)
            const _Badge(text: 'NEW FAULT', color: Colors.red),
        ],
      ),
    );
  }
}

class _TempoRow extends StatelessWidget {
  const _TempoRow({required this.tempo});

  final TempoComparison tempo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, word) = switch (tempo.trend) {
      Trend.improved => (
          Icons.arrow_downward,
          Colors.green,
          'improved (closer to the 3:1 tour benchmark)'
        ),
      Trend.worsened => (
          Icons.arrow_upward,
          Colors.red,
          'worsened (further from the 3:1 tour benchmark)'
        ),
      Trend.unchanged => (Icons.remove, Colors.grey, 'unchanged'),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Tempo ratio: ${tempo.valuesText} — $word',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final MaterialColor color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.shade50,
        border: Border.all(color: color.shade400),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color.shade800,
        ),
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.color, required this.icon, required this.text});

  final MaterialColor color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.shade50,
        border: Border.all(color: color.shade200),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color.shade700),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
