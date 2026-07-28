/// Drill recommendation, ported from `src/drill_recommender.py`.
///
/// Parsing the bundled JSON is separated from the recommendation logic so the
/// logic stays pure and testable; loading the asset lives in
/// `services/drill_library_loader.dart`.
library;

import '../models/drill.dart';
import 'faults.dart';

/// Sort order for recommendations: gentlest first.
const Map<String, int> difficultyOrder = {
  'beginner': 0,
  'intermediate': 1,
  'advanced': 2,
};

/// Human-friendly labels for the fault ids.
const Map<String, String> faultLabels = {
  faultHeadSway: 'Head sway',
  faultReversePivot: 'Reverse pivot',
  faultEarlyExtension: 'Early extension',
  faultLossOfPosture: 'Loss of posture',
};

/// Parse the drill library JSON (the decoded top-level map of `drills.json`)
/// into a list of [Drill]s.
List<Drill> parseDrillLibrary(Map<String, dynamic> json) {
  final raw = (json['drills'] as List<dynamic>? ?? const []);
  return raw
      .whereType<Map<String, dynamic>>()
      .map(Drill.fromJson)
      .toList(growable: false);
}

/// Return the drills addressing [faultId], sorted beginner→advanced.
List<Drill> drillsForFault(String faultId, List<Drill> drills) {
  final matches = drills.where((d) => d.fault == faultId).toList();
  matches.sort((a, b) {
    final ra = difficultyOrder[a.difficulty] ?? 99;
    final rb = difficultyOrder[b.difficulty] ?? 99;
    return ra.compareTo(rb);
  });
  return matches;
}

/// Map each flagged fault id to its recommended drills (easiest first).
///
/// [flaggedFaultIds] should contain only the ids that were actually flagged.
/// Direct port of `recommend_drills`.
Map<String, List<Drill>> recommendDrills(
  Iterable<String> flaggedFaultIds,
  List<Drill> drills,
) {
  final recommendations = <String, List<Drill>>{};
  for (final faultId in flaggedFaultIds) {
    recommendations[faultId] = drillsForFault(faultId, drills);
  }
  return recommendations;
}
