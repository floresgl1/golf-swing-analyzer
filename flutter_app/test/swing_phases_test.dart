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
}
