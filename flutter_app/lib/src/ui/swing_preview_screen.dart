import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../analysis/swing_history.dart';
import '../models/drill.dart';
import 'analyzing_screen.dart';
import 'theme/app_theme.dart';

/// Quick preview of the recorded clip before committing to analysis.
///
/// Shows the video so the golfer can confirm the framing was right before
/// waiting 10–15 seconds for the pipeline. If it's a bad take they tap
/// "Record again" and skip the wait entirely.
///
/// This is NOT a frame-level trimmer — the stance-bounded localization handles
/// finding the swing in a long clip. This catches the cases where the camera
/// moved, the golfer was out of frame, or they just want to try again.
class SwingPreviewScreen extends StatefulWidget {
  const SwingPreviewScreen({
    super.key,
    required this.videoPath,
    required this.drills,
    required this.handedness,
    required this.participantId,
    required this.captureSessionId,
    this.targeting,
    this.swingKind = SwingKind.natural,
    this.calibrationFault,
  });

  final String videoPath;
  final List<Drill> drills;
  final Handedness handedness;
  final String participantId;
  final String captureSessionId;
  final String? targeting;
  final SwingKind swingKind;
  final String? calibrationFault;

  @override
  State<SwingPreviewScreen> createState() => _SwingPreviewScreenState();
}

class _SwingPreviewScreenState extends State<SwingPreviewScreen> {
  late final VideoPlayerController _controller;
  bool _initialized = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.videoPath));
    _controller.initialize().then((_) {
      if (!mounted) return;
      _controller.setLooping(true);
      _controller.play();
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
      _controller.play();
    }
  }

  void _analyze() {
    // Pause playback and dispose before navigating — the analyzer will read
    // the same file.
    _controller.pause();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => AnalyzingScreen(
          videoPath: widget.videoPath,
          drills: widget.drills,
          handedness: widget.handedness,
          targeting: widget.targeting,
          participantId: widget.participantId,
          captureSessionId: widget.captureSessionId,
          swingKind: widget.swingKind,
          calibrationFault: widget.calibrationFault,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Video preview — fills the screen.
          if (_initialized)
            GestureDetector(
              onTap: _togglePlayPause,
              child: Center(
                child: AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                ),
              ),
            )
          else if (_error)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline,
                      size: 48, color: Theme.of(context).colorScheme.error),
                  Gap.md,
                  Text(
                    'Couldn\'t load the preview.',
                    style: TextStyle(color: sc.onScrim),
                  ),
                ],
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),

          // Playback state overlay — shows a play icon when paused.
          if (_initialized && !_controller.value.isPlaying)
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: sc.scrim.withValues(alpha: 0.7),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 36,
                    color: sc.onScrim,
                  ),
                ),
              ),
            ),

          // Top bar — "Record again" button.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.arrow_back, color: sc.onScrim, size: 20),
                      label: Text(
                        'Record again',
                        style: TextStyle(color: sc.onScrim),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: sc.scrim,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        'Check your clip',
                        style: TextStyle(
                          color: sc.onScrim.withValues(alpha: 0.8),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom — "Analyze" button, always visible.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, sc.scrim],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Progress bar.
                    if (_initialized)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _MiniProgress(controller: _controller),
                      ),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _initialized || _error ? _analyze : null,
                        icon: const Icon(Icons.analytics_outlined),
                        label: const Text('Analyze this swing'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thin progress bar showing how far through the video the playback is.
class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    final duration = controller.value.duration;
    final position = controller.value.position;
    final fraction = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: fraction,
        minHeight: 3,
        color: sc.focus,
        backgroundColor: sc.onScrim.withValues(alpha: 0.2),
      ),
    );
  }
}
