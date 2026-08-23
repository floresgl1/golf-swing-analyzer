/// Who recorded a swing, and what they already know about their own swing.
///
/// Deliberately anonymous: a random local id, no account, no name, nothing that
/// identifies a person. Its only job is to let swings be grouped by golfer, which
/// the noise-floor work needs — within-subject variance is meaningless if two
/// people share a phone and their swings land in one undifferentiated stream.
///
/// Stored in its **own file**, not in the corpus, for two reasons. Identity must
/// survive corpus damage: if a quarantined history took the participant id with
/// it, the same golfer would reappear as a new subject and their repeated swings
/// would stop being repeated swings. And the coach self-report belongs to the
/// person, not to a swing — recording it per swing would invite it drifting
/// between records of the same golfer and would imply it was observed for that
/// swing, which it was not.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'faults.dart';
import 'handedness.dart';

/// Whether a coach has told this golfer they have a given fault.
///
/// A weak label, not ground truth: it is one human's opinion, usually about the
/// golfer's swing in general rather than the swing just recorded. Useful as a
/// prior when validating thresholds, dangerous if treated as a verdict — hence
/// the explicit [unsure], so "not asked" never reads as "no".
enum CoachConfirmation {
  yes,
  no,
  unsure;

  String get id => switch (this) {
        CoachConfirmation.yes => 'yes',
        CoachConfirmation.no => 'no',
        CoachConfirmation.unsure => 'unsure',
      };

  static CoachConfirmation? tryParse(Object? value) => switch (value) {
        'yes' => CoachConfirmation.yes,
        'no' => CoachConfirmation.no,
        'unsure' => CoachConfirmation.unsure,
        _ => null,
      };
}

/// The local, anonymous golfer record.
class Participant {
  /// Random local identifier. Not derived from any device or account property.
  final String id;

  /// When this participant record was created.
  final DateTime createdAt;

  /// The golfer's handedness, remembered across app launches so it does not
  /// have to be re-picked (and re-forgotten) every session.
  final Handedness? handedness;

  /// Per fault id: has a coach identified this fault in this golfer?
  final Map<String, CoachConfirmation> coachReports;

  /// Whether the first-run framing guide has been shown. Set to true after
  /// the golfer dismisses it so it only appears once.
  final bool onboardingShown;

  /// When true, the next swing is recorded as a calibration swing — a
  /// labelled positive control with one fault deliberately exaggerated.
  /// Lives on the participant rather than the record screen because the
  /// ROADMAP requires it off the viewfinder and behind a Profile toggle.
  final bool calibrationMode;

  /// The fault being deliberately exaggerated on a calibration swing. Only
  /// meaningful when [calibrationMode] is true. Defaults to head sway.
  final String? calibrationFault;

  /// Unknown keys from the stored file, preserved on write.
  final Map<String, dynamic> _source;

  const Participant({
    required this.id,
    required this.createdAt,
    this.handedness,
    this.coachReports = const {},
    this.onboardingShown = false,
    this.calibrationMode = false,
    this.calibrationFault,
    Map<String, dynamic> source = const <String, dynamic>{},
  }) : _source = source;

  Participant copyWith({
    Handedness? handedness,
    Map<String, CoachConfirmation>? coachReports,
    bool? onboardingShown,
    bool? calibrationMode,
    String? calibrationFault,
  }) =>
      Participant(
        id: id,
        createdAt: createdAt,
        handedness: handedness ?? this.handedness,
        coachReports: coachReports ?? this.coachReports,
        onboardingShown: onboardingShown ?? this.onboardingShown,
        calibrationMode: calibrationMode ?? this.calibrationMode,
        calibrationFault: calibrationFault ?? this.calibrationFault,
        source: _source,
      );

  factory Participant.fromJson(Map<String, dynamic> json) {
    final rawReports = json['coach_reports'];
    final reports = <String, CoachConfirmation>{};
    if (rawReports is Map<String, dynamic>) {
      for (final entry in rawReports.entries) {
        final parsed = CoachConfirmation.tryParse(entry.value);
        if (parsed != null) reports[entry.key] = parsed;
      }
    }
    return Participant(
      id: json['participant_id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      handedness: Handedness.tryParse(json['handedness']),
      coachReports: reports,
      onboardingShown: json['onboarding_shown'] == true,
      calibrationMode: json['calibration_mode'] == true,
      calibrationFault: json['calibration_fault'] as String?,
      source: json,
    );
  }

  Map<String, dynamic> toJson() => {
        ..._source,
        'participant_id': id,
        'created_at': createdAt.toIso8601String(),
        'handedness': handedness?.id,
        'coach_reports': {
          for (final entry in coachReports.entries) entry.key: entry.value.id,
        },
        'onboarding_shown': onboardingShown,
        'calibration_mode': calibrationMode,
        if (calibrationFault != null) 'calibration_fault': calibrationFault,
      };

  /// A fresh anonymous participant with a random id.
  factory Participant.generate({DateTime? createdAt}) => Participant(
        id: _randomHex(16),
        createdAt: createdAt ?? DateTime.now(),
      );

}

String _randomHex(int bytes) {
  final rng = Random.secure();
  return [
    for (var i = 0; i < bytes; i++)
      rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// One sitting: a single run of the app, from launch until it is closed.
///
/// Minted once at startup and stamped on every swing recorded during that run,
/// which is what makes *within-session* variance measurable from ordinary beta
/// use — five swings in one visit share an id; the same golfer next week does
/// not. Between-session variance is the difference between those groups.
///
/// Deliberately not persisted: a sitting ends when the app does.
class CaptureSession {
  CaptureSession._(this.id, this.startedAt);

  factory CaptureSession.start({DateTime? startedAt}) =>
      CaptureSession._(_randomHex(8), startedAt ?? DateTime.now());

  final String id;
  final DateTime startedAt;
}

/// Reads and writes the participant record, atomically.
///
/// Never throws on read: a damaged participant file yields a *new* participant
/// rather than blocking recording. That does cost the link to earlier swings, so
/// the damaged file is kept as `.corrupt.bak` and the earlier records still
/// carry the old id — the grouping is recoverable by hand, which is better than
/// a device that refuses to record.
class ParticipantStore {
  ParticipantStore(this.file);

  final File file;

  Participant? _cached;

  /// Load the stored participant, creating and persisting one on first run.
  Future<Participant> loadOrCreate() async {
    final cached = _cached;
    if (cached != null) return cached;

    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic> &&
            decoded['participant_id'] is String) {
          return _cached = Participant.fromJson(decoded);
        }
      } catch (_) {
        // fall through to regeneration
      }
      try {
        await file.rename('${file.path}.corrupt.bak');
      } catch (_) {
        // best effort
      }
    }

    final created = Participant.generate();
    await save(created);
    return created;
  }

  /// Persist [participant] via a temp file and rename, so an interrupted write
  /// cannot leave an unreadable identity behind.
  Future<void> save(Participant participant) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(participant.toJson())}\n',
      flush: true,
    );
    await tmp.rename(file.path);
    _cached = participant;
  }

  /// Record whether a coach has identified [faultId] in this golfer.
  Future<Participant> setCoachReport(
    String faultId,
    CoachConfirmation confirmation,
  ) async {
    final current = await loadOrCreate();
    final updated = current.copyWith(
      coachReports: {...current.coachReports, faultId: confirmation},
    );
    await save(updated);
    return updated;
  }

  /// Remember the golfer's handedness across launches.
  Future<Participant> setHandedness(Handedness handedness) async {
    final current = await loadOrCreate();
    final updated = current.copyWith(handedness: handedness);
    await save(updated);
    return updated;
  }

  /// Mark the first-run onboarding as shown.
  Future<Participant> setOnboardingShown() async {
    final current = await loadOrCreate();
    final updated = current.copyWith(onboardingShown: true);
    await save(updated);
    return updated;
  }

  /// Toggle calibration mode on or off, optionally setting the fault.
  Future<Participant> setCalibration({
    required bool enabled,
    String? fault,
  }) async {
    final current = await loadOrCreate();
    final updated = current.copyWith(
      calibrationMode: enabled,
      calibrationFault: fault ?? current.calibrationFault,
    );
    await save(updated);
    return updated;
  }
}

/// Fault ids a coach report can be recorded against — the same four the
/// detectors cover, in report order.
const List<String> coachReportFaultIds = [
  faultHeadSway,
  faultReversePivot,
  faultEarlyExtension,
  faultLossOfPosture,
];
