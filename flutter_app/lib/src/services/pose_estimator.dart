/// Pose estimation on a single video frame using ML Kit
/// (`google_mlkit_pose_detection`), the mobile counterpart to the Python
/// MediaPipe Tasks pipeline in `src/pose_estimation.py`.
///
/// ML Kit returns landmark positions in *image pixel* coordinates, so — unlike
/// the normalized MediaPipe landmarks — no multiply by width/height is needed;
/// the torso-length normalization in the fault detectors handles scale.
library;

import 'dart:math' as math;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../analysis/handedness.dart';
import '../models/frame_features.dart';

// [Handedness] moved to the pure-Dart analysis layer (`analysis/handedness.dart`)
// so the swing record can carry it without dragging the ML Kit dependency into
// the testable core. Re-exported here so existing importers keep working.
export '../analysis/handedness.dart' show Handedness;

class PoseEstimator {
  PoseEstimator({this.handedness = Handedness.right})
      : _detector = PoseDetector(
          options: PoseDetectorOptions(
            mode: PoseDetectionMode.single, // still images, one frame at a time
            model: PoseDetectionModel.accurate, // matches the "heavy" model
          ),
        );

  final Handedness handedness;
  final PoseDetector _detector;

  PoseLandmarkType get _leadWrist => handedness == Handedness.right
      ? PoseLandmarkType.leftWrist
      : PoseLandmarkType.rightWrist;

  /// Run pose detection on the image at [framePath] and reduce it to the
  /// midpoints/torso/wrist the detectors need. Returns [FrameFeatures.missing]
  /// when no full-body pose is found.
  ///
  /// ML Kit's per-landmark `likelihood` (0.0–1.0) is now read and stored as
  /// [FrameFeatures.poseConfidence] — the minimum across the seven required
  /// landmarks. This is the signal P1.1 identified as "the one thing separating
  /// 'a person is here' from 'a person has been invented'": ML Kit emits all 33
  /// landmarks even when guessing, so without it the null-check gate below is
  /// essentially always passed once any pose is returned.
  ///
  /// Frames where any required landmark is null still return `missing()`.
  /// Low-confidence frames (all landmarks present but the model is guessing)
  /// return a real [FrameFeatures] with the measured [poseConfidence]; the
  /// downstream [FrameFeatures.detected] getter gates on it via
  /// [FrameFeatures.confidenceFloor], so pose coverage, gap filling, and the
  /// "fewer than 2 good frames" check all benefit without a separate gate here.
  Future<FrameFeatures> featuresForFrame(String framePath) async {
    final input = InputImage.fromFilePath(framePath);
    final poses = await _detector.processImage(input);
    if (poses.isEmpty) return const FrameFeatures.missing();

    final lm = poses.first.landmarks;
    final leftEye = lm[PoseLandmarkType.leftEye];
    final rightEye = lm[PoseLandmarkType.rightEye];
    final leftShoulder = lm[PoseLandmarkType.leftShoulder];
    final rightShoulder = lm[PoseLandmarkType.rightShoulder];
    final leftHip = lm[PoseLandmarkType.leftHip];
    final rightHip = lm[PoseLandmarkType.rightHip];
    final wrist = lm[_leadWrist];

    if (leftEye == null ||
        rightEye == null ||
        leftShoulder == null ||
        rightShoulder == null ||
        leftHip == null ||
        rightHip == null ||
        wrist == null) {
      return const FrameFeatures.missing();
    }

    // Minimum likelihood across the seven landmarks the detectors need.
    // A low value means ML Kit placed the landmark but is not confident it
    // is correct — the coordinates may be hallucinated.
    final confidence = [
      leftEye.likelihood,
      rightEye.likelihood,
      leftShoulder.likelihood,
      rightShoulder.likelihood,
      leftHip.likelihood,
      rightHip.likelihood,
      wrist.likelihood,
    ].reduce(math.min);

    final eyeX = (leftEye.x + rightEye.x) / 2;
    final eyeY = (leftEye.y + rightEye.y) / 2;
    final shoulderX = (leftShoulder.x + rightShoulder.x) / 2;
    final shoulderY = (leftShoulder.y + rightShoulder.y) / 2;
    final hipX = (leftHip.x + rightHip.x) / 2;
    final hipY = (leftHip.y + rightHip.y) / 2;
    final torso = math.sqrt(
      math.pow(shoulderX - hipX, 2) + math.pow(shoulderY - hipY, 2),
    ).toDouble();

    return FrameFeatures(
      eyeX: eyeX,
      eyeY: eyeY,
      shoulderX: shoulderX,
      shoulderY: shoulderY,
      hipX: hipX,
      hipY: hipY,
      torso: torso,
      wristY: wrist.y,
      poseConfidence: confidence,
    );
  }

  Future<void> dispose() => _detector.close();
}
