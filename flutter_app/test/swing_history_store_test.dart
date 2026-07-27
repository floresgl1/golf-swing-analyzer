/// Tests for the corpus store: damage recovery, the capture-context fields, and
/// the round-trip that lets a stored swing be re-measured offline.
///
/// The behaviour under test is the fix for the bug that made a beta device stop
/// recording permanently: a corrupt history file used to make both `load()` and
/// `append()` throw, and the call site swallowed it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/faults.dart';
import 'package:golf_swing_analyzer/src/analysis/swing_history.dart';
import 'package:golf_swing_analyzer/src/analysis/swing_history_store.dart';
import 'package:golf_swing_analyzer/src/models/frame_features.dart';

SwingSession sampleSession({
  DateTime? timestamp,
  double? fps,
  int? frameCount,
  Handedness? handedness,
  double? poseCoverageFraction,
  FrameSeries? frames,
}) =>
    SwingSession(
      timestamp: timestamp ?? DateTime(2026, 7, 21, 18, 40),
      faults: {
        faultHeadSway: const FaultResult(
            value: 0.11, threshold: swayThreshold, flagged: false),
        faultReversePivot: const FaultResult(
            value: -0.05, threshold: reversePivotThreshold, flagged: false),
        faultEarlyExtension: const FaultResult(
            value: 0.04, threshold: earlyExtensionThreshold, flagged: false),
        faultLossOfPosture: const FaultResult(
            value: 5.0, threshold: postureThreshold, flagged: false),
      },
      tempoRatio: 2.9,
      fps: fps,
      frameCount: frameCount,
      handedness: handedness,
      poseCoverageFraction: poseCoverageFraction,
      frames: frames,
    );

Directory tempDir() {
  final dir = Directory.systemTemp.createTempSync('swing_store_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  group('corrupt-file recovery', () {
    test('a file of garbage is quarantined and recording resumes', () async {
      final dir = tempDir();
      final file = File('${dir.path}/swing_history.jsonl');
      file.writeAsStringSync('this is not json at all\nnor is this\n');

      final store = SwingHistoryStore(file);

      // Reading recovers instead of throwing.
      final loaded = await store.load();
      expect(loaded.sessions, isEmpty);
      expect(loaded.recoveredFromCorruption, isTrue);
      expect(File('${file.path}.corrupt.bak').existsSync(), isTrue);

      // ...and the next append succeeds, which is the whole point: the old
      // behaviour left the device unable to record another swing, ever.
      final result = await store.append(sampleSession());
      expect(result.isFirstSwing, isTrue);
      expect((await store.load()).sessions, hasLength(1));
    });

    test('one damaged line costs that record only, not the corpus', () async {
      final dir = tempDir();
      final file = File('${dir.path}/swing_history.jsonl');
      final store = SwingHistoryStore(file);

      await store.append(sampleSession(timestamp: DateTime(2026, 7, 1)));
      await store.append(sampleSession(timestamp: DateTime(2026, 7, 2)));

      // Simulate a partial write: a truncated trailing line, as a crash
      // mid-append would leave behind.
      file.writeAsStringSync('{"timestamp": "2026-07-03T00:00:00', mode: FileMode.append);

      final loaded = await store.load();
      expect(loaded.sessions, hasLength(2));
      expect(loaded.skippedLines, 1);
      expect(loaded.recoveredFromCorruption, isFalse);
      // The good records are still there and still readable.
      expect(loaded.sessions.first.timestamp, DateTime(2026, 7, 1));
    });

    test('append onto a corrupt file recovers rather than throwing', () async {
      final dir = tempDir();
      final file = File('${dir.path}/swing_history.jsonl');
      file.writeAsStringSync('{{{ not json\n');

      final store = SwingHistoryStore(file);
      final result = await store.append(sampleSession());

      expect(result.recoveredFromCorruption, isTrue);
      expect(result.isFirstSwing, isTrue);
      expect(result.comparison, isNull);
      expect((await store.load()).sessions, hasLength(1));
    });

    test('a missing file is empty history, not an error', () async {
      final dir = tempDir();
      final store = SwingHistoryStore(File('${dir.path}/nothing-here.jsonl'));
      final loaded = await store.load();
      expect(loaded.sessions, isEmpty);
      expect(loaded.recoveredFromCorruption, isFalse);
      expect(await store.lastSession(), isNull);
    });
  });

  group('append is line-oriented', () {
    test('each swing is one line and earlier lines are untouched', () async {
      final dir = tempDir();
      final file = File('${dir.path}/swing_history.jsonl');
      final store = SwingHistoryStore(file);

      await store.append(sampleSession(timestamp: DateTime(2026, 7, 1)));
      final afterFirst = file.readAsStringSync();
      await store.append(sampleSession(timestamp: DateTime(2026, 7, 2)));
      final afterSecond = file.readAsStringSync();

      expect(afterSecond.startsWith(afterFirst), isTrue,
          reason: 'appending must not rewrite existing records');
      expect(afterSecond.trim().split('\n'), hasLength(2));
      for (final line in afterSecond.trim().split('\n')) {
        expect(() => jsonDecode(line), returnsNormally);
      }
    });

    test('lastSession reads the newest record without parsing the rest',
        () async {
      final dir = tempDir();
      final file = File('${dir.path}/swing_history.jsonl');
      final store = SwingHistoryStore(file);

      await store.append(sampleSession(timestamp: DateTime(2026, 7, 1)));
      await store.append(sampleSession(timestamp: DateTime(2026, 7, 5)));

      expect((await store.lastSession())!.timestamp, DateTime(2026, 7, 5));
    });
  });

  group('capture context survives the round-trip', () {
    test('fps, frame count, handedness and pose coverage are persisted',
        () async {
      final dir = tempDir();
      final file = File('${dir.path}/swing_history.jsonl');
      final store = SwingHistoryStore(file);

      await store.append(sampleSession(
        fps: 29.97,
        frameCount: 180,
        handedness: Handedness.left,
        poseCoverageFraction: 0.85,
      ));

      final reloaded = (await store.load()).sessions.single;
      expect(reloaded.fps, closeTo(29.97, 1e-9));
      expect(reloaded.frameCount, 180);
      expect(reloaded.handedness, Handedness.left);
      expect(reloaded.poseCoverageFraction, closeTo(0.85, 1e-9));
    });

    test('a record with no handedness stays null, not right-handed', () async {
      // Every swing recorded before the field existed was analyzed as
      // right-handed whether or not the golfer was; reading those back as
      // "right" would launder that into apparent ground truth.
      final dir = tempDir();
      final file = File('${dir.path}/swing_history.jsonl');
      final store = SwingHistoryStore(file);

      await store.append(sampleSession());

      expect((await store.load()).sessions.single.handedness, isNull);
      expect(Handedness.tryParse(null), isNull);
      expect(Handedness.tryParse('sideways'), isNull);
      expect(Handedness.tryParse('left'), Handedness.left);
    });
  });

  group('frame series', () {
    test('round-trips through JSON and back into detector inputs', () async {
      final features = [
        const FrameFeatures(
          eyeX: 100.126,
          eyeY: 50.0,
          shoulderX: 101.0,
          shoulderY: 80.0,
          hipX: 102.0,
          hipY: 140.0,
          torso: 60.0,
          wristY: 200.0,
        ),
        const FrameFeatures.missing(),
      ];

      final series = FrameSeries.fromFeatures(features);
      expect(series.frameCount, 2);
      // NaN has no JSON representation; undetected frames store as null.
      expect(series.eyeX[1], isNull);
      expect(series.eyeX[0], closeTo(100.13, 1e-9)); // rounded to 2 dp

      final decoded = FrameSeries.fromJson(
          jsonDecode(jsonEncode(series.toJson())) as Map<String, dynamic>);
      final rebuilt = decoded.toFeatures();

      expect(rebuilt, hasLength(2));
      expect(rebuilt.first.eyeX, closeTo(100.13, 1e-9));
      expect(rebuilt.first.torso, 60.0);
      expect(rebuilt.last.eyeX.isNaN, isTrue,
          reason: 'null must come back as NaN so the detectors see a gap');
      expect(rebuilt.first.detected, isTrue);
      expect(rebuilt.last.detected, isFalse);
    });

    test('a stored swing survives encode/decode inside a record', () async {
      final dir = tempDir();
      final file = File('${dir.path}/swing_history.jsonl');
      final store = SwingHistoryStore(file);

      final features = [
        for (var i = 0; i < 5; i++)
          FrameFeatures(
            eyeX: 100.0 + i,
            eyeY: 50.0,
            shoulderX: 101.0,
            shoulderY: 80.0,
            hipX: 102.0,
            hipY: 140.0,
            torso: 60.0,
            wristY: 200.0 - i,
          ),
      ];
      await store.append(sampleSession(
        frameCount: features.length,
        frames: FrameSeries.fromFeatures(features),
      ));

      final frames = (await store.load()).sessions.single.frames;
      expect(frames, isNotNull);
      expect(frames!.frameCount, 5);
      expect(frames.toFeatures().last.wristY, 196.0);
    });

    test('pose coverage counts undetected frames', () {
      expect(poseCoverage(const []), isNull);
      expect(
        poseCoverage(const [
          FrameFeatures(
            eyeX: 1, eyeY: 1, shoulderX: 1, shoulderY: 1,
            hipX: 1, hipY: 1, torso: 1, wristY: 1,
          ),
          FrameFeatures.missing(),
          FrameFeatures.missing(),
          FrameFeatures.missing(),
        ]),
        closeTo(0.25, 1e-9),
      );
    });
  });

  group('HistoryFailureLog', () {
    test('counts failures and never throws', () async {
      final dir = tempDir();
      final log = HistoryFailureLog(File('${dir.path}/failures.jsonl'));

      expect(await log.count(), 0);
      await log.record(StateError('disk full'));
      await log.record(const FileSystemException('read-only'));
      expect(await log.count(), 2);

      final lines =
          File('${dir.path}/failures.jsonl').readAsStringSync().trim().split('\n');
      expect(jsonDecode(lines.first)['error'], contains('disk full'));
    });
  });
}
