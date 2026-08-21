import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/frame_series.dart';
import 'package:golf_swing_analyzer/src/models/frame_features.dart';
import 'package:golf_swing_analyzer/src/analysis/rejection_log.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late RejectionLog log;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rejection_log_test');
    log = RejectionLog(File(p.join(dir.path, 'swing_history_rejections.jsonl')));
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  RejectedSwing sample({String? clipName = 'swing_20260820_175600.mp4'}) =>
      RejectedSwing(
        timestamp: DateTime(2026, 8, 20, 17, 56, 0),
        reason: 'no phases were detected',
        clipName: clipName,
        fps: 29.97,
        frameCount: 372,
        poseCoverageFraction: 0.0,
        participantId: 'abc',
        captureSessionId: 'def',
        appVersion: '0.1.0+1',
      );

  Map<String, dynamic> onlyLine(File f) =>
      jsonDecode(f.readAsLinesSync().single) as Map<String, dynamic>;

  test('a rejection is written and marked as one', () async {
    expect(await log.record(sample()), isTrue);
    final row = onlyLine(log.file);
    expect(row['record'], 'rejected');
    expect(row['reason'], 'no phases were detected');
  });

  test('names the clip it came from', () async {
    // Without this the negative cannot be watched back or labelled, which is
    // most of what makes a rejected clip worth keeping.
    await log.record(sample());
    expect(onlyLine(log.file)['clip_name'], 'swing_20260820_175600.mp4');
  });

  test('keeps the measurements taken before the rejection', () async {
    await log.record(sample());
    final row = onlyLine(log.file);
    expect(row['fps'], 29.97);
    expect(row['frame_count'], 372);
    expect(row['pose_coverage'], 0.0);
  });

  test('carries the timestamp with its UTC offset', () async {
    await log.record(sample());
    expect(onlyLine(log.file)['timestamp'], matches(r'[+-]\d\d:\d\d$|Z$'));
  });

  test('a clip with no pose in any frame still records', () async {
    // The empty-range clip of 2026-08-20 found no pose anywhere. That is a
    // fact about the clip, not a reason to write nothing -- and it is the
    // exact shape of negative P1.1 needs most.
    //
    // Built through FrameSeries.fromFeatures, the way production does, because
    // that is where NaN becomes null. JSON has no NaN: a series holding raw
    // NaN cannot be encoded at all, and record() would drop it silently.
    final blank = FrameSeries.fromFeatures([
      for (var i = 0; i < 3; i++)
        const FrameFeatures(
          eyeX: double.nan,
          eyeY: double.nan,
          shoulderX: double.nan,
          shoulderY: double.nan,
          hipX: double.nan,
          hipY: double.nan,
          torso: double.nan,
          wristY: double.nan,
        ),
    ]);
    expect(await log.record(RejectedSwing(
      timestamp: DateTime(2026, 8, 20),
      reason: 'no phases were detected',
      frames: blank,
      frameCount: 3,
    )), isTrue);

    final row = onlyLine(log.file);
    expect(row['frame_count'], 3);
    // Every untracked frame lands as null, which is what makes it encodable.
    expect((row['frames'] as Map)['wrist_y'], [null, null, null]);
  });

  test('appends rather than overwrites', () async {
    await log.record(sample());
    await log.record(sample(clipName: 'swing_20260820_180000.mp4'));
    expect(log.file.readAsLinesSync().length, 2);
  });

  test('a missing clip name is recorded as null, not invented', () async {
    await log.record(sample(clipName: null));
    expect(onlyLine(log.file)['clip_name'], isNull);
  });

  test('a log that cannot be written reports false instead of throwing', () async {
    // The golfer has already been told the swing was unusable; a logging
    // failure on top of that must not surface as a crash. A plain file where
    // the directory should be makes the write genuinely impossible.
    final blocker = File(p.join(dir.path, 'blocked'))..writeAsStringSync('x');
    final bad = RejectionLog(File(p.join(blocker.path, 'x.jsonl')));
    expect(await bad.record(sample()), isFalse);
  });
}
