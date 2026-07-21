/// Loads the bundled drill library asset and parses it into [Drill]s.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../analysis/drill_recommender.dart';
import '../models/drill.dart';

/// Path of the bundled drill library (declared under `assets/` in pubspec.yaml).
const String drillAssetPath = 'assets/drills.json';

/// Load and parse the drill library from the app bundle.
Future<List<Drill>> loadDrillLibrary() async {
  final raw = await rootBundle.loadString(drillAssetPath);
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return parseDrillLibrary(json);
}
