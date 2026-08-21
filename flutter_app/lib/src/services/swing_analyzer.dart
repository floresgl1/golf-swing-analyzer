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
import '../analysis/measurement_basis.dart';
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
  /// What to show the golfer.
  final String message;

  /// Why the swing was rejected, in the detector's words rather than the
  /// golfer's — e.g. 'no phases were detected'.
  final String? reason;

  /// Everything measured before the rejection, so the clip can still become a
  /// corpus record.
  ///
  /// **A rejected clip is the most valuable clip there is, and until
  /// 2026-08-20 the app threw it away.** Nothing was written when analysis
  /// hard-failed, so the corpus could only ever contain swings that passed the
  /// gate — which makes the gate's own error rate unmeasurable from it. P1.1
  /// needs negatives, and the app was discarding the very clips a golfer had
  /// already gone to the trouble of filming. See P1.1 in ROADMAP.md.
  final FrameSeries? frames;
  final double? fps;
  final int? frameCount;
  final double? poseCoverageFraction;

  const SwingAnalysisException(
    this.message, {
    this.reason,
    this.frames,
    this.fps,
    this.frameCount,
    this.poseCoverageFraction,
  });

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
    this.handedness = Handedness.right,
    this.participantId,
    this.captureSessionId,
    FrameExtractor? frameExtractor,
    PoseEstimator? poseEstimator,
  })  : _frameExtractor = frameExtractor ?? FrameExtractor(),
        _poseEstimator = poseEstimator ?? PoseEstimator(handedness: handedness);

  final List<Drill> drills;

  /// Which wrist phase detection tracks. Recorded on every swing so a record
  /// analyzed on the wrong wrist stays identifiable in the corpus.
  final Handedness handedness;

  /// Anonymous golfer these swings belong to.
  final String? participantId;

  /// Groups the swings recorded in one sitting.
  final String? captureSessionId;

  final FrameExtractor _frameExtractor;
  final PoseEstimator _poseEstimator;

  /// Analyze the recorded video at [videoPath]. [onProgress] is optional.
  ///
  /// [targeting] is the fault the golfer chose to work on (a fault id), or null
  /// for a full swing check. All four detectors run either way; targeting only
  /// marks the report's focus and is recorded in the swing history.
  /// [clipName] is the retained recording this swing was measured from, so
  /// the record can be joined back to a watchable video. Null when the clip
  /// could not be kept.
  Future<SwingAnalysis> analyze(
    String videoPath, {
    String? targeting,
    SwingKind swingKind = SwingKind.natural,
    String? calibrationFault,
    String? clipName,
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
      return _buildReport(
        features,
        extracted.fps,
        targeting,
        swingKind,
        calibrationFault,
        clipName,
      );
    } finally {
      // Clean up the extracted JPEGs regardless of outcome.
      if (extracted.workingDir.existsSync()) {
        extracted.workingDir.deleteSync(recursive: true);
      }
    }
  }

  SwingAnalysis _buildReport(
    List<FrameFeatures> features,
    double fps,
    String? targeting,
    SwingKind swingKind,
    String? calibrationFault,
    String? clipName,
  ) {
    // Assemble parallel arrays, matching the lists built in faults.main().
    final eyeX = [for (final f in features) f.eyeX];
    final eyeY = [for (final f in features) f.eyeY];
    final shX = [for (final f in features) f.shoulderX];
    final shY = [for (final f in features) f.shoulderY];
    final hipX = [for (final f in features) f.hipX];
    final hipY = [for (final f in features) f.hipY];
    final torso = [for (final f in features) f.torso];
    final wristY = [for (final f in features) f.wristY];

    // Stance-bounded localization, live as of 2026-08-20. Passing torso and
    // hipX opts into it; without them this is the peak-based localization that
    // scored **0/14** against device labels, anchoring in the walk-in on every
    // real clip ever measured. Bounded to the stance it scores 12/14 and
    // declines one of the three no-swing clips instead of inventing a swing.
    //
    // A null here now has two meanings, and both are handled by the gate
    // below: fewer than two frames had a pose, OR the golfer never stood still
    // long enough to form a stance. The second is a real answer -- there is no
    // swing in a clip where nobody settled -- and it must NOT fall back to the
    // 0/14 method. See P1.4 in ROADMAP.md.
    final detected = detectPhases(
      wristY,
      fps: fps,
      torso: torso,
      hipX: hipX,
    );

    // Hard fail rather than reporting around the gap. Showing tempo with the
    // verdicts suppressed would invite the surviving numbers to be read as
    // meaningful — the same failure in a smaller costume. If there was no
    // swing there is nothing for the app to say about it.
    final reason = implausibleSwing(detected);
    if (reason != null) {
      // Carry the measurements out with the rejection. The golfer sees the
      // message; the corpus gets a negative it can be scored against.
      throw SwingAnalysisException(
        "That didn't look like a golf swing — $reason. Film from side-on with "
        'your whole body in frame, and keep the camera still.',
        reason: reason,
        frames: FrameSeries.fromFeatures(features),
        fps: fps,
        frameCount: features.length,
        poseCoverageFraction: poseCoverage(features),
      );
    }

    // Non-null past the guard: implausibleSwing returns a reason for null.
    final phases = detected!;

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
            '(beta reference ${_fmt(swayThreshold)}). '
            'Vertical dip ${_fmt(head.vertical)} — informational.',
      ),
      FaultVerdict(
        id: faultReversePivot,
        label: faultLabels[faultReversePivot]!,
        flagged: pivot.flagged,
        detail: 'Spine lean ${_fmtSigned(pivot.reverse)} torso-lengths toward '
            'target (beta reference ${_fmt(reversePivotThreshold)}).',
      ),
      FaultVerdict(
        id: faultEarlyExtension,
        label: faultLabels[faultEarlyExtension]!,
        flagged: extension.flagged,
        detail: 'Pelvis rise ${_fmtSigned(extension.rise)} torso-lengths '
            '(beta reference ${_fmt(earlyExtensionThreshold)}).',
      ),
      FaultVerdict(
        id: faultLossOfPosture,
        label: faultLabels[faultLossOfPosture]!,
        flagged: posture.flagged,
        detail: 'Spine tilt ${_fmtDeg(posture.tiltAddress)} → '
            '${_fmtDeg(posture.tiltImpact)} '
            '(straightened ${_fmtSignedDeg(posture.straighten)}, '
            'beta reference ${_fmtDeg(postureThreshold)}).',
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
      targeting: targeting,
      session: buildSession(
        head: head,
        pivot: pivot,
        extension: extension,
        posture: posture,
        tempo: tempo,
        targeting: targeting,
        // Capture context: none of this survives the frame cleanup below, so it
        // is written now or lost for this swing permanently.
        fps: fps,
        frameCount: features.length,
        handedness: handedness,
        poseCoverageFraction: poseCoverage(features),
        frames: FrameSeries.fromFeatures(features),
        // Grouping and provenance: who, which sitting, and what these numbers
        // mean. The basis stamps are what stop a value recorded now from being
        // compared with one recorded after P0.2 moves the thresholds.
        participantId: participantId,
        captureSessionId: captureSessionId,
        appVersion: appVersion,
        valueBasis: valueBasis,
        thresholdBasis: thresholdBasis,
        swingKind: swingKind,
        calibrationFault: calibrationFault,
        clipName: clipName,
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
