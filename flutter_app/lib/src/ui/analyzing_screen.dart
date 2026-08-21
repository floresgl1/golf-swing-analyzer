import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../analysis/measurement_basis.dart';
import '../analysis/rejection_log.dart';
import '../analysis/swing_history.dart';
import '../analysis/swing_history_store.dart';
import '../models/drill.dart';
import '../services/clip_store.dart';
import '../services/swing_analyzer.dart';
import 'report_screen.dart';
import 'theme/app_theme.dart';

/// Runs the analysis pipeline on the recorded video, shows progress as a
/// three-step stepper with a determinate arc, then replaces itself with the
/// report (or an error). The first frame of the golfer's video is shown behind
/// the progress so the wait reads as work on *their* swing.
class AnalyzingScreen extends StatefulWidget {
  const AnalyzingScreen({
    super.key,
    required this.videoPath,
    required this.drills,
    required this.handedness,
    required this.participantId,
    required this.captureSessionId,
    this.swingKind = SwingKind.natural,
    this.calibrationFault,
    this.targeting,
  });

  final String videoPath;
  final List<Drill> drills;

  /// Anonymous golfer this swing belongs to.
  final String participantId;

  /// Groups this swing with the others recorded in the same sitting.
  final String captureSessionId;

  /// Whether this is a natural swing or a labelled calibration swing.
  final SwingKind swingKind;

  /// The fault deliberately exaggerated, when [swingKind] is calibration.
  final String? calibrationFault;

  /// Which wrist phase detection should track. Chosen on the record screen;
  /// there is no safe default, because analyzing a left-handed golfer as
  /// right-handed measures the trail wrist and yields meaningless phases.
  final Handedness handedness;

  /// The fault the golfer chose to work on, or null for a full swing check.
  final String? targeting;

  @override
  State<AnalyzingScreen> createState() => _AnalyzingScreenState();
}

class _AnalyzingScreenState extends State<AnalyzingScreen> {
  late final SwingAnalyzer _analyzer;
  AnalysisStage _stage = AnalysisStage.extractingFrames;
  double _fraction = 0;
  String? _error;

  /// First frame of the golfer's video, shown as a dimmed background while
  /// the pipeline runs. Null until extracted (or on failure — a dark
  /// background is fine).
  String? _previewPath;

  @override
  void initState() {
    super.initState();
    _analyzer = SwingAnalyzer(
      drills: widget.drills,
      handedness: widget.handedness,
      participantId: widget.participantId,
      captureSessionId: widget.captureSessionId,
    );
    _run();
  }

  /// Grab frame 0 from the video as a quick preview thumbnail. This is a
  /// single-frame extraction that takes milliseconds, not the full decode the
  /// pipeline does. Returns null on any failure — a missing preview is a
  /// cosmetic loss, never a blocking one.
  Future<String?> _extractPreviewFrame() async {
    try {
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path,
          'analysis_preview_${DateTime.now().millisecondsSinceEpoch}.jpg');
      final session = await FFmpegKit.execute(
        '-y -i "${widget.videoPath}" -vframes 1 -qscale:v 4 "$path"',
      );
      if (ReturnCode.isSuccess(await session.getReturnCode())) {
        return path;
      }
    } catch (_) {
      // Preview is cosmetic; swallow any failure.
    }
    return null;
  }

  /// Move this swing's recording somewhere it will survive, or null if that
  /// failed.
  ///
  /// Never allowed to fail the analysis: a golfer who cannot keep the video is
  /// still owed their report. The failure is logged rather than shown, because
  /// the report itself carries no claim that depends on the clip existing.
  Future<StoredClip?> _retainClip() async {
    try {
      final store = await ClipStore.forApp();
      return await store.retain(widget.videoPath);
    } catch (error, stack) {
      debugPrint('Clip retention failed: $error\n$stack');
      return null;
    }
  }

  Future<void> _run() async {
    // Quick single-frame thumbnail for the background. This is a separate
    // ffmpeg call that grabs only frame 0, not the full extraction the
    // pipeline will do — it takes milliseconds and gives the golfer their
    // own swing to look at while they wait.
    final preview = await _extractPreviewFrame();
    if (mounted && preview != null) {
      setState(() => _previewPath = preview);
    }

    // Declared outside the try so the rejection path can still name the clip:
    // a rejected swing is only useful as a corpus record if it says which
    // video it came from.
    StoredClip? clip;
    try {
      // Retain the recording BEFORE analyzing it, for two reasons. The clip
      // lives in a temp directory iOS reclaims on its own schedule, and a
      // swing that fails to analyze is the most useful one to be able to
      // rewatch — the hard-fail path throws, so retaining afterwards would
      // lose exactly the clips worth keeping. Analysis then reads the retained
      // copy, so there is only ever one of a ~50 MB file on the phone.
      clip = await _retainClip();

      final analysis = await _analyzer.analyze(
        clip?.path ?? widget.videoPath,
        targeting: widget.targeting,
        swingKind: widget.swingKind,
        calibrationFault: widget.calibrationFault,
        clipName: clip?.name,
        onProgress: (stage, fraction) {
          if (!mounted) return;
          setState(() {
            _stage = stage;
            _fraction = fraction;
          });
        },
      );

      // Record this swing and fetch the previous one's values to show alongside
      // it. A storage failure must not block the report — but it must not be
      // silent either: this swing is then absent from the corpus, and the old
      // blanket `catch` made that indistinguishable from a first swing.
      SwingComparison? comparison;
      var writeStatus = HistoryWriteStatus.saved;
      try {
        final dir = await getApplicationDocumentsDirectory();
        final store = SwingHistoryStore(
          File(p.join(dir.path, 'swing_history.jsonl')),
          legacyFile: File(p.join(dir.path, 'swing_history.json')),
          participantId: widget.participantId,
        );
        final result = await store.append(analysis.session);
        comparison = result.comparison;
      } catch (error, stack) {
        writeStatus = HistoryWriteStatus.failed;
        comparison = null;
        debugPrint('Swing history append failed: $error\n$stack');
        await _logWriteFailure(error);
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ReportScreen(
            analysis: analysis,
            comparison: comparison,
            writeStatus: writeStatus,
            clipPath: clip?.path,
          ),
        ),
      );
    } on SwingAnalysisException catch (e) {
      // Keep the clip and everything measured from it. The golfer has already
      // been told this was not a usable swing; the corpus still wants it,
      // because a gate whose rejections are never recorded cannot be measured.
      await _logRejection(e, clip?.name);
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Analysis failed: $e');
    }
  }

  /// Record a swing the app refused to report on.
  ///
  /// These are the negatives P1.1 needs and the corpus was missing: before
  /// 2026-08-20 a hard fail wrote nothing at all, so the only clips that ever
  /// reached the corpus were the ones that passed the gate.
  Future<void> _logRejection(
      SwingAnalysisException error, String? clipName) async {
    if (error.reason == null) return; // not a rejection, a crash
    try {
      final dir = await getApplicationDocumentsDirectory();
      await RejectionLog(
        File(p.join(dir.path, 'swing_history_rejections.jsonl')),
      ).record(RejectedSwing(
        timestamp: DateTime.now(),
        reason: error.reason!,
        clipName: clipName,
        fps: error.fps,
        frameCount: error.frameCount,
        poseCoverageFraction: error.poseCoverageFraction,
        frames: error.frames,
        participantId: widget.participantId,
        captureSessionId: widget.captureSessionId,
        appVersion: appVersion,
      ));
    } catch (_) {
      // The golfer has already seen the message; a failed log helps nobody.
    }
  }

  /// Count a failed history write somewhere durable, so "this device is not
  /// recording swings" is discoverable later instead of only in a debug console.
  Future<void> _logWriteFailure(Object error) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      await HistoryFailureLog(
        File(p.join(dir.path, 'swing_history_failures.jsonl')),
      ).record(error);
    } catch (_) {
      // If even the failure log is unwritable there is nothing further to do.
    }
  }

  @override
  void dispose() {
    _analyzer.dispose();
    // Clean up the preview thumbnail.
    final path = _previewPath;
    if (path != null) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background: their swing, dimmed.
          if (_previewPath != null)
            Image.file(
              File(_previewPath!),
              fit: BoxFit.cover,
              color: Colors.black.withValues(alpha: 0.6),
              colorBlendMode: BlendMode.darken,
              errorBuilder: (_, __, ___) => const SizedBox.expand(),
            ),

          // Cancel button (top-left).
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: IconButton(
                  tooltip: 'Cancel',
                  icon: Icon(Icons.close, color: sc.onScrim),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),

          // Content: progress stepper or error.
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _error != null
                  ? _ErrorView(
                      message: _error!,
                      onBack: () => Navigator.of(context).pop(),
                    )
                  : _ProgressView(stage: _stage, fraction: _fraction),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Progress view — circular arc + three-step stepper
// ---------------------------------------------------------------------------

class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.stage, required this.fraction});

  final AnalysisStage stage;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);

    // Determinate during pose detection (the longest wait); indeterminate
    // during the other two stages where we can't report frame-level progress.
    final showPercent = stage == AnalysisStage.detectingPose;
    final progressValue = showPercent ? fraction : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Circular progress arc.
        SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 120,
                height: 120,
                child: CircularProgressIndicator(
                  value: progressValue,
                  strokeWidth: 5,
                  color: sc.focus,
                  backgroundColor: sc.onScrim.withValues(alpha: 0.12),
                  strokeCap: StrokeCap.round,
                ),
              ),
              if (showPercent)
                Text(
                  '${(fraction * 100).toInt()}%',
                  style: TextStyle(
                    color: sc.onScrim,
                    fontSize: 24,
                    fontWeight: FontWeight.w300,
                  ),
                ),
            ],
          ),
        ),
        Gap.lg,

        // Three-step stepper.
        _StepRow(
          label: 'Reading video',
          status: _statusFor(AnalysisStage.extractingFrames),
        ),
        Gap.sm,
        _StepRow(
          label: 'Finding your body',
          status: _statusFor(AnalysisStage.detectingPose),
        ),
        Gap.sm,
        _StepRow(
          label: 'Building report',
          status: _statusFor(AnalysisStage.computingReport),
        ),
      ],
    );
  }

  _StepStatus _statusFor(AnalysisStage step) {
    if (stage.index > step.index) return _StepStatus.completed;
    if (stage == step) return _StepStatus.active;
    return _StepStatus.pending;
  }
}

enum _StepStatus { pending, active, completed }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.status});

  final String label;
  final _StepStatus status;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    final Color iconColor;
    final Color textColor;
    final IconData icon;

    switch (status) {
      case _StepStatus.completed:
        iconColor = sc.notSeen;
        textColor = sc.onScrim.withValues(alpha: 0.6);
        icon = Icons.check_circle;
      case _StepStatus.active:
        iconColor = sc.focus;
        textColor = sc.onScrim;
        icon = Icons.radio_button_checked;
      case _StepStatus.pending:
        iconColor = sc.onScrim.withValues(alpha: 0.3);
        textColor = sc.onScrim.withValues(alpha: 0.4);
        icon = Icons.radio_button_unchecked;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: iconColor),
        Gap.hsm,
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 15,
            fontWeight:
                status == _StepStatus.active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Error view
// ---------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline,
            size: 48, color: Theme.of(context).colorScheme.error),
        Gap.md,
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: sc.onScrim),
        ),
        Gap.lg,
        FilledButton(
          onPressed: onBack,
          child: const Text('Record again'),
        ),
      ],
    );
  }
}
