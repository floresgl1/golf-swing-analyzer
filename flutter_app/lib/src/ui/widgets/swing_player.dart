import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../analysis/swing_phases.dart';
import '../theme/app_theme.dart';

/// Inline video player for the retained clip, with a custom scrubber showing
/// phase markers (address, top, impact, finish) on the timeline.
///
/// Placed on the report screen right after the hero stills so the golfer can
/// scrub through the exact clip those stills came from. This is the "scrubbing
/// of the retained clip with phase markers" item 3 calls for.
class SwingPlayer extends StatefulWidget {
  const SwingPlayer({
    super.key,
    required this.clipPath,
    required this.phases,
    required this.fps,
    required this.frameCount,
  });

  final String clipPath;
  final SwingPhases phases;
  final double fps;
  final int frameCount;

  @override
  State<SwingPlayer> createState() => _SwingPlayerState();
}

class _SwingPlayerState extends State<SwingPlayer> {
  late final VideoPlayerController _controller;
  bool _initialized = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.clipPath));
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _initialized = true);
    }).catchError((_) {
      if (!mounted) return;
      setState(() => _error = true);
    });
    _controller.addListener(_onPlayback);
  }

  void _onPlayback() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onPlayback);
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      // If at the end, restart.
      final position = _controller.value.position;
      final duration = _controller.value.duration;
      if (duration > Duration.zero &&
          position >= duration - const Duration(milliseconds: 100)) {
        _controller.seekTo(Duration.zero);
      }
      _controller.play();
    }
  }

  /// Seek to a specific fraction of the video (0.0–1.0).
  void _seekToFraction(double fraction) {
    final duration = _controller.value.duration;
    if (duration <= Duration.zero) return;
    final target = duration * fraction;
    _controller.seekTo(target);
  }

  /// Convert a frame index to a fraction of the total duration.
  double _frameFraction(int frame) {
    if (widget.frameCount <= 0) return 0;
    return (frame / widget.frameCount).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    if (_error) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Video viewport — maintains the clip's aspect ratio.
          if (_initialized)
            GestureDetector(
              onTap: _togglePlayPause,
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    VideoPlayer(_controller),
                    // Play/pause overlay — visible when paused.
                    if (!_controller.value.isPlaying)
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: SwingColors.of(context)
                              .scrim
                              .withValues(alpha: 0.7),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 36,
                          color: SwingColors.of(context).onScrim,
                        ),
                      ),
                  ],
                ),
              ),
            )
          else
            AspectRatio(
              aspectRatio: 9 / 16,
              child: Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),

          // Scrubber with phase markers.
          if (_initialized)
            _PhaseScrubber(
              controller: _controller,
              phases: widget.phases,
              frameFraction: _frameFraction,
              onSeek: _seekToFraction,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Custom scrubber with phase markers
// ---------------------------------------------------------------------------

class _PhaseScrubber extends StatelessWidget {
  const _PhaseScrubber({
    required this.controller,
    required this.phases,
    required this.frameFraction,
    required this.onSeek,
  });

  final VideoPlayerController controller;
  final SwingPhases phases;
  final double Function(int frame) frameFraction;
  final ValueChanged<double> onSeek;

  double get _progress {
    final duration = controller.value.duration;
    if (duration <= Duration.zero) return 0;
    return (controller.value.position.inMilliseconds /
            duration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    final theme = Theme.of(context);

    final markers = <_PhaseMarker>[
      _PhaseMarker('Address', frameFraction(phases.takeaway)),
      _PhaseMarker('Top', frameFraction(phases.top)),
      _PhaseMarker('Impact', frameFraction(phases.impact)),
      _PhaseMarker('Finish', frameFraction(phases.finish)),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        children: [
          // The scrubber track — tappable to seek.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              // Compensate for padding.
              final fraction = details.localPosition.dx / box.size.width;
              onSeek(fraction.clamp(0.0, 1.0));
            },
            onHorizontalDragUpdate: (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              final fraction = details.localPosition.dx / box.size.width;
              onSeek(fraction.clamp(0.0, 1.0));
            },
            child: SizedBox(
              height: 32,
              child: CustomPaint(
                painter: _ScrubberPainter(
                  progress: _progress,
                  markers: markers,
                  trackColor: sc.onScrim.withValues(alpha: 0.12),
                  progressColor: sc.focus,
                  markerColor: sc.onScrim.withValues(alpha: 0.5),
                ),
                size: Size.infinite,
              ),
            ),
          ),
          Gap.xs,
          // Phase labels below the track.
          SizedBox(
            height: 16,
            child: CustomPaint(
              painter: _MarkerLabelPainter(
                markers: markers,
                textColor: theme.colorScheme.outline,
              ),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }
}

class _PhaseMarker {
  final String label;
  final double fraction;
  const _PhaseMarker(this.label, this.fraction);
}

// ---------------------------------------------------------------------------
// CustomPainters for the scrubber
// ---------------------------------------------------------------------------

class _ScrubberPainter extends CustomPainter {
  const _ScrubberPainter({
    required this.progress,
    required this.markers,
    required this.trackColor,
    required this.progressColor,
    required this.markerColor,
  });

  final double progress;
  final List<_PhaseMarker> markers;
  final Color trackColor;
  final Color progressColor;
  final Color markerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final trackHeight = 4.0;
    final trackY = size.height / 2;
    final trackRadius = Radius.circular(trackHeight / 2);

    // Background track.
    canvas.drawRRect(
      RRect.fromLTRBR(
        0, trackY - trackHeight / 2,
        size.width, trackY + trackHeight / 2,
        trackRadius,
      ),
      Paint()..color = trackColor,
    );

    // Progress fill.
    final progressWidth = size.width * progress;
    if (progressWidth > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          0, trackY - trackHeight / 2,
          progressWidth, trackY + trackHeight / 2,
          trackRadius,
        ),
        Paint()..color = progressColor,
      );
    }

    // Phase markers — thin vertical lines.
    final markerPaint = Paint()
      ..color = markerColor
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    for (final marker in markers) {
      final x = size.width * marker.fraction;
      canvas.drawLine(
        Offset(x, trackY - 8),
        Offset(x, trackY + 8),
        markerPaint,
      );
    }

    // Playhead — a small circle on the progress line.
    canvas.drawCircle(
      Offset(progressWidth, trackY),
      6,
      Paint()..color = progressColor,
    );
  }

  @override
  bool shouldRepaint(covariant _ScrubberPainter old) =>
      progress != old.progress ||
      trackColor != old.trackColor ||
      progressColor != old.progressColor;
}

class _MarkerLabelPainter extends CustomPainter {
  const _MarkerLabelPainter({
    required this.markers,
    required this.textColor,
  });

  final List<_PhaseMarker> markers;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    final style = TextStyle(
      color: textColor,
      fontSize: 10,
      fontWeight: FontWeight.w500,
    );

    for (final marker in markers) {
      final span = TextSpan(text: marker.label, style: style);
      final painter = TextPainter(
        text: span,
        textDirection: TextDirection.ltr,
      )..layout();

      // Center the label under its marker, but clamp to stay on screen.
      final x = (size.width * marker.fraction - painter.width / 2)
          .clamp(0.0, size.width - painter.width);
      painter.paint(canvas, Offset(x, 0));
    }
  }

  @override
  bool shouldRepaint(covariant _MarkerLabelPainter old) =>
      textColor != old.textColor;
}
