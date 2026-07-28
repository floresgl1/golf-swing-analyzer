/// Extracts individual frames from a recorded video so each can be fed to the
/// still-image pose detector. This replaces OpenCV's `VideoCapture` frame loop
/// from the Python code.
///
/// Uses ffmpeg (via `ffmpeg_kit_flutter_new`) to dump every frame to a temp
/// directory as JPEGs, and ffprobe to read the true frame rate needed for
/// tempo. The list of frame paths is returned in capture order.
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ExtractedFrames {
  final List<String> framePaths; // ordered by capture time
  final double fps;
  final Directory workingDir; // caller deletes when done

  const ExtractedFrames({
    required this.framePaths,
    required this.fps,
    required this.workingDir,
  });
}

class FrameExtractor {
  /// Fallback frame rate if ffprobe can't report one.
  static const double _defaultFps = 30.0;

  /// Extract all frames of [videoPath] as JPEGs and report the video's fps.
  Future<ExtractedFrames> extract(String videoPath) async {
    final tempRoot = await getTemporaryDirectory();
    final workingDir = await Directory(
      p.join(tempRoot.path, 'frames_${DateTime.now().millisecondsSinceEpoch}'),
    ).create(recursive: true);

    final fps = await _probeFps(videoPath);

    // -vsync 0 keeps every source frame; %05d zero-pads so lexical sort ==
    // temporal order. -qscale:v 2 keeps the JPEGs high quality for detection.
    final pattern = p.join(workingDir.path, 'frame_%05d.jpg');
    final session = await FFmpegKit.execute(
      '-i "$videoPath" -vsync 0 -qscale:v 2 "$pattern"',
    );
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      throw StateError('Frame extraction failed: $logs');
    }

    final framePaths = workingDir
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((path) => path.endsWith('.jpg'))
        .toList()
      ..sort();

    return ExtractedFrames(
      framePaths: framePaths,
      fps: fps,
      workingDir: workingDir,
    );
  }

  Future<double> _probeFps(String videoPath) async {
    try {
      final info = await FFprobeKit.getMediaInformation(videoPath);
      final streams = info.getMediaInformation()?.getStreams() ?? const [];
      for (final stream in streams) {
        final rate = stream.getRealFrameRate() ?? stream.getAverageFrameRate();
        final parsed = _parseRational(rate);
        if (parsed != null && parsed > 0) return parsed;
      }
    } catch (_) {
      // Fall through to the default on any probe error.
    }
    return _defaultFps;
  }

  /// Parse ffprobe's "num/den" frame-rate strings (e.g. "30000/1001").
  double? _parseRational(String? value) {
    if (value == null || value.isEmpty) return null;
    if (value.contains('/')) {
      final parts = value.split('/');
      final num = double.tryParse(parts[0]);
      final den = double.tryParse(parts[1]);
      if (num == null || den == null || den == 0) return null;
      return num / den;
    }
    return double.tryParse(value);
  }
}
