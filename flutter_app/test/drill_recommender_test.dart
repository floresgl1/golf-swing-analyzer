import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/drill_recommender.dart';
import 'package:golf_swing_analyzer/src/analysis/faults.dart';

/// Loads the real bundled drill library from disk (not via rootBundle) so the
/// parsing + recommendation logic can be tested without a Flutter engine.
void main() {
  final json = jsonDecode(
    File('assets/drills.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final drills = parseDrillLibrary(json);

  test('library parses with 3 drills per fault', () {
    expect(drills.length, 12);
    for (final fault in const [
      faultHeadSway,
      faultReversePivot,
      faultEarlyExtension,
      faultLossOfPosture,
    ]) {
      expect(drills.where((d) => d.fault == fault).length, 3,
          reason: 'expected 3 drills for $fault');
    }
  });

  test('drillsForFault sorts beginner -> intermediate -> advanced', () {
    final ds = drillsForFault(faultHeadSway, drills);
    expect(ds.map((d) => d.difficulty).toList(),
        ['beginner', 'intermediate', 'advanced']);
  });

  test('recommendDrills only returns flagged faults', () {
    final recs = recommendDrills([faultHeadSway, faultLossOfPosture], drills);
    expect(recs.keys.toSet(), {faultHeadSway, faultLossOfPosture});
    expect(recs[faultHeadSway], isNotEmpty);
  });

  test('no flagged faults -> no recommendations', () {
    expect(recommendDrills(const [], drills), isEmpty);
  });
}
