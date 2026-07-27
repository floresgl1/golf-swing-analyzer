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

  const FrameFeatures({
    required this.eyeX,
    required this.eyeY,
    required this.shoulderX,
    required this.shoulderY,
    required this.hipX,
    required this.hipY,
    required this.torso,
    required this.wristY,
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
        wristY = double.nan;

  /// Whether a pose was found for this frame. [FrameFeatures.missing] sets every
  /// field to NaN and the estimator only emits a frame once every landmark it
  /// needs is present, so this is all-or-nothing in practice; it is written out
  /// in full anyway so a partially-NaN frame from a future backend still counts
  /// as undetected rather than silently inflating pose coverage.
  bool get detected =>
      eyeX.isFinite &&
      eyeY.isFinite &&
      shoulderX.isFinite &&
      shoulderY.isFinite &&
      hipX.isFinite &&
      hipY.isFinite &&
      torso.isFinite &&
      wristY.isFinite;
}
