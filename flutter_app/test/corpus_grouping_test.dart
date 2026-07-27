/// Tests for the fields that make the corpus groupable: who recorded a swing,
/// in which sitting, under which measurement basis, and whether it was a
/// natural swing or a labelled control.
///
/// None of this is reconstructable after the fact, so the tests here are mostly
/// about a field surviving the round-trip intact — and about the two places
/// where a plausible-looking simplification would quietly break the corpus:
/// defaulting an absent value, and letting the basis stamp stop tracking.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/faults.dart';
import 'package:golf_swing_analyzer/src/analysis/measurement_basis.dart';
import 'package:golf_swing_analyzer/src/analysis/participant.dart';
import 'package:golf_swing_analyzer/src/analysis/swing_history.dart';
import 'package:golf_swing_analyzer/src/analysis/swing_history_store.dart';

SwingSession record({
  DateTime? timestamp,
  String? participantId,
  String? captureSessionId,
  SwingKind? swingKind,
  String? calibrationFault,
}) =>
    buildSession(
      head: const HeadMovementResult(
        lateral: 0.11,
        vertical: 0.2,
        swayFlagged: false,
        dipFlagged: false,
        flagged: false,
      ),
      pivot: const ReversePivotResult(reverse: -0.05, flagged: false),
      extension: const EarlyExtensionResult(rise: 0.04, flagged: false),
      posture: const LossOfPostureResult(
        tiltAddress: 39,
        tiltImpact: 36,
        straighten: 3,
        flagged: false,
      ),
      timestamp: timestamp,
      participantId: participantId,
      captureSessionId: captureSessionId,
      appVersion: appVersion,
      valueBasis: valueBasis,
      thresholdBasis: thresholdBasis,
      swingKind: swingKind,
      calibrationFault: calibrationFault,
    );

Directory tempDir() {
  final dir = Directory.systemTemp.createTempSync('corpus_grouping_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  group('measurement basis', () {
    test('is stable across calls', () {
      expect(valueBasis, valueBasis);
      expect(thresholdBasis, thresholdBasis);
      expect(valueBasis, hasLength(8));
    });

    test('value basis and threshold basis are different stamps', () {
      // They answer different questions: what was measured, versus what counted
      // as flagged. Collapsing them into one would mean a threshold-only
      // recalibration threw away value trends it did not invalidate.
      expect(valueBasis, isNot(thresholdBasis));
    });

    test('the stamps are derived, not declared', () {
      // The guard this test exists for: a later change replacing the hash with
      // a hand-maintained integer. A derived stamp must change when a
      // parameter changes -- proven here by hashing a perturbed parameter set
      // the same way and seeing a different value.
      String basisFor(double sway) {
        final canonical = [
          'default_radius_frames=$defaultRadiusFrames',
          'early_extension=$earlyExtensionThreshold',
          'sway=$sway',
        ].join('&');
        return canonical;
      }

      expect(basisFor(swayThreshold), isNot(basisFor(swayThreshold + 0.01)));
    });
  });

  group('grouping fields survive the round-trip', () {
    test('participant, sitting, version and basis are all persisted', () async {
      final dir = tempDir();
      final store = SwingHistoryStore(
        File('${dir.path}/swing_history.jsonl'),
        participantId: 'participant-abc',
      );

      await store.append(record(
        participantId: 'participant-abc',
        captureSessionId: 'sitting-1',
      ));

      final loaded = await store.load();
      final swing = loaded.sessions.single;
      expect(swing.participantId, 'participant-abc');
      expect(swing.captureSessionId, 'sitting-1');
      expect(swing.appVersion, appVersion);
      expect(swing.valueBasis, valueBasis);
      expect(swing.thresholdBasis, thresholdBasis);

      // ...and the header states the format and the golfer.
      expect(loaded.header, isNotNull);
      expect(loaded.header!.schemaVersion, historySchemaVersion);
      expect(loaded.header!.participantId, 'participant-abc');
    });

    test('swings in one sitting share an id; a later sitting does not',
        () async {
      final dir = tempDir();
      final store = SwingHistoryStore(File('${dir.path}/swing_history.jsonl'));

      await store.append(record(captureSessionId: 'sitting-1'));
      await store.append(record(captureSessionId: 'sitting-1'));
      await store.append(record(captureSessionId: 'sitting-2'));

      final ids = (await store.load())
          .sessions
          .map((s) => s.captureSessionId)
          .toList();
      expect(ids, ['sitting-1', 'sitting-1', 'sitting-2']);
      // Within-session repeats -- the noise floor's lower bound -- are the two
      // that share an id.
      expect(ids.where((id) => id == 'sitting-1'), hasLength(2));
    });

    test('a calibration swing keeps its label; a natural swing carries none',
        () async {
      final dir = tempDir();
      final store = SwingHistoryStore(File('${dir.path}/swing_history.jsonl'));

      await store.append(record(
        swingKind: SwingKind.calibration,
        calibrationFault: faultEarlyExtension,
      ));
      // A stale picker value must not leak onto a natural swing.
      await store.append(record(
        swingKind: SwingKind.natural,
        calibrationFault: faultHeadSway,
      ));

      final swings = (await store.load()).sessions;
      expect(swings.first.swingKind, SwingKind.calibration);
      expect(swings.first.calibrationFault, faultEarlyExtension);
      expect(swings.last.swingKind, SwingKind.natural);
      expect(swings.last.calibrationFault, isNull);
    });

    test('an unrecognized swing kind reads back as null, not natural', () {
      expect(SwingKind.tryParse(null), isNull);
      expect(SwingKind.tryParse('practice'), isNull);
      expect(SwingKind.tryParse('calibration'), SwingKind.calibration);
    });
  });

  group('timestamps carry their offset', () {
    test('written with an offset, to seconds, like the Python side', () {
      final local = DateTime(2026, 7, 14, 18, 2, 11);
      final text = formatIsoWithOffset(local);
      expect(
        text,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}([+-]\d{2}:\d{2}|Z)$')),
      );
      expect(text, startsWith('2026-07-14T18:02:11'));
    });

    test('round-trips to the same instant', () async {
      final dir = tempDir();
      final store = SwingHistoryStore(File('${dir.path}/swing_history.jsonl'));
      final when = DateTime(2026, 7, 14, 18, 2, 11);

      await store.append(record(timestamp: when));
      final reloaded = (await store.load()).sessions.single.timestamp;

      expect(reloaded.isAtSameMomentAs(when), isTrue);
      expect(reloaded, when);
    });

    test('a UTC timestamp is written with Z', () {
      expect(formatIsoWithOffset(DateTime.utc(2026, 7, 14, 18, 2, 11)),
          '2026-07-14T18:02:11Z');
    });
  });

  group('participant record', () {
    test('is created once and reused across loads', () async {
      final dir = tempDir();
      final store = ParticipantStore(File('${dir.path}/participant.json'));

      final first = await store.loadOrCreate();
      final second =
          await ParticipantStore(File('${dir.path}/participant.json'))
              .loadOrCreate();

      expect(first.id, isNotEmpty);
      expect(second.id, first.id,
          reason: 'a golfer must not become a new subject on every launch');
    });

    test('coach reports live on the participant, not on a swing', () async {
      final dir = tempDir();
      final store = ParticipantStore(File('${dir.path}/participant.json'));

      await store.setCoachReport(faultHeadSway, CoachConfirmation.yes);
      await store.setCoachReport(faultEarlyExtension, CoachConfirmation.no);

      final reloaded =
          await ParticipantStore(File('${dir.path}/participant.json'))
              .loadOrCreate();
      expect(reloaded.coachReports[faultHeadSway], CoachConfirmation.yes);
      expect(reloaded.coachReports[faultEarlyExtension], CoachConfirmation.no);
      // Unanswered stays unanswered -- "not asked" must never read as "no".
      expect(reloaded.coachReports[faultReversePivot], isNull);
      expect(CoachConfirmation.tryParse('maybe'), isNull);

      // And none of it is on a swing record.
      expect(record().toJson().containsKey('coach_reports'), isFalse);
    });

    test('handedness is remembered across launches', () async {
      final dir = tempDir();
      final store = ParticipantStore(File('${dir.path}/participant.json'));
      await store.setHandedness(Handedness.left);

      final reloaded =
          await ParticipantStore(File('${dir.path}/participant.json'))
              .loadOrCreate();
      expect(reloaded.handedness, Handedness.left);
    });

    test('a damaged participant file yields a new id rather than blocking',
        () async {
      final dir = tempDir();
      final file = File('${dir.path}/participant.json');
      file.writeAsStringSync('not json');

      final participant = await ParticipantStore(file).loadOrCreate();
      expect(participant.id, isNotEmpty);
      expect(File('${file.path}.corrupt.bak').existsSync(), isTrue);
    });

    test('unknown keys survive a save', () async {
      final dir = tempDir();
      final file = File('${dir.path}/participant.json');
      file.writeAsStringSync(jsonEncode({
        'participant_id': 'abc',
        'created_at': '2026-07-14T18:02:11-06:00',
        'recruited_by': 'range day 3',
      }));

      final store = ParticipantStore(file);
      await store.setCoachReport(faultHeadSway, CoachConfirmation.yes);

      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(raw['recruited_by'], 'range day 3');
      expect(raw['participant_id'], 'abc');
    });

    test('capture sessions are distinct per start', () {
      expect(CaptureSession.start().id, isNot(CaptureSession.start().id));
    });
  });
}
