/// Identifies *what a measurement means*, so records taken before and after a
/// recalibration are not silently compared.
///
/// P0.2 is expected to move all four thresholds and the address window. Once it
/// does, a value recorded today and a value recorded afterwards are different
/// quantities. Nothing in a record used to say so, so the corpus would have
/// quietly mixed them.
///
/// Design follows the Practice Focus section of `ROADMAP.md`, which
/// specifies this shape for a reason and warns about the ways it gets broken:
///
/// * **Derived, never hand-incremented.** These are hashes of the parameters
///   themselves. A manual integer depends on a human remembering to bump it on
///   every threshold change, and stops tracking the first time someone forgets.
///   Do not "simplify" this to a counter.
/// * **Only output-affecting parameters.** Window sizes, the four thresholds,
///   an algorithm version. Never formatting or logging changes — hashing those
///   would invalidate trends for changes that moved no measurement.
/// * **Value basis is split from threshold basis.** A threshold-only
///   recalibration changes which swings are *flagged* but not what they
///   *measured*, so it resets crossings and leaves value trends intact. A window
///   change resets both, which is why [thresholdBasis] is derived over
///   [valueBasis].
library;

import 'dart:convert';

import 'faults.dart';

/// Bump when the measurement *algorithm* changes in a way the parameter values
/// below cannot express — a different estimator, a changed normalization, a
/// reordered pipeline. Feeds [valueBasis].
const int measurementAlgoVersion = 1;

/// App build recorded alongside each swing. Mirrors `version:` in pubspec.yaml.
const String appVersion = '0.1.0+1';

// ---------------------------------------------------------------------------
// Window constants — MIRRORED from faults.dart / swing_phases.dart.
//
// These are the frame counts the Dart detectors actually use. They are written
// out here rather than imported because on this branch they are inline literals
// in the detector functions (`takeaway - 10`, `radius: 2`, `radius: 3`,
// `smooth = 5`), not named constants, and this tier is not permitted to touch
// faults.dart.
//
// That makes this the one drift hazard in the basis: change a window in
// faults.dart without changing it here and the basis will not notice, which is
// precisely the failure mode the derived-hash design exists to prevent. The
// durable fix is to name those literals in faults.dart and import them here;
// it belongs with P0.2, which is going to rewrite them anyway.
//
// The four thresholds below carry no such hazard — they are imported.
// ---------------------------------------------------------------------------

/// Address median window: `[takeaway - 10, takeaway]` in `_addrMedian`.
const int addressWindowFrames = 10;

/// Impact median radius for head and pelvis (`radius: 2`).
const int impactRadiusFrames = 2;

/// Median radius everywhere else — top, finish, impact posture (`radius: 3`).
const int defaultRadiusFrames = 3;

/// Moving-average width in `detectPhases` (`smooth = 5`).
const int phaseSmoothFrames = 5;

/// 32-bit FNV-1a as lowercase hex.
///
/// Chosen because it is deterministic across runs, platforms and Dart versions.
/// `Object.hashAll` is not: it is randomly seeded per isolate, so a corpus
/// stamped with it could not be compared with itself tomorrow.
String _fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Canonical rendering of a parameter set: sorted keys, so the hash depends on
/// the values and not on declaration order.
String _canonical(Map<String, Object> params) {
  final keys = params.keys.toList()..sort();
  return [for (final k in keys) '$k=${params[k]}'].join('&');
}

/// Hash of everything that affects a measured *value*.
///
/// Two records sharing this stamp measured the same quantity and their values
/// are directly comparable. Records that differ here are not comparable at all,
/// flagged or otherwise.
String get valueBasis => _fnv1a(_canonical({
      'algo': measurementAlgoVersion,
      'address_window_frames': addressWindowFrames,
      'impact_radius_frames': impactRadiusFrames,
      'default_radius_frames': defaultRadiusFrames,
      'phase_smooth_frames': phaseSmoothFrames,
    }));

/// Hash of everything that affects whether a value is *flagged*.
///
/// Derived over [valueBasis] so a window change resets this too: if the measured
/// quantity changed, so did the meaning of crossing a threshold. A
/// threshold-only recalibration changes this and leaves [valueBasis] alone.
String get thresholdBasis => _fnv1a(_canonical({
      'value_basis': valueBasis,
      'sway': swayThreshold,
      'dip': dipThreshold,
      'reverse_pivot': reversePivotThreshold,
      'early_extension': earlyExtensionThreshold,
      'posture': postureThreshold,
    }));
