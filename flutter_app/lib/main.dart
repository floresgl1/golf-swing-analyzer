import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'src/models/drill.dart';
import 'src/services/drill_library_loader.dart';
import 'src/ui/record_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load the bundled drill library and the device cameras once at startup.
  final drills = await loadDrillLibrary();
  List<CameraDescription> cameras;
  try {
    cameras = await availableCameras();
  } on CameraException {
    cameras = const [];
  }

  runApp(GolfSwingApp(drills: drills, cameras: cameras));
}

class GolfSwingApp extends StatelessWidget {
  const GolfSwingApp({
    super.key,
    required this.drills,
    required this.cameras,
  });

  final List<Drill> drills;
  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Golf Swing Analyzer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: RecordScreen(drills: drills, cameras: cameras),
    );
  }
}
