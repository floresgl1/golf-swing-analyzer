import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../analysis/faults.dart';
import '../analysis/swing_history.dart';
import '../analysis/swing_phases.dart';
import 'theme/app_theme.dart';
import 'widgets/swing_player.dart';

/// Detail view for one stored swing from the history list.
///
/// Shows the four fault measurements, tempo, and — when a clip and per-frame
/// data are both available — the video player with phase markers.
///
/// **No trend or improvement claims appear here.** This screen shows
/// measurements for a single swing, consistent with the Beta decision record.
class SwingDetailScreen extends StatefulWidget {
  const SwingDetailScreen({super.key, required this.session});

  final SwingSession session;

  @override
  State<SwingDetailScreen> createState() => _SwingDetailScreenState();
}

class _SwingDetailScreenState extends State<SwingDetailScreen> {
  /// Absolute path to the retained clip, or null when no clip was kept or
  /// the file is no longer on disk.
  String? _clipPath;

  /// Phases re-derived from stored frame series, for the video scrubber.
  SwingPhases? _phases;

  @override
  void initState() {
    super.initState();
    _resolveClip();
  }

  /// Try to find the clip on disk and re-compute phases from stored frame data.
  Future<void> _resolveClip() async {
    final clipName = widget.session.clipName;
    if (clipName == null) return;

    try {
      final docs = await getApplicationDocumentsDirectory();
      final path = p.join(docs.path, 'clips', clipName);
      if (!await File(path).exists()) return;

      SwingPhases? phases;
      final frames = widget.session.frames;
      final fps = widget.session.fps;
      if (frames != null && fps != null && fps > 0) {
        final wristY = frames.wristY.map((v) => v ?? double.nan).toList();
        final torso = frames.torso.map((v) => v ?? double.nan).toList();
        final hipX = frames.hipX.map((v) => v ?? double.nan).toList();
        phases = detectPhases(wristY, fps: fps, torso: torso, hipX: hipX);
      }

      if (!mounted) return;
      setState(() {
        _clipPath = path;
        _phases = phases;
      });
    } catch (_) {
      // Clip playback is a convenience; a missing clip never blocks the
      // measurements view.
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final theme = Theme.of(context);
    final sc = SwingColors.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(_formatAppBarDate(session.timestamp))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // Video player — only when clip and phases are available.
          if (_clipPath != null && _phases != null)
            SwingPlayer(
              clipPath: _clipPath!,
              phases: _phases!,
              fps: session.fps ?? 30,
              frameCount: session.frameCount ?? _phases!.finish + 1,
              faultWindows: _buildFaultWindows(session, _phases!),
            ),

          // Calibration banner.
          if (session.swingKind == SwingKind.calibration)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: sc.drillAdvanced.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.science_outlined, size: 16,
                      color: sc.drillAdvanced),
                  Gap.hsm,
                  Expanded(
                    child: Text(
                      'Calibration swing'
                      '${session.calibrationFault != null ? ' — ${faultLabels[session.calibrationFault] ?? session.calibrationFault}' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: sc.drillAdvanced,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Focus fault.
          if (session.targeting != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'Working on: ${faultLabels[session.targeting] ?? session.targeting}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: sc.focus,
                ),
              ),
            ),

          // Tempo.
          if (session.tempoRatio != null)
            _TempoTile(ratio: session.tempoRatio!),

          Gap.sm,

          // Measurements header.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('Measurements', style: theme.textTheme.titleMedium),
          ),

          // The four faults.
          for (final faultId in faultIds)
            _FaultTile(
              faultId: faultId,
              result: session.faults[faultId],
              isFocus: session.targeting == faultId,
            ),

          const Divider(height: 32),

          // Metadata.
          _MetadataSection(session: session),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fault-window highlights for the video scrubber
// ---------------------------------------------------------------------------

/// Build [FaultWindow]s from a stored session's fault map. Same logic as the
/// report-screen version, but driven by [SwingSession.faults] instead of
/// [SwingAnalysis.faults].
List<FaultWindow> _buildFaultWindows(SwingSession session, SwingPhases phases) {
  final windows = <FaultWindow>[];
  for (final id in faultIds) {
    final result = session.faults[id];
    if (result == null || !result.flagged) continue;
    final int start;
    final int end;
    switch (id) {
      case faultReversePivot:
        start = phases.takeaway;
        end = phases.top;
      default:
        start = phases.takeaway;
        end = phases.impact;
    }
    windows.add(FaultWindow(
      label: faultLabels[id] ?? id,
      startFrame: start,
      endFrame: end,
    ));
  }
  return windows;
}

// ---------------------------------------------------------------------------
// Tempo tile
// ---------------------------------------------------------------------------

class _TempoTile extends StatelessWidget {
  const _TempoTile({required this.ratio});

  final double ratio;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tempo', style: theme.textTheme.titleSmall),
                    Gap.xs,
                    Text(
                      '${ratio.toStringAsFixed(1)} : 1',
                      style: theme.textTheme.headlineMedium,
                    ),
                  ],
                ),
              ),
              Text(
                'backswing : downswing',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fault tile
// ---------------------------------------------------------------------------

class _FaultTile extends StatelessWidget {
  const _FaultTile({
    required this.faultId,
    required this.result,
    required this.isFocus,
  });

  final String faultId;
  final FaultResult? result;
  final bool isFocus;

  @override
  Widget build(BuildContext context) {
    if (result == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final sc = SwingColors.of(context);
    final value = result!.value;
    final flagged = result!.flagged;

    final statusColor = flagged ? sc.flagged : sc.notSeen;
    final statusLabel = flagged ? 'Possible' : 'Not seen';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: isFocus
            ? sc.focus.withValues(alpha: 0.08)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: isFocus
            ? Border.all(color: sc.focus.withValues(alpha: 0.3))
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Status dot.
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor,
              ),
            ),
            Gap.hsm,
            // Label + status.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    faultLabels[faultId] ?? faultId,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isFocus ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  Gap.xs,
                  Text(
                    statusLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: statusColor,
                    ),
                  ),
                ],
              ),
            ),
            // Value.
            if (value != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatFaultValue(faultId, value),
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    faultUnits[faultId] ?? '',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Metadata section — small, at the bottom
// ---------------------------------------------------------------------------

class _MetadataSection extends StatelessWidget {
  const _MetadataSection({required this.session});

  final SwingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );

    final items = <String>[];
    final fps = session.fps;
    if (fps != null) items.add('${fps.toStringAsFixed(fps == fps.roundToDouble() ? 0 : 1)} fps');
    final fc = session.frameCount;
    if (fc != null) items.add('$fc frames');
    final cov = session.poseCoverageFraction;
    if (cov != null) items.add('${(cov * 100).toInt()}% pose coverage');
    final hand = session.handedness;
    if (hand != null) items.add(hand == Handedness.left ? 'Left-handed' : 'Right-handed');
    final ver = session.appVersion;
    if (ver != null) items.add('v$ver');
    if (session.clipName != null) items.add(session.clipName!);

    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Details', style: theme.textTheme.titleSmall),
          Gap.sm,
          Text(items.join(' · '), style: muted),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Date formatting
// ---------------------------------------------------------------------------

String _formatAppBarDate(DateTime dt) {
  final month = const {
    1: 'Jan', 2: 'Feb', 3: 'Mar', 4: 'Apr', 5: 'May', 6: 'Jun',
    7: 'Jul', 8: 'Aug', 9: 'Sep', 10: 'Oct', 11: 'Nov', 12: 'Dec',
  }[dt.month] ?? '${dt.month}';
  final hour = dt.hour;
  final minute = dt.minute.toString().padLeft(2, '0');
  final period = hour >= 12 ? 'PM' : 'AM';
  final h = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
  return '$month ${dt.day}, ${dt.year} · $h:$minute $period';
}
