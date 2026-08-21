import 'package:flutter/material.dart';

import '../analysis/swing_history.dart';
import '../analysis/swing_phases.dart';
import '../analysis/swing_history_store.dart';
import '../models/drill.dart';
import '../models/swing_analysis.dart';
import 'theme/app_theme.dart';
import 'widgets/drill_tile.dart';
import 'widgets/measurement_gauge.dart';
import 'widgets/phase_montage.dart';
import 'widgets/swing_comparison_view.dart';
import 'widgets/swing_player.dart';

/// The swing report, structured around visual hierarchy:
///   1. Hero — swing stills + tempo on one strong surface.
///   2. Measurements — four faults as a dense list, not individual cards.
///   3. Drills collapsed under each flagged fault, expanded only for the
///      focus fault.
///   4. Swing-over-swing comparison last.
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
    this.clipPath,
  });

  final SwingAnalysis analysis;

  /// Measured values from the previous stored session alongside this one; null
  /// on the first swing. Carries no improvement judgment.
  final SwingComparison? comparison;

  /// Whether this swing made it into the on-device corpus. A failure is shown
  /// rather than swallowed: a tester whose swings stopped recording should find
  /// that out from the app, not from an empty export weeks later.
  final HistoryWriteStatus writeStatus;

  /// Path to the retained recording, or null when the clip could not be kept.
  /// When present, the report shows a video player with phase markers so the
  /// golfer can scrub through the swing that was measured.
  final String? clipPath;

  @override
  Widget build(BuildContext context) {
    final comparison = this.comparison;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Report'),
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
          // 1. Hero: stills + tempo on one strong surface.
          _HeroSection(analysis: analysis),

          // Video scrubber — the golfer's swing with phase markers on the
          // timeline. Placed right after the hero stills so they can scrub
          // through the exact clip those stills came from.
          if (clipPath != null)
            SwingPlayer(
              clipPath: clipPath!,
              phases: analysis.phases,
              fps: analysis.fps,
              frameCount: analysis.frameCount,
            ),
          const _BetaCaveat(),
          if (writeStatus == HistoryWriteStatus.failed) const _NotSavedNotice(),

          // 2. Dense measurement list.
          const _SectionHeader('Measurements'),
          _MeasurementList(analysis: analysis),
          if (!analysis.anyFlagged) const _CleanSwingBanner(),

          // 3. Comparison last.
          if (comparison != null)
            SwingComparisonView(comparison: comparison),
          Gap.lg,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero section — swing stills + tempo on one strong surface
// ---------------------------------------------------------------------------

/// Unifies the phase montage stills and tempo stats into one Card. The stills
/// bleed to the card edges (the Card clips them); the tempo data sits in
/// padded space beneath.
class _HeroSection extends StatelessWidget {
  const _HeroSection({required this.analysis});

  final SwingAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final tempo = analysis.tempo;
    final hasStills =
        analysis.keyFrames != null && analysis.keyFrames!.isNotEmpty;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasStills) PhaseMontage(keyFrames: analysis.keyFrames!),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Swing tempo',
                    style: Theme.of(context).textTheme.titleMedium),
                Gap.sm,
                if (tempo == null)
                  const Text('Tempo unavailable.')
                else ...[
                  Row(
                    children: [
                      _TempoStat(
                        label: 'Back',
                        value:
                            '${tempo.backswingSeconds.toStringAsFixed(2)}s',
                      ),
                      Gap.hlg,
                      _TempoStat(
                        label: 'Down',
                        value:
                            '${tempo.downswingSeconds.toStringAsFixed(2)}s',
                      ),
                      Gap.hlg,
                      _TempoStat(
                        label: 'Ratio',
                        value: tempo.ratio.isFinite
                            ? '${tempo.ratio.toStringAsFixed(1)} : 1'
                            : '—',
                      ),
                    ],
                  ),
                  Gap.sm,
                  // The "tour average ~3 : 1" benchmark used to sit next to this
                  // number, inviting a comparison the capture rate cannot support.
                  // See the original _tempoCaveat comment for the full reasoning.
                  Text(
                    _tempoCaveat(tempo, analysis.fps),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ],
                Gap.xs,
                Text(
                  '${analysis.fps.toStringAsFixed(0)} fps',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One labelled value in the horizontal tempo row (Back / Down / Ratio).
class _TempoStat extends StatelessWidget {
  const _TempoStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
        Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Measurements — dense list, focus fault emphasized
// ---------------------------------------------------------------------------

/// Splits the four fault verdicts into a focus card (if the golfer targeted a
/// fault this swing) and a dense card grouping the rest.
class _MeasurementList extends StatelessWidget {
  const _MeasurementList({required this.analysis});

  final SwingAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final targeting = analysis.targeting;
    final faults = analysis.faults; // stable order

    FaultVerdict? focusVerdict;
    final restVerdicts = <FaultVerdict>[];
    for (final f in faults) {
      if (f.id == targeting) {
        focusVerdict = f;
      } else {
        restVerdicts.add(f);
      }
    }

    return Column(
      children: [
        // Focus fault — one genuinely emphasized surface.
        if (focusVerdict != null)
          _FocusMeasurementCard(
            verdict: focusVerdict,
            drills: analysis.recommendations[focusVerdict.id] ?? const [],
          ),

        // Remaining faults — dense rows, one shared surface.
        if (restVerdicts.isNotEmpty)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                for (var i = 0; i < restVerdicts.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  _MeasurementRow(
                    verdict: restVerdicts[i],
                    drills: analysis.recommendations[restVerdicts[i].id] ??
                        const [],
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// The focus fault's card: tinted in brand gold, detail text visible, and
/// drills expanded by default. This is the "one genuinely emphasized surface"
/// the hierarchy calls for — not a border on an otherwise identical card.
class _FocusMeasurementCard extends StatelessWidget {
  const _FocusMeasurementCard({
    required this.verdict,
    required this.drills,
  });

  final FaultVerdict verdict;
  final List<Drill> drills;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: sc.focus.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.center_focus_strong, size: 16, color: sc.focus),
                const SizedBox(width: 6),
                Text(
                  'Your focus this swing',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: sc.focus,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            Gap.sm,
            _MeasurementContent(verdict: verdict),
            if (drills.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Try these drills',
                  style: Theme.of(context).textTheme.labelLarge),
              Gap.xs,
              for (final drill in drills) DrillTile(drill: drill),
            ],
          ],
        ),
      ),
    );
  }
}

/// One compact measurement row in the dense card. Drills start collapsed;
/// tapping the "N drills" control expands them alongside the detail text.
class _MeasurementRow extends StatefulWidget {
  const _MeasurementRow({
    required this.verdict,
    required this.drills,
  });

  final FaultVerdict verdict;
  final List<Drill> drills;

  @override
  State<_MeasurementRow> createState() => _MeasurementRowState();
}

class _MeasurementRowState extends State<_MeasurementRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hasDrills = widget.verdict.flagged && widget.drills.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MeasurementContent(verdict: widget.verdict),
          if (hasDrills) ...[
            Gap.sm,
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${widget.drills.length} '
                      'drill${widget.drills.length == 1 ? '' : 's'}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              Gap.sm,
              for (final drill in widget.drills) DrillTile(drill: drill),
            ],
          ],
        ],
      ),
    );
  }
}

/// The icon + label + badge + detail + gauge core shared by both the focus card
/// and the dense measurement rows.
class _MeasurementContent extends StatelessWidget {
  const _MeasurementContent({required this.verdict});

  final FaultVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    final statusColor = verdict.flagged ? sc.flagged : sc.notSeen;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              verdict.flagged ? Icons.info_outline : Icons.check_circle_outline,
              color: statusColor,
              size: 20,
            ),
            Gap.hsm,
            Expanded(
              child: Text(
                verdict.tentativeLabel,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                verdict.flagged ? 'Possible' : 'Not flagged',
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
        Gap.xs,
        Text(verdict.detail,
            style: Theme.of(context).textTheme.bodySmall),
        if (verdict.measured != null && verdict.reference != null)
          MeasurementGauge(
            measured: verdict.measured!,
            reference: verdict.reference!,
            flagged: verdict.flagged,
            isAngle: verdict.isAngle,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Supporting widgets
// ---------------------------------------------------------------------------

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
          Icon(Icons.info_outline,
              size: 16, color: theme.colorScheme.outline),
          Gap.hsm,
          Expanded(
            child: Text(
              'Early numbers — we haven\'t validated these against a wide '
              'range of swings yet, so treat them as rough readings.',
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
            Gap.hsm,
            Expanded(
              child: Text(
                'This swing wasn\'t saved — your report is still here, '
                'but it won\'t show up in your history.',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
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
          'Nothing flagged. We only check four things so far — '
          'this just means nothing stood out.',
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tempo caveat — how much to trust the ratio
// ---------------------------------------------------------------------------

/// How much to trust the tempo ratio on this particular swing.
///
/// Keyed on the frames the phases actually span, not on the capture rate. The
/// previous version branched on fps alone and so told a golfer their downswing
/// "spans only a few frames" when the detector had put 58 frames in it — a
/// hedge about a condition that was not true. Frame rate only matters here
/// through the counts it produces, so the counts are what this reads.
String _tempoCaveat(SwingTempo? tempo, double fps) {
  final rate = 'Captured at ${fps.toStringAsFixed(0)} fps.';
  final precision = tempoRatioPrecision(tempo);
  if (tempo == null || precision == null) return rate;

  // Events are located to the nearest frame, so the ratio is only pinned down
  // to within `precision`. Saying that number is more use than grading it —
  // and it is printed at whatever precision it actually has, never rounded up
  // to a friendlier-looking figure. Overstating the uncertainty is a smaller
  // lie than understating it, but it is still a lie.
  final window = precision.toStringAsFixed(precision < 0.1 ? 2 : 1);
  return '$rate Ratio is accurate to about ±$window.';
}
