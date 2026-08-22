/// A single video frame preserved from the analysis pipeline for the report.
///
/// The analysis pipeline extracts every frame as a JPEG, runs pose estimation,
/// then deletes the working directory. These are the 3 frames that matter —
/// address, top, impact — copied to a durable location before cleanup, so the
/// report can show the golfer the body positions the numbers came from.
library;

import 'frame_features.dart';

/// One preserved frame with its phase label and pose landmarks.
class KeyFrame {
  /// Absolute path to the JPEG on disk.
  final String imagePath;

  /// Human-readable phase label, e.g. "Address", "Top", "Impact".
  final String label;

  /// Frame index within the original video.
  final int frameIndex;

  /// Pose landmarks for this frame — the same midpoints the detectors used.
  /// Null when no pose was detected for this frame (which would be unusual for
  /// a key frame, since the phase detector needs a pose to locate the phase).
  final FrameFeatures? features;

  const KeyFrame({
    required this.imagePath,
    required this.label,
    required this.frameIndex,
    this.features,
  });
}
