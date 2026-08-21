import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'src/analysis/participant.dart';
import 'src/models/drill.dart';
import 'src/services/drill_library_loader.dart';
import 'src/ui/record_screen.dart';
import 'src/ui/theme/app_theme.dart';

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

  // Anonymous local identity, so swings can be grouped by golfer, plus an id
  // for this sitting, so they can be grouped by visit. A storage failure must
  // not stop the app starting: it costs the link to earlier swings for this
  // launch, which is worth far less than being able to record at all.
  ParticipantStore? participantStore;
  Participant participant;
  try {
    final dir = await getApplicationDocumentsDirectory();
    participantStore =
        ParticipantStore(File(p.join(dir.path, 'participant.json')));
    participant = await participantStore.loadOrCreate();
  } catch (_) {
    participantStore = null;
    participant = Participant.generate();
  }

  runApp(GolfSwingApp(
    drills: drills,
    cameras: cameras,
    participant: participant,
    participantStore: participantStore,
    captureSession: CaptureSession.start(),
  ));
}

class GolfSwingApp extends StatelessWidget {
  const GolfSwingApp({
    super.key,
    required this.drills,
    required this.cameras,
    required this.participant,
    required this.participantStore,
    required this.captureSession,
  });

  final List<Drill> drills;
  final List<CameraDescription> cameras;

  /// The anonymous local golfer record.
  final Participant participant;

  /// Null when device storage was unavailable at startup; the profile screen
  /// then shows values that cannot be saved.
  final ParticipantStore? participantStore;

  /// Identifies this run of the app, grouping the swings recorded in it.
  final CaptureSession captureSession;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fore Swing',
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      darkTheme: appTheme,
      home: RecordScreen(
        drills: drills,
        cameras: cameras,
        participant: participant,
        participantStore: participantStore,
        captureSession: captureSession,
      ),
    );
  }
}
