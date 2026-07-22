/// Orchestrates the full "record then analyze" pipeline, the mobile equivalent
/// of the Python `faults.main()`:
///   1. extract every frame of the recorded video,
///   2. run pose estimation on each,
///   3. assemble the per-frame trajectory arrays,
///   4. detect swing phases + tempo,
///   5. run the four fault detectors,
///   6. recommend drills for whatever was flagged.
library;

import 'dart:async';

import '../analysis/drill_recommender.dart';
import '../analysis/faults.dart';
import '../analysis/swing_history.dart';
import '../analysis/swing_phases.dart';
import '../models/drill.dart';
import '../models/frame_features.dart';
import '../models/swing_analysis.dart';
import 'frame_extractor.dart';
import 'pose_estimator.dart';

/// Thrown when the swing can't be analyzed (e.g. no pose detected in enough
/// frames, so phases can't be located).
class SwingAnalysisException implements Exception {
  final String message;
  const SwingAnalysisException(this.message);
  @override
  String toString() => 'SwingAnalysisException: $message';
}

/// Progress phases reported to the UI while analysis runs.
enum AnalysisStage { extractingFrames, detectingPose, computingReport }

typedef ProgressCallback = void Function(
  AnalysisStage stage,
  double fraction,
);

class SwingAnalyzer {
  SwingAnalyzer({
    required this.drills,
    Handedness handedness = Handedness.right,
    FrameExtractor? frameExtractor,
    PoseEstimator? poseEstimator,
  })  : _frameExtractor = frameExtractor ?? FrameExtractor(),
        _poseEstimator = poseEstimator ?? PoseEstimator(handedness: handedness);

  final List<Drill> drills;
  final FrameExtractor _frameExtractor;
  final PoseEstimator _poseEstimator;

  /// Analyze the recorded video at [videoPath]. [onProgress] is optional.
  Future<SwingAnalysis> analyze(
    String videoPath, {
    ProgressCallback? onProgress,
  }) async {
    onProgress?.call(AnalysisStage.extractingFrames, 0);
    final extracted = await _frameExtractor.extract(videoPath);
    try {
      final features = <FrameFeatures>[];
      final total = extracted.framePaths.length;
      for (var i = 0; i < total; i++) {
        features.add(
          await _poseEstimator.featuresForFrame(extracted.framePaths[i]),
        );
        onProgress?.call(
          AnalysisStage.detectingPose,
          total == 0 ? 1 : (i + 1) / total,
        );
      }

      onProgress?.call(AnalysisStage.computingReport, 1);
      return _buildReport(features, extracted.fps);
    } finally {
      // Clean up the extracted JPEGs regardless of outcome.
      if (extracted.workingDir.existsSync()) {
        extracted.workingDir.deleteSync(recursive: true);
      }
    }
  }

  SwingAnalysis _buildReport(List<FrameFeatures> features, double fps) {
    // Assemble parallel arrays, matching the lists built in faults.main().
    final eyeX = [for (final f in features) f.eyeX];
    final eyeY = [for (final f in features) f.eyeY];
    final shX = [for (final f in features) f.shoulderX];
    final shY = [for (final f in features) f.shoulderY];
    final hipX = [for (final f in features) f.hipX];
    final hipY = [for (final f in features) f.hipY];
    final torso = [for (final f in features) f.torso];
    final wristY = [for (final f in features) f.wristY];

    final phases = detectPhases(wristY);
    if (phases == null) {
      throw const SwingAnalysisException(
        'Could not detect swing phases — no clear pose was found. Make sure '
        'your whole body is in frame and try again.',
      );
    }

    final head = detectHeadMovement(eyeX, eyeY, torso, phases);
    final pivot = detectReversePivot(eyeX, hipX, torso, phases);
    final extension = detectEarlyExtension(hipY, torso, phases);
    final posture = detectLossOfPosture(shX, shY, hipX, hipY, phases);

    final faultVerdicts = <FaultVerdict>[
      FaultVerdict(
        id: faultHeadSway,
        label: faultLabels[faultHeadSway]!,
        flagged: head.flagged,
        detail: 'Lateral sway ${_fmt(head.lateral)} torso-lengths '
            '(threshold ${_fmt(swayThreshold)}). '
            'Vertical dip ${_fmt(head.vertical)} — informational.',
      ),
      FaultVerdict(
        id: faultReversePivot,
        label: faultLabels[faultReversePivot]!,
        flagged: pivot.flagged,
        detail: 'Spine lean ${_fmtSigned(pivot.reverse)} torso-lengths toward '
            'target (threshold ${_fmt(reversePivotThreshold)}).',
      ),
      FaultVerdict(
        id: faultEarlyExtension,
        label: faultLabels[faultEarlyExtension]!,
        flagged: extension.flagged,
        detail: 'Pelvis rise ${_fmtSigned(extension.rise)} torso-lengths '
            '(threshold ${_fmt(earlyExtensionThreshold)}).',
      ),
      FaultVerdict(
        id: faultLossOfPosture,
        label: faultLabels[faultLossOfPosture]!,
        flagged: posture.flagged,
        detail: 'Spine tilt ${_fmtDeg(posture.tiltAddress)} → '
            '${_fmtDeg(posture.tiltImpact)} '
            '(straightened ${_fmtSignedDeg(posture.straighten)}, '
            'threshold ${_fmtDeg(postureThreshold)}).',
      ),
    ];

    final flaggedIds =
        faultVerdicts.where((f) => f.flagged).map((f) => f.id).toList();
    final recommendations = recommendDrills(flaggedIds, drills);

    final tempo = swingTempo(phases, fps);
    return SwingAnalysis(
      phases: phases,
      tempo: tempo,
      fps: fps,
      frameCount: features.length,
      faults: faultVerdicts,
      recommendations: recommendations,
      session: buildSession(
        head: head,
        pivot: pivot,
        extension: extension,
        posture: posture,
        tempo: tempo,
      ),
    );
  }

  Future<void> dispose() => _poseEstimator.dispose();

  static String _fmt(double v) => v.isFinite ? v.toStringAsFixed(2) : '—';
  static String _fmtSigned(double v) =>
      v.isFinite ? '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}' : '—';
  static String _fmtDeg(double v) =>
      v.isFinite ? '${v.toStringAsFixed(0)}°' : '—';
  static String _fmtSignedDeg(double v) =>
      v.isFinite ? '${v >= 0 ? '+' : ''}${v.toStringAsFixed(0)}°' : '—';
}
