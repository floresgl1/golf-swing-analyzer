/// Loads the bundled drill library asset and parses it into [Drill]s.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import '../analysis/drill_recommender.dart';
import '../models/drill.dart';

/// Path of the bundled drill library (declared under `assets/` in pubspec.yaml).
const String drillAssetPath = 'assets/drills.json';

/// Load and parse the drill library from the app bundle.
///
/// A corrupt or malformed `drills.json` must not take down app startup: on any
/// parse failure this logs a warning and falls back to an empty drill list so
/// recommendations degrade to "no drills in the library".
Future<List<Drill>> loadDrillLibrary() async {
  final raw = await rootBundle.loadString(drillAssetPath);
  try {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return parseDrillLibrary(json);
  } catch (e) {
    debugPrint('Could not load drill library $drillAssetPath ($e) -- '
        'continuing with an empty drill list.');
    return const <Drill>[];
  }
}
