import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../analysis/participant.dart';
import '../analysis/swing_history.dart';
import '../models/drill.dart';
import 'analyzing_screen.dart';
import 'theme/app_theme.dart';

/// First screen: full-bleed camera viewfinder with a circular shutter button,
/// focus picker, framing guide, and elapsed timer. When recording stops, hands
/// the clip to the analysis screen ("record then analyze").
class RecordScreen extends StatefulWidget {
  const RecordScreen({
    super.key,
    required this.drills,
    required this.cameras,
    required this.participant,
    required this.captureSession,
  });

  final List<Drill> drills;
  final List<CameraDescription> cameras;

  /// The anonymous local golfer these swings belong to. Updated by the shell
  /// when Profile saves changes, so [didUpdateWidget] picks up the latest.
  final Participant participant;

  /// Groups every swing recorded in this run of the app.
  final CaptureSession captureSession;

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  CameraController? _controller;
  Future<void>? _initFuture;
  bool _isRecording = false;

  /// The fault the golfer wants to work on this swing, or null for a full swing
  /// check. Every detector still runs; this only sets the report's focus.
  String? _targeting;

  /// Which hand the golfer swings with. This is not cosmetic: it picks the
  /// wrist phase detection tracks, and every measurement is sampled at the
  /// frame indices that produces. Analyzing a lefty as right-handed measures
  /// the trail wrist and yields meaningless phases.
  ///
  /// Remembered on the participant record, so it survives app restarts and does
  /// not silently revert to right-handed for a lefty who set it last week.
  late Handedness _handedness;

  /// Whether this is a natural swing or a deliberately exaggerated one recorded
  /// as a labelled positive control.
  SwingKind _swingKind = SwingKind.natural;

  /// The fault being deliberately exaggerated on a calibration swing.
  String _calibrationFault = faultIds.first;

  /// Elapsed recording timer.
  Timer? _elapsedTimer;
  Duration _elapsed = Duration.zero;

  /// Self-timer countdown. Null when not counting down.
  int? _selfTimerRemaining;
  Timer? _selfTimer;

  @override
  void initState() {
    super.initState();
    _handedness = widget.participant.handedness ?? Handedness.right;
    if (widget.cameras.isNotEmpty) {
      _setupCamera(widget.cameras.first);
    }
  }

  @override
  void didUpdateWidget(covariant RecordScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant.id != widget.participant.id) {
      // Participant changed (e.g. Profile saved) — pick up new handedness.
      _handedness = widget.participant.handedness ?? _handedness;
    }
  }

  void _setupCamera(CameraDescription camera) {
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
    );
    _controller = controller;
    _initFuture = controller.initialize();
    setState(() {});
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _selfTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _startElapsedTimer() {
    _elapsed = Duration.zero;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  String get _elapsedLabel {
    final minutes = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// Start a 3-second countdown before recording begins. Gives the golfer time
  /// to step back from the phone.
  void _startSelfTimer() {
    setState(() => _selfTimerRemaining = 3);
    HapticFeedback.mediumImpact();
    _selfTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final remaining = (_selfTimerRemaining ?? 0) - 1;
      if (remaining <= 0) {
        timer.cancel();
        setState(() => _selfTimerRemaining = null);
        _startRecording();
      } else {
        HapticFeedback.lightImpact();
        setState(() => _selfTimerRemaining = remaining);
      }
    });
  }

  void _cancelSelfTimer() {
    _selfTimer?.cancel();
    _selfTimer = null;
    if (mounted) setState(() => _selfTimerRemaining = null);
  }

  Future<void> _startRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.startVideoRecording();
    HapticFeedback.heavyImpact();
    _startElapsedTimer();
    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final file = await controller.stopVideoRecording();
    HapticFeedback.heavyImpact();
    _stopElapsedTimer();
    setState(() => _isRecording = false);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnalyzingScreen(
          videoPath: file.path,
          drills: widget.drills,
          handedness: _handedness,
          targeting: _targeting,
          participantId: widget.participant.id,
          captureSessionId: widget.captureSession.id,
          swingKind: _swingKind,
          calibrationFault: _calibrationFault,
        ),
      ),
    );
  }

  void _onShutterTap() {
    if (_selfTimerRemaining != null) {
      _cancelSelfTimer();
      return;
    }
    if (_isRecording) {
      _stopRecording();
    } else {
      _startRecording();
    }
  }

  void _onSelfTimerTap() {
    if (_selfTimerRemaining != null) {
      _cancelSelfTimer();
      return;
    }
    if (_isRecording) return;
    _startSelfTimer();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cameras.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Record')),
        body: const _NoCameraMessage(),
      );
    }

    return Scaffold(
      // Edge-to-edge: no AppBar, camera fills the screen.
      extendBodyBehindAppBar: true,
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Camera error: ${snapshot.error}'),
            );
          }
          return _ViewfinderLayout(
            controller: _controller!,
            isRecording: _isRecording,
            selfTimerRemaining: _selfTimerRemaining,
            elapsed: _elapsedLabel,
            targeting: _targeting,
            onTargetingChanged: _isRecording
                ? null
                : (value) => setState(() => _targeting = value),
            onShutterTap: _onShutterTap,
            onSelfTimerTap: _onSelfTimerTap,
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Viewfinder layout — camera + overlays
// ---------------------------------------------------------------------------

class _ViewfinderLayout extends StatelessWidget {
  const _ViewfinderLayout({
    required this.controller,
    required this.isRecording,
    required this.selfTimerRemaining,
    required this.elapsed,
    required this.targeting,
    required this.onTargetingChanged,
    required this.onShutterTap,
    required this.onSelfTimerTap,
  });

  final CameraController controller;
  final bool isRecording;
  final int? selfTimerRemaining;
  final String elapsed;
  final String? targeting;
  final ValueChanged<String?>? onTargetingChanged;
  final VoidCallback onShutterTap;
  final VoidCallback onSelfTimerTap;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview — fills the entire screen.
        CameraPreview(controller),

        // Framing guide overlay — always visible when not recording.
        if (!isRecording && selfTimerRemaining == null)
          const _FramingGuide(),

        // Self-timer countdown overlay.
        if (selfTimerRemaining != null)
          _SelfTimerOverlay(remaining: selfTimerRemaining!),

        // Top bar — profile button + instruction hint.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!isRecording && selfTimerRemaining == null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: sc.scrim,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        'Side-on, full body in frame',
                        style: TextStyle(
                            color: sc.onScrim,
                            fontSize: 12,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  if (isRecording)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: sc.scrim,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: sc.drillAdvanced,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Gap.hsm,
                          Text(
                            elapsed,
                            style: TextStyle(
                              color: sc.onScrim,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // Bottom control bar.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    sc.scrim,
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Focus picker — only when not recording.
                  if (!isRecording)
                    _FocusPicker(
                      value: targeting,
                      onChanged: onTargetingChanged,
                    ),
                  if (!isRecording) Gap.md,
                  // Shutter row: self-timer + shutter button + spacer.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Self-timer button.
                      SizedBox(
                        width: 48,
                        child: isRecording
                            ? const SizedBox.shrink()
                            : IconButton(
                                tooltip: 'Self-timer',
                                icon: Icon(Icons.timer,
                                    color: sc.onScrim, size: 28),
                                onPressed: onSelfTimerTap,
                              ),
                      ),
                      Gap.hlg,
                      // Circular shutter button.
                      _ShutterButton(
                        isRecording: isRecording,
                        onTap: onShutterTap,
                      ),
                      Gap.hlg,
                      // Balance the row.
                      const SizedBox(width: 48),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shutter button — circular, with a recording ring animation
// ---------------------------------------------------------------------------

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.isRecording, required this.onTap});

  final bool isRecording;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: sc.onScrim,
            width: 4,
          ),
        ),
        padding: const EdgeInsets.all(4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            color: isRecording ? sc.drillAdvanced : sc.onScrim,
            borderRadius:
                BorderRadius.circular(isRecording ? 8 : 28),
          ),
          width: isRecording ? 28 : 56,
          height: isRecording ? 28 : 56,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Framing guide — CustomPainter silhouette + vertical alignment line
// ---------------------------------------------------------------------------

class _FramingGuide extends StatelessWidget {
  const _FramingGuide();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _FramingGuidePainter(
          color: SwingColors.of(context).onScrim.withValues(alpha: 0.25),
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _FramingGuidePainter extends CustomPainter {
  _FramingGuidePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final centerX = size.width * 0.5;

    // Vertical alignment line — helps the golfer center themselves.
    canvas.drawLine(
      Offset(centerX, size.height * 0.1),
      Offset(centerX, size.height * 0.9),
      paint,
    );

    // Simplified golfer silhouette — head, torso, stance.
    final headCenterY = size.height * 0.22;
    const headRadius = 14.0;

    // Head
    canvas.drawCircle(Offset(centerX, headCenterY), headRadius, paint);

    // Shoulders
    final shoulderY = headCenterY + headRadius + 6;
    canvas.drawLine(
      Offset(centerX - 24, shoulderY),
      Offset(centerX + 24, shoulderY),
      paint,
    );

    // Torso
    final hipY = shoulderY + 50;
    canvas.drawLine(Offset(centerX, shoulderY), Offset(centerX, hipY), paint);

    // Hips
    canvas.drawLine(
      Offset(centerX - 18, hipY),
      Offset(centerX + 18, hipY),
      paint,
    );

    // Legs — slight stance width
    final footY = hipY + 55;
    canvas.drawLine(
        Offset(centerX - 18, hipY), Offset(centerX - 22, footY), paint);
    canvas.drawLine(
        Offset(centerX + 18, hipY), Offset(centerX + 22, footY), paint);

    // Feet
    canvas.drawLine(Offset(centerX - 22, footY),
        Offset(centerX - 22 - 8, footY), paint);
    canvas.drawLine(Offset(centerX + 22, footY),
        Offset(centerX + 22 + 8, footY), paint);
  }

  @override
  bool shouldRepaint(covariant _FramingGuidePainter oldDelegate) =>
      color != oldDelegate.color;
}

// ---------------------------------------------------------------------------
// Self-timer countdown overlay
// ---------------------------------------------------------------------------

class _SelfTimerOverlay extends StatelessWidget {
  const _SelfTimerOverlay({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Text(
          '$remaining',
          style: TextStyle(
            fontSize: 96,
            fontWeight: FontWeight.w300,
            color: SwingColors.of(context).onScrim.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Focus picker — compact pill-style chips instead of a dropdown
// ---------------------------------------------------------------------------

class _FocusPicker extends StatelessWidget {
  const _FocusPicker({required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _focusChip(
            context: context,
            label: 'Everything',
            selected: value == null,
            onTap: onChanged == null ? null : () => onChanged!(null),
            sc: sc,
          ),
          for (final id in faultIds) ...[
            Gap.hsm,
            _focusChip(
              context: context,
              label: faultLabels[id] ?? id,
              selected: value == id,
              onTap: onChanged == null ? null : () => onChanged!(id),
              sc: sc,
            ),
          ],
        ],
      ),
    );
  }

  Widget _focusChip({
    required BuildContext context,
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    required SwingColors sc,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? sc.focus.withValues(alpha: 0.85) : sc.scrim,
          borderRadius: BorderRadius.circular(16),
          border: selected
              ? Border.all(color: sc.focus, width: 1.5)
              : Border.all(color: sc.onScrim.withValues(alpha: 0.2)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? sc.onScrim : sc.onScrim.withValues(alpha: 0.7),
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// No-camera fallback
// ---------------------------------------------------------------------------

class _NoCameraMessage extends StatelessWidget {
  const _NoCameraMessage();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Text(
          'No camera found. Fore Swing needs a camera to record your swing.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
