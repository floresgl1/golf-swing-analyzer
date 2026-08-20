/// Boundary tests for the four fault detectors, matching the discipline of
/// `tests/test_faults.py`.
///
/// Each detector is probed with a table of absolute values straddling its
/// boundary: clearly below, exactly on it, a hair above, clearly above. **The
/// thresholds are deliberately not read.** They are named in comments so the
/// intent survives, and nowhere else — so when a constant moves these tests go
/// red, and that failure is the feature.
///
/// This file was already structurally right before 2026-08-19: its probes were
/// absolute, which is the part the Python side copied. What it lacked was
/// resolution and coverage. Sway was probed at 0.20 and 0.05 against a
/// threshold of 0.13, so the constant could move anywhere in (0.05, 0.20) —
/// a band 58% as wide as the constant — with the suite green. Early extension,
/// loss of posture and reverse pivot had flag-true cases only, so a threshold
/// moved *down* to zero would still have passed. Nothing tested the boundary
/// itself, `dipThreshold` was untested entirely, and one assertion —
/// `expect(r.reverse, greaterThan(reversePivotThreshold))` — was the vacuous
/// derived form, true for any threshold below the probe. See P0.4 in
/// ROADMAP.md.
///
/// **Boundary convention: a value landing exactly on a threshold falls on the
/// no-action side.** Every comparison in `faults.dart` is strict (`>`).
///
/// The probe values match the Python suite's, which is convenience rather than
/// a parity requirement: these are test inputs, not detector constants, so the
/// byte-parallel rule does not apply to them. The two suites should agree on
/// discipline, not on numbers.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/faults.dart';
import 'package:golf_swing_analyzer/src/analysis/swing_phases.dart';

/// Helpers to build per-frame arrays with a constant base value and specific
/// windows overwritten, matching how the detectors sample address vs. impact.
List<double> filled(int n, double value) => List<double>.filled(n, value);

void setRange(List<double> a, int start, int end, double value) {
  for (var i = start; i <= end; i++) {
    a[i] = value;
  }
}

void main() {
  // Common geometry: 40 frames, torso 100px, address window ends at takeaway
  // (5..15), impact window is 28..32 (radius 2), top/finish windows radius 3.
  const phases = SwingPhases(takeaway: 15, top: 20, impact: 30, finish: 39);
  const n = 40;
  List<double> torso() => filled(n, 100);

  // Each table row is (probe px, expected metric, expected flag). The two
  // "above" probes exist because a fixed probe only catches a threshold that
  // moves past it, and the directions are not symmetric: any downward move is
  // caught at once by the on-boundary row, while an upward move is only caught
  // once it clears the nearest above-row. Probe spacing IS the resolution.

  group('detectHeadMovement — sway boundary (swayThreshold, currently 0.13)', () {
    HeadMovementResult sway(double impactHeadX) {
      final headX = filled(n, 0);
      setRange(headX, 28, 32, impactHeadX);
      return detectHeadMovement(headX, filled(n, 0), torso(), phases);
    }

    for (final probe in const [
      (12.0, 0.12, false), // clearly below
      (13.0, 0.13, false), // exactly the boundary -> no-action side
      (13.01, 0.1301, true), // a hair above
      (14.0, 0.14, true), // clearly above
    ]) {
      final (px, lateral, flagged) = probe;
      test('$px px -> lateral $lateral, flagged $flagged', () {
        final r = sway(px);
        expect(r.lateral, closeTo(lateral, 1e-9));
        expect(r.swayFlagged, flagged);
        expect(r.flagged, flagged);
        expect(r.dipFlagged, isFalse); // no vertical movement in these probes
      });
    }

    test('the boundary value is exact, not merely close', () {
      expect(sway(13.0).lateral, 0.13);
    });
  });

  group('detectHeadMovement — dip boundary (dipThreshold, currently 0.25)', () {
    // Untested before 2026-08-19. Informational rather than a verdict —
    // `flagged` keys on sway alone — but still printed, so a wrong constant is
    // still a wrong claim shown to a golfer.
    HeadMovementResult dip(double impactHeadY) {
      final headY = filled(n, 50);
      setRange(headY, 28, 32, impactHeadY);
      return detectHeadMovement(filled(n, 0), headY, torso(), phases);
    }

    for (final probe in const [
      (74.0, 0.24, false), // clearly below (address y = 50)
      (75.0, 0.25, false), // exactly the boundary -> no-action side
      (75.01, 0.2501, true), // a hair above
      (76.0, 0.26, true), // clearly above
    ]) {
      final (px, vertical, flagged) = probe;
      test('$px px -> vertical $vertical, dipFlagged $flagged', () {
        final r = dip(px);
        expect(r.vertical, closeTo(vertical, 1e-9));
        expect(r.dipFlagged, flagged);
        expect(r.flagged, isFalse); // a dip never sets the head-movement fault
      });
    }

    test('the boundary value is exact, not merely close', () {
      expect(dip(75.0).vertical, 0.25);
    });
  });

  group('detectReversePivot (reversePivotThreshold, currently 0.12)', () {
    // Hips drift +x from address to finish, so the target sign is +1 and the
    // hip terms cancel; the head's offset at the top is the whole metric.
    ReversePivotResult pivot(double headTopX) {
      final headX = filled(n, 0);
      final hipX = filled(n, 0);
      setRange(headX, 17, 23, headTopX);
      setRange(hipX, 36, 39, 10);
      return detectReversePivot(headX, hipX, torso(), phases);
    }

    for (final probe in const [
      (11.0, 0.11, false), // clearly below
      (12.0, 0.12, false), // exactly the boundary -> no-action side
      (12.01, 0.1201, true), // a hair above
      (13.0, 0.13, true), // clearly above
    ]) {
      final (px, reverse, flagged) = probe;
      test('$px px -> reverse $reverse, flagged $flagged', () {
        final r = pivot(px);
        expect(r.reverse, closeTo(reverse, 1e-9));
        expect(r.flagged, flagged);
      });
    }

    test('the boundary value is exact, not merely close', () {
      expect(pivot(12.0).reverse, 0.12);
    });
  });

  group('detectEarlyExtension (earlyExtensionThreshold, currently 0.10)', () {
    // Address hip y is 200, so an impact hip y of 190 is a rise of 0.10 torso
    // lengths. The probes run downward: a smaller impact y is a larger rise.
    EarlyExtensionResult extension(double impactHipY) {
      final hipY = filled(n, 200);
      setRange(hipY, 28, 32, impactHipY);
      return detectEarlyExtension(hipY, torso(), phases);
    }

    for (final probe in const [
      (191.0, 0.09, false), // clearly below
      (190.0, 0.10, false), // exactly the boundary -> no-action side
      (189.99, 0.1001, true), // a hair above
      (189.0, 0.11, true), // clearly above
    ]) {
      final (px, rise, flagged) = probe;
      test('$px px -> rise $rise, flagged $flagged', () {
        final r = extension(px);
        expect(r.rise, closeTo(rise, 1e-9));
        expect(r.flagged, flagged);
      });
    }

    test('the boundary value is exact, not merely close', () {
      expect(extension(190.0).rise, 0.10);
    });
  });

  group('detectLossOfPosture (postureThreshold, currently 12.0 degrees)', () {
    // Hip fixed at (0, 200), shoulder 100px above it. The address shoulder is
    // offset sideways (a forward spine tilt); at impact it is directly above
    // the hip (upright), so straighten = the address tilt.
    LossOfPostureResult posture(double addrShoulderX) {
      final shX = filled(n, addrShoulderX);
      setRange(shX, 27, 33, 0);
      return detectLossOfPosture(
          shX, filled(n, 100), filled(n, 0), filled(n, 200), phases);
    }

    /// Address shoulder offset producing a spine tilt of [deg] degrees. A
    /// coordinate constructor, not a threshold reference: every caller passes
    /// a literal.
    double shoulderXForTilt(double deg) => 100.0 * math.tan(deg * math.pi / 180.0);

    for (final probe in const [
      (11.5, false), // clearly below
      (12.0, false), // exactly the boundary -> no-action side
      (12.001, true), // a hair above
      (12.5, true), // clearly above
    ]) {
      final (deg, flagged) = probe;
      test('$deg degrees -> flagged $flagged', () {
        final r = posture(shoulderXForTilt(deg));
        expect(r.straighten, closeTo(deg, 1e-6));
        expect(r.tiltImpact, closeTo(0, 1e-9));
        expect(r.flagged, flagged);
      });
    }
  });

  group('a clean swing flags nothing', () {
    test('minimal movement in every metric', () {
      final headX = filled(n, 0);
      final headY = filled(n, 50);
      final hipX = filled(n, 0);
      final hipY = filled(n, 200);
      final shX = filled(n, 5); // a tiny, constant tilt that never changes
      final shY = filled(n, 100);

      expect(detectHeadMovement(headX, headY, torso(), phases).flagged, isFalse);
      expect(detectReversePivot(headX, hipX, torso(), phases).flagged, isFalse);
      expect(detectEarlyExtension(hipY, torso(), phases).flagged, isFalse);
      expect(
          detectLossOfPosture(shX, shY, hipX, hipY, phases).flagged, isFalse);
    });
  });
}
