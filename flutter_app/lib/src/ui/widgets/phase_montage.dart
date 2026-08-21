import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/frame_features.dart';
import '../../models/key_frame.dart';
import '../theme/app_theme.dart';

/// Address / Top / Impact stills shown at the top of the report, so the golfer
/// sees the body positions the measurements came from.
///
/// Each still is drawn with a simplified skeleton overlay — head, shoulder
/// midpoint, spine, hip midpoint — which is what the detectors actually measure.
/// A full 33-point skeleton would need the complete landmark set; the midpoints
/// are what we have, and showing them is honest about what was observed.
class PhaseMontage extends StatelessWidget {
  const PhaseMontage({super.key, required this.keyFrames});

  final List<KeyFrame> keyFrames;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Row(
          children: [
            for (var i = 0; i < keyFrames.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(child: _KeyFrameStill(frame: keyFrames[i])),
            ],
          ],
        ),
      ),
    );
  }
}

class _KeyFrameStill extends StatelessWidget {
  const _KeyFrameStill({required this.frame});

  final KeyFrame frame;

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
                child: const Center(
                  child: Icon(Icons.broken_image_outlined, size: 24),
                ),
              ),
            )
          else
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Center(
                child: Icon(Icons.image_not_supported_outlined, size: 24),
              ),
            ),

          // Skeleton overlay — the 4 midpoints the detectors use.
          if (exists && frame.features != null && frame.features!.detected)
            CustomPaint(
              painter: _SkeletonPainter(features: frame.features!),
            ),

          // Phase label at the bottom.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, sc.scrim],
                ),
              ),
              child: Text(
                frame.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: sc.onScrim,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws the simplified skeleton the detectors actually use: head (eye
/// midpoint), shoulder midpoint, spine line, and hip midpoint. All coordinates
/// are in image-pixel space; the painter scales them to the widget's size.
///
/// This is deliberately not a full 33-point skeleton: we only have the midpoints
/// that matter for the four fault detectors, and pretending to have more would
/// be dishonest.
class _SkeletonPainter extends CustomPainter {
  const _SkeletonPainter({required this.features});

  final FrameFeatures features;

  @override
  void paint(Canvas canvas, Size size) {
    // The image is displayed with BoxFit.cover inside a 9:16 aspect ratio.
    // We don't know the actual image dimensions here, so we use the features'
    // pixel coordinates relative to each other. The Image.file widget scales
    // the image to cover the widget, so we need to map pixel coords to the
    // widget's coordinate space.
    //
    // Without the image dimensions, we can't do this precisely. Instead, we
    // estimate: the image is likely 1080×1920 (1080p) or similar, so we scale
    // the pixel coordinates to fit the widget. The skeleton is an approximate
    // overlay, not a precision tool.
    //
    // A better solution would carry image dimensions from the extractor, but
    // that requires changes to the pipeline. This is good enough to show the
    // golfer where the app is looking.

    // Estimate image dimensions from the feature ranges. We'll assume a
    // standard phone video resolution and scale accordingly.
    const imageWidth = 1080.0;
    const imageHeight = 1920.0;

    final scaleX = size.width / imageWidth;
    final scaleY = size.height / imageHeight;

    Offset map(double x, double y) => Offset(x * scaleX, y * scaleY);

    final paint = Paint()
      ..color = const Color(0xBBF5A623) // flagged amber, 73% opacity
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final dotPaint = Paint()
      ..color = const Color(0xBBF5A623)
      ..style = PaintingStyle.fill;

    final head = map(features.eyeX, features.eyeY);
    final shoulder = map(features.shoulderX, features.shoulderY);
    final hip = map(features.hipX, features.hipY);

    // Head dot.
    canvas.drawCircle(head, 5, dotPaint);

    // Spine: head → shoulder → hip.
    canvas.drawLine(head, shoulder, paint);
    canvas.drawLine(shoulder, hip, paint);

    // Shoulder crossbar.
    final shoulderHalf = 15.0 * scaleX;
    canvas.drawLine(
      Offset(shoulder.dx - shoulderHalf, shoulder.dy),
      Offset(shoulder.dx + shoulderHalf, shoulder.dy),
      paint,
    );

    // Hip crossbar.
    final hipHalf = 12.0 * scaleX;
    canvas.drawLine(
      Offset(hip.dx - hipHalf, hip.dy),
      Offset(hip.dx + hipHalf, hip.dy),
      paint,
    );

    // Joint dots.
    canvas.drawCircle(shoulder, 3, dotPaint);
    canvas.drawCircle(hip, 3, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _SkeletonPainter oldDelegate) =>
      features != oldDelegate.features;
}
