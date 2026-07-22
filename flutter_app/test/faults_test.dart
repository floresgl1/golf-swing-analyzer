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

  group('detectHeadMovement', () {
    test('flags lateral sway past 0.13 torso-lengths', () {
      final headX = filled(n, 0);
      setRange(headX, 28, 32, 20); // impact window shifts +20px = 0.20 torso
      final headY = filled(n, 0);

      final r = detectHeadMovement(headX, headY, torso(), phases);
      expect(r.lateral, closeTo(0.20, 1e-9));
      expect(r.swayFlagged, isTrue);
      expect(r.flagged, isTrue);
      expect(r.dipFlagged, isFalse);
    });

    test('does not flag a quiet head', () {
      final headX = filled(n, 0);
      setRange(headX, 28, 32, 5); // 0.05 torso < 0.13
      final r = detectHeadMovement(headX, filled(n, 0), torso(), phases);
      expect(r.flagged, isFalse);
    });
  });

  group('detectEarlyExtension', () {
    test('flags the pelvis rising past 0.10 torso-lengths', () {
      final hipY = filled(n, 200);
      setRange(hipY, 28, 32, 180); // rose 20px toward top of frame = 0.20 torso
      final r = detectEarlyExtension(hipY, torso(), phases);
      expect(r.rise, closeTo(0.20, 1e-9));
      expect(r.flagged, isTrue);
    });
  });

  group('detectLossOfPosture', () {
    test('flags the spine straightening past 12 degrees', () {
      // Address: shoulder 30px to the side and 100px above hip -> ~16.7deg.
      // Impact: shoulder directly above hip -> 0deg. Straighten ~16.7 > 12.
      final shX = filled(n, 30);
      final shY = filled(n, 100);
      final hipX = filled(n, 0);
      final hipY = filled(n, 200);
      setRange(shX, 27, 33, 0); // impact window: no side offset

      final r = detectLossOfPosture(shX, shY, hipX, hipY, phases);
      expect(r.tiltAddress, closeTo(16.699, 0.05));
      expect(r.tiltImpact, closeTo(0, 1e-6));
      expect(r.flagged, isTrue);
    });
  });

  group('detectReversePivot', () {
    test('flags head leaning toward target at the top', () {
      // Target is +x (hips drift +x from address to finish). Head leans +x
      // relative to hips at the top by 0.20 torso -> reverse pivot.
      final headX = filled(n, 0);
      final hipX = filled(n, 0);
      setRange(headX, 17, 23, 20); // top window: head +20px toward target
      setRange(hipX, 36, 39, 10); // finish: hips drift +x -> target sign +1

      final r = detectReversePivot(headX, hipX, torso(), phases);
      expect(r.flagged, isTrue);
      expect(r.reverse, greaterThan(reversePivotThreshold));
    });
  });
}
