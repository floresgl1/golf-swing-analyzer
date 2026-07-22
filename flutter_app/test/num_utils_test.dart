import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/num_utils.dart';

void main() {
  group('nanMedian', () {
    test('ignores NaNs and averages middle pair on even count', () {
      expect(nanMedian([1, 2, 3, double.nan]), 2);
      expect(nanMedian([1, 2, 3, 4]), 2.5);
      expect(nanMedian([double.nan, double.nan]).isNaN, isTrue);
    });
  });

  group('fillNaNLinear', () {
    test('interpolates interior gaps and clamps the ends', () {
      final out = fillNaNLinear([double.nan, 1, double.nan, 3, double.nan]);
      // Leading NaN clamps to first finite (1); interior gap 1->3 lerps to 2;
      // trailing NaN clamps to last finite (3).
      expect(out[0], 1);
      expect(out[1], 1);
      expect(out[2], 2);
      expect(out[3], 3);
      expect(out[4], 3);
    });
  });

  group('movingAverageEdge', () {
    test('edge-padded window of 3 matches hand calculation', () {
      // a = [0,3,6]; w=3 -> [(0+0+3)/3, (0+3+6)/3, (3+6+6)/3] = [1,3,5]
      final out = movingAverageEdge([0, 3, 6], 3);
      expect(out[0], closeTo(1, 1e-9));
      expect(out[1], closeTo(3, 1e-9));
      expect(out[2], closeTo(5, 1e-9));
    });
  });

  group('argMin/argMax slices', () {
    test('return first occurrence within the range', () {
      final a = [5.0, 1.0, 1.0, 9.0, 9.0];
      expect(argMinSlice(a, 0, a.length), 1);
      expect(argMaxSlice(a, 0, a.length), 3);
    });
  });
}
