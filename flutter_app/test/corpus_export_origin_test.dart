import 'dart:ui' show Rect, Size, Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/services/corpus_export.dart';

/// Found on device 2026-08-17: the export failed outright with
/// "sharePositionOrigin: argument must be set, {{0, 0}, {0, 0}} must be
/// non-zero". iOS rejects both a null and a zero-sized origin, so the only
/// property that matters here is that the result is never degenerate.
void main() {
  const screen = Size(430, 932); // the device it failed on

  group('shareOriginOrFallback', () {
    test('uses the control rect when it has size', () {
      const control = Rect.fromLTWH(16, 700, 398, 48);
      expect(shareOriginOrFallback(control, screen), control);
    });

    test('never returns a degenerate rect', () {
      // null: the button had no render box yet
      expect(shareOriginOrFallback(null, screen).isEmpty, isFalse);
      // Rect.zero: exactly what iOS rejected on device
      expect(shareOriginOrFallback(Rect.zero, screen).isEmpty, isFalse);
      // zero-height but positioned — still degenerate to UIKit
      expect(
        shareOriginOrFallback(const Rect.fromLTWH(10, 10, 100, 0), screen)
            .isEmpty,
        isFalse,
      );
    });

    test('clamps a partly off-screen control into the source view', () {
      // iOS requires CGRectContainsRect(view.frame, origin). A button in a
      // scrolled list can extend past the screen edge, and the un-clamped rect
      // would be rejected even though it is non-empty.
      const offBottom = Rect.fromLTWH(16, 900, 398, 100); // ends at y=1000
      final clamped = shareOriginOrFallback(offBottom, screen);
      expect((Offset.zero & screen).contains(clamped.topLeft), isTrue);
      expect(clamped.bottom, lessThanOrEqualTo(screen.height));
      expect(clamped.isEmpty, isFalse);
    });

    test('falls back when the control is entirely off screen', () {
      const gone = Rect.fromLTWH(16, 2000, 398, 48);
      final origin = shareOriginOrFallback(gone, screen);
      expect(origin.isEmpty, isFalse);
      expect((Offset.zero & screen).contains(origin.center), isTrue);
    });

    test('the fallback sits inside the screen it will be presented in', () {
      // UIKit also requires the origin to be within the source view's
      // coordinate space -- the device error named both conditions.
      final fallback = shareOriginOrFallback(null, screen);
      expect((Offset.zero & screen).contains(fallback.center), isTrue);
    });
  });
}
