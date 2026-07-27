import 'package:flutter/material.dart';

import '../analysis/swing_history.dart';
import '../analysis/swing_history_store.dart';
import '../models/swing_analysis.dart';
import 'widgets/drill_tile.dart';
import 'widgets/fault_card.dart';
import 'widgets/swing_comparison_view.dart';

/// The swing report: tempo summary, the four fault measurements, drills nested
/// under each flagged fault, and — from the second swing on — a raw value
/// comparison against the previous session.
///
/// Fault language is deliberately tentative and the comparison carries no
/// verdict: the thresholds are unvalidated, so the report measures and shows,
/// it does not judge.
class ReportScreen extends StatelessWidget {
  const ReportScreen({
    super.key,
    required this.analysis,
    this.comparison,
    this.writeStatus = HistoryWriteStatus.saved,
  });

  final SwingAnalysis analysis;

  /// Measured values from the previous stored session alongside this one; null
  /// on the first swing. Carries no improvement judgment.
  final SwingComparison? comparison;

  /// Whether this swing made it into the on-device corpus. A failure is shown
  /// rather than swallowed: a tester whose swings stopped recording should find
  /// that out from the app, not from an empty export weeks later.
  final HistoryWriteStatus writeStatus;

  @override
  Widget build(BuildContext context) {
    final comparison = this.comparison;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Swing report'),
        actions: [
          IconButton(
            tooltip: 'Record another',
            icon: const Icon(Icons.videocam),
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
          ),
        ],
      ),
      body: ListView(
        children: [
          const _BetaCaveat(),
          if (writeStatus == HistoryWriteStatus.failed) const _NotSavedNotice(),
          _TempoSummary(analysis: analysis),
          const _SectionHeader('What we measured'),
          for (final verdict in analysis.faultsByFocus)
            FaultCard(
              verdict: verdict,
              isFocus: verdict.id == analysis.targeting,
              drills: [
                for (final drill in analysis.recommendations[verdict.id] ??
                    const [])
                  DrillTile(drill: drill),
              ],
            ),
          if (!analysis.anyFlagged) const _CleanSwingBanner(),
          if (comparison != null)
            SwingComparisonView(comparison: comparison),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Beta honesty note: the reference values behind every flag on this screen are
/// still unvalidated, so the report is indicative only.
class _BetaCaveat extends StatelessWidget {
  const _BetaCaveat();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.science_outlined,
              size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Beta: these measurements are indicative only. The reference '
              'values were tuned on high-speed footage, and phone video is '
              'measured over different time windows than they assume, so the '
              'numbers below are not directly comparable to them and have not '
              'been checked against a reference set.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the swing could not be written to the on-device corpus. The
/// report itself is still valid — only the record of it is missing.
class _NotSavedNotice extends StatelessWidget {
  const _NotSavedNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.save_outlined, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'This swing could not be saved to your swing history. The '
                'report below is still accurate, but this swing will not appear '
                'in your history or in an export.',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TempoSummary extends StatelessWidget {
  const _TempoSummary({required this.analysis});

  final SwingAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final tempo = analysis.tempo;
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Swing tempo',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (tempo == null)
              const Text('Tempo unavailable.')
            else ...[
              Text('Backswing: ${tempo.backswingSeconds.toStringAsFixed(2)}s '
                  '(${tempo.backswingFrames} frames)'),
              Text('Downswing: ${tempo.downswingSeconds.toStringAsFixed(2)}s '
                  '(${tempo.downswingFrames} frames)'),
              const SizedBox(height: 4),
              Text(
                'Ratio ${tempo.ratio.isFinite ? tempo.ratio.toStringAsFixed(1) : '—'} : 1',
              ),
              const SizedBox(height: 4),
              // The "tour average ~3 : 1" benchmark used to sit next to this
              // number, inviting a comparison the capture rate cannot support.
              // The downswing is roughly a quarter of a second: at this phone's
              // frame rate that is a handful of frames, and being off by one or
              // two on where impact lands moves the ratio across most of the
              // range that would make the comparison meaningful.
              Text(
                _tempoCaveat(analysis.fps),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${analysis.frameCount} frames @ ${analysis.fps.toStringAsFixed(0)} fps',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// How much to trust the tempo ratio at the rate this swing was captured.
///
/// Below roughly 120 fps the downswing spans too few frames for the ratio to be
/// worth comparing against anything, so the report says so instead of printing
/// a benchmark beside it.
String _tempoCaveat(double fps) {
  if (fps >= 120) {
    return 'Timing precision depends on frame rate; this swing was captured at '
        '${fps.toStringAsFixed(0)} fps.';
  }
  return 'At ${fps.toStringAsFixed(0)} fps the downswing spans only a few '
      'frames, so this ratio is rough — not precise enough to compare against '
      'a target.';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}

/// Shown when no measurement passed its reference value.
///
/// Deliberately not an all-clear, and deliberately not green. The softening
/// pass hedged the positive direction ("Possible…") and left this one
/// confident, but nothing measured here supports "your swing is fine": the
/// false-negative rate is as unvalidated as the false-positive rate, and only
/// four faults are measured at all.
class _CleanSwingBanner extends StatelessWidget {
  const _CleanSwingBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'None of the four measurements passed its reference value this '
          'swing. That is not a clean bill of health — it means these four '
          'checks did not see anything, not that the swing was good.',
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}
