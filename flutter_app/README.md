# Golf Swing Analyzer — Flutter MVP

A cross-platform (Android/iOS) port of the Python golf swing analyzer. It
follows a **record → analyze** flow: record one swing with the device camera,
then run on-device pose estimation, phase detection, fault detection, and drill
recommendation, and show a report. Real-time analysis is intentionally out of
scope for this MVP.

## Pipeline

```
RecordScreen (camera)  ->  video file
        │
        ▼
FrameExtractor (ffmpeg)          extract every frame as JPEG + read fps
        │
        ▼
PoseEstimator (ML Kit)           per-frame landmarks -> eye/shoulder/hip
        │                        midpoints, torso length, lead-wrist y
        ▼
SwingAnalyzer                    assemble trajectory arrays, then:
   detectPhases  ->  swingTempo
   detectHeadMovement / detectReversePivot /
   detectEarlyExtension / detectLossOfPosture
   recommendDrills (from bundled assets/drills.json)
        │
        ▼
ReportScreen                     tempo + 4 fault verdicts + drills per fault
```

## What was ported from Python

The detection logic is a faithful, line-by-line port. It is **pure Dart** (no
Flutter imports) so it is unit-testable off-device and matches the Python
numerically.

| Python (`src/`) | Dart (`lib/src/analysis/`) |
| --- | --- |
| `swing_phases.py` → `detect_phases`, `swing_tempo`, `_moving_average` | `swing_phases.dart`, `num_utils.dart` |
| `faults.py` → 4 detectors, `_addr_median`, `_window_median`, `_spine_tilt` | `faults.dart` |
| `drill_recommender.py` → load + recommend | `drill_recommender.dart` |
| `data/drills.json` | `assets/drills.json` (bundled) |

Key details preserved exactly:

- **Torso-length normalization** — every fault metric is divided by the
  shoulder→hip distance measured at address, so thresholds are resolution- and
  size-independent.
- **Median windowing** — address values use the median over the 10 frames
  ending at the takeaway; impact/top/finish use a small median window (radius 2
  for head/pelvis at impact, radius 3 otherwise) so one bad frame can't flip a
  verdict.
- **Thresholds** — sway `0.13`, dip `0.25` (informational), reverse pivot
  `0.12`, early extension `0.10`, loss of posture `12°`.
- **Phase detection** — interpolate missing frames, smooth wrist *height*
  (`1 − y`) with an edge-padded moving average, then locate the first tall peak
  (top), the following trough (impact), and the later peak (finish).

Coordinate note: MediaPipe landmarks are normalized (0..1); ML Kit landmarks are
already in image pixels. Because every detector normalizes by torso length and
phase detection depends only on the trajectory's shape, the change of units
requires no code change.

### Cross-checked against Python

The Dart unit tests in `test/` use synthetic swings whose expected phase indices
and fault verdicts were verified against the original Python detectors
(`top=29, impact=45, finish=60`; sway/early-extension/posture/reverse-pivot all
flag at the constructed magnitudes). Run them with `flutter test`.

## Building and running

This repo contains the Dart/Flutter source and assets. Generate the platform
folders and fetch packages before the first run:

```bash
cd flutter_app
flutter create .          # generates android/ and ios/ around this source
flutter pub get
flutter run                # on a connected device (camera is required)
```

### Permissions

Add the camera permission to each platform after `flutter create`:

- **Android** — `android/app/src/main/AndroidManifest.xml`:
  ```xml
  <uses-permission android:name="android.permission.CAMERA"/>
  ```
  and set `minSdkVersion 21` (ML Kit) / `24` (ffmpeg) in
  `android/app/build.gradle`.
- **iOS** — `ios/Runner/Info.plist`:
  ```xml
  <key>NSCameraUsageDescription</key>
  <string>Record your golf swing for analysis.</string>
  ```

## Editing the drill library

`assets/drills.json` is the same instructor-editable format as the Python
project: add or edit entries and rebuild. The header comment in the file lists
the allowed `fault` and `difficulty` values.

## Notes / next steps

- `detectReversePivot` omits the Python function's `head_y`/`hip_y` arguments,
  which existed only to draw debug overlay points — the computed `reverse` value
  is identical.
- Frame extraction dumps all frames to a temp dir and deletes them after
  analysis. For long clips, sampling every Nth frame would cut analysis time.
- A future iteration could move to the camera image stream for real-time
  feedback; the pure-Dart detectors would be reused unchanged.
