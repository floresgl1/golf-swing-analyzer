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

/// Why [phases] cannot describe a golf swing, or null if it might.
///
/// Byte-parallel port of `implausible_swing` in `src/swing_phases.py`.
///
/// This answers PRESENCE, not severity. [detectPhases] locates its events with
/// argMin/argMax over slices, and those always return an index — so it reports
/// phases for any trajectory whatsoever, including one interpolated out of a
/// video containing no golfer. Found on device 2026-08-17: a clip of nothing
/// produced a full fault report with drills. See P1.1 in ROADMAP.md.
///
/// Every check here is an impossibility, not a tuned threshold, so none of them
/// borrow against the P0.1 corpus:
///
///   - The events must be strictly ordered. [detectPhases] guarantees only
///     takeaway <= top <= impact by construction; equality means a phase has
///     zero duration, which is not a swing that happened.
///
/// REMOVED 2026-08-17: a tempo-inversion check (backswing must outlast the
/// downswing) lived here and rejected 3 of the first 4 real swings measured on
/// a phone. It rested on the detected phases meaning something; on real device
/// clips they do not. See P1.3 in ROADMAP.md. Do not reinstate it without
/// fixing phase location first.
///
/// Deliberately NOT checked here: anything needing a calibrated number. If a
/// proposed check requires a constant only P0.1 can supply, it belongs in P0.2.
String? implausibleSwing(SwingPhases? phases) {
  if (phases == null) return 'no phases were detected';

  final takeaway = phases.takeaway;
  final top = phases.top;
  final impact = phases.impact;

  if (top <= takeaway) {
    return 'the backswing has no duration (takeaway and top are the same '
        'frame)';
  }
  if (impact <= top) {
    return 'the downswing has no duration (top and impact are the same frame)';
  }

  return null;
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

/// How precisely the tempo ratio is pinned down, given that both phases are
/// counted in whole frames.
///
/// Returns the half-width of the ratio's uncertainty: the events are located
/// to the nearest frame, so each duration carries about one frame of slack,
/// and the relative error in a quotient is the sum of the relative errors in
/// its terms — `(1/backswing + 1/downswing) * ratio`. Returns null when the
/// ratio does not exist.
///
/// **This introduces no constant and borrows nothing from P0.1.** It is the
/// arithmetic of counting in frames, not a judgement about golf. That matters
/// because the hedge it feeds used to be keyed on frame RATE — below 120 fps
/// the report always claimed "the downswing spans only a few frames", which on
/// the first real device report was said of a 58-frame downswing. A hedge that
/// describes a condition that is not true spends credibility exactly where the
/// golfer most needs to trust the number. See P1.1 in ROADMAP.md.
double? tempoRatioPrecision(SwingTempo? tempo) {
  if (tempo == null) return null;
  final b = tempo.backswingFrames;
  final d = tempo.downswingFrames;
  if (b <= 0 || d <= 0 || !tempo.ratio.isFinite) return null;
  return (1.0 / b + 1.0 / d) * tempo.ratio;
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
