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
///   2. Headline — one sentence summarising the swing.
///   3. Measurements — four faults as a dense list, not individual cards.
///   4. Drills collapsed under each flagged fault, expanded only for the
///      focus fault.
///   5. Swing-over-swing comparison last.
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
          if (writeStatus == HistoryWriteStatus.failed) const _NotSavedNotice(),

          // 2. Headline — one sentence the golfer came for.
          _HeadlineSummary(analysis: analysis),

          // 3. Dense measurement list.
          _MeasurementList(analysis: analysis),

          // 4. Comparison last.
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
                  const Text('Could not measure tempo for this swing.')
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
                  Text(
                    _tempoCaveat(tempo, analysis.fps),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ],
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
///
/// When nothing is flagged, the measurements start collapsed — the headline
/// already said "looking good", so the detail is there for the curious, not
/// pushed in the golfer's face.
class _MeasurementList extends StatefulWidget {
  const _MeasurementList({required this.analysis});

  final SwingAnalysis analysis;

  @override
  State<_MeasurementList> createState() => _MeasurementListState();
}

class _MeasurementListState extends State<_MeasurementList> {
  late bool _collapsed = !widget.analysis.anyFlagged;

  @override
  Widget build(BuildContext context) {
    final analysis = widget.analysis;
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

    // When collapsed, show a subtle "show measurements" tap target instead of
    // the full list.
    if (_collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: InkWell(
          onTap: () => setState(() => _collapsed = false),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.expand_more,
                    size: 18, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 4),
                Text(
                  'Show measurements',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ],
            ),
          ),
        ),
      );
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

/// One-sentence summary of the swing — the headline the golfer came for.
///
/// When something is flagged, names the flagged faults. When nothing is flagged,
/// gives a brief encouraging note. The beta caveat is folded in as a small
/// tappable footnote rather than a separate block that pushes content down.
class _HeadlineSummary extends StatelessWidget {
  const _HeadlineSummary({required this.analysis});

  final SwingAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sc = SwingColors.of(context);
    final flagged = analysis.faults.where((f) => f.flagged).toList();

    final String headline;
    final Color headlineColor;
    final IconData headlineIcon;

    if (flagged.isEmpty) {
      headline = 'Looking good — nothing stood out.';
      headlineColor = sc.notSeen;
      headlineIcon = Icons.check_circle_outline;
    } else if (flagged.length == 1) {
      headline = '${flagged.first.label} stood out this swing.';
      headlineColor = sc.flagged;
      headlineIcon = Icons.info_outline;
    } else {
      final names = flagged.map((f) => f.label.toLowerCase()).toList();
      final last = names.removeLast();
      headline = '${names.join(', ')} and $last stood out.';
      headlineColor = sc.flagged;
      headlineIcon = Icons.info_outline;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(headlineIcon, size: 20, color: headlineColor),
              ),
              Gap.hsm,
              Expanded(
                child: Text(
                  headline,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: headlineColor,
                  ),
                ),
              ),
            ],
          ),
          Gap.sm,
          // Beta note — compact, tappable for detail, not a content-pushing block.
          const _BetaFootnote(),
        ],
      ),
    );
  }
}

/// Compact beta note: a single line with a tooltip for the full explanation.
/// Replaces the old multi-line _BetaCaveat that pushed content down.
class _BetaFootnote extends StatelessWidget {
  const _BetaFootnote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'These numbers haven\'t been validated against a wide range '
          'of swings yet — treat them as rough readings.',
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.science_outlined,
              size: 13, color: theme.colorScheme.outline),
          const SizedBox(width: 4),
          Text(
            'Early readings',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
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
  final rate = '${fps.toStringAsFixed(0)} fps';
  final precision = tempoRatioPrecision(tempo);
  if (tempo == null || precision == null) return rate;

  // Events are located to the nearest frame, so the ratio is only pinned down
  // to within `precision`. A golfer doesn't need the arithmetic — just whether
  // the reading is solid.
  if (precision < 0.15) return rate;
  return '$rate · ratio is approximate at this frame count';
}
