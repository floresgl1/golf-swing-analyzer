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

import '../models/frame_features.dart';

/// Which hand is the lead (target-side) hand. Right-handed golfers lead with the
/// left wrist; lefties with the right. Mirrors `HANDEDNESS` in swing_phases.py.
enum Handedness { right, left }

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
    );
  }

  Future<void> dispose() => _detector.close();
}
