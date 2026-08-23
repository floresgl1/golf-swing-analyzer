import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/frame_features.dart';
import '../../models/key_frame.dart';
import '../../analysis/faults.dart';
import '../theme/app_theme.dart';

/// Side-by-side address / impact stills for one fault, with the measured
/// landmark highlighted so the golfer can see what moved.
///
/// Placed inside the expanded measurement row for flagged faults. Smaller than
/// the hero montage — this is evidence for one specific measurement, not the
/// headline image.
class FaultStills extends StatelessWidget {
  const FaultStills({
    super.key,
    required this.faultId,
    required this.addressFrame,
    required this.impactFrame,
  });

  final String faultId;
  final KeyFrame addressFrame;
  final KeyFrame impactFrame;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          Expanded(
            child: _AnnotatedStill(
              frame: addressFrame,
              label: 'Address',
              faultId: faultId,
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: _AnnotatedStill(
              frame: impactFrame,
              label: 'Impact',
              faultId: faultId,
            ),
          ),
        ],
      ),
    );
  }
}

class _AnnotatedStill extends StatelessWidget {
  const _AnnotatedStill({
    required this.frame,
    required this.label,
    required this.faultId,
  });

  final KeyFrame frame;
  final String label;
  final String faultId;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    final file = File(frame.imagePath);
    final exists = file.existsSync();

    return AspectRatio(
      aspectRatio: 9 / 16,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Frame image.
          if (exists)
            Image.file(
              file,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            )
          else
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),

          // Highlight the measured landmark for this fault.
          if (exists && frame.features != null && frame.features!.detected)
            CustomPaint(
              painter: _FaultHighlightPainter(
                features: frame.features!,
                faultId: faultId,
              ),
            ),

          // Phase label at the bottom.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, sc.scrim],
                ),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: sc.onScrim,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws a highlighted ring around the landmark the fault actually measures:
///   - Head sway / reverse pivot → eye midpoint
///   - Early extension → hip midpoint
///   - Loss of posture → shoulder + hip (spine line)
///
/// Everything else gets a subtle spine overlay, same as the montage.
class _FaultHighlightPainter extends CustomPainter {
  const _FaultHighlightPainter({
    required this.features,
    required this.faultId,
  });

  final FrameFeatures features;
  final String faultId;

  @override
  void paint(Canvas canvas, Size size) {
    // Same assumed resolution as the montage painter.
    const imageWidth = 1080.0;
    const imageHeight = 1920.0;
    final scaleX = size.width / imageWidth;
    final scaleY = size.height / imageHeight;

    Offset map(double x, double y) => Offset(x * scaleX, y * scaleY);

    final head = map(features.eyeX, features.eyeY);
    final shoulder = map(features.shoulderX, features.shoulderY);
    final hip = map(features.hipX, features.hipY);

    // Subtle spine line — always drawn.
    final spinePaint = Paint()
      ..color = const Color(0x55FFFFFF)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(head, shoulder, spinePaint);
    canvas.drawLine(shoulder, hip, spinePaint);

    // Highlighted ring on the measured landmark.
    final highlightPaint = Paint()
      ..color = const Color(0xDDF5A623) // flagged amber, strong
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = const Color(0xDDF5A623)
      ..style = PaintingStyle.fill;

    switch (faultId) {
      case faultHeadSway:
      case faultReversePivot:
        // Eye midpoint — what the head-movement and reverse-pivot detectors
        // track.
        canvas.drawCircle(head, 10 * scaleX, highlightPaint);
        canvas.drawCircle(head, 3 * scaleX, dotPaint);

      case faultEarlyExtension:
        // Hip midpoint — early extension tracks pelvis rise.
        canvas.drawCircle(hip, 10 * scaleX, highlightPaint);
        canvas.drawCircle(hip, 3 * scaleX, dotPaint);

      case faultLossOfPosture:
        // Spine line — loss of posture tracks spine tilt change.
        final postPaint = Paint()
          ..color = const Color(0xDDF5A623)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(shoulder, hip, postPaint);
        canvas.drawCircle(shoulder, 4 * scaleX, dotPaint);
        canvas.drawCircle(hip, 4 * scaleX, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FaultHighlightPainter old) =>
      faultId != old.faultId || features != old.features;
}
