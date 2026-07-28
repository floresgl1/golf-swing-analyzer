/// Swing session history: local persistence and swing-over-swing comparison,
/// ported from `src/swing_history.py` (the verification loop).
///
/// After each analysis the app appends a [SwingSession] to a JSON file on the
/// device, then compares it against the previous session: per fault, previous
/// value -> current value, whether it improved/worsened/stayed put, and
/// whether it crossed the fault threshold in either direction.
///
/// The trend and threshold-crossing parts of that comparison are computed here
/// but **not rendered** — see the guardrail note on [SwingComparison.between].
///
/// Pure Dart (no Flutter imports) so the logic stays unit-testable; the
/// report-screen UI lives in `ui/widgets/swing_comparison_view.dart`. The
/// stored file has the same shape as the Python pipeline's
/// `data/swing_history.json`, so histories are interchangeable across the two
/// implementations.
///
/// All four fault metrics measure excess motion, so for every fault a LOWER
/// value is better. Tempo is judged by distance from the ~3:1 tour benchmark.
library;

import 'dart:convert';
import 'dart:io';

import 'drill_recommender.dart';
import 'faults.dart';
import 'swing_phases.dart';

export 'drill_recommender.dart' show faultLabels;

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
class SwingSession {
  final DateTime timestamp;
  final Map<String, FaultResult> faults;
  final double? tempoRatio;
  final String? targeting;

  /// The raw map this was parsed from, kept so top-level keys the model doesn't
  /// know (e.g. a field a future Python writer adds) survive a load/save
  /// round-trip. Empty for instances built in code rather than read from JSON.
  final Map<String, dynamic> _source;

  const SwingSession({
    required this.timestamp,
    required this.faults,
    this.tempoRatio,
    this.targeting,
    Map<String, dynamic> source = const <String, dynamic>{},
  }) : _source = source;

  factory SwingSession.fromJson(Map<String, dynamic> json) => SwingSession(
        timestamp: DateTime.parse(json['timestamp'] as String),
        faults: (json['faults'] as Map<String, dynamic>).map(
          (id, result) => MapEntry(
              id, FaultResult.fromJson(result as Map<String, dynamic>)),
        ),
        tempoRatio: (json['tempo_ratio'] as num?)?.toDouble(),
        targeting: json['targeting'] as String?,
        source: json,
      );

  /// The raw source with the typed fields merged over it -- faults are
  /// re-emitted so each fault's own unknown keys are preserved too -- so
  /// nothing a reader didn't model is dropped on write.
  Map<String, dynamic> toJson() => {
        ..._source,
        'timestamp': timestamp.toIso8601String(),
        'faults': faults.map((id, result) => MapEntry(id, result.toJson())),
        'tempo_ratio': tempoRatio,
        'targeting': targeting,
      };
}

/// Build a history entry from one run of the fault detectors, the counterpart
/// of `build_session` in `src/swing_history.py`. Non-finite measurements are
/// stored as null.
SwingSession buildSession({
  required HeadMovementResult head,
  required ReversePivotResult pivot,
  required EarlyExtensionResult extension,
  required LossOfPostureResult posture,
  SwingTempo? tempo,
  String? targeting,
  DateTime? timestamp,
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

  double get delta => current - previous;

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

/// Loads and appends swing sessions in a JSON file on the device.
///
/// In the app, build the store with a file under the app documents directory
/// (package `path_provider`):
///
/// ```dart
/// final dir = await getApplicationDocumentsDirectory();
/// final store = SwingHistoryStore(File(p.join(dir.path, 'swing_history.json')));
/// final comparison = await store.append(session); // null on the first swing
/// ```
class SwingHistoryStore {
  final File file;

  SwingHistoryStore(this.file);

  /// All stored sessions, oldest first ([] if there is no history yet).
  Future<List<SwingSession>> load() async {
    if (!await file.exists()) return [];
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final sessions = data['sessions'] as List<dynamic>? ?? [];
    return [
      for (final s in sessions)
        SwingSession.fromJson(s as Map<String, dynamic>)
    ];
  }

  /// Append [session] to the history and return its comparison against the
  /// previously latest session, or null when this is the first swing.
  Future<SwingComparison?> append(SwingSession session) async {
    final sessions = await load();
    final previous = sessions.isEmpty ? null : sessions.last;
    sessions.add(session);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'sessions': [for (final s in sessions) s.toJson()],
    }));
    return previous == null
        ? null
        : SwingComparison.between(previous, session);
  }
}
