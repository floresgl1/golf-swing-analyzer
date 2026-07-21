/// The four swing-fault detectors, ported from `src/faults.py`.
///
/// Every detector normalizes by torso length (shoulder→hip distance at address)
/// so thresholds are independent of camera resolution and golfer size, and uses
/// median windows so a single bad frame can't swing a verdict. All inputs are
/// per-frame parallel lists in *pixel* coordinates (NaN where no pose was
/// detected), matching the arrays the Python `main()` collects.
library;

import 'dart:math' as math;

import 'num_utils.dart';
import 'swing_phases.dart';

// ---- Thresholds (fractions of torso length unless noted) ----

/// Lateral head sway (address→impact) — the flagged head-movement fault.
const double swayThreshold = 0.13;

/// Vertical head dip (address→impact) — informational only.
const double dipThreshold = 0.25;

/// Reverse pivot: head lean toward the target (address→top).
const double reversePivotThreshold = 0.12;

/// Early extension: pelvis rise (address→impact).
const double earlyExtensionThreshold = 0.10;

/// Loss of posture: spine straightening in degrees (address→impact).
const double postureThreshold = 12.0;

/// The four fault ids, matching `data/drills.json` and the drill recommender.
const String faultHeadSway = 'head_sway';
const String faultReversePivot = 'reverse_pivot';
const String faultEarlyExtension = 'early_extension';
const String faultLossOfPosture = 'loss_of_posture';

// ---- Windowing helpers (ports of the module-private functions in faults.py) ----

/// Median over the stable setup window ending at the takeaway
/// (`a[takeaway-10 .. takeaway]`, inclusive).
double _addrMedian(List<double> a, int takeaway) =>
    nanMedianSlice(a, takeaway - 10, takeaway + 1);

/// Median over a small window centered on [center] (`± radius`, inclusive).
double _windowMedian(List<double> a, int center, {int radius = 3}) =>
    nanMedianSlice(a, center - radius, center + radius + 1);

/// Spine tilt from vertical in degrees (unsigned), from hip to shoulder.
double _spineTilt(double shX, double shY, double hipX, double hipY) {
  final dx = shX - hipX;
  final up = hipY - shY; // shoulder above hip → positive
  return math.atan2(dx.abs(), up.abs()) * 180.0 / math.pi;
}

// ---- Detector results ----

class HeadMovementResult {
  final double lateral; // torso-lengths, address→impact
  final double vertical;
  final double total;
  final double distPx;
  final bool swayFlagged;
  final bool dipFlagged;

  /// The head-movement fault is lateral sway.
  final bool flagged;

  const HeadMovementResult({
    required this.lateral,
    required this.vertical,
    required this.total,
    required this.distPx,
    required this.swayFlagged,
    required this.dipFlagged,
    required this.flagged,
  });
}

class ReversePivotResult {
  /// Signed lean toward the target (positive = reverse pivot), torso-lengths.
  final double reverse;
  final bool flagged;

  const ReversePivotResult({required this.reverse, required this.flagged});
}

class EarlyExtensionResult {
  /// Pelvis rise address→impact, torso-lengths (positive = rose).
  final double rise;
  final bool flagged;

  const EarlyExtensionResult({required this.rise, required this.flagged});
}

class LossOfPostureResult {
  final double tiltAddress; // degrees from vertical
  final double tiltImpact;

  /// Degrees the spine straightened (positive = stood up).
  final double straighten;
  final bool flagged;

  const LossOfPostureResult({
    required this.tiltAddress,
    required this.tiltImpact,
    required this.straighten,
    required this.flagged,
  });
}

// ---- Detectors ----

/// Flag excessive head movement between address and impact (port of
/// `detect_head_movement`). The flagged fault is lateral sway; vertical dip is
/// informational.
HeadMovementResult detectHeadMovement(
  List<double> headX,
  List<double> headY,
  List<double> torso,
  SwingPhases phases,
) {
  final ta = phases.takeaway;
  final im = phases.impact;

  final addrX = _addrMedian(headX, ta);
  final addrY = _addrMedian(headY, ta);
  final scale = _addrMedian(torso, ta);
  final impX = _windowMedian(headX, im, radius: 2);
  final impY = _windowMedian(headY, im, radius: 2);

  final dx = impX - addrX;
  final dy = impY - addrY;
  final distPx = hypot(dx, dy);
  final hasScale = scale != 0 && scale.isFinite;
  final lateral = hasScale ? dx.abs() / scale : double.nan;
  final vertical = hasScale ? dy.abs() / scale : double.nan;

  return HeadMovementResult(
    lateral: lateral,
    vertical: vertical,
    total: hasScale ? distPx / scale : double.nan,
    distPx: distPx,
    swayFlagged: lateral > swayThreshold,
    dipFlagged: vertical > dipThreshold,
    flagged: lateral > swayThreshold,
  );
}

/// Flag a reverse pivot: upper body leaning toward the target at the top (port
/// of `detect_reverse_pivot`). Target direction is inferred from net hip
/// translation address→finish.
ReversePivotResult detectReversePivot(
  List<double> headX,
  List<double> hipX,
  List<double> torso,
  SwingPhases phases,
) {
  final ta = phases.takeaway;
  final top = phases.top;
  final fin = phases.finish;

  final headAddr = _addrMedian(headX, ta);
  final hipAddr = _addrMedian(hipX, ta);
  final scale = _addrMedian(torso, ta);
  final headTop = _windowMedian(headX, top);
  final hipTop = _windowMedian(hipX, top);
  final hipFin = _windowMedian(hipX, fin);

  final targetSign = hipFin >= hipAddr ? 1.0 : -1.0;
  final leanShift = (headTop - hipTop) - (headAddr - hipAddr);
  final hasScale = scale != 0 && scale.isFinite;
  final reverse = hasScale ? leanShift * targetSign / scale : double.nan;

  return ReversePivotResult(
    reverse: reverse,
    flagged: reverse > reversePivotThreshold,
  );
}

/// Flag early extension: the pelvis rising toward the ball on the downswing
/// (port of `detect_early_extension`).
EarlyExtensionResult detectEarlyExtension(
  List<double> hipY,
  List<double> torso,
  SwingPhases phases,
) {
  final ta = phases.takeaway;
  final im = phases.impact;

  final hipAddr = _addrMedian(hipY, ta);
  final hipImpact = _windowMedian(hipY, im, radius: 2);
  final scale = _addrMedian(torso, ta);
  final hasScale = scale != 0 && scale.isFinite;
  final rise = hasScale ? (hipAddr - hipImpact) / scale : double.nan;

  return EarlyExtensionResult(
    rise: rise,
    flagged: rise > earlyExtensionThreshold,
  );
}

/// Flag loss of posture: the spine's forward bend straightening address→impact
/// (port of `detect_loss_of_posture`).
LossOfPostureResult detectLossOfPosture(
  List<double> shX,
  List<double> shY,
  List<double> hipX,
  List<double> hipY,
  SwingPhases phases,
) {
  final ta = phases.takeaway;
  final im = phases.impact;

  final shAddrX = _addrMedian(shX, ta);
  final shAddrY = _addrMedian(shY, ta);
  final hipAddrX = _addrMedian(hipX, ta);
  final hipAddrY = _addrMedian(hipY, ta);
  final shImpX = _windowMedian(shX, im);
  final shImpY = _windowMedian(shY, im);
  final hipImpX = _windowMedian(hipX, im);
  final hipImpY = _windowMedian(hipY, im);

  final tiltAddr = _spineTilt(shAddrX, shAddrY, hipAddrX, hipAddrY);
  final tiltImpact = _spineTilt(shImpX, shImpY, hipImpX, hipImpY);
  final straighten = tiltAddr - tiltImpact;

  return LossOfPostureResult(
    tiltAddress: tiltAddr,
    tiltImpact: tiltImpact,
    straighten: straighten,
    flagged: straighten > postureThreshold,
  );
}
