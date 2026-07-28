/// Swing-phase and tempo detection, ported from `src/swing_phases.py`.
///
/// The phases are located purely from the lead-wrist vertical trajectory, so
/// this file has no dependency on any particular pose backend: feed it the
/// per-frame lead-wrist y values (NaN where no pose was detected) and it returns
/// the key frame indices.
library;

import 'num_utils.dart';

/// Frame indices of the four key swing events.
class SwingPhases {
  final int takeaway;
  final int top;
  final int impact;
  final int finish;

  const SwingPhases({
    required this.takeaway,
    required this.top,
    required this.impact,
    required this.finish,
  });

  @override
  String toString() =>
      'SwingPhases(takeaway: $takeaway, top: $top, impact: $impact, '
      'finish: $finish)';
}

/// Locate the key swing events from the lead-wrist vertical trajectory.
///
/// Direct port of `detect_phases`. Works on wrist *height* (`1 - y`, so up is
/// positive), which rises through the backswing to a peak (top), drops to a
/// valley (impact), then rises again to the finish. Returns null when fewer than
/// two frames had a detected pose.
///
/// Note: [wristY] may be in normalized (0..1) or pixel units — the algorithm
/// only depends on the trajectory's shape, which an affine change of units
/// leaves unchanged.
SwingPhases? detectPhases(List<double> wristY, {int smooth = 5}) {
  final n = wristY.length;
  if (n == 0) return null;

  final goodCount = wristY.where((v) => v.isFinite).length;
  if (goodCount < 2) return null;

  // Fill undetected frames by linear interpolation, then convert to height.
  final y = fillNaNLinear(wristY);
  final flipped = [for (final v in y) 1.0 - v]; // up is positive
  final height = movingAverageEdge(flipped, smooth);

  // Local maxima of height (wrist momentarily highest).
  final peaks = <int>[];
  for (var i = 1; i < n - 1; i++) {
    if (height[i] >= height[i - 1] && height[i] > height[i + 1]) {
      peaks.add(i);
    }
  }

  // Top of backswing = the first "tall" peak; fall back to the highest point in
  // the first half if no peak clears the halfway line.
  var hMax = height[0];
  var hMin = height[0];
  for (final h in height) {
    if (h > hMax) hMax = h;
    if (h < hMin) hMin = h;
  }
  final span = hMax - hMin;
  final tall = peaks.where((i) => height[i] >= hMin + 0.5 * span).toList();
  final top = tall.isNotEmpty ? tall.first : argMaxSlice(height, 0, n ~/ 2);

  // Impact = lowest wrist point after the top; finish = highest after impact.
  final impact = argMinSlice(height, top, n);
  final finish = argMaxSlice(height, impact, n);

  // Takeaway = the lowest wrist point before the top (bottom of the address
  // "sit"), so tempo isn't clipped by a later threshold crossing.
  final takeaway = top > 0 ? argMinSlice(height, 0, top) : 0;

  return SwingPhases(
    takeaway: takeaway,
    top: top,
    impact: impact,
    finish: finish,
  );
}

/// Backswing/downswing durations and their tempo ratio.
class SwingTempo {
  final int backswingFrames;
  final int downswingFrames;
  final double backswingSeconds;
  final double downswingSeconds;

  /// Backswing:downswing ratio. Tour players average ~3:1.
  final double ratio;

  const SwingTempo({
    required this.backswingFrames,
    required this.downswingFrames,
    required this.backswingSeconds,
    required this.downswingSeconds,
    required this.ratio,
  });
}

/// Compute backswing/downswing durations and their tempo ratio.
///
/// Direct port of `swing_tempo`. Backswing = takeaway → top, downswing =
/// top → impact. Returns null when [phases] is null or [fps] is zero.
SwingTempo? swingTempo(SwingPhases? phases, double fps) {
  if (phases == null || fps == 0) return null;
  final backswingFrames = phases.top - phases.takeaway;
  final downswingFrames = phases.impact - phases.top;
  final backswingSeconds = backswingFrames / fps;
  final downswingSeconds = downswingFrames / fps;
  final ratio =
      downswingSeconds != 0 ? backswingSeconds / downswingSeconds : double.nan;
  return SwingTempo(
    backswingFrames: backswingFrames,
    downswingFrames: downswingFrames,
    backswingSeconds: backswingSeconds,
    downswingSeconds: downswingSeconds,
    ratio: ratio,
  );
}
