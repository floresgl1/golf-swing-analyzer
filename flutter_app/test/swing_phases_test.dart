import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/swing_phases.dart';

void main() {
  group('detectPhases', () {
    test('returns null when fewer than two frames have a pose', () {
      expect(detectPhases([double.nan, double.nan, double.nan]), isNull);
      expect(detectPhases([]), isNull);
    });

    test('locates top, impact and finish on a synthetic swing', () {
      // Build a lead-wrist y trajectory (image y: larger = lower wrist).
      // Address sits low, backswing raises the wrist to a peak at ~frame 30,
      // downswing drops it to the lowest point at ~frame 45 (impact), then the
      // follow-through raises it again to ~frame 60.
      final wristY = <double>[];
      for (var i = 0; i < 61; i++) {
        double y;
        if (i <= 10) {
          y = 0.80; // address
        } else if (i <= 30) {
          y = 0.80 - (i - 10) / 20 * 0.60; // rise to 0.20 at frame 30 (top)
        } else if (i <= 45) {
          y = 0.20 + (i - 30) / 15 * 0.70; // drop to 0.90 at frame 45 (impact)
        } else {
          y = 0.90 - (i - 45) / 15 * 0.80; // rise to 0.10 at frame 60 (finish)
        }
        wristY.add(y);
      }

      final phases = detectPhases(wristY);
      expect(phases, isNotNull);
      expect(phases!.takeaway, lessThan(phases.top));
      expect(phases.top, lessThan(phases.impact));
      expect(phases.impact, lessThanOrEqualTo(phases.finish));
      expect(phases.top, inInclusiveRange(26, 34));
      expect(phases.impact, inInclusiveRange(41, 49));
      expect(phases.finish, inInclusiveRange(56, 60));
    });
  });

  group('swingTempo', () {
    test('computes durations and ratio', () {
      const phases =
          SwingPhases(takeaway: 0, top: 30, impact: 40, finish: 60);
      final tempo = swingTempo(phases, 30);
      expect(tempo, isNotNull);
      expect(tempo!.backswingFrames, 30);
      expect(tempo.downswingFrames, 10);
      expect(tempo.ratio, closeTo(3.0, 1e-9)); // 1.0s : 0.333s
    });

    test('returns null without phases or fps', () {
      expect(swingTempo(null, 30), isNull);
      const phases = SwingPhases(takeaway: 0, top: 30, impact: 40, finish: 60);
      expect(swingTempo(phases, 0), isNull);
    });
  });

  // --- P1.1: presence gate ---------------------------------------------------
  // Found on device 2026-08-17 -- a video of nothing produced a full fault
  // report. Byte-parallel with test_swing_phases.py. Impossibilities only; no
  // calibrated thresholds.
  group('implausibleSwing', () {
    SwingPhases p(int takeaway, int top, int impact, int finish) => SwingPhases(
          takeaway: takeaway,
          top: top,
          impact: impact,
          finish: finish,
        );

    test('accepts a normal swing', () {
      // 30 fps, backswing 22 frames, downswing 8 -> ~2.75:1
      expect(implausibleSwing(p(10, 32, 40, 60)), isNull);
    });


    test('rejects a zero-duration backswing', () {
      expect(implausibleSwing(p(5, 5, 20, 40)), isNotNull);
    });

    test('rejects a zero-duration downswing', () {
      expect(implausibleSwing(p(0, 20, 20, 40)), isNotNull);
    });

    test('rejects null phases', () {
      expect(implausibleSwing(null), isNotNull);
    });

  });

  // Stance-bounded phases from the first five real recordings off a phone
  // (2026-08-17, 30 fps), recomputed through locate_swing with hip_x (the path
  // the app runs). The four genuine swings all have ratio >= 2.78; the clip of
  // nothing has ratio 0.29 and is correctly rejected.
  //
  // These REPLACE the peak-localized fixture that was here before the tempo
  // check was reinstated (2026-08-23). Peak localization (0/14 against labels)
  // is no longer used by any code path.
  group('implausibleSwing with stance-bounded device recordings', () {
    const deviceSwings = <String, SwingPhases>{
      // Ratios: 5.00, 2.80, 3.75, 2.78
      'real swing 1':
          SwingPhases(takeaway: 239, top: 299, impact: 311, finish: 320),
      'real swing 2':
          SwingPhases(takeaway: 244, top: 272, impact: 282, finish: 301),
      'real swing 3':
          SwingPhases(takeaway: 264, top: 294, impact: 302, finish: 312),
      'real swing 4':
          SwingPhases(takeaway: 316, top: 341, impact: 350, finish: 360),
    };

    deviceSwings.forEach((label, phases) {
      test('accepts $label', () => expect(implausibleSwing(phases), isNull));
    });

    test('rejects the nothing-clip', () {
      // Clip 0 of device 2026-08-17: ratio 0.29 under stance-bounded
      // localization — correctly rejected by the tempo check.
      const phases =
          SwingPhases(takeaway: 106, top: 110, impact: 124, finish: 137);
      final reason = implausibleSwing(phases);
      expect(reason, isNotNull);
      expect(reason!, contains('backswing is shorter than the downswing'));
    });
  });

  group('tempoRatioPrecision', () {
    // Both phases are counted in whole frames, so the ratio is only pinned
    // down to (1/backswing + 1/downswing) * ratio. No constant, no calibration
    // debt -- this is the arithmetic of counting, not a claim about golf.

    test('null when there is no tempo', () {
      expect(tempoRatioPrecision(null), isNull);
    });

    test('null when a phase has no duration', () {
      const zeroDown = SwingPhases(takeaway: 0, top: 10, impact: 10, finish: 20);
      expect(tempoRatioPrecision(swingTempo(zeroDown, 30)), isNull);
    });

    test('a long swing is pinned down tightly', () {
      // 90 frames up, 30 down at 240fps: ratio 3.0, precision 0.13.
      const phases = SwingPhases(takeaway: 0, top: 90, impact: 120, finish: 150);
      final tempo = swingTempo(phases, 240)!;
      expect(tempo.ratio, closeTo(3.0, 1e-9));
      expect(tempoRatioPrecision(tempo), closeTo(0.133, 1e-3));
    });

    test('a short downswing is pinned down loosely', () {
      // 9 frames up, 3 down at 30fps: same 3.0 ratio, 4x the uncertainty.
      const phases = SwingPhases(takeaway: 0, top: 9, impact: 12, finish: 20);
      final tempo = swingTempo(phases, 30)!;
      expect(tempo.ratio, closeTo(3.0, 1e-9));
      expect(tempoRatioPrecision(tempo), closeTo(1.333, 1e-3));
    });

    test('the device report that produced the false hedge is pinned tightly',
        () {
      // Device 2026-08-17, 30fps: the report told the golfer their downswing
      // "spans only a few frames" while the detector had put 58 in it. Frame
      // rate is not what decides this -- the counts are.
      const phases = SwingPhases(takeaway: 0, top: 6, impact: 64, finish: 136);
      final tempo = swingTempo(phases, 29.97)!;
      final precision = tempoRatioPrecision(tempo)!;
      expect(tempo.downswingFrames, 58);
      expect(precision, lessThan(0.05));
    });
  });

}
