import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/faults.dart';
import 'package:golf_swing_analyzer/src/analysis/swing_history.dart';
import 'package:golf_swing_analyzer/src/analysis/swing_history_store.dart';

/// Build a session from plain per-fault (value, flagged) pairs, using the real
/// thresholds. Mirrors the synthetic sessions in the Python module's demo.
SwingSession session({
  required double headSway,
  required bool headSwayFlagged,
  required double reversePivot,
  required bool reversePivotFlagged,
  required double earlyExtension,
  required bool earlyExtensionFlagged,
  required double lossOfPosture,
  required bool lossOfPostureFlagged,
  double? tempoRatio,
  String? targeting,
  DateTime? timestamp,
}) {
  return SwingSession(
    timestamp: timestamp ?? DateTime(2026, 7, 21, 18, 40),
    faults: {
      faultHeadSway: FaultResult(
          value: headSway, threshold: swayThreshold, flagged: headSwayFlagged),
      faultReversePivot: FaultResult(
          value: reversePivot,
          threshold: reversePivotThreshold,
          flagged: reversePivotFlagged),
      faultEarlyExtension: FaultResult(
          value: earlyExtension,
          threshold: earlyExtensionThreshold,
          flagged: earlyExtensionFlagged),
      faultLossOfPosture: FaultResult(
          value: lossOfPosture,
          threshold: postureThreshold,
          flagged: lossOfPostureFlagged),
    },
    tempoRatio: tempoRatio,
    targeting: targeting,
  );
}

void main() {
  final previous = session(
    headSway: 0.18, headSwayFlagged: true,
    reversePivot: -0.05, reversePivotFlagged: false,
    earlyExtension: 0.04, earlyExtensionFlagged: false,
    lossOfPosture: 5.0, lossOfPostureFlagged: false,
    tempoRatio: 2.4,
    targeting: faultHeadSway,
    timestamp: DateTime(2026, 7, 14, 18, 2),
  );
  final current = session(
    headSway: 0.09, headSwayFlagged: false,
    reversePivot: -0.06, reversePivotFlagged: false,
    earlyExtension: 0.14, earlyExtensionFlagged: true,
    lossOfPosture: 5.2, lossOfPostureFlagged: false,
    tempoRatio: 2.9,
  );

  group('SwingComparison.between', () {
    final cmp = SwingComparison.between(previous, current);
    FaultComparison faultCmp(String id) =>
        cmp.faults.firstWhere((f) => f.faultId == id);

    test('lower value reads as improved; threshold drop reads as fixed', () {
      final head = faultCmp(faultHeadSway);
      expect(head.trend, Trend.improved);
      expect(head.crossing, Crossing.faultFixed);
      expect(head.valuesText, '0.18 -> 0.09 torso-lengths');
    });

    test('rising value reads as worsened; crossing up reads as new fault', () {
      final ext = faultCmp(faultEarlyExtension);
      expect(ext.trend, Trend.worsened);
      expect(ext.crossing, Crossing.faultNew);
    });

    test('changes under the per-fault epsilon read as unchanged', () {
      // Posture moved 0.2 deg, under its 0.5 deg epsilon.
      expect(faultCmp(faultLossOfPosture).trend, Trend.unchanged);
      expect(faultCmp(faultLossOfPosture).crossing, isNull);
      // Head-sway epsilon is 0.005, so -0.01 on reverse pivot still counts.
      expect(faultCmp(faultReversePivot).trend, Trend.improved);
    });

    test('collects new and fixed fault ids', () {
      expect(cmp.newFaults, [faultEarlyExtension]);
      expect(cmp.fixedFaults, [faultHeadSway]);
      expect(cmp.focusFault, faultHeadSway);
    });

    test('tempo is judged by distance from the 3:1 benchmark', () {
      expect(cmp.tempo!.trend, Trend.improved); // 2.4 -> 2.9, closer to 3.0
      expect(cmp.tempo!.valuesText, '2.4:1 -> 2.9:1');
    });

    test('a fault with a null value in either session is skipped', () {
      final missing = SwingSession(
        timestamp: DateTime(2026, 7, 15),
        faults: {
          faultHeadSway: const FaultResult(
              value: null, threshold: swayThreshold, flagged: false),
        },
      );
      final c = SwingComparison.between(missing, current);
      expect(c.faults.where((f) => f.faultId == faultHeadSway), isEmpty);
      expect(c.tempo, isNull); // missing session has no tempo either
    });
  });

  group('SwingSession JSON', () {
    test('round-trips through toJson/fromJson', () {
      final decoded = SwingSession.fromJson(
          jsonDecode(jsonEncode(previous.toJson())) as Map<String, dynamic>);
      expect(decoded.timestamp, previous.timestamp);
      expect(decoded.tempoRatio, previous.tempoRatio);
      expect(decoded.targeting, previous.targeting);
      expect(decoded.faults[faultHeadSway]!.value, 0.18);
      expect(decoded.faults[faultHeadSway]!.flagged, isTrue);
    });
  });

  group('buildSession', () {
    test('maps detector results and stores non-finite values as null', () {
      final s = buildSession(
        head: const HeadMovementResult(
            lateral: 0.11,
            vertical: 0.2,
            swayFlagged: false,
            dipFlagged: false,
            flagged: false),
        pivot: const ReversePivotResult(reverse: double.nan, flagged: false),
        extension: const EarlyExtensionResult(rise: -0.04, flagged: false),
        posture: const LossOfPostureResult(
            tiltAddress: 39, tiltImpact: 36, straighten: 3, flagged: false),
      );
      expect(s.faults[faultHeadSway]!.value, 0.11);
      expect(s.faults[faultHeadSway]!.threshold, swayThreshold);
      expect(s.faults[faultReversePivot]!.value, isNull);
      expect(s.faults[faultLossOfPosture]!.value, 3);
      expect(s.tempoRatio, isNull); // no tempo passed
    });
  });

  group('SwingHistoryStore', () {
    test('first append is flagged as such; the second carries the comparison',
        () async {
      final dir = Directory.systemTemp.createTempSync('swing_history_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = SwingHistoryStore(File('${dir.path}/swing_history.jsonl'));

      final first = await store.append(previous);
      expect(first.comparison, isNull);
      expect(first.isFirstSwing, isTrue);

      final second = await store.append(current);
      expect(second.isFirstSwing, isFalse);
      expect(second.comparison, isNotNull);
      expect(second.comparison!.fixedFaults, [faultHeadSway]);

      final loaded = await store.load();
      expect(loaded.sessions, hasLength(2));
      expect(loaded.skippedLines, 0);
      expect(loaded.recoveredFromCorruption, isFalse);
      expect(loaded.sessions.first.targeting, faultHeadSway);
      expect(loaded.sessions.last.faults[faultEarlyExtension]!.flagged, isTrue);
    });
  });

  group('preserves unknown keys (forward compatibility)', () {
    test('fromJson/toJson keeps keys the model does not know', () {
      final raw = {
        'timestamp': '2026-07-14T18:02:11-06:00',
        'faults': {
          faultHeadSway: {
            'value': 0.18,
            'threshold': swayThreshold,
            'flagged': true,
            'confidence': 0.9, // a fault-level field a future writer added
          },
        },
        'tempo_ratio': 2.4,
        'targeting': faultHeadSway,
        'coach_note': 'head still', // a session-level field we don't model
      };

      final out = SwingSession.fromJson(raw).toJson();

      // Unknown keys survive at both the session and the fault level.
      expect(out['coach_note'], 'head still');
      final head = (out['faults'] as Map)[faultHeadSway] as Map;
      expect(head['confidence'], 0.9);
      // ...while the modeled fields stay canonical.
      expect(out['targeting'], faultHeadSway);
      expect(head['value'], 0.18);
    });

    test('an unknown key survives a store load/append/reload cycle', () async {
      final dir = Directory.systemTemp.createTempSync('swing_history_unknown');
      addTearDown(() => dir.deleteSync(recursive: true));
      final legacy = File('${dir.path}/swing_history.json');
      final file = File('${dir.path}/swing_history.jsonl');

      // A history file as another writer (e.g. the Python pipeline) might leave
      // it, carrying fields this Dart model does not know about. In the new
      // line format this is also the legacy-migration path, so it exercises
      // both: unknown keys must survive the format change, not just a
      // re-serialize.
      legacy.writeAsStringSync(jsonEncode({
        'sessions': [
          {
            'timestamp': '2026-07-14T18:02:11-06:00',
            'faults': {
              faultHeadSway: {
                'value': 0.18,
                'threshold': swayThreshold,
                'flagged': true,
                'confidence': 0.9,
              },
              faultReversePivot: {
                'value': -0.05,
                'threshold': reversePivotThreshold,
                'flagged': false,
              },
              faultEarlyExtension: {
                'value': 0.04,
                'threshold': earlyExtensionThreshold,
                'flagged': false,
              },
              faultLossOfPosture: {
                'value': 5.0,
                'threshold': postureThreshold,
                'flagged': false,
              },
            },
            'tempo_ratio': 2.4,
            'targeting': faultHeadSway,
            'coach_note': 'keep your head still',
          },
        ],
      }));

      final store = SwingHistoryStore(file, legacyFile: legacy);
      // Migrates the legacy document into the line format, then appends -- both
      // paths run every stored session back through toJson.
      await store.append(current);

      // Inspect the persisted lines directly: the migrated session's unknown
      // keys must still be there.
      final lines = file.readAsStringSync().trim().split('\n');
      expect(lines, hasLength(2));
      final first = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(first['coach_note'], 'keep your head still');
      final head =
          (first['faults'] as Map<String, dynamic>)[faultHeadSway] as Map;
      expect(head['confidence'], 0.9);

      // ...and the store still parses everything, modeled fields intact.
      final loaded = await store.load();
      expect(loaded.sessions, hasLength(2));
      expect(loaded.sessions.first.targeting, faultHeadSway);
      expect(loaded.sessions.first.faults[faultHeadSway]!.value, 0.18);

      // The legacy file is renamed aside so migration cannot run twice.
      expect(legacy.existsSync(), isFalse);
      expect(File('${legacy.path}.migrated.bak').existsSync(), isTrue);
    });
  });
}
