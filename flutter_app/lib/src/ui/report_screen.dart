import 'package:flutter/material.dart';

import '../analysis/swing_history.dart';
import '../models/swing_analysis.dart';
import 'widgets/drill_tile.dart';
import 'widgets/fault_card.dart';
import 'widgets/swing_comparison_view.dart';

/// The swing report: tempo summary, the four fault verdicts, drills nested
/// under each flagged fault, and — from the second swing on — progress vs the
/// previous session.
class ReportScreen extends StatelessWidget {
  const ReportScreen({super.key, required this.analysis, this.comparison});

  final SwingAnalysis analysis;

  /// Progress vs the previous stored session; null on the first swing.
  final SwingComparison? comparison;

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
          _TempoSummary(analysis: analysis),
          const _SectionHeader('Fault check'),
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
                'Ratio ${tempo.ratio.isFinite ? tempo.ratio.toStringAsFixed(1) : '—'} : 1  '
                '(tour average ~3 : 1)',
                style: const TextStyle(fontWeight: FontWeight.w600),
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

class _CleanSwingBanner extends StatelessWidget {
  const _CleanSwingBanner();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: Colors.green.withValues(alpha: 0.12),
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.emoji_events, color: Colors.green),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'No faults flagged — nice swing! Keep grooving that move.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
