import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../analysis/swing_history.dart';
import '../analysis/swing_history_store.dart';
import '../models/drill.dart';
import '../services/swing_analyzer.dart';
import 'report_screen.dart';

/// Runs the analysis pipeline on the recorded video, shows progress, then
/// replaces itself with the report (or an error).
class AnalyzingScreen extends StatefulWidget {
  const AnalyzingScreen({
    super.key,
    required this.videoPath,
    required this.drills,
    required this.handedness,
    this.targeting,
  });

  final String videoPath;
  final List<Drill> drills;

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
    );
    _run();
  }

  Future<void> _run() async {
    try {
      final analysis = await _analyzer.analyze(
        widget.videoPath,
        targeting: widget.targeting,
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
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Analysis failed: $e');
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
                    const SizedBox(height: 20),
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
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton(onPressed: onBack, child: const Text('Record again')),
      ],
    );
  }
}
