/// Swing session records and swing-over-swing comparison, ported from
/// `src/swing_history.py` (the verification loop).
///
/// After each analysis the app appends a [SwingSession] to the on-device
/// corpus, then compares it against the previous session: per fault, previous
/// value -> current value, whether it improved/worsened/stayed put, and
/// whether it crossed the fault threshold in either direction. Persistence
/// itself lives in `swing_history_store.dart`.
///
/// The trend and threshold-crossing parts of that comparison are computed here
/// but **not rendered** — see the guardrail note on [SwingComparison.between].
///
/// Pure Dart (no Flutter imports) so the logic stays unit-testable; the
/// report-screen UI lives in `ui/widgets/swing_comparison_view.dart`.
///
/// **Storage shape diverges from Python.** The Python side writes a single
/// `{'sessions': [...]}` document; this side writes one JSON object per line
/// (see `swing_history_store.dart` for why) and records several fields the
/// Python entry has no counterpart for — capture rate, pose coverage, the
/// per-frame arrays, handedness. Histories are therefore **not** interchangeable
/// between the two implementations today; the per-record field names are kept
/// snake_case and aligned where they do overlap so a converter stays trivial.
///
/// All four fault metrics measure excess motion, so for every fault a LOWER
/// value is better. Tempo is judged by distance from the ~3:1 tour benchmark.
library;

import 'drill_recommender.dart';
import 'faults.dart';
import 'frame_series.dart';
import 'handedness.dart';
import 'swing_phases.dart';

export 'drill_recommender.dart' show faultLabels;
export 'frame_series.dart' show FrameSeries, poseCoverage;
export 'handedness.dart' show Handedness;

/// Why a swing was recorded.
///
/// Calibration swings are positive controls: a tester deliberately exaggerating
/// one fault so the corpus contains known-label examples. They must be
/// distinguishable from natural swings, because mixing them in would make the
/// false-positive rate look far better than it is — the detector is supposed to
/// flag them.
enum SwingKind {
  /// A swing the golfer was trying to hit normally.
  natural,

  /// A swing with one fault deliberately exaggerated, recorded as a labelled
  /// positive control. See [SwingSession.calibrationFault].
  calibration;

  String get id => switch (this) {
        SwingKind.natural => 'natural',
        SwingKind.calibration => 'calibration',
      };

  static SwingKind? tryParse(Object? value) => switch (value) {
        'natural' => SwingKind.natural,
        'calibration' => SwingKind.calibration,
        _ => null,
      };
}

/// Format [t] as ISO-8601 **carrying its UTC offset**, to seconds precision —
/// matching Python's `datetime.now().astimezone().isoformat(timespec='seconds')`
/// in `src/swing_history.py`.
///
/// `DateTime.toIso8601String()` emits no offset for a local DateTime, so every
/// record written before this was ambiguous about the instant it described.
/// That matters here: grouping swings into sittings by time gap, and comparing
/// a capture session against a later one, both assume timestamps are
/// comparable across devices and travel. They were not.
String formatIsoWithOffset(DateTime t) {
  if (t.isUtc) {
    final u = t;
    return '${_datePart(u)}T${_timePart(u)}Z';
  }
  final offset = t.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hours = _two(offset.inHours.abs());
  final minutes = _two(offset.inMinutes.abs().remainder(60));
  return '${_datePart(t)}T${_timePart(t)}$sign$hours:$minutes';
}

String _two(int n) => n.toString().padLeft(2, '0');
String _datePart(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}';
String _timePart(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// Fault ids in report order.
const List<String> faultIds = [
  faultHeadSway,
  faultReversePivot,
  faultEarlyExtension,
  faultLossOfPosture,
];

/// Changes smaller than this count as "unchanged" -- below what the report's
/// own rounding can show, so calling them progress would be noise.
const Map<String, double> _faultEpsilons = {
  faultHeadSway: 0.005,
  faultReversePivot: 0.005,
  faultEarlyExtension: 0.005,
  faultLossOfPosture: 0.5,
};

/// Display decimals per fault (posture is in whole degrees).
const Map<String, int> _faultDecimals = {
  faultHeadSway: 2,
  faultReversePivot: 2,
  faultEarlyExtension: 2,
  faultLossOfPosture: 0,
};

/// Unit shown next to each fault's values in the report.
const Map<String, String> faultUnits = {
  faultHeadSway: 'torso-lengths',
  faultReversePivot: 'torso-lengths',
  faultEarlyExtension: 'torso-lengths',
  faultLossOfPosture: 'deg',
};

/// Backswing:downswing ratio of the average tour player.
const double tempoIdeal = 3.0;
const double _tempoEpsilon = 0.05;

/// Format a fault value the way the Python report does (signed for the
/// direction-carrying metrics, plain for head sway).
String formatFaultValue(String faultId, double value) {
  final text = value.toStringAsFixed(_faultDecimals[faultId] ?? 2);
  final signed = faultId != faultHeadSway;
  return (signed && value >= 0) ? '+$text' : text;
}

/// One fault's measurement in one session.
class FaultResult {
  /// Measured value, or null when the metric could not be computed.
  final double? value;
  final double threshold;
  final bool flagged;

  /// The raw map this was parsed from, kept so keys the model doesn't know
  /// (e.g. a field a future writer adds) survive a load/save round-trip. Empty
  /// for instances built in code rather than read from JSON.
  final Map<String, dynamic> _source;

  const FaultResult({
    required this.value,
    required this.threshold,
    required this.flagged,
    Map<String, dynamic> source = const <String, dynamic>{},
  }) : _source = source;

  factory FaultResult.fromJson(Map<String, dynamic> json) => FaultResult(
        value: (json['value'] as num?)?.toDouble(),
        threshold: (json['threshold'] as num).toDouble(),
        flagged: json['flagged'] as bool,
        source: json,
      );

  /// The raw source with the typed fields merged over it, so unknown keys are
  /// preserved while the modeled fields stay canonical.
  Map<String, dynamic> toJson() => {
        ..._source,
        'value': value,
        'threshold': threshold,
        'flagged': flagged,
      };
}

/// One analyzed swing: every fault measurement plus tempo, with an optional
/// note of which fault the golfer was targeting that session.
///
/// Beyond the measurements, a record carries the *capture context* needed to
/// interpret them later. None of it can be reconstructed after the fact — the
/// extracted frames are deleted as soon as analysis finishes — so a field not
/// written at record time is gone for that swing permanently:
///
/// * [fps] / [frameCount] — without the capture rate, tempo is uninterpretable
///   and there is no way to know what duration the frame-count median windows
///   actually covered.
/// * [handedness] — which wrist phase detection tracked. Recorded even though
///   the app can now ask, so that a lefty analyzed on the trail wrist stays
///   identifiable rather than silently poisoning the corpus.
/// * [poseCoverageFraction] — how much of the swing had a detected pose.
/// * [frames] — the arrays the measurements were computed from, so the swing
///   can be re-measured at a different threshold or window basis.
class SwingSession {
  final DateTime timestamp;
  final Map<String, FaultResult> faults;
  final double? tempoRatio;
  final String? targeting;

  /// Capture rate reported by the video container, or null when not recorded.
  ///
  /// Note this is the *container* rate. Per `swing_phases.py`, a
  /// slow-motion clip reports its render rate here, not the rate it was
  /// captured at; the two are only equal for real-time capture. Stored as-is
  /// and labelled honestly rather than guessed at.
  final double? fps;

  /// Number of frames analyzed, or null when not recorded.
  final int? frameCount;

  /// Which wrist the phase detector tracked. Null on records written before the
  /// field existed — which is **not** the same as [Handedness.right], because
  /// those swings were analyzed as right-handed regardless of the golfer.
  final Handedness? handedness;

  /// Fraction of frames (0..1) in which a pose was detected, or null when not
  /// recorded.
  final double? poseCoverageFraction;

  /// The per-frame trajectory arrays the measurements were computed from, or
  /// null when not recorded.
  final FrameSeries? frames;

  /// Anonymous local golfer id. Stamped on the record as well as held in the
  /// participant file so an exported record stays self-describing once it has
  /// been merged with other devices' exports.
  final String? participantId;

  /// Groups swings taken in one sitting. Minted per app session; this is what
  /// turns ordinary beta use into the within-session repeats the noise floor
  /// needs.
  final String? captureSessionId;

  /// App build that produced this record.
  final String? appVersion;

  /// Hash of the parameters that determine the measured *value*. Records with
  /// different value bases measured different quantities.
  final String? valueBasis;

  /// Hash of the parameters that determine whether a value is *flagged*.
  final String? thresholdBasis;

  /// Whether this was a natural swing or a labelled calibration swing.
  final SwingKind? swingKind;

  /// File name of the retained recording in `<Documents>/clips`, or null when
  /// no clip was kept — every record written before 2026-08-19, and any swing
  /// whose recording could not be retained.
  ///
  /// This is the join between a measurement and the video it was measured
  /// from, and it exists because that join was missing: the five recordings of
  /// 2026-08-17 left per-frame series behind but no watchable clip, so nobody
  /// could say where the swing in them actually was. Written onto the record
  /// rather than derived from [timestamp] so the two are never required to
  /// agree — a derived join breaks silently the first time either side rounds
  /// differently. See P1.4 in ROADMAP.md.
  final String? clipName;

  /// For a [SwingKind.calibration] swing, the fault id the golfer was
  /// deliberately exaggerating. Null otherwise.
  final String? calibrationFault;

  /// The raw map this was parsed from, kept so top-level keys the model doesn't
  /// know (e.g. a field a future writer adds) survive a load/save round-trip.
  /// Empty for instances built in code rather than read from JSON.
  final Map<String, dynamic> _source;

  const SwingSession({
    required this.timestamp,
    required this.faults,
    this.tempoRatio,
    this.targeting,
    this.fps,
    this.frameCount,
    this.handedness,
    this.poseCoverageFraction,
    this.frames,
    this.participantId,
    this.captureSessionId,
    this.appVersion,
    this.valueBasis,
    this.thresholdBasis,
    this.swingKind,
    this.calibrationFault,
    this.clipName,
    Map<String, dynamic> source = const <String, dynamic>{},
  }) : _source = source;

  factory SwingSession.fromJson(Map<String, dynamic> json) {
    final rawFrames = json['frames'];
    return SwingSession(
      // toLocal() because an offset-carrying string parses to UTC; keeping the
      // model in local time makes round-trips compare equal.
      timestamp: DateTime.parse(json['timestamp'] as String).toLocal(),
      faults: (json['faults'] as Map<String, dynamic>).map(
        (id, result) =>
            MapEntry(id, FaultResult.fromJson(result as Map<String, dynamic>)),
      ),
      tempoRatio: (json['tempo_ratio'] as num?)?.toDouble(),
      targeting: json['targeting'] as String?,
      fps: (json['fps'] as num?)?.toDouble(),
      frameCount: (json['frame_count'] as num?)?.toInt(),
      handedness: Handedness.tryParse(json['handedness']),
      poseCoverageFraction: (json['pose_coverage'] as num?)?.toDouble(),
      frames: rawFrames is Map<String, dynamic>
          ? FrameSeries.fromJson(rawFrames)
          : null,
      participantId: json['participant_id'] as String?,
      captureSessionId: json['capture_session_id'] as String?,
      appVersion: json['app_version'] as String?,
      valueBasis: json['value_basis'] as String?,
      thresholdBasis: json['threshold_basis'] as String?,
      swingKind: SwingKind.tryParse(json['swing_kind']),
      calibrationFault: json['calibration_fault'] as String?,
      clipName: json['clip_name'] as String?,
      source: json,
    );
  }

  /// The raw source with the typed fields merged over it -- faults are
  /// re-emitted so each fault's own unknown keys are preserved too -- so
  /// nothing a reader didn't model is dropped on write.
  Map<String, dynamic> toJson() => {
        ..._source,
        'timestamp': formatIsoWithOffset(timestamp),
        'faults': faults.map((id, result) => MapEntry(id, result.toJson())),
        'tempo_ratio': tempoRatio,
        'targeting': targeting,
        'fps': fps,
        'frame_count': frameCount,
        'handedness': handedness?.id,
        'pose_coverage': poseCoverageFraction,
        'participant_id': participantId,
        'capture_session_id': captureSessionId,
        'app_version': appVersion,
        'value_basis': valueBasis,
        'threshold_basis': thresholdBasis,
        'swing_kind': swingKind?.id,
        'calibration_fault': calibrationFault,
        'clip_name': clipName,
        // Last: the bulky arrays sort to the end of the line, so a record stays
        // readable when eyeballing the file.
        'frames': frames?.toJson(),
      };
}

/// Build a history entry from one run of the fault detectors, the counterpart
/// of `build_session` in `src/swing_history.py`. Non-finite
/// measurements are stored as null.
///
/// The capture-context arguments ([fps], [frameCount], [handedness],
/// [poseCoverageFraction], [frames]) are optional so unit tests can build a
/// bare measurement record, but the app passes all of them: see the note on
/// [SwingSession] for why each one is unreconstructable after the fact.
SwingSession buildSession({
  required HeadMovementResult head,
  required ReversePivotResult pivot,
  required EarlyExtensionResult extension,
  required LossOfPostureResult posture,
  SwingTempo? tempo,
  String? targeting,
  DateTime? timestamp,
  double? fps,
  int? frameCount,
  Handedness? handedness,
  double? poseCoverageFraction,
  FrameSeries? frames,
  String? participantId,
  String? captureSessionId,
  String? appVersion,
  String? valueBasis,
  String? thresholdBasis,
  SwingKind? swingKind,
  String? calibrationFault,
  String? clipName,
}) {
  double? finiteOrNull(double v) => v.isFinite ? v : null;
  return SwingSession(
    timestamp: timestamp ?? DateTime.now(),
    faults: {
      faultHeadSway: FaultResult(
        value: finiteOrNull(head.lateral),
        threshold: swayThreshold,
        flagged: head.flagged,
      ),
      faultReversePivot: FaultResult(
        value: finiteOrNull(pivot.reverse),
        threshold: reversePivotThreshold,
        flagged: pivot.flagged,
      ),
      faultEarlyExtension: FaultResult(
        value: finiteOrNull(extension.rise),
        threshold: earlyExtensionThreshold,
        flagged: extension.flagged,
      ),
      faultLossOfPosture: FaultResult(
        value: finiteOrNull(posture.straighten),
        threshold: postureThreshold,
        flagged: posture.flagged,
      ),
    },
    tempoRatio: tempo == null ? null : finiteOrNull(tempo.ratio),
    targeting: targeting,
    fps: fps == null ? null : finiteOrNull(fps),
    frameCount: frameCount,
    handedness: handedness,
    poseCoverageFraction:
        poseCoverageFraction == null ? null : finiteOrNull(poseCoverageFraction),
    frames: frames,
    participantId: participantId,
    captureSessionId: captureSessionId,
    appVersion: appVersion,
    valueBasis: valueBasis,
    thresholdBasis: thresholdBasis,
    swingKind: swingKind,
    // Only meaningful on a calibration swing; dropped otherwise so a stale
    // picker value cannot mislabel a natural swing.
    calibrationFault:
        swingKind == SwingKind.calibration ? calibrationFault : null,
    clipName: clipName,
  );
}

enum Trend { improved, worsened, unchanged }

/// Did the fault flag flip between sessions? Computed but not rendered — see the
/// guardrail note on [SwingComparison.between].
enum Crossing {
  /// Was flagged, now under the threshold.
  faultFixed,

  /// Newly over the threshold.
  faultNew,
}

/// One fault's previous -> current change.
class FaultComparison {
  final String faultId;
  final double previous;
  final double current;
  final Trend trend;
  final Crossing? crossing;
  final bool flagged;
  final double threshold;

  const FaultComparison({
    required this.faultId,
    required this.previous,
    required this.current,
    required this.trend,
    required this.crossing,
    required this.flagged,
    required this.threshold,
  });

  /// Display label, e.g. "Head sway".
  String get label => faultLabels[faultId] ?? faultId;

  /// "0.18 -> 0.09 torso-lengths", matching the Python report line.
  String get valuesText => '${formatFaultValue(faultId, previous)} -> '
      '${formatFaultValue(faultId, current)} ${faultUnits[faultId]}';
}

/// Tempo ratio previous -> current, judged by distance from [tempoIdeal].
class TempoComparison {
  final double previous;
  final double current;
  final Trend trend;

  const TempoComparison({
    required this.previous,
    required this.current,
    required this.trend,
  });

  String get valuesText =>
      '${previous.toStringAsFixed(1)}:1 -> ${current.toStringAsFixed(1)}:1';
}

/// The full progress report between two sessions.
class SwingComparison {
  final SwingSession previousSession;
  final SwingSession currentSession;
  final List<FaultComparison> faults;
  final TempoComparison? tempo;

  const SwingComparison({
    required this.previousSession,
    required this.currentSession,
    required this.faults,
    required this.tempo,
  });

  /// Fault ids flagged now but not in the previous session.
  List<String> get newFaults => [
        for (final f in faults)
          if (f.crossing == Crossing.faultNew) f.faultId
      ];

  /// Fault ids flagged before but cleared now.
  List<String> get fixedFaults => [
        for (final f in faults)
          if (f.crossing == Crossing.faultFixed) f.faultId
      ];

  /// The fault the golfer said they were working on last session, if any.
  String? get focusFault => previousSession.targeting;

  /// Pair up two sessions' measurements.
  ///
  /// GUARDRAIL — the [Trend] and [Crossing] values this computes are
  /// intentionally **computed but not rendered**. The report's comparison card
  /// (`ui/widgets/swing_comparison_view.dart`) shows previous -> current values
  /// only; it deliberately does not surface trend, `newFaults`, `fixedFaults`,
  /// or the FIXED/NEW badges.
  ///
  /// Reason: the fault thresholds have never been validated against a real
  /// corpus, so "improved", "fixed", and "new fault" are conclusions the data
  /// cannot support — a threshold crossing may be measurement noise rather than
  /// a change in the golfer's swing. The machinery is kept (and stays tested) so
  /// it can be switched back on once the beta has accumulated enough swings to
  /// validate the thresholds. Do not re-surface it in the UI before then.
  factory SwingComparison.between(SwingSession previous, SwingSession current) {
    final faults = <FaultComparison>[];
    for (final faultId in faultIds) {
      final prev = previous.faults[faultId];
      final curr = current.faults[faultId];
      if (prev == null || curr == null) continue;
      final prevValue = prev.value, currValue = curr.value;
      if (prevValue == null || currValue == null) continue;

      final epsilon = _faultEpsilons[faultId]!;
      final delta = currValue - prevValue;
      final trend = delta.abs() < epsilon
          ? Trend.unchanged
          : (delta < 0 ? Trend.improved : Trend.worsened);
      Crossing? crossing;
      if (prev.flagged && !curr.flagged) {
        crossing = Crossing.faultFixed;
      } else if (curr.flagged && !prev.flagged) {
        crossing = Crossing.faultNew;
      }
      faults.add(FaultComparison(
        faultId: faultId,
        previous: prevValue,
        current: currValue,
        trend: trend,
        crossing: crossing,
        flagged: curr.flagged,
        threshold: curr.threshold,
      ));
    }

    TempoComparison? tempo;
    final prevRatio = previous.tempoRatio, currRatio = current.tempoRatio;
    if (prevRatio != null && currRatio != null) {
      final drift =
          (currRatio - tempoIdeal).abs() - (prevRatio - tempoIdeal).abs();
      tempo = TempoComparison(
        previous: prevRatio,
        current: currRatio,
        trend: drift.abs() < _tempoEpsilon
            ? Trend.unchanged
            : (drift < 0 ? Trend.improved : Trend.worsened),
      );
    }

    return SwingComparison(
      previousSession: previous,
      currentSession: current,
      faults: faults,
      tempo: tempo,
    );
  }
}

// Persistence lives in `swing_history_store.dart` — see [SwingHistoryStore]
// there for the on-disk format, the corrupt-file recovery, and why appends are
// line-oriented rather than a whole-file rewrite.
