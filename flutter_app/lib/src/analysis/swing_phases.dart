/// Swing-phase and tempo detection, ported from `src/swing_phases.py`.
///
/// The phases are located purely from the lead-wrist vertical trajectory, so
/// this file has no dependency on any particular pose backend: feed it the
/// per-frame lead-wrist y values (NaN where no pose was detected) and it returns
/// the key frame indices.
library;

import 'num_utils.dart';

// ---- Duration-based windows, for the stance-bounded localization only ----
//
// **This is the one place in the Dart port that resolves windows from
// durations rather than using frame counts at 240fps.** The held divergence
// (see ROADMAP.md) is that `detectPhases` kept its frame-count constants while
// Python got the duration refactor; that is untouched here. `locateSwing` and
// `stanceBounds` are NEW code with no frame-count ancestor, and they are ports
// of Python functions that are duration-based on both sides, so making them
// duration-based is what keeps them parallel — not a change to the divergence.

/// Frame count for a duration at [fps], never zero.
///
/// Direct port of `frames_for`. A zero-width window silently disables the
/// thing it is windowing rather than raising, so the result is clamped to
/// [minimum]. Pass [odd] for a centered moving-average kernel: an even-length
/// kernel offsets the average by half a frame, which moves the minima and
/// maxima being located. Even results are bumped UP, never down — bumping up
/// never under-smooths.
int framesFor(double seconds, double fps, {int minimum = 1, bool odd = false}) {
  var n = (seconds * fps).round();
  if (odd && n % 2 == 0) n += 1;
  return n < minimum ? minimum : n;
}

/// Frame range over which the golfer is standing still.
class StanceBounds {
  /// First frame of the stance, inclusive.
  final int lo;

  /// One past the last frame of the stance.
  final int hi;

  const StanceBounds(this.lo, this.hi);

  int get length => hi - lo;
}

/// How far the hips may travel, in torso lengths, over a one-second window and
/// still count as standing still.
///
/// Measured rather than chosen: the result is identical from 0.25 through 1.5,
/// a six-fold range, on the video-labelled swings. 0.4 sits mid-plateau.
const double stanceTravelMax = 0.4;

/// Frame range over which the golfer is standing still, or null.
///
/// Byte-parallel port of `stance_bounds` in `src/swing_phases.py`.
///
/// Filming yourself produces a walk-in, a stance, and a walk away. Only the
/// stance can contain a swing, and every localization failure measured on real
/// device clips happened outside it: peak localization anchors on walk-in pose
/// garbage (0/14 against labels), and descent-anchoring over the whole clip
/// catches the club being lowered into address, which out-descends the
/// downswing itself (3/14). Bounded to the stance: 12/14. See P1.4 in
/// ROADMAP.md.
///
/// Standing still is hip travel over a one-second window, in torso lengths, so
/// it does not depend on the golfer's distance from the camera.
StanceBounds? stanceBounds(
  List<double> hipX,
  List<double> torso,
  double fps, {
  double travelMax = stanceTravelMax,
}) {
  final n = hipX.length;
  if (n == 0) return null;

  final tracked = [
    for (var i = 0; i < n; i++) hipX[i].isFinite && torso[i].isFinite,
  ];
  var trackedCount = 0;
  for (final t in tracked) {
    if (t) trackedCount++;
  }
  if (trackedCount < 3) return null;

  final win = framesFor(1.0, fps);
  final still = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    final lo = i - win ~/ 2 < 0 ? 0 : i - win ~/ 2;
    final hi = i + win ~/ 2 + 1 > n ? n : i + win ~/ 2 + 1;
    var count = 0;
    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    final scales = <double>[];
    for (var j = lo; j < hi; j++) {
      if (!tracked[j]) continue;
      count++;
      if (hipX[j] < minX) minX = hipX[j];
      if (hipX[j] > maxX) maxX = hipX[j];
      scales.add(torso[j]);
    }
    if (count < 3) continue;
    final scale = nanMedian(scales);
    still[i] = (maxX - minX) / (scale > 1e-6 ? scale : 1e-6) < travelMax;
  }

  StanceBounds? best;
  var i = 0;
  while (i < n) {
    if (still[i]) {
      var j = i;
      while (j < n && still[j]) {
        j++;
      }
      if (best == null || j - i > best.length) best = StanceBounds(i, j);
      i = j;
    } else {
      i++;
    }
  }
  return best;
}

// Search windows for the descent-anchored localization, in seconds.
const double _descentSmoothS = 0.10; // smoothing for height and its derivative
const double _topSearchS = 1.5; // look back from the steepest descent
const double _impactSearchS = 1.0; // look forward from the top
const double _takeawaySearchS = 2.0; // look back from the top
const double _finishSearchS = 1.5; // look forward from impact

/// Locate the swing by anchoring on the fastest downward wrist motion.
///
/// Byte-parallel port of `locate_swing`. Without [hipX] this is the
/// whole-clip form, measured at 3/14 against labels and kept only so the
/// comparison stays runnable. With [hipX] the search is bounded to the stance.
///
/// Returns null when there is no usable pose, or when [hipX] was supplied and
/// no stance was found — **that null is an answer**, not a gap: the golfer
/// never stood still, so there is no swing to locate. Do not make the caller
/// fall back to peak localization on it; doing so turned a usable decline into
/// an invented swing at 0.2s on a no-swing clip.
SwingPhases? locateSwing(
  List<double> wristY,
  List<double> torso,
  double fps, {
  List<double>? hipX,
}) {
  final n = wristY.length;
  if (n == 0) return null;

  var good = 0;
  for (final v in wristY) {
    if (v.isFinite) good++;
  }
  if (good < 2) return null;

  final y = fillNaNLinear(wristY);
  final t = fillNaNLinear(torso);
  for (var i = 0; i < n; i++) {
    if (!t[i].isFinite || t[i] < 1e-6) t[i] = 1e-6;
  }

  final w = framesFor(_descentSmoothS, fps, odd: true);
  final height = movingAverageEdge([for (final v in y) -v], w);

  // Descent rate in torso-lengths per second; most negative = fastest drop.
  final rate = List<double>.filled(n, 0.0);
  for (var i = 1; i < n; i++) {
    rate[i] = (height[i] - height[i - 1]) / t[i] * fps;
  }
  final smoothed = movingAverageEdge(rate, w);

  var loB = 0;
  var hiB = n;
  if (hipX != null) {
    final bounds = stanceBounds(hipX, torso, fps);
    if (bounds == null || bounds.length < framesFor(1.0, fps)) return null;
    loB = bounds.lo;
    hiB = bounds.hi;
  }

  final steepest = argMinSlice(smoothed, loB, hiB);

  int back(int frm, double seconds) {
    final v = frm - framesFor(seconds, fps);
    return v < loB ? loB : v;
  }

  int fwd(int frm, double seconds) {
    final v = frm + framesFor(seconds, fps) + 1;
    return v > hiB ? hiB : v;
  }

  final a = back(steepest, _topSearchS);
  final top = argMaxSlice(height, a, steepest + 1);
  final b = fwd(top, _impactSearchS);
  final impact = b > top ? argMinSlice(height, top, b) : top;
  final c = back(top, _takeawaySearchS);
  final takeaway = top > c ? argMinSlice(height, c, top + 1) : c;
  final d = fwd(impact, _finishSearchS);
  final finish = d > impact ? argMaxSlice(height, impact, d) : impact;

  return SwingPhases(
    takeaway: takeaway,
    top: top,
    impact: impact,
    finish: finish,
  );
}

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
SwingPhases? detectPhases(
  List<double> wristY, {
  int smooth = 5,
  double? fps,
  List<double>? torso,
  List<double>? hipX,
}) {
  // Opt-in, mirroring the Python dispatch. Without [torso] the original
  // peak-based localization runs unchanged, which is what the existing tests
  // exercise. [hipX] additionally bounds the search to the stance, and it is
  // the only form with measured support: against device labels, peak
  // localization scores 0/14, descent-anchored-over-the-whole-clip 3/14, and
  // stance-bounded 12/14. See P1.4 in ROADMAP.md.
  if (torso != null && fps != null) {
    final located = locateSwing(wristY, torso, fps, hipX: hipX);
    if (located != null) return located;
    // When the caller asked for stance bounding and no stance was found, that
    // is the answer. Falling through to peak localization here would replace
    // "the golfer never stood still, so there is no swing" with a guess from a
    // method measured at 0/14.
    if (hipX != null) return null;
  }

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
