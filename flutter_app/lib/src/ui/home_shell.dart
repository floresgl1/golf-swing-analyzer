import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../analysis/participant.dart';
import '../models/drill.dart';
import 'profile_screen.dart';
import 'record_screen.dart';
import 'swings_screen.dart';
import 'theme/app_theme.dart';

/// Three-tab navigation shell: Record / Swings / Profile.
///
/// Camera-first by design — the app opens on the Record tab (index 0), which
/// is the viewfinder. This is a deliberate product choice, not an accident of
/// the original push-only routing. See ROADMAP.md item 7.
///
/// An [IndexedStack] keeps all three tabs alive so the camera controller
/// survives tab switches without reinitializing.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.drills,
    required this.cameras,
    required this.participant,
    required this.participantStore,
    required this.captureSession,
  });

  final List<Drill> drills;
  final List<CameraDescription> cameras;
  final Participant participant;

  /// Null when device storage was unavailable at startup.
  final ParticipantStore? participantStore;

  /// Groups every swing recorded in this run of the app.
  final CaptureSession captureSession;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _currentIndex = 0;

  /// The live participant record — updated when Profile saves changes, so
  /// RecordScreen picks up the new participant id and (eventually) handedness
  /// without an app restart.
  late Participant _participant = widget.participant;

  void _onParticipantChanged(Participant updated) {
    setState(() => _participant = updated);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          RecordScreen(
            drills: widget.drills,
            cameras: widget.cameras,
            participant: _participant,
            captureSession: widget.captureSession,
          ),
          const SwingsScreen(),
          ProfileScreen(
            participant: _participant,
            store: widget.participantStore,
            onParticipantChanged: _onParticipantChanged,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.videocam_outlined),
            selectedIcon: Icon(Icons.videocam),
            label: 'Record',
          ),
          NavigationDestination(
            icon: Icon(Icons.format_list_bulleted_outlined),
            selectedIcon: Icon(Icons.format_list_bulleted),
            label: 'Swings',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
