/// Proves the Dart stance-bounded localization is a PORT, not a rewrite.
///
/// `src/swing_phases.py` is the source of truth. This runs the Dart
/// `detectPhases(..., torso:, hipX:)` over every device clip committed to the
/// corpus and requires the frame indices to match Python's **exactly** —
/// including the clip Python declines.
///
/// Exact, not approximate, and that is the point. Both sides interpolate the
/// same gaps, smooth with the same odd-width kernel, and take argmin/argmax
/// over the same slices; a one-frame drift means a helper diverged, and a
/// helper that has drifted by one frame today will drift by more tomorrow.
/// Expected values live in `tests/fixtures/stance_parity_expected.json`,
/// regenerated only when the Python side changes deliberately.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/frame_series.dart';
import 'package:golf_swing_analyzer/src/analysis/swing_phases.dart';

/// The repo root, from wherever `flutter test` was invoked.
Directory get _repoRoot {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (Directory('${dir.path}/tests/fixtures').existsSync()) return dir;
    dir = dir.parent;
  }
  throw StateError('could not find tests/fixtures from ${Directory.current}');
}

void main() {
  final root = _repoRoot;
  final expected = jsonDecode(
    File('${root.path}/tests/fixtures/stance_parity_expected.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final clips = (expected['clips'] as List).cast<Map<String, dynamic>>();

  // Every record, keyed by timestamp, across all the dated corpus files.
  final records = <String, Map<String, dynamic>>{};
  for (final file in Directory('${root.path}/tests/fixtures')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('device_corpus_'))) {
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final row = jsonDecode(line) as Map<String, dynamic>;
      if (row['record'] == 'header') continue;
      records[row['timestamp'] as String] = row;
    }
  }

  group('framesFor matches Python', () {
    // The corpus cannot test this on its own: every device clip is 29.97fps,
    // where 0.10s rounds to 3 frames -- already odd, so the odd-bump never
    // fires. Mutating the bump to round DOWN left the parity suite green.
    // These values come from `frames_for` in src/swing_phases.py, and 240fps
    // is not hypothetical: it is the rate the Dart windows were built for.
    for (final c in const [
      (0.10, 240.0, 24, 25),
      (0.10, 30.0, 3, 3),
      (0.10, 29.97, 3, 3),
      (1.0, 240.0, 240, 241),
      (1.0, 29.97, 30, 31),
      (1.5, 60.0, 90, 91),
    ]) {
      final (seconds, fps, plain, odd) = c;
      test('${seconds}s @ ${fps}fps -> $plain / $odd odd', () {
        expect(framesFor(seconds, fps), plain);
        expect(framesFor(seconds, fps, odd: true), odd);
      });
    }

    test('never returns zero, however short the duration', () {
      // A zero-width window silently disables the thing it windows.
      expect(framesFor(0.02, 30), 1);
      expect(framesFor(0.001, 240), 1);
      expect(framesFor(0.0, 240), 1);
    });

    test('the odd bump rounds UP, never down', () {
      // Bumping up never under-smooths; bumping down does.
      expect(framesFor(0.10, 240, odd: true), greaterThan(framesFor(0.10, 240)));
    });
  });

  test('the corpus and the expectations cover the same clips', () {
    // Guards the whole file: if a fixture is added without regenerating the
    // expectations, the parity tests below would silently skip it.
    expect(clips.length, records.length,
        reason: 'regenerate stance_parity_expected.json after adding clips');
  });

  group('what the app now does with a real clip', () {
    // The parity tests above prove the port matches Python. These prove the
    // behaviour a golfer actually meets, through the same gate the app uses.

    SwingPhases? phasesFor(String clipName) {
      final record = records.values.firstWhere(
        (r) => r['clip_name'] == clipName,
        orElse: () => throw StateError('no record for $clipName'),
      );
      final features =
          FrameSeries.fromJson(record['frames'] as Map<String, dynamic>)
              .toFeatures();
      return detectPhases(
        [for (final f in features) f.wristY],
        fps: (record['fps'] as num).toDouble(),
        torso: [for (final f in features) f.torso],
        hipX: [for (final f in features) f.hipX],
      );
    }

    test('a clip where the golfer never settled is REJECTED', () {
      // 2026-08-20 clip 5: walk in, stand about, walk out. No swing. The
      // shipped peak localization reported takeaway 0.0s / top 0.2s / impact
      // 9.8s and the app produced a full fault report with drills.
      final phases = phasesFor('swing_20260820_180317.mp4');
      expect(phases, isNull);
      expect(implausibleSwing(phases), 'no phases were detected');
    });

    test('a real swing is still accepted, and located in the swing', () {
      // Same session, same golfer, a real swing labelled at ~7s. The gate must
      // not have become stricter at the cost of rejecting genuine swings: on
      // all 14 labelled swings in the corpus this declines none.
      final phases = phasesFor('swing_20260820_185134.mp4');
      expect(phases, isNotNull);
      expect(implausibleSwing(phases), isNull);
      // 29.97fps: frames 190-247 is roughly 6.3-8.2s, inside the labelled swing.
      expect(phases!.top, inInclusiveRange(190, 260));
      expect(phases.takeaway, lessThan(phases.top));
      expect(phases.impact, greaterThan(phases.top));
    });

    test('the practice-swing clip is accepted, on the wrong swing', () {
      // Known limitation, recorded rather than hidden: clip 3 holds a practice
      // swing at ~8s and the real one at ~13s, both inside the stance, and the
      // localization takes the first. A practice swing is a real swing; no
      // signal processing separates them. See P1.4 in ROADMAP.md.
      final phases = phasesFor('swing_20260820_180238.mp4');
      expect(phases, isNotNull);
      expect(implausibleSwing(phases), isNull);
      expect(phases!.top / 29.97, closeTo(8.0, 0.5));
    });
  });

  for (final clip in clips) {
    final timestamp = clip['timestamp'] as String;
    final name = (clip['clip_name'] as String?) ?? timestamp;

    test('matches Python on $name', () {
      final record = records[timestamp];
      expect(record, isNotNull, reason: 'no corpus record for $timestamp');

      final frames =
          FrameSeries.fromJson(record!['frames'] as Map<String, dynamic>);
      final features = frames.toFeatures();
      final fps = (record['fps'] as num).toDouble();

      final actual = detectPhases(
        [for (final f in features) f.wristY],
        fps: fps,
        torso: [for (final f in features) f.torso],
        hipX: [for (final f in features) f.hipX],
      );

      final want = clip['phases'] as Map<String, dynamic>?;
      if (want == null) {
        // Python declined: no stance, so no swing to locate. The port must
        // decline too rather than falling back to peak localization.
        expect(actual, isNull,
            reason: '$name: Python found no stance; Dart must also decline');
        return;
      }

      expect(actual, isNotNull, reason: '$name: Python located a swing');
      expect(actual!.takeaway, want['takeaway'], reason: '$name takeaway');
      expect(actual.top, want['top'], reason: '$name top');
      expect(actual.impact, want['impact'], reason: '$name impact');
      expect(actual.finish, want['finish'], reason: '$name finish');
    });
  }
}
