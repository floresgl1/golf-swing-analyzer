import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../analysis/participant.dart';
import '../analysis/swing_history.dart';
import '../models/drill.dart';
import 'analyzing_screen.dart';
import 'profile_screen.dart';

/// First screen: preview the camera and record a swing. When recording stops,
/// hands the video file off to the analysis screen ("record then analyze").
class RecordScreen extends StatefulWidget {
  const RecordScreen({
    super.key,
    required this.drills,
    required this.cameras,
    required this.participant,
    required this.participantStore,
    required this.captureSession,
  });

  final List<Drill> drills;
  final List<CameraDescription> cameras;

  /// The anonymous local golfer these swings belong to.
  final Participant participant;

  /// Null when device storage was unavailable at startup.
  final ParticipantStore? participantStore;

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

  late Participant _participant = widget.participant;

  @override
  void initState() {
    super.initState();
    _handedness = widget.participant.handedness ?? Handedness.right;
    if (widget.cameras.isNotEmpty) {
      _setupCamera(widget.cameras.first);
    }
  }

  Future<void> _setHandedness(Handedness value) async {
    setState(() => _handedness = value);
    final store = widget.participantStore;
    if (store == null) return;
    try {
      final saved = await store.setHandedness(value);
      if (mounted) setState(() => _participant = saved);
    } catch (_) {
      // Failing to remember the choice must not block recording with it.
    }
  }

  Future<void> _openProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(
          participant: _participant,
          store: widget.participantStore,
        ),
      ),
    );
    final store = widget.participantStore;
    if (store == null) return;
    try {
      final refreshed = await store.loadOrCreate();
      if (mounted) setState(() => _participant = refreshed);
    } catch (_) {
      // Keep the in-memory copy.
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
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (_isRecording) {
      final file = await controller.stopVideoRecording();
      setState(() => _isRecording = false);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AnalyzingScreen(
            videoPath: file.path,
            drills: widget.drills,
            handedness: _handedness,
            targeting: _targeting,
            participantId: _participant.id,
            captureSessionId: widget.captureSession.id,
            swingKind: _swingKind,
            calibrationFault: _calibrationFault,
          ),
        ),
      );
    } else {
      await controller.startVideoRecording();
      setState(() => _isRecording = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Record your swing'),
        actions: [
          IconButton(
            tooltip: 'Profile and export',
            icon: const Icon(Icons.person_outline),
            onPressed: _openProfile,
          ),
        ],
      ),
      body: widget.cameras.isEmpty
          ? const _NoCameraMessage()
          : FutureBuilder<void>(
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
                return _CameraPreviewWithHint(
                  controller: _controller!,
                  targeting: _targeting,
                  onTargetingChanged: _isRecording
                      ? null
                      : (value) => setState(() => _targeting = value),
                  handedness: _handedness,
                  onHandednessChanged: _isRecording ? null : _setHandedness,
                  swingKind: _swingKind,
                  onSwingKindChanged: _isRecording
                      ? null
                      : (value) => setState(() => _swingKind = value),
                  calibrationFault: _calibrationFault,
                  onCalibrationFaultChanged: _isRecording
                      ? null
                      : (value) => setState(() => _calibrationFault = value),
                );
              },
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: widget.cameras.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _toggleRecording,
              backgroundColor: _isRecording ? Colors.red : null,
              icon: Icon(_isRecording ? Icons.stop : Icons.fiber_manual_record),
              label: Text(_isRecording ? 'Stop & analyze' : 'Record'),
            ),
    );
  }
}

class _CameraPreviewWithHint extends StatelessWidget {
  const _CameraPreviewWithHint({
    required this.controller,
    required this.targeting,
    required this.onTargetingChanged,
    required this.handedness,
    required this.onHandednessChanged,
    required this.swingKind,
    required this.onSwingKindChanged,
    required this.calibrationFault,
    required this.onCalibrationFaultChanged,
  });

  final CameraController controller;
  final String? targeting;

  /// Called when the golfer picks a focus fault; null disables the picker (e.g.
  /// while recording).
  final ValueChanged<String?>? onTargetingChanged;

  final Handedness handedness;

  /// Called when the golfer picks their handedness; null disables the control.
  final ValueChanged<Handedness>? onHandednessChanged;

  final SwingKind swingKind;
  final ValueChanged<SwingKind>? onSwingKindChanged;

  final String calibrationFault;
  final ValueChanged<String>? onCalibrationFaultChanged;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(controller),
        Positioned(
          left: 16,
          right: 16,
          top: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Frame your whole body, down-the-line. Record one full swing, '
                  'then tap stop to analyze.',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              const SizedBox(height: 8),
              _HandednessSelector(
                value: handedness,
                onChanged: onHandednessChanged,
              ),
              const SizedBox(height: 8),
              _SwingKindSelector(
                value: swingKind,
                onChanged: onSwingKindChanged,
                calibrationFault: calibrationFault,
                onCalibrationFaultChanged: onCalibrationFaultChanged,
              ),
              const SizedBox(height: 8),
              _TargetSelector(
                value: targeting,
                onChanged: onTargetingChanged,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Lets the golfer mark a swing as a deliberate, exaggerated example of one
/// fault — a labelled positive control for the corpus.
///
/// These have to be distinguishable from natural swings: they are swings the
/// detector is *supposed* to flag, so counting them among natural swings would
/// make the false-positive rate look far better than it is.
class _SwingKindSelector extends StatelessWidget {
  const _SwingKindSelector({
    required this.value,
    required this.onChanged,
    required this.calibrationFault,
    required this.onCalibrationFaultChanged,
  });

  final SwingKind value;
  final ValueChanged<SwingKind>? onChanged;
  final String calibrationFault;
  final ValueChanged<String>? onCalibrationFaultChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.science_outlined,
                  color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Text('This swing is',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<SwingKind>(
                  segments: const [
                    ButtonSegment(
                        value: SwingKind.natural, label: Text('Normal')),
                    ButtonSegment(
                        value: SwingKind.calibration,
                        label: Text('Exaggerated')),
                  ],
                  selected: {value},
                  showSelectedIcon: false,
                  onSelectionChanged: onChanged == null
                      ? null
                      : (selection) => onChanged!(selection.first),
                ),
              ),
            ],
          ),
          if (value == SwingKind.calibration) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const SizedBox(width: 26),
                const Text('Exaggerating',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: calibrationFault,
                      isExpanded: true,
                      dropdownColor: Colors.black87,
                      iconEnabledColor: Colors.white,
                      style: const TextStyle(color: Colors.white),
                      onChanged: onCalibrationFaultChanged == null
                          ? null
                          : (v) {
                              if (v != null) onCalibrationFaultChanged!(v);
                            },
                      items: [
                        for (final id in faultIds)
                          DropdownMenuItem<String>(
                            value: id,
                            child: Text(faultLabels[id] ?? id),
                          ),
                      ],
                    ),
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

/// Lets the golfer say which hand they swing with.
///
/// Not a preference: it selects the wrist the phase detector tracks, and every
/// fault measurement and the tempo ratio are sampled at the frame indices that
/// produces. Until this existed the app analyzed every golfer as right-handed.
class _HandednessSelector extends StatelessWidget {
  const _HandednessSelector({required this.value, required this.onChanged});

  final Handedness value;
  final ValueChanged<Handedness>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.sports_golf, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          const Text('I swing', style: TextStyle(color: Colors.white70)),
          const SizedBox(width: 12),
          Expanded(
            child: SegmentedButton<Handedness>(
              segments: const [
                ButtonSegment(
                  value: Handedness.right,
                  label: Text('Right-handed'),
                ),
                ButtonSegment(
                  value: Handedness.left,
                  label: Text('Left-handed'),
                ),
              ],
              selected: {value},
              showSelectedIcon: false,
              onSelectionChanged: onChanged == null
                  ? null
                  : (selection) => onChanged!(selection.first),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lets the golfer name the one fault they're working on this swing. Defaults
/// to "Full swing check" (null), which runs the report with no focus.
class _TargetSelector extends StatelessWidget {
  const _TargetSelector({required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.center_focus_strong, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          const Text('Working on', style: TextStyle(color: Colors.white70)),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: value,
                isExpanded: true,
                dropdownColor: Colors.black87,
                iconEnabledColor: Colors.white,
                style: const TextStyle(color: Colors.white),
                onChanged: onChanged,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Full swing check'),
                  ),
                  for (final id in faultIds)
                    DropdownMenuItem<String?>(
                      value: id,
                      child: Text(faultLabels[id] ?? id),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoCameraMessage extends StatelessWidget {
  const _NoCameraMessage();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Text(
          'No camera available on this device. A camera is required to record '
          'and analyze a swing.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
