import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../analysis/swing_history.dart';
import '../models/drill.dart';
import 'analyzing_screen.dart';

/// First screen: preview the camera and record a swing. When recording stops,
/// hands the video file off to the analysis screen ("record then analyze").
class RecordScreen extends StatefulWidget {
  const RecordScreen({
    super.key,
    required this.drills,
    required this.cameras,
  });

  final List<Drill> drills;
  final List<CameraDescription> cameras;

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

  @override
  void initState() {
    super.initState();
    if (widget.cameras.isNotEmpty) {
      _setupCamera(widget.cameras.first);
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
            targeting: _targeting,
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
      appBar: AppBar(title: const Text('Record your swing')),
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
  });

  final CameraController controller;
  final String? targeting;

  /// Called when the golfer picks a focus fault; null disables the picker (e.g.
  /// while recording).
  final ValueChanged<String?>? onTargetingChanged;

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
