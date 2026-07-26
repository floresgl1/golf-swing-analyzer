# Golf Swing Analyzer

Analyze a golf swing from video: estimate body pose, detect swing phases and
tempo, flag four common faults, and recommend corrective drills.

The project has **two parts** that share the same analysis design:

| Part | Location | Role |
| --- | --- | --- |
| **Python prototype** | repo root (`src/`, `data/`) | Reference implementation and research playground — where the detection logic was developed and tuned. |
| **Flutter app** | [`flutter_app/`](flutter_app/) | Cross-platform (Android/iOS) MVP that ports the same logic to Dart and runs it on-device from a recorded swing. |

## How the two relate

The Flutter app is a faithful port of the Python detection logic — the same
algorithms, thresholds, and normalization, re-expressed in pure Dart. The Python
side is the source of truth; the Dart port is verified against it (the Flutter
unit tests use synthetic swings whose expected results were cross-checked against
the Python detectors).

| Concern | Python (`src/`) | Dart (`flutter_app/lib/src/analysis/`) |
| --- | --- | --- |
| Pose estimation | MediaPipe Tasks (`pose_estimation.py`) | ML Kit (`services/pose_estimator.dart`) |
| Swing phases + tempo | `swing_phases.py` | `swing_phases.dart` |
| Fault detectors (×4) | `faults.py` | `faults.dart` |
| Drill recommendation | `drill_recommender.py` | `drill_recommender.dart` |
| Drill library | `data/drills.json` | bundled `flutter_app/assets/drills.json` |
| Swing history + value comparison | `swing_history.py` (`data/swing_history.json`) | `swing_history.dart` (app documents dir) |

The four faults — **head sway, reverse pivot, early extension, loss of
posture** — are all measured against torso length (so thresholds are
resolution- and size-independent) using median windows at address and impact.

## Python prototype

Scripts under `src/` process a video with MediaPipe and print/plot results.

```bash
pip install -r requirements.txt
# Place a swing video at data/videos/videoplayback.mp4 and the pose model at
# data/pose_landmarker.task (both are git-ignored as large binaries).
cd src
python swing_phases.py     # detect phases + tempo, plot wrist trajectory
python faults.py           # fault report + drill recommendations
python pose_estimation.py  # render an annotated skeleton video
```

Modules:

- `pose_estimation.py` — MediaPipe pose estimation, skeleton overlay (33 keypoints)
- `swing_phases.py` — swing phases from the lead-wrist trajectory, plus tempo
- `faults.py` — the four fault detectors; prints a report and recommends drills
- `drill_recommender.py` — loads `data/drills.json`, recommends drills for flagged faults
- `data/drills.json` — 12 drills (3 per fault), instructor-editable

## Flutter app

A "record then analyze" MVP: record a swing, extract frames, run on-device pose
estimation, then show a report with fault verdicts and drills. See
[`flutter_app/README.md`](flutter_app/README.md) for the required Flutter SDK
version, camera-permission setup for iOS/Android, and build/run/test steps.

## Editing the drill library

Both parts read the same JSON format. Golf instructors can add or edit drills by
editing the `drills.json` file (Python: `data/drills.json`; Flutter:
`flutter_app/assets/drills.json`) — the header comment lists the allowed `fault`
and `difficulty` values. Keep the two copies in sync when changing drills.
