import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../analysis/swing_history.dart';
import '../models/drill.dart';
import '../models/swing_analysis.dart';
import '../services/swing_analyzer.dart';
import 'report_screen.dart';

/// Runs the analysis pipeline on the recorded video, shows progress, then
/// replaces itself with the report (or an error).
class AnalyzingScreen extends StatefulWidget {
  const AnalyzingScreen({
    super.key,
    required this.videoPath,
    required this.drills,
    this.targeting,
  });

  final String videoPath;
  final List<Drill> drills;

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
    _analyzer = SwingAnalyzer(drills: widget.drills);
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
      // Verification loop: log this swing to the on-device history and fetch
      // the comparison against the previous session. Best-effort — a storage
      // hiccup must never block the report.
      SwingComparison? comparison;
      try {
        final dir = await getApplicationDocumentsDirectory();
        final store =
            SwingHistoryStore(File(p.join(dir.path, 'swing_history.json')));
        comparison = await store.append(analysis.session);
      } catch (_) {
        comparison = null;
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) =>
              ReportScreen(analysis: analysis, comparison: comparison),
        ),
      );
    } on SwingAnalysisException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Analysis failed: $e');
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
        AnalysisStage.computingReport => 'Scoring your swing…',
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
