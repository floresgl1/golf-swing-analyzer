/// Recording the swings the app refused to analyze.
///
/// **A rejected clip is the most valuable clip in the corpus, and the app used
/// to throw it away.** When analysis hard-failed, nothing was written: the
/// golfer saw "that didn't look like a golf swing" and the evidence went with
/// it. That biases the corpus to clips which passed the gate, which makes the
/// gate's own error rate unmeasurable from the data it produces — you can
/// count the swings it accepted, never the ones it turned down.
///
/// P1.1 is exactly that measurement. As of 2026-08-20 the corpus held ten
/// positives and **one** negative, and every threshold a gate could use would
/// have been fitted to that single clip. Meanwhile golfers were filming
/// negatives and the app was discarding them.
///
/// Written as its own file rather than mixed into `swing_history.jsonl`: these
/// records have no faults, no tempo and no phases, and a reader that assumed
/// those fields would break on them. Same JSON-Lines shape, same per-frame
/// series, so the scorer reads both with one parser.
library;

import 'dart:convert';
import 'dart:io';

import 'frame_series.dart';
import 'swing_history.dart' show formatIsoWithOffset;

/// One clip the app declined to report on.
class RejectedSwing {
  final DateTime timestamp;

  /// The detector's reason, not the golfer-facing sentence.
  final String reason;

  /// The retained recording this was measured from, so the rejection can be
  /// watched back and labelled like any other clip.
  final String? clipName;

  final double? fps;
  final int? frameCount;
  final double? poseCoverageFraction;

  /// The per-frame trajectories, in the same shape a normal record carries.
  /// Present even when no pose was found anywhere — an all-NaN series is the
  /// signature of an empty frame, and that is a fact worth keeping.
  final FrameSeries? frames;

  final String? participantId;
  final String? captureSessionId;
  final String? appVersion;

  const RejectedSwing({
    required this.timestamp,
    required this.reason,
    this.clipName,
    this.fps,
    this.frameCount,
    this.poseCoverageFraction,
    this.frames,
    this.participantId,
    this.captureSessionId,
    this.appVersion,
  });

  Map<String, dynamic> toJson() => {
        'record': 'rejected',
        'timestamp': formatIsoWithOffset(timestamp),
        'reason': reason,
        'clip_name': clipName,
        'fps': fps,
        'frame_count': frameCount,
        'pose_coverage': poseCoverageFraction,
        'participant_id': participantId,
        'capture_session_id': captureSessionId,
        'app_version': appVersion,
        'frames': frames?.toJson(),
      };
}

/// Appends rejected swings to a JSON-Lines file.
class RejectionLog {
  final File file;
  const RejectionLog(this.file);

  /// Append one rejection.
  ///
  /// Never allowed to break the golfer's flow: they have already been told the
  /// swing was not usable, and a logging failure on top of that helps nobody.
  Future<bool> record(RejectedSwing rejection) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(rejection.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
