import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models/drill.dart';
import '../theme/app_theme.dart';

/// One recommended drill: name + difficulty badge, description, optional
/// equipment line, and — when a demo clip is bundled — a tap-to-play video.
///
/// Drills without a clip show a "demo coming soon" placeholder so the golfer
/// knows the container is deliberate, not broken.
class DrillTile extends StatefulWidget {
  const DrillTile({super.key, required this.drill});

  final Drill drill;

  @override
  State<DrillTile> createState() => _DrillTileState();
}

class _DrillTileState extends State<DrillTile> {
  bool _showVideo = false;
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _error = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _toggleVideo() {
    if (!widget.drill.hasMedia) return;
    setState(() => _showVideo = !_showVideo);
    if (_showVideo && _controller == null) {
      _initVideo();
    }
  }

  Future<void> _initVideo() async {
    final controller = VideoPlayerController.asset(
      'assets/${widget.drill.media}',
    );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      controller.setLooping(true);
      setState(() => _initialized = true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = true);
    }
  }

  void _playPause() {
    final c = _controller;
    if (c == null || !_initialized) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  Color _difficultyColor(BuildContext context) {
    final sc = SwingColors.of(context);
    switch (widget.drill.difficulty) {
      case 'beginner':
        return sc.drillBeginner;
      case 'intermediate':
        return sc.drillIntermediate;
      case 'advanced':
        return sc.drillAdvanced;
      default:
        return Theme.of(context).colorScheme.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final drill = widget.drill;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: name + difficulty badge
          Row(
            children: [
              Expanded(
                child: Text(
                  drill.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _difficultyColor(context).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _capitalize(drill.difficulty),
                  style: TextStyle(
                    color: _difficultyColor(context),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (drill.needsEquipment)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Equipment: ${drill.equipment}',
                style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ),
          Gap.xs,
          Text(drill.description, style: theme.textTheme.bodySmall),

          // Video section
          Gap.sm,
          if (drill.hasMedia) ...[
            // Tap to expand/collapse the demo clip
            InkWell(
              onTap: _toggleVideo,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _showVideo ? Icons.expand_less : Icons.play_circle_outline,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _showVideo ? 'Hide demo' : 'Watch demo',
                      style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            if (_showVideo) ...[
              Gap.sm,
              _DrillVideoPlayer(
                controller: _controller,
                initialized: _initialized,
                error: _error,
                onPlayPause: _playPause,
              ),
            ],
          ] else ...[
            // Placeholder for drills without clips yet
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.videocam_off_outlined,
                    size: 14, color: theme.colorScheme.outline),
                const SizedBox(width: 4),
                Text(
                  'Demo coming soon',
                  style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The inline video player for a drill demo clip.
class _DrillVideoPlayer extends StatelessWidget {
  const _DrillVideoPlayer({
    required this.controller,
    required this.initialized,
    required this.error,
    required this.onPlayPause,
  });

  final VideoPlayerController? controller;
  final bool initialized;
  final bool error;
  final VoidCallback onPlayPause;

  @override
  Widget build(BuildContext context) {
    if (error) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Could not load the demo clip.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
        ),
      );
    }

    if (!initialized || controller == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final c = controller!;
    final aspectRatio = c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: GestureDetector(
        onTap: onPlayPause,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AspectRatio(
              aspectRatio: aspectRatio,
              child: VideoPlayer(c),
            ),
            // Play/pause overlay — fades out while playing
            if (!c.value.isPlaying)
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(12),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 32),
              ),
          ],
        ),
      ),
    );
  }
}

String _capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
