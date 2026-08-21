import 'dart:io';

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

/// Runs the analysis pipeline on the recorded video, shows progress, then
/// replaces itself with the report (or an error).
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
  Future<void> _logRejection(SwingAnalysisException error, String? clipName) async {
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
    super.dispose();
  }

  String get _stageLabel => switch (_stage) {
        AnalysisStage.extractingFrames => 'Extracting frames…',
        AnalysisStage.detectingPose => 'Detecting body pose…',
        AnalysisStage.computingReport => 'Measuring your swing…',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Analyzing')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error != null
              ? _ErrorView(
                  message: _error!,
                  onBack: () => Navigator.of(context).pop(),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(
                        value: _stage == AnalysisStage.detectingPose
                            ? _fraction
                            : null,
                      ),
                    ),
                    Gap.lg,
                    Text(_stageLabel,
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline,
            size: 48, color: Theme.of(context).colorScheme.error),
        Gap.md,
        Text(message, textAlign: TextAlign.center),
        Gap.lg,
        FilledButton(onPressed: onBack, child: const Text('Record again')),
      ],
    );
  }
}
