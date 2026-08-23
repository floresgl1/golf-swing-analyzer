/// Per-frame landmark midpoints and torso length extracted from one video
/// frame. These mirror the arrays the Python `faults.main()` collects, in pixel
/// coordinates. Fields are NaN when no pose was detected for the frame.
library;

class FrameFeatures {
  final double eyeX; // eye midpoint = the head point used by the detectors
  final double eyeY;
  final double shoulderX; // shoulder midpoint
  final double shoulderY;
  final double hipX; // hip midpoint
  final double hipY;
  final double torso; // shoulder→hip distance in pixels
  final double wristY; // lead-wrist y in pixels

  /// Minimum ML Kit landmark likelihood across the seven required landmarks
  /// (0.0–1.0). ML Kit emits landmarks even when guessing, so this is the one
  /// signal separating "a person is here" from "a person has been invented."
  /// See P1.1 in ROADMAP.md.
  ///
  /// Defaults to 1.0 so analysis-layer tests (which construct [FrameFeatures]
  /// directly, without ML Kit) are unaffected by the confidence gate.
  final double poseConfidence;

  const FrameFeatures({
    required this.eyeX,
    required this.eyeY,
    required this.shoulderX,
    required this.shoulderY,
    required this.hipX,
    required this.hipY,
    required this.torso,
    required this.wristY,
    this.poseConfidence = 1.0,
  });

  /// A frame where the pose failed to detect: every value is NaN so the
  /// downstream median windows and interpolation treat it as a gap.
  const FrameFeatures.missing()
      : eyeX = double.nan,
        eyeY = double.nan,
        shoulderX = double.nan,
        shoulderY = double.nan,
        hipX = double.nan,
        hipY = double.nan,
        torso = double.nan,
        wristY = double.nan,
        poseConfidence = 0.0;

  /// ML Kit considers a landmark "in frame" when its likelihood >= 0.5.
  /// Below that the model is guessing — the coordinates may be plausible-looking
  /// hallucinations. This is ML Kit's own scale, not a golf-domain constant.
  static const double confidenceFloor = 0.5;

  /// Whether a pose was found for this frame. [FrameFeatures.missing] sets every
  /// field to NaN and the estimator only emits a frame once every landmark it
  /// needs is present, so this is all-or-nothing in practice; it is written out
  /// in full anyway so a partially-NaN frame from a future backend still counts
  /// as undetected rather than silently inflating pose coverage.
  ///
  /// Also requires [poseConfidence] >= [confidenceFloor]. ML Kit emits all 33
  /// landmarks even when it is guessing, so without this check [detected] is
  /// essentially always true once any pose is returned — and pose coverage
  /// becomes meaningless. The nothing-clip of 2026-08-17 had coverage 0.61
  /// because ML Kit hallucinated a person in 61% of empty frames. See P1.1.
  bool get detected =>
      eyeX.isFinite &&
      eyeY.isFinite &&
      shoulderX.isFinite &&
      shoulderY.isFinite &&
      hipX.isFinite &&
      hipY.isFinite &&
      torso.isFinite &&
      wristY.isFinite &&
      poseConfidence >= confidenceFloor;
}
